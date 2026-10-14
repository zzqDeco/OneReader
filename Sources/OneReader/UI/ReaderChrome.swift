import SwiftUI

/// Small shared layout tokens for application chrome, never for source content.
enum ReaderChromeMetrics {
    static func minimumActionHeight(touch: Bool) -> CGFloat { touch ? 44 : 28 }

    static let continuationMinimumCopyWidth: CGFloat = 220

    static func shelfMinimumWidth(compact: Bool, accessibilitySize: Bool) -> CGFloat {
        if accessibilitySize { return compact ? 260 : 240 }
        return compact ? 148 : 172
    }

    static var actionHeight: CGFloat {
#if os(iOS)
        minimumActionHeight(touch: true)
#else
        minimumActionHeight(touch: false)
#endif
    }
}

/// The minimum hit area is part of the button's label, not an inert outer frame.
struct ReaderActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(minHeight: ReaderChromeMetrics.actionHeight)
            .contentShape(Rectangle())
    }
}

/// A continuation card always shows a determinate track, including at zero.
/// The minimum survives an adjacent Spacer; the maximum leaves room for copy.
struct ReaderProgressSummary: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("\(Int(fraction * 100))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .tint(ReaderTheme.accent)
                .frame(minWidth: 72, maxWidth: 190)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }
}

/// Actions remain separate accessibility children and stack before clipping.
struct ReaderAdaptiveActions<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { content }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { content }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { content }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ReaderSectionHeading: View {
    let title: String
    var systemImage: String? = nil
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(ReaderTheme.accent)
                    .accessibilityHidden(true)
            }
            Text(title).font(.headline)
            if let count {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct ReaderStatusBadge: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.08), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ReaderPanelHeading: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(ReaderTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
