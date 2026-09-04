import SwiftUI

/// The app's chrome colors for one appearance; the terminal background itself comes from the bundled theme.
struct AppPalette: Equatable {
    /// The window's ground, matching the bundled terminal theme's background.
    let background: Color

    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let textPlaceholder: Color
    let textFaint: Color

    let divider: Color
    let controlBorder: Color
    let hover: Color
    let selection: Color
    let selectionForeground: Color

    let accent: Color
    let accentSecondary: Color
    let purple: Color
    let success: Color
    let warning: Color
    let error: Color
    let info: Color
    let teal: Color

    /// Git graph lane colors; green and red stay reserved for diff semantics.
    let graphLanes: [Color]

    /// Cyrene Dark, the plum-tinted dark scheme.
    static let dark = AppPalette(
        background: Color(hex: 0x262033),
        textPrimary: Color(hex: 0xE8E4F2),
        textSecondary: Color(hex: 0xB5ADCA),
        textTertiary: Color(hex: 0x8D84A6),
        textPlaceholder: Color(hex: 0x7B7291),
        textFaint: Color(hex: 0x6F6787),
        divider: Color(hex: 0x362E4A),
        controlBorder: Color(hex: 0x3A3150),
        hover: Color(hex: 0x2C2540),
        selection: Color(hex: 0x3D2450),
        selectionForeground: Color(hex: 0xF9DCEC),
        accent: Color(hex: 0xF472B6),
        accentSecondary: Color(hex: 0xEC4899),
        purple: Color(hex: 0xA78BFA),
        success: Color(hex: 0x34D399),
        warning: Color(hex: 0xFBBF24),
        error: Color(hex: 0xFB7185),
        info: Color(hex: 0x38BDF8),
        teal: Color(hex: 0x2DD4BF),
        graphLanes: [
            Color(hex: 0x38BDF8),
            Color(hex: 0xFBBF24),
            Color(hex: 0xA78BFA),
            Color(hex: 0x2DD4BF),
            Color(hex: 0xF472B6),
            Color(hex: 0xA3E635),
        ])

    /// Cyrene Light, the cool-white scheme.
    static let light = AppPalette(
        background: Color(hex: 0xF3F1F7),
        textPrimary: Color(hex: 0x2B2937),
        textSecondary: Color(hex: 0x4B465C),
        textTertiary: Color(hex: 0x7D7690),
        textPlaceholder: Color(hex: 0xA49CBA),
        textFaint: Color(hex: 0x8E87A3),
        divider: Color(hex: 0xE7E2F2),
        controlBorder: Color(hex: 0xE2DCF0),
        hover: Color(hex: 0xE9E5F2),
        selection: Color(hex: 0xFCE7F3),
        selectionForeground: Color(hex: 0x831843),
        accent: Color(hex: 0xDB2777),
        accentSecondary: Color(hex: 0xEC4899),
        purple: Color(hex: 0x7C3AED),
        success: Color(hex: 0x059669),
        warning: Color(hex: 0xD97706),
        error: Color(hex: 0xE11D48),
        info: Color(hex: 0x0284C7),
        teal: Color(hex: 0x0D9488),
        graphLanes: [
            Color(hex: 0x0284C7),
            Color(hex: 0xD97706),
            Color(hex: 0x7C3AED),
            Color(hex: 0x0D9488),
            Color(hex: 0xDB2777),
            Color(hex: 0x65A30D),
        ])

    static func resolve(_ scheme: ColorScheme) -> AppPalette {
        scheme == .light ? .light : .dark
    }
}
