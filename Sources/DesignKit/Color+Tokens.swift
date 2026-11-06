import AppKit
import SwiftUI

/// Brewed AI color tokens, adapted for a dark-first native window.
///
/// Dark is the base palette (it's what the brand's application surfaces look like);
/// Light is derived from the brand guide's own "light/crema section" rule, not invented
/// separately. Every adaptive token tracks `NSApp.effectiveAppearance` automatically.
public enum PourColor {

    // MARK: - Adaptive (dark base / light override)

    public static let bgCanvas = adaptive(dark: "#050A15", light: "#FAF6EB")
    public static let bgAlt = adaptive(dark: "#070D1C", light: "#F7EAD0")
    public static let surfacePanel = adaptive(dark: "#101C36", light: "#FFFDF8")
    public static let surfacePanel2 = adaptive(dark: "#162443", light: "#F7EAD0")

    public static let borderHairline = adaptive(dark: hex("#123A63", alpha: 0.55), light: hex("#5B3829", alpha: 0.16))
    public static let borderStrong = adaptive(dark: hex("#38BDF8", alpha: 0.30), light: hex("#5B3829", alpha: 0.28))

    public static let text = adaptive(dark: "#F4F7FC", light: "#0B1329")
    public static let textMuted = adaptive(dark: "#9FB0CC", light: "#4A5568")
    public static let textDim = adaptive(dark: "#6B7D9C", light: "#6B7280")

    // MARK: - Flat brand accents (same intent in both appearances)

    public static let blue400 = fixed("#7FD4FF")
    public static let blue500 = fixed("#38BDF8")
    public static let blue600 = fixed("#1D8FE0")
    public static let blue700 = fixed("#1A6FC4")
    public static let blue900 = fixed("#123A63")

    public static let amber = fixed("#FBBF24")
    public static let amberDark = fixed("#B7791F")
    public static let violet = fixed("#A78BFA")
    public static let crema = fixed("#F7EAD0")
    public static let coffee = fixed("#5B3829")
    public static let espresso = fixed("#2E1A10")

    /// Label color for text drawn on a filled Amber control — always Espresso, in both appearances.
    public static let onAmber = espresso

    // MARK: - Semantic

    public static let success = fixed("#4ADE80")
    public static let warning = fixed("#FBBF24")
    public static let error = fixed("#FF5F57")
    public static let selection = fixed(hex("#FBBF24", alpha: 0.85))

    // MARK: - Construction

    private static func adaptive(dark: String, light: String) -> Color {
        adaptive(dark: hex(dark), light: hex(light))
    }

    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }

    private static func fixed(_ color: NSColor) -> Color { Color(color) }
    private static func fixed(_ hexString: String) -> Color { Color(hex(hexString)) }

    private static func hex(_ hexString: String, alpha: CGFloat = 1) -> NSColor {
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        s.removeAll { $0 == "#" }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
