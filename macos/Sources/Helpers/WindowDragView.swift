import AppKit
import SwiftUI

/// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
class WindowDragView: NSView {
    override public func mouseDown(with event: NSEvent) {
        // Drag the window for single left clicks, double clicks should bypass the drag handle.
        if event.type == .leftMouseDown && event.clickCount == 1 {
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A double click on a drag region zooms the window, like a native titlebar.
        if event.clickCount == 2 { window?.performZoom(nil) }
        super.mouseUp(with: event)
    }
}

/// A SwiftUI background that makes empty space in a top bar move the window.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}
