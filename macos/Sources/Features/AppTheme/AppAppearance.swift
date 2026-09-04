import AppKit
import SwiftUI

/// The system appearance, observed directly; SwiftUI's own colorScheme can stall in a hosted window.
@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()

    @Published private(set) var colorScheme: ColorScheme

    private var observation: NSKeyValueObservation?

    private init() {
        colorScheme = Self.scheme(of: NSApplication.shared.effectiveAppearance)
        observation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak self] app, _ in
            let scheme = Self.scheme(of: app.effectiveAppearance)
            Task { @MainActor in
                guard let self, self.colorScheme != scheme else { return }
                self.colorScheme = scheme
            }
        }
    }

    private static func scheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.isDark ? .dark : .light
    }
}
