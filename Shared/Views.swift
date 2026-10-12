import SwiftUI

extension Provider {
    var tint: AnyShapeStyle {
        switch self {
        case .claude:
            AnyShapeStyle(Color(red: 0.851, green: 0.467, blue: 0.341))
        case .codex:
            AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.69, green: 0.65, blue: 1), Color(red: 0.48, green: 0.62, blue: 1), Color(red: 0.22, green: 0.25, blue: 1)],
                startPoint: .top, endPoint: .bottom))
        case .cursor:
            AnyShapeStyle(.primary)
        }
    }
}

struct ProviderIcon: View {
    let provider: Provider
    var size: CGFloat = 16
    var tinted = true

    var body: some View {
        let image = Image(provider.rawValue, bundle: .main)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
        if tinted {
            image.foregroundStyle(provider.tint)
        } else {
            image
        }
    }
}

extension Pace? {
    var color: Color {
        switch self {
        case .runsOut: .orange
        case .limited: .red
        default: .primary
        }
    }
}

/// Usage bar with a tick where usage would be at an even pace through the window.
struct UsageBar: View {
    let window: UsageWindow
    let date: Date
    var height: CGFloat = 5

    var body: some View {
        let used = min(max(window.usedPercent / 100, 0), 1)
        let pace = window.pace(at: date)
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                    .frame(height: height)
                Capsule()
                    .fill(pace.color.opacity(pace == .onTrack || pace == nil ? 0.8 : 1))
                    .frame(width: used > 0 ? max(width * used, height) : 0, height: height)
                if let elapsed = window.elapsed(at: date) {
                    Capsule()
                        .fill(.primary.opacity(0.45))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: min(max(width * elapsed - 0.75, 0), width - 1.5))
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height + 6)
    }
}

/// Label, bar, reset and pace for one window. Used by the popover and the large widget.
struct WindowRow: View {
    let window: UsageWindow
    let date: Date

    var body: some View {
        let pace = window.pace(at: date)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(Format.percent(window.usedPercent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            UsageBar(window: window, date: date)
            HStack(alignment: .firstTextBaseline) {
                if let reset = Format.reset(window, from: date) {
                    Text(reset).foregroundStyle(.secondary)
                }
                Spacer()
                if let text = Format.pace(pace, from: date) {
                    Text(text).foregroundStyle(pace == .onTrack ? AnyShapeStyle(.secondary) : AnyShapeStyle(pace.color))
                }
            }
            .font(.system(size: 11))
        }
    }
}

struct ProviderSection: View {
    let usage: ProviderUsage
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                ProviderIcon(provider: usage.provider)
                Text(usage.provider.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let note = staleNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            if usage.windows.isEmpty, let error = usage.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(usage.windows.map { $0.at(date) }) { window in
                WindowRow(window: window, date: date)
            }
        }
    }

    /// Only shown when refreshing has been failing long enough to matter.
    private var staleNote: String? {
        guard !usage.windows.isEmpty, usage.error != nil else { return nil }
        let age = date.timeIntervalSince(usage.updatedAt)
        guard age > 10 * 60 else { return nil }
        return "as of " + Format.duration(age) + " ago"
    }
}

/// Template-rendered label for the menu bar: icon and tightest percentage per provider.
struct MenuBarLabel: View {
    let snapshot: Snapshot
    let date: Date
    /// When true, off-pace numbers are drawn in color instead of the menu bar's ink.
    var colored = false
    var ink: Color = .black

    var body: some View {
        HStack(spacing: 9) {
            ForEach(snapshot.providers) { usage in
                let window = usage.tightest(at: date)
                let pace = window?.pace(at: date)
                HStack(spacing: 3) {
                    ProviderIcon(provider: usage.provider, size: 15, tinted: false)
                        .foregroundStyle(ink)
                    Text(window.map { Format.percent($0.usedPercent) } ?? "–")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(colored && pace != .onTrack && pace != nil ? pace.color : ink)
                }
            }
        }
        .fixedSize()
    }
}
