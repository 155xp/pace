import CoreServices
import Foundation

/// Reports which tool you're using by watching where each one writes its
/// sessions. FSEvents batches changes in the kernel, so a busy session costs
/// one callback every few seconds and an idle Mac costs nothing.
final class ActivityWatcher {
    private var stream: FSEventStreamRef?
    private let roots: [(path: String, provider: Provider)]
    private let onActivity: (Provider) -> Void

    init(onActivity: @escaping (Provider) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        let claude = env["CLAUDE_CONFIG_DIR"] ?? home + "/.claude"
        let codex = env["CODEX_HOME"] ?? home + "/.codex"
        let candidates: [(String, Provider)] = [
            (claude + "/projects", .claude),
            (codex + "/sessions", .codex),
            (home + "/Library/Application Support/Cursor/User/globalStorage", .cursor),
            (home + "/.cursor/chats", .cursor),
        ]
        roots = candidates.filter { FileManager.default.fileExists(atPath: $0.0) }
        self.onActivity = onActivity
        start()
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func start() {
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var seen = Set<Provider>()
            for path in changed.prefix(count) {
                if let root = watcher.roots.first(where: { path.hasPrefix($0.path) }) { seen.insert(root.provider) }
            }
            seen.forEach(watcher.onActivity)
        }
        stream = FSEventStreamCreate(nil, callback, &context, roots.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }
}
