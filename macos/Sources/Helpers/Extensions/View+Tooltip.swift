import SwiftUI

extension View {
    /// AppKit-backed tooltip: `.help()` rects go stale when lazy rows recycle in a ScrollView.
    func nativeTooltip(_ text: String) -> some View {
        overlay(NativeTooltip(text: text).allowsHitTesting(false))
    }
}

/// A transparent, non-interactive view whose only job is to own a tooltip rect.
private struct NativeTooltip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard view.toolTip != text else { return }
        view.toolTip = text
    }

    /// Clicks must reach the row underneath; tooltips track by rect, not by hit test.
    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
