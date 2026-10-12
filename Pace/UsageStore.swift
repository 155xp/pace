import AppKit
import WidgetKit

/// Fetches usage as cheaply as possible. A provider is refreshed shortly after
/// its tool writes to disk (you're using it), at most once per `minimumGap`.
/// Everything else is covered by a slow sweep that stops while the screens sleep.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot
    @Published private(set) var lastRefresh: Date?
    /// Providers turned off from the menu. They aren't fetched or shown anywhere.
    @Published private(set) var hidden: Set<Provider>

    private let fetchers: [UsageFetcher] = [ClaudeFetcher(), CodexFetcher(), CursorFetcher()]
    private var watcher: ActivityWatcher?
    private var sweep: Timer?
    private var pending: [Provider: Timer] = [:]
    private var lastFetch: [Provider: Date] = [:]
    /// After a 429 a provider is left alone until `until`, doubling each time.
    private var backoff: [Provider: (until: Date, step: TimeInterval)] = [:]
    private var inFlight = false
    private var queued: Set<Provider> = []
    private var screensAsleep = false

    /// Usage from other devices or the web only shows up through the sweep.
    private var sweepInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 30 * 60 : 15 * 60
    }

    /// Claude's usage endpoint has a tight rate limit shared with Claude Code
    /// itself. Cursor's pools are monthly, so it needs far fewer checks.
    private func minimumGap(_ provider: Provider) -> TimeInterval {
        provider == .cursor ? 5 * 60 : 2 * 60
    }

    init() {
        snapshot = SnapshotStore.load() ?? Snapshot()
        hidden = Set((UserDefaults.standard.stringArray(forKey: "hiddenProviders") ?? []).compactMap(Provider.init))
        snapshot.providers.removeAll { hidden.contains($0.provider) }
    }

    func start() {
        refreshAll()
        // FSEvents delivers on the main queue.
        watcher = ActivityWatcher { [weak self] provider in
            MainActor.assumeIsolated { self?.noteActivity(provider) }
        }
        scheduleSweep()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSweep() }
        }
    }

    func refreshAll() {
        Task { await refresh(Set(Provider.allCases)) }
    }

    /// Refreshes the providers whose numbers are older than `minimumAge` seconds.
    func refresh(ifOlderThan minimumAge: TimeInterval) {
        let stale = Provider.allCases.filter { Date().timeIntervalSince(lastFetch[$0] ?? .distantPast) > minimumAge }
        if !stale.isEmpty { Task { await refresh(Set(stale)) } }
    }

    func setHidden(_ provider: Provider, _ hide: Bool) {
        if hide { hidden.insert(provider) } else { hidden.remove(provider) }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: "hiddenProviders")
        if hide {
            var next = snapshot
            next.providers.removeAll { $0.provider == provider }
            publish(next)
        } else {
            Task { await refresh([provider]) }
        }
    }

    private func pause() {
        screensAsleep = true
        sweep?.invalidate()
        sweep = nil
        pending.values.forEach { $0.invalidate() }
        pending = [:]
    }

    private func resume() {
        guard screensAsleep || sweep == nil else { return }
        screensAsleep = false
        refreshAll()
        scheduleSweep()
    }

    private func scheduleSweep() {
        sweep?.invalidate()
        guard !screensAsleep else { return }
        let timer = Timer(timeInterval: sweepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        sweep = timer
    }

    /// A tool wrote to disk. Refresh it a little later, once the burst settles
    /// and the provider has counted the usage.
    private func noteActivity(_ provider: Provider) {
        guard !screensAsleep, !hidden.contains(provider), pending[provider] == nil else { return }
        let earliest = max((lastFetch[provider] ?? .distantPast).addingTimeInterval(minimumGap(provider)),
                           backoff[provider]?.until ?? .distantPast)
        let timer = Timer(timeInterval: max(earliest.timeIntervalSinceNow, 10), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pending[provider] = nil
                Task { await self?.refresh([provider]) }
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pending[provider] = timer
    }

    func refresh(_ requested: Set<Provider>) async {
        let now = Date()
        let requested = requested.subtracting(hidden).filter { (backoff[$0]?.until ?? .distantPast) <= now }
        guard !requested.isEmpty else { return }
        guard !inFlight else {
            queued.formUnion(requested)
            return
        }
        inFlight = true
        defer {
            inFlight = false
            if !queued.isEmpty {
                let next = queued
                queued = []
                Task { await refresh(next) }
            }
        }

        let active = fetchers.filter { requested.contains($0.provider) }
        let results = await withTaskGroup(of: (Provider, Result<Fetched, Error>).self) { group in
            for fetcher in active {
                group.addTask {
                    do { return (fetcher.provider, .success(try await fetcher.fetch())) }
                    catch { return (fetcher.provider, .failure(error)) }
                }
            }
            var results: [Provider: Result<Fetched, Error>] = [:]
            for await (provider, result) in group { results[provider] = result }
            return results
        }

        var providers: [ProviderUsage] = []
        for provider in Provider.allCases where !hidden.contains(provider) {
            let previous = snapshot.providers.first { $0.provider == provider }
            guard requested.contains(provider) else {
                if let previous { providers.append(previous) }
                continue
            }
            lastFetch[provider] = now
            if case .failure(FetchError.rateLimited(let retryAfter)) = results[provider] {
                let step = min(max((backoff[provider]?.step ?? 60) * 2, 120), 30 * 60)
                backoff[provider] = (now.addingTimeInterval(max(retryAfter ?? step, step)), step)
            } else {
                backoff[provider] = nil
            }
            switch results[provider] {
            case .success(let fetched):
                if var previous, previous.updatedAt > fetched.asOf {
                    // A fallback came back with older numbers than the ones we have.
                    previous.error = "Couldn't refresh."
                    providers.append(previous)
                } else {
                    // Older numbers mean they came from a fallback (Codex's session logs).
                    let stale = now.timeIntervalSince(fetched.asOf) > 10 * 60
                    providers.append(ProviderUsage(provider: provider, windows: fetched.windows, updatedAt: fetched.asOf,
                                                   error: stale ? "Showing the last logged limits." : nil,
                                                   resetExpiries: fetched.resetExpiries ?? previous?.resetExpiries))
                }
            case .failure(FetchError.notConfigured), nil:
                continue
            case .failure(let error):
                var usage = previous ?? ProviderUsage(provider: provider, windows: [], updatedAt: .distantPast)
                usage.error = error.localizedDescription
                providers.append(usage)
            }
        }

        lastRefresh = now
        publish(Snapshot(providers: providers))
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        let changed = widgetFingerprint(next) != widgetFingerprint(snapshot)
        snapshot = next
        // The widget only needs a new file, and a reload from its budget, when
        // something it draws has moved.
        guard changed else { return }
        SnapshotStore.save(next)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func widgetFingerprint(_ snapshot: Snapshot) -> [String] {
        snapshot.providers.map { usage in
            let windows = usage.windows.map { "\($0.label) \(Int($0.usedPercent.rounded())) \(Int(($0.resetsAt?.timeIntervalSince1970 ?? 0) / 60))" }
            let resets = (usage.resetExpiries ?? []).map { "\(Int($0.timeIntervalSince1970 / 60))" }
            return "\(usage.provider.rawValue) \(windows) \(resets) \(usage.error != nil)"
        }
    }
}
