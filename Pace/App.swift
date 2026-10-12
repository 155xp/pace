import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum PaceMain {
    @MainActor private static var delegate: AppDelegate?

    static func main() {
        MainActor.assumeIsolated {
            if let index = CommandLine.arguments.firstIndex(of: "--render") {
                let dir = CommandLine.arguments.dropFirst(index + 1).first ?? "."
                Renderer.run(into: URL(fileURLWithPath: dir), sample: CommandLine.arguments.contains("--sample"))
                return
            }
            let app = NSApplication.shared
            delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(store: store)
        store.start()

        // A menu bar app that feeds a widget is only useful while running, so
        // it opens at login unless you turn that off.
        if !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        }
    }

    /// Clicking the widget opens pace://, which shows the popover.
    func application(_ application: NSApplication, open urls: [URL]) {
        statusItem?.showPopover()
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: UsageStore
    private var subscription: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var ticker: Timer?

    init(store: UsageStore) {
        self.store = store
        super.init()

        let hosting = NSHostingController(rootView: PopoverView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.updateLabel() }
            }
        }
        subscription = store.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateLabel() }
        // Pace and rollovers depend on the clock, not just on new data.
        ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateLabel() }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item.button, !popover.isShown else { return }
        store.refresh(ifOlderThan: 30)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showMenu() {
        let menu = NSMenu()
        // Providers that aren't set up on this Mac are left out, unless they were turned off.
        let listed = Provider.allCases.filter { provider in
            store.hidden.contains(provider) || store.snapshot.providers.contains { $0.provider == provider }
        }
        for provider in listed {
            let item = menu.addItem(withTitle: provider.name, action: #selector(toggleProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = store.hidden.contains(provider) ? .off : .on
        }
        if !listed.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r").target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Pace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func refresh() {
        Task { await store.refresh() }
    }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = Provider(rawValue: raw) else { return }
        store.setHidden(provider, !store.hidden.contains(provider))
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    private func updateLabel() {
        guard let button = item.button else { return }
        let snapshot = store.snapshot
        guard !snapshot.providers.isEmpty else {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Pace")
            return
        }
        let now = Date()
        // Template images follow the menu bar's look. Color is only used when
        // something is off pace, so it has to pick its own ink.
        let warning = snapshot.providers.contains { usage in
            guard let pace = usage.tightest(at: now)?.pace(at: now) else { return false }
            return pace != .onTrack
        }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let label = MenuBarLabel(snapshot: snapshot, date: now, colored: warning, ink: warning && dark ? .white : .black)
            .environment(\.colorScheme, dark ? .dark : .light)
        guard let image = Renderer.image(label) else { return }
        image.isTemplate = !warning
        button.image = image
        button.setAccessibilityLabel(snapshot.providers.map { usage in
            let used = usage.tightest(at: now).map { Format.percent($0.usedPercent) } ?? "unknown"
            return "\(usage.provider.name) \(used)"
        }.joined(separator: ", "))
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    private var emptyMessage: String {
        if store.lastRefresh == nil { return "Loading…" }
        if !store.hidden.isEmpty { return "Everything is turned off. Right-click the menu bar item to turn providers back on." }
        return "No Claude Code, Codex or Cursor sign-in found on this Mac."
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PopoverContent(snapshot: store.snapshot, empty: emptyMessage, date: context.date)
        }
    }
}

struct PopoverContent: View {
    let snapshot: Snapshot
    let empty: String
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if snapshot.providers.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(snapshot.providers) { usage in
                ProviderSection(usage: usage, date: date)
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}
