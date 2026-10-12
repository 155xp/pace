import AppKit
import SwiftUI

/// Draws SwiftUI views to images: the menu bar label at runtime, and
/// `Pace --render <dir> [--sample]` writes every surface to PNGs for review.
@MainActor
enum Renderer {
    static func image<V: View>(_ view: V, scale: CGFloat = 2) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    static func run(into dir: URL, sample: Bool) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let snapshot = sample ? sampleSnapshot(now) : liveSnapshot()

        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            let ink: Color = dark ? .white : .black
            let barBackground = dark ? Color(white: 0.16) : Color(white: 0.93)
            write(MenuBarLabel(snapshot: snapshot, date: now, colored: true, ink: ink)
                .padding(.horizontal, 10).frame(height: 24).background(barBackground)
                .environment(\.colorScheme, scheme), "menubar-\(suffix)", dir)
            write(PopoverContent(snapshot: snapshot, loaded: true, date: now)
                .background(dark ? Color(white: 0.17) : Color(white: 0.97))
                .environment(\.colorScheme, scheme), "popover-\(suffix)", dir)
            for (size, name, width, height) in [(WidgetSize.small, "small", 170.0, 170.0), (.medium, "medium", 364, 170), (.large, "large", 364, 382)] {
                write(PaceWidgetView(snapshot: snapshot, date: now, size: size)
                    .padding(16)
                    .frame(width: width, height: height)
                    .background(dark ? Color(white: 0.13) : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(20)
                    .background(dark ? Color(white: 0.3) : Color(white: 0.82))
                    .environment(\.colorScheme, scheme), "widget-\(name)-\(suffix)", dir)
            }
        }
    }

    private static func write<V: View>(_ view: V, _ name: String, _ dir: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private static func liveSnapshot() -> Snapshot {
        let store = UsageStore()
        var done = false
        Task { await store.refresh(); done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return store.snapshot
    }

    /// Covers every state: on track, running out, limited, rolled over.
    private static func sampleSnapshot(_ now: Date) -> Snapshot {
        let h: TimeInterval = 3600
        return Snapshot(providers: [
            ProviderUsage(provider: .claude, windows: [
                UsageWindow(label: "Session", usedPercent: 64, resetsAt: now.addingTimeInterval(3.2 * h), length: 5 * h),
                UsageWindow(label: "Week", usedPercent: 41, resetsAt: now.addingTimeInterval(4.6 * 24 * h), length: 168 * h),
            ], updatedAt: now),
            ProviderUsage(provider: .codex, windows: [
                UsageWindow(label: "Session", usedPercent: 100, resetsAt: now.addingTimeInterval(0.7 * h), length: 5 * h),
                UsageWindow(label: "Week", usedPercent: 22, resetsAt: now.addingTimeInterval(5.5 * 24 * h), length: 168 * h),
            ], updatedAt: now.addingTimeInterval(-40 * 60), error: "Couldn't refresh."),
            ProviderUsage(provider: .cursor, windows: [
                UsageWindow(label: "Month", usedPercent: 12, resetsAt: now.addingTimeInterval(27 * 24 * h), length: 31 * 24 * h),
            ], updatedAt: now),
        ])
    }
}
