#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

enum ReaderTheme {
    static let teal = Color(red: 0.05, green: 0.58, blue: 0.53)
    static let deepTeal = Color(red: 0.07, green: 0.31, blue: 0.29)
    static let orange = Color(red: 0.97, green: 0.45, blue: 0.12)
#if os(macOS)
    static let paper = Color(
        light: NSColor(calibratedRed: 0.985, green: 0.982, blue: 0.965, alpha: 1),
        dark: NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.11, alpha: 1)
    )
    static let raised = Color(
        light: NSColor(calibratedWhite: 1, alpha: 0.82),
        dark: NSColor(calibratedWhite: 0.16, alpha: 0.86)
    )
    static let mutedFill = Color(
        light: NSColor(calibratedWhite: 0.93, alpha: 0.8),
        dark: NSColor(calibratedWhite: 0.2, alpha: 0.8)
    )
#else
    static let paper = Color(
        light: UIColor(red: 0.985, green: 0.982, blue: 0.965, alpha: 1),
        dark: UIColor(red: 0.095, green: 0.105, blue: 0.11, alpha: 1)
    )
    static let raised = Color(
        light: UIColor(white: 1, alpha: 0.82),
        dark: UIColor(white: 0.16, alpha: 0.86)
    )
    static let mutedFill = Color(
        light: UIColor(white: 0.93, alpha: 0.8),
        dark: UIColor(white: 0.2, alpha: 0.8)
    )
#endif
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
            .background(ReaderTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
    }
}

extension View {
    func readerCard() -> some View {
        modifier(ReaderCardModifier())
    }
}
