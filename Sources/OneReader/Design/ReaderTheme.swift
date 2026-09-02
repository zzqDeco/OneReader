#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

enum ReaderTheme {
#if os(macOS)
    static let accent = Color(
        light: NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.36, alpha: 1),
        dark: NSColor(calibratedRed: 0.31, green: 0.75, blue: 0.68, alpha: 1)
    )
    static let highlight = Color(
        light: NSColor(calibratedRed: 0.66, green: 0.42, blue: 0.17, alpha: 1),
        dark: NSColor(calibratedRed: 0.90, green: 0.67, blue: 0.34, alpha: 1)
    )
#else
    static let accent = Color(
        light: UIColor(red: 0.06, green: 0.40, blue: 0.36, alpha: 1),
        dark: UIColor(red: 0.31, green: 0.75, blue: 0.68, alpha: 1)
    )
    static let highlight = Color(
        light: UIColor(red: 0.66, green: 0.42, blue: 0.17, alpha: 1),
        dark: UIColor(red: 0.90, green: 0.67, blue: 0.34, alpha: 1)
    )
#endif
    static let accentMuted = accent.opacity(0.12)
    static let teal = accent
    static let deepTeal = accent
    static let orange = highlight
#if os(macOS)
    static let window = Color(
        light: NSColor(calibratedRed: 0.955, green: 0.950, blue: 0.930, alpha: 1),
        dark: NSColor(calibratedRed: 0.070, green: 0.075, blue: 0.080, alpha: 1)
    )
    static let grouped = Color(
        light: NSColor(calibratedRed: 0.972, green: 0.968, blue: 0.950, alpha: 1),
        dark: NSColor(calibratedRed: 0.085, green: 0.090, blue: 0.095, alpha: 1)
    )
    static let paper = Color(
        light: NSColor(calibratedRed: 0.985, green: 0.980, blue: 0.960, alpha: 1),
        dark: NSColor(calibratedRed: 0.086, green: 0.090, blue: 0.094, alpha: 1)
    )
    static let raised = Color(
        light: NSColor(calibratedRed: 0.998, green: 0.996, blue: 0.988, alpha: 1),
        dark: NSColor(calibratedWhite: 0.135, alpha: 1)
    )
    static let mutedFill = Color(
        light: NSColor(calibratedRed: 0.918, green: 0.910, blue: 0.880, alpha: 1),
        dark: NSColor(calibratedWhite: 0.19, alpha: 1)
    )
#else
    static let window = Color(
        light: UIColor(red: 0.955, green: 0.950, blue: 0.930, alpha: 1),
        dark: UIColor(red: 0.070, green: 0.075, blue: 0.080, alpha: 1)
    )
    static let grouped = Color(
        light: UIColor(red: 0.972, green: 0.968, blue: 0.950, alpha: 1),
        dark: UIColor(red: 0.085, green: 0.090, blue: 0.095, alpha: 1)
    )
    static let paper = Color(
        light: UIColor(red: 0.985, green: 0.980, blue: 0.960, alpha: 1),
        dark: UIColor(red: 0.086, green: 0.090, blue: 0.094, alpha: 1)
    )
    static let raised = Color(
        light: UIColor(red: 0.998, green: 0.996, blue: 0.988, alpha: 1),
        dark: UIColor(white: 0.135, alpha: 1)
    )
    static let mutedFill = Color(
        light: UIColor(red: 0.918, green: 0.910, blue: 0.880, alpha: 1),
        dark: UIColor(white: 0.19, alpha: 1)
    )
#endif

    static let proseMaxWidth: CGFloat = 720
    static let compactInset: CGFloat = 22
    static let panelRadius: CGFloat = 12
    static let coverRadius: CGFloat = 10

    static func coverColor(for value: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.20, green: 0.30, blue: 0.34),
            Color(red: 0.20, green: 0.36, blue: 0.29),
            Color(red: 0.38, green: 0.28, blue: 0.36),
            Color(red: 0.50, green: 0.38, blue: 0.20),
            Color(red: 0.49, green: 0.28, blue: 0.23),
        ]
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private extension Color {
#if os(macOS)
    init(light: NSColor, dark: NSColor) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
    }
#else
    init(light: UIColor, dark: UIColor) {
        self.init(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
#endif
}

struct ReaderCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: ReaderTheme.panelRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ReaderTheme.panelRadius)
                    .stroke(.separator.opacity(0.42), lineWidth: 0.5)
            }
    }
}

extension View {
    func readerCard() -> some View {
        modifier(ReaderCardModifier())
    }
}
