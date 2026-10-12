import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

/// One rate-limit window, e.g. Claude's 5-hour session or Cursor's billing month.
struct UsageWindow: Codable, Hashable, Identifiable {
    var id: String { label }
    var label: String
    var usedPercent: Double
    /// nil when the window isn't running, e.g. no active Claude session.
    var resetsAt: Date?
    var length: TimeInterval
}

struct ProviderUsage: Codable, Hashable, Identifiable {
    var id: Provider { provider }
    var provider: Provider
    var windows: [UsageWindow]
    /// When the numbers were last confirmed by the provider.
    var updatedAt: Date
    /// Set when the latest refresh failed; the windows are from an earlier one.
    var error: String?
}

struct Snapshot: Codable, Hashable {
    var providers: [ProviderUsage] = []
}

enum Pace: Hashable {
    case onTrack
    case runsOut(Date)
    case limited
}

extension UsageWindow {
    /// The window as it looks at `date`. A window whose reset has passed rolls
    /// over to a fresh one at 0%.
    func at(_ date: Date) -> UsageWindow {
        guard let resetsAt, date >= resetsAt else { return self }
        var next = self
        next.usedPercent = 0
        if length > 0 {
            let periods = (date.timeIntervalSince(resetsAt) / length).rounded(.down) + 1
            next.resetsAt = resetsAt.addingTimeInterval(periods * length)
        }
        return next
    }

    /// Fraction of the window that has elapsed at `date`.
    func elapsed(at date: Date) -> Double? {
        guard let resetsAt, length > 0 else { return nil }
        let start = resetsAt.addingTimeInterval(-length)
        return min(max(date.timeIntervalSince(start) / length, 0), 1)
    }

    /// Projects the current burn rate to the reset. The first 10% of a window
    /// is treated as if it had already passed, so one early burst doesn't read
    /// as a runaway pace, and landing within 5% of the limit still counts as
    /// on track.
    func pace(at date: Date) -> Pace? {
        guard resetsAt != nil, let elapsed = elapsed(at: date) else { return nil }
        if usedPercent >= 100 { return .limited }
        let elapsedSeconds = max(elapsed, 0.1) * length
        guard usedPercent > 0, usedPercent / max(elapsed, 0.1) > 105 else { return .onTrack }
        let ratePerSecond = usedPercent / elapsedSeconds
        return .runsOut(date.addingTimeInterval((100 - usedPercent) / ratePerSecond))
    }
}

extension ProviderUsage {
    /// The window closest to blocking you: a hit limit first, then the
    /// soonest projected run-out, then the highest usage.
    func tightest(at date: Date) -> UsageWindow? {
        let current = windows.map { $0.at(date) }
        func rank(_ w: UsageWindow) -> (Int, Double) {
            switch w.pace(at: date) {
            case .limited: (2, w.usedPercent)
            case .runsOut(let d): (1, -d.timeIntervalSince(date))
            default: (0, w.usedPercent)
            }
        }
        return current.max { rank($0) < rank($1) }
    }
}

enum Format {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "45m", "3h 20m", "2d 4h"
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 1)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
        }
        let days = hours / 24
        let rest = hours % 24
        return rest == 0 ? "\(days)d" : "\(days)d \(rest)h"
    }

    /// "in 3h 20m" within a day, "Fri 9 PM" within a week, "Nov 9" after that.
    static func moment(_ target: Date, from now: Date) -> String {
        let seconds = target.timeIntervalSince(now)
        if seconds < 24 * 3600 { return "in " + duration(seconds) }
        if seconds < 6 * 24 * 3600 {
            return target.formatted(.dateTime.weekday(.abbreviated).hour())
        }
        return target.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Short form for tight spaces: "3h 20m", "Fri", "Nov 9".
    static func shortMoment(_ target: Date, from now: Date) -> String {
        let seconds = target.timeIntervalSince(now)
        if seconds < 24 * 3600 { return duration(seconds) }
        if seconds < 6 * 24 * 3600 { return target.formatted(.dateTime.weekday(.abbreviated)) }
        return target.formatted(.dateTime.month(.abbreviated).day())
    }

    static func reset(_ window: UsageWindow, from now: Date) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        return "Resets " + moment(resetsAt, from: now)
    }

    static func pace(_ pace: Pace?, from now: Date) -> String? {
        switch pace {
        case .onTrack: "On track"
        case .runsOut(let date): "Runs out " + moment(date, from: now)
        case .limited: "Limit reached"
        case nil: nil
        }
    }
}
