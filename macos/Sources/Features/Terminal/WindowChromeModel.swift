import AppKit
import Combine

/// Window-level chrome facts the SwiftUI top bars need: where the traffic lights are and whether they exist.
@MainActor
final class WindowChromeModel: ObservableObject {
    @Published var isFullscreen = false
    @Published var windowButtonsVisible = true

    /// How much leading space the traffic lights need when they sit over a bar of the given width.
    func windowButtonsInset(barWidth: CGFloat) -> CGFloat {
        guard windowButtonsVisible, !isFullscreen else { return 0 }
        return max(0, AppMetrics.windowButtonsInset - barWidth)
    }
}
