import SwiftUI

enum WidgetSize {
    case small, medium, large
}

struct PaceWidgetView: View {
    let snapshot: Snapshot
    let date: Date
    let size: WidgetSize

    var body: some View {
        if snapshot.providers.isEmpty {
            Text("Open Pace to load your usage.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch size {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.providers.prefix(3).enumerated()), id: \.element.id) { index, usage in
                if index > 0 { Spacer(minLength: 6) }
                if let window = usage.tightest(at: date) {
                    HStack(alignment: .center, spacing: 9) {
                        ProviderIcon(provider: usage.provider, size: 15)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(Format.percent(window.usedPercent))
                                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                                Spacer(minLength: 4)
                                if let resetsAt = window.resetsAt {
                                    Text(Format.shortMoment(resetsAt, from: date))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            UsageBar(window: window, date: date, height: 4)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(snapshot.providers.prefix(3)) { usage in
                if let window = usage.tightest(at: date) {
                    let pace = window.pace(at: date)
                    VStack(alignment: .leading, spacing: 0) {
                        ProviderIcon(provider: usage.provider, size: 17)
                        Spacer(minLength: 8)
                        Text(Format.percent(window.usedPercent))
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                        UsageBar(window: window, date: date)
                            .padding(.top, 4)
                        Group {
                            if let resetsAt = window.resetsAt {
                                Text((window.shortLabel ?? window.label) + " · " + Format.shortMoment(resetsAt, from: date))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(window.shortLabel ?? window.label).foregroundStyle(.secondary)
                            }
                            if let text = Format.pace(pace, from: date).map(shortPace) {
                                Text(text)
                                    .foregroundStyle(pace == .onTrack ? AnyShapeStyle(.secondary) : AnyShapeStyle(pace.color))
                            }
                        }
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .padding(.top, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.providers.enumerated()), id: \.element.id) { index, usage in
                if index > 0 { Spacer(minLength: 12) }
                ProviderSection(usage: usage, date: date, compact: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// "Runs out in 2h 10m" doesn't fit a medium column; "Out in 2h 10m" does.
    private func shortPace(_ text: String) -> String {
        text.replacingOccurrences(of: "Runs out", with: "Out")
    }
}
