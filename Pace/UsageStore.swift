import AppKit
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot
    @Published private(set) var lastRefresh: Date?
    /// Providers turned off from the menu. They aren't fetched or shown anywhere.
    @Published private(set) var hidden: Set<Provider>

    private let fetchers: [UsageFetcher] = [ClaudeFetcher(), CodexFetcher(), CursorFetcher()]
    private var timer: Timer?
    private var refreshing = false
    private var refreshQueued = false

    init() {
        snapshot = SnapshotStore.load() ?? Snapshot()
        hidden = Set((UserDefaults.standard.stringArray(forKey: "hiddenProviders") ?? []).compactMap(Provider.init))
        snapshot.providers.removeAll { hidden.contains($0.provider) }
    }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Refreshes unless the last refresh was under `minimumAge` seconds ago.
    func refresh(ifOlderThan minimumAge: TimeInterval) {
        guard Date().timeIntervalSince(lastRefresh ?? .distantPast) > minimumAge else { return }
        Task { await refresh() }
    }

    func setHidden(_ provider: Provider, _ hide: Bool) {
        if hide { hidden.insert(provider) } else { hidden.remove(provider) }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: "hiddenProviders")
        if hide {
            var next = snapshot
            next.providers.removeAll { $0.provider == provider }
            publish(next)
        } else {
            Task { await refresh() }
        }
    }

    func refresh() async {
        guard !refreshing else {
            refreshQueued = true
            return
        }
        refreshing = true
        defer {
            refreshing = false
            if refreshQueued {
                refreshQueued = false
                Task { await refresh() }
            }
        }

        let active = fetchers.filter { !hidden.contains($0.provider) }
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
            switch results[provider] {
            case .success(let fetched):
                if var previous, previous.updatedAt > fetched.asOf {
                    // A fallback came back with older numbers than the ones we have.
                    previous.error = "Couldn't refresh."
                    providers.append(previous)
                } else {
                    // Older numbers mean they came from a fallback (Codex's session logs).
                    let stale = Date().timeIntervalSince(fetched.asOf) > 10 * 60
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

        lastRefresh = Date()
        publish(Snapshot(providers: providers))
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        let widgetChanged = widgetFingerprint(next) != widgetFingerprint(snapshot)
        snapshot = next
        SnapshotStore.save(next)
        // Widget reloads are budgeted, so only spend one when something visible moved.
        if widgetChanged { WidgetCenter.shared.reloadAllTimelines() }
    }

    private func widgetFingerprint(_ snapshot: Snapshot) -> [String] {
        snapshot.providers.flatMap { usage in
            usage.windows.map { "\(usage.provider.rawValue) \($0.label) \(Int($0.usedPercent.rounded())) \(Int(($0.resetsAt?.timeIntervalSince1970 ?? 0) / 60))" }
        }
    }
}
