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

    @Test func hexColorDecodesChannels() {
        let color = NSColor(Color(hex: 0x102030)).usingColorSpace(.sRGB)!
        #expect(abs(color.redComponent - 16.0 / 255) < 0.001)
        #expect(abs(color.greenComponent - 32.0 / 255) < 0.001)
        #expect(abs(color.blueComponent - 48.0 / 255) < 0.001)
    }
}
