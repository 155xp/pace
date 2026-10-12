import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

struct UsageTimeline: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: SnapshotStore.load() ?? Snapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(placeholder(in: context))
    }

    /// The app reloads the timeline when numbers change. Between reloads the
    /// entries step the clock forward so countdowns, pace and rollovers stay current.
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = SnapshotStore.load() ?? Snapshot()
        let now = Date()
        let entries = (0..<12).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 300), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(3600))))
    }
}

struct PaceWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        PaceWidgetView(snapshot: entry.snapshot, date: entry.date, size: size)
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "pace://open"))
    }

    private var size: WidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemLarge, .systemExtraLarge: .large
        default: .medium
        }
    }
}

@main
struct PaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PaceUsage", provider: UsageTimeline()) { entry in
            PaceWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("Claude Code, Codex and Cursor usage, and whether you're on pace for each reset.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
