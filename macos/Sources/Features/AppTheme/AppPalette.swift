import SwiftUI

/// The app's chrome colors for one appearance; the terminal background itself comes from the bundled theme.
struct AppPalette: Equatable {
    /// Floating layers: popovers, pills, and anything that reads as lifted off the ground.
    let surfaceRaised: Color

    /// The window's ground, matching the bundled terminal theme's background.
    let background: Color

    /// Chrome panes flanking the terminal: sidebar, tab strip, workspace panel.
    let surface: Color

    /// The deepest step, for collapsed rails.
    let surfaceSunken: Color

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

    /// Shadows carry a rose tint rather than neutral black, which is what keeps the light scheme warm.
    let shadow: Color

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

    private static let darkLanes: [Color] = [
        Color(hex: 0x38BDF8),
        Color(hex: 0xFBBF24),
        Color(hex: 0xA78BFA),
        Color(hex: 0x2DD4BF),
        Color(hex: 0xF472B6),
        Color(hex: 0xA3E635),
    ]

    private static let lightLanes: [Color] = [
        Color(hex: 0x0284C7),
        Color(hex: 0xD97706),
        Color(hex: 0x7C3AED),
        Color(hex: 0x0D9488),
        Color(hex: 0xDB2777),
        Color(hex: 0x65A30D),
    ]

    /// Cyrene Dark, the plum-tinted dark scheme.
    static let dark = AppPalette(
        surfaceRaised: Color(hex: 0x2B2440),
        background: Color(hex: 0x262033),
        surface: Color(hex: 0x211B2C),
        surfaceSunken: Color(hex: 0x1C1726),
        textPrimary: Color(hex: 0xE8E4F2),
        textSecondary: Color(hex: 0xB5ADCA),
        textTertiary: Color(hex: 0x8D84A6),
        textPlaceholder: Color(hex: 0x7B7291),
        textFaint: Color(hex: 0x6F6787),
        divider: Color(hex: 0x3A3150),
        controlBorder: Color(hex: 0x443A5E),
        hover: Color(hex: 0x332B47),
        selection: Color(hex: 0x3D2450),
        selectionForeground: Color(hex: 0xF9DCEC),
        shadow: Color(hex: 0x000000, opacity: 0.40),
        accent: Color(hex: 0xF472B6),
        accentSecondary: Color(hex: 0xEC4899),
        purple: Color(hex: 0xA78BFA),
        success: Color(hex: 0x34D399),
        warning: Color(hex: 0xFBBF24),
        error: Color(hex: 0xFB7185),
        info: Color(hex: 0x38BDF8),
        teal: Color(hex: 0x2DD4BF),
        graphLanes: darkLanes)

    /// Cyrene Light, the cool-white scheme.
    static let light = AppPalette(
        surfaceRaised: Color(hex: 0xF5F2FA),
        background: Color(hex: 0xEDEAF5),
        surface: Color(hex: 0xE7E3F1),
        surfaceSunken: Color(hex: 0xE0DBEC),
        textPrimary: Color(hex: 0x2B2937),
        textSecondary: Color(hex: 0x4B465C),
        textTertiary: Color(hex: 0x67607C),
        textPlaceholder: Color(hex: 0x8A82A1),
        textFaint: Color(hex: 0x7B7492),
        divider: Color(hex: 0xD3CBE4),
        controlBorder: Color(hex: 0xC9C0DE),
        hover: Color(hex: 0xD9D2E8),
        selection: Color(hex: 0xFCE7F3),
        selectionForeground: Color(hex: 0x831843),
        shadow: Color(hex: 0xBE5A96, opacity: 0.13),
        accent: Color(hex: 0xDB2777),
        accentSecondary: Color(hex: 0xEC4899),
        purple: Color(hex: 0x7C3AED),
        success: Color(hex: 0x059669),
        warning: Color(hex: 0xD97706),
        error: Color(hex: 0xE11D48),
        info: Color(hex: 0x0284C7),
        teal: Color(hex: 0x0D9488),
        graphLanes: lightLanes)

    static func resolve(_ scheme: ColorScheme) -> AppPalette {
        scheme == .light ? .light : .dark
    }
}
