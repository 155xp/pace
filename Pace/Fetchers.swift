import Foundation
import SQLite3

enum FetchError: LocalizedError {
    /// The tool isn't installed or signed in on this Mac. The provider is hidden.
    case notConfigured
    case signedOut(String)
    case http(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Not set up on this Mac."
        case .signedOut(let hint): hint
        case .http(let code): "Couldn't refresh (HTTP \(code))."
        case .unreadable: "Couldn't read the usage response."
        }
    }
}

struct Fetched {
    var windows: [UsageWindow]
    /// The time the numbers describe.
    var asOf: Date
    /// Expiry dates of unused limit resets. nil when unknown.
    var resetExpiries: [Date]? = nil
}

protocol UsageFetcher: Sendable {
    var provider: Provider { get }
    func fetch() async throws -> Fetched
}

private let home = FileManager.default.homeDirectoryForCurrentUser
private let hour: TimeInterval = 3600
private let week: TimeInterval = 7 * 24 * hour

private func getJSON(_ url: URL, headers: [String: String]) async throws -> [String: Any] {
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Pace/1.0", forHTTPHeaderField: "User-Agent")
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else { throw FetchError.http(status) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.unreadable }
    return json
}

private func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func number(_ value: Any?) -> Double? {
    switch value {
    case let n as NSNumber: n.doubleValue
    case let s as String: Double(s)
    default: nil
    }
}

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func isoDate(_ value: Any?) -> Date? {
    guard let s = value as? String else { return nil }
    return isoFractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

/// Names a window by its length: "Session" for 5 hours, "Week" for 7 days.
private func windowLabel(_ seconds: TimeInterval) -> String {
    switch seconds {
    case 5 * hour: "Session"
    case week: "Week"
    case ..<(48 * hour): "\(Int(seconds / hour))h"
    default: "\(Int((seconds / (24 * hour)).rounded()))d"
    }
}

// MARK: - Claude Code

/// Reads Claude Code's OAuth token (keychain, or the credentials file on
/// setups without one) and asks the same endpoint `/usage` uses.
struct ClaudeFetcher: UsageFetcher {
    let provider = Provider.claude

    func fetch() async throws -> Fetched {
        guard let oauth = credentials()?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw FetchError.notConfigured }
        if let expires = number(oauth["expiresAt"]), Date(timeIntervalSince1970: expires / 1000) < Date() {
            throw FetchError.signedOut("Open Claude Code to refresh its sign-in.")
        }
        let json = try await getJSON(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ])
        return Fetched(windows: Self.windows(json), asOf: Date())
    }

    static func windows(_ json: [String: Any]) -> [UsageWindow] {
        func window(_ key: String, _ label: String, _ length: TimeInterval) -> UsageWindow? {
            guard let w = json[key] as? [String: Any], let used = number(w["utilization"]) else { return nil }
            return UsageWindow(label: label, usedPercent: used, resetsAt: isoDate(w["resets_at"]), length: length)
        }
        var windows = [window("five_hour", "Session", 5 * hour), window("seven_day", "Week", week)].compactMap { $0 }

        // Per-model weekly caps only matter when they're tighter than the overall week.
        let overall = windows.first { $0.label == "Week" }?.usedPercent ?? 0
        for limit in json["limits"] as? [[String: Any]] ?? [] where limit["kind"] as? String == "weekly_scoped" {
            guard let used = number(limit["percent"]), used > overall,
                  let scope = limit["scope"] as? [String: Any],
                  let model = (scope["model"] as? [String: Any])?["display_name"] as? String else { continue }
            windows.append(UsageWindow(label: "\(model) week", usedPercent: used, resetsAt: isoDate(limit["resets_at"]), length: week))
        }
        return windows
    }

    private func credentials() -> [String: Any]? {
        // /usr/bin/security created the item for Claude Code, so it can read it without a prompt.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude")
        return readJSON(configDir.appendingPathComponent(".credentials.json"))
    }
}

// MARK: - Codex

/// Uses the ChatGPT sign-in from Codex's auth.json. If the token has gone
/// stale, falls back to the rate limits Codex logs in its session files.
struct CodexFetcher: UsageFetcher {
    let provider = Provider.codex

    private var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
    }

    func fetch() async throws -> Fetched {
        guard let auth = readJSON(codexHome.appendingPathComponent("auth.json")),
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { throw FetchError.notConfigured }
        var headers = ["Authorization": "Bearer \(token)"]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        do {
            let json = try await getJSON(URL(string: "https://chatgpt.com/backend-api/wham/usage")!, headers: headers)
            let limits = json["rate_limit"] as? [String: Any] ?? [:]
            let windows = ["primary_window", "secondary_window"].compactMap { key -> UsageWindow? in
                guard let w = limits[key] as? [String: Any],
                      let used = number(w["used_percent"]),
                      let length = number(w["limit_window_seconds"]) else { return nil }
                let reset = number(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                return UsageWindow(label: windowLabel(length), usedPercent: used, resetsAt: reset, length: length)
            }
            return Fetched(windows: windows.sorted { $0.length < $1.length }, asOf: Date(),
                           resetExpiries: try? await resetExpiries(json, headers: headers))
        } catch {
            if let logged = loggedLimits() { return logged }
            throw error
        }
    }

    /// Codex grants free full resets that expire after 30 days. The usage
    /// response only has the count, so the dates need a second request.
    private func resetExpiries(_ usage: [String: Any], headers: [String: String]) async throws -> [Date] {
        let count = number((usage["rate_limit_reset_credits"] as? [String: Any])?["available_count"]) ?? 0
        guard count > 0 else { return [] }
        let json = try await getJSON(URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!, headers: headers)
        let credits = json["credits"] as? [[String: Any]] ?? []
        return credits
            .filter { $0["status"] as? String == "available" && $0["is_supported_by_plan"] as? Bool != false }
            .compactMap { isoDate($0["expires_at"]) }
            .sorted()
    }

    /// The newest `rate_limits` entry in the last few days of session logs.
    private func loggedLimits() -> Fetched? {
        let sessions = codexHome.appendingPathComponent("sessions")
        let calendar = Calendar(identifier: .gregorian)
        let files = (0..<4).flatMap { daysAgo -> [URL] in
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date())!
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        .filter { $0.pathExtension == "jsonl" }
        .sorted { modified($0) > modified($1) }

        for file in files.prefix(10) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = json["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any],
                      let asOf = isoDate(json["timestamp"]) else { continue }
                let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                    guard let w = limits[key] as? [String: Any],
                          let used = number(w["used_percent"]),
                          let minutes = number(w["window_minutes"]) else { return nil }
                    let reset = number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) }
                        ?? number(w["resets_in_seconds"]).map { asOf.addingTimeInterval($0) }
                    return UsageWindow(label: windowLabel(minutes * 60), usedPercent: used, resetsAt: reset, length: minutes * 60)
                }
                if !windows.isEmpty { return Fetched(windows: windows.sorted { $0.length < $1.length }, asOf: asOf) }
            }
        }
        return nil
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

// MARK: - Cursor

/// Reads the session token from Cursor's local state database and asks the
/// endpoint behind cursor.com/dashboard.
struct CursorFetcher: UsageFetcher {
    let provider = Provider.cursor

    func fetch() async throws -> Fetched {
        guard let token = accessToken() else { throw FetchError.notConfigured }
        guard let userID = userID(fromJWT: token) else { throw FetchError.signedOut("Sign in to Cursor again.") }
        let json = try await getJSON(URL(string: "https://cursor.com/api/usage-summary")!, headers: [
            "Cookie": "WorkosCursorSessionToken=\(userID)%3A%3A\(token)",
            "Origin": "https://cursor.com",
            "Referer": "https://cursor.com/dashboard",
        ])
        guard let start = isoDate(json["billingCycleStart"]), let end = isoDate(json["billingCycleEnd"]) else {
            throw FetchError.unreadable
        }
        let plan = (json["individualUsage"] as? [String: Any])?["plan"] as? [String: Any] ?? [:]
        let length = end.timeIntervalSince(start)
        // Cursor's own models (Auto, Composer) and named outside models draw from separate pools.
        var windows: [UsageWindow] = []
        if let auto = number(plan["autoPercentUsed"]) {
            windows.append(UsageWindow(label: "Auto + Composer", usedPercent: auto, resetsAt: end, length: length, shortLabel: "Auto"))
        }
        if let api = number(plan["apiPercentUsed"]) {
            windows.append(UsageWindow(label: "API", usedPercent: api, resetsAt: end, length: length))
        }
        if windows.isEmpty, let spent = number(plan["used"]), let limit = number(plan["limit"]), limit > 0 {
            windows.append(UsageWindow(label: "Month", usedPercent: spent / limit * 100, resetsAt: end, length: length))
        }
        guard !windows.isEmpty else { throw FetchError.unreadable }
        return Fetched(windows: windows, asOf: Date())
    }

    private func accessToken() -> String? {
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let token = String(cString: text)
        return token.isEmpty ? nil : token
    }

    /// The user ID is the part of the JWT subject after the identity provider,
    /// e.g. "google-oauth2|user_123" → "user_123".
    private func userID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = claims["sub"] as? String else { return nil }
        return subject.split(separator: "|").last.map(String.init)
    }
}
