import SwiftUI
import Testing
@testable import Ghostty

struct AppPaletteTests {
    @Test func resolvePicksMatchingScheme() {
        #expect(AppPalette.resolve(.dark) == AppPalette.dark)
        #expect(AppPalette.resolve(.light) == AppPalette.light)
    }

    @Test func schemesDiffer() {
        #expect(AppPalette.dark != AppPalette.light)
    }

    @Test func graphLanesHaveSixColors() {
        #expect(AppPalette.dark.graphLanes.count == 6)
        #expect(AppPalette.light.graphLanes.count == 6)
    }

    /// The chrome reads as flat unless every step is actually a step, so the ladder is asserted.
    @Test func lightSurfacesStepDown() {
        let palette = AppPalette.light
        let ladder = [
            palette.surfaceRaised,
            palette.background,
            palette.surface,
            palette.surfaceSunken,
            palette.hover,
            palette.divider,
            palette.controlBorder,
        ]
        for (above, below) in zip(ladder, ladder.dropFirst()) {
            #expect(NSColor(above).luminance > NSColor(below).luminance)
        }
    }

    @Test func darkSurfacesStepUp() {
        let palette = AppPalette.dark
        let ladder = [
            palette.surfaceSunken,
            palette.surface,
            palette.background,
            palette.surfaceRaised,
            palette.hover,
            palette.divider,
            palette.controlBorder,
        ]
        for (below, above) in zip(ladder, ladder.dropFirst()) {
            #expect(NSColor(below).luminance < NSColor(above).luminance)
        }
    }

    /// Collapsed rails sit on surfaceSunken and their only feedback is hover, which must stay visible there.
    @Test func hoverSeparatesFromTheDeepestSurface() {
        #expect(NSColor(AppPalette.light.hover).luminance < NSColor(AppPalette.light.surfaceSunken).luminance)
        #expect(NSColor(AppPalette.dark.hover).luminance > NSColor(AppPalette.dark.surfaceSunken).luminance)
    }

    @Test func shadowsAreTranslucent() {
        #expect(NSColor(AppPalette.light.shadow).alphaComponent < 1)
        #expect(NSColor(AppPalette.dark.shadow).alphaComponent < 1)
    }

    @Test func hexColorDecodesChannels() {
        let color = NSColor(Color(hex: 0x102030)).usingColorSpace(.sRGB)!
        #expect(abs(color.redComponent - 16.0 / 255) < 0.001)
        #expect(abs(color.greenComponent - 32.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 48.0 / 255) < 0.001)
    }
}
