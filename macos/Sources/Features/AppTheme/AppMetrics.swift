import SwiftUI

/// Shared layout constants so the sidebar, tab strip and panel line up.
enum AppMetrics {
    static let rowRadius: CGFloat = 8
    static let controlRadius: CGFloat = 6
    static let cardRadius: CGFloat = 12

    static let bodyFontSize: CGFloat = 13
    static let secondaryFontSize: CGFloat = 11
    static let headerFontSize: CGFloat = 12

    /// The height of the top bar shared by the sidebar header, tab strip and panel header.
    static let topBarHeight: CGFloat = 38

    /// Space reserved at the window's leading edge for the traffic lights.
    static let windowButtonsInset: CGFloat = 76
}
