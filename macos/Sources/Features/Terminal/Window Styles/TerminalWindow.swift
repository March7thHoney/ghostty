import AppKit
import SwiftUI
import GhosttyKit

/// The one terminal window style: no titlebar, traffic lights floating over the sidebar, tabs drawn by SwiftUI.
class TerminalWindow: NSWindow {
    /// Posted when a terminal window awakes from nib.
    static let terminalDidAwake = Notification.Name("TerminalWindowDidAwake")

    /// Posted when a terminal window will close
    static let terminalWillCloseNotification = Notification.Name("TerminalWindowWillClose")

    /// Posted when a tab-visible property (title, color, activity, zoom, shortcut) changes.
    static let tabStateDidChangeNotification = Notification.Name("TerminalWindowTabStateDidChange")

    /// This is the key in UserDefaults to use for the default `level` value. This is
    /// used by the manual float on top menu item feature.
    static let defaultLevelKey: String = "TerminalDefaultLevel"

    /// Where the traffic lights sit; matches the sidebar header's leading padding.
    static let windowButtonsLeading: CGFloat = 13
    static let windowButtonsTopInset: CGFloat = 13
    static let windowButtonsSpacing: CGFloat = 20

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig = .init()

    /// The update overlay lives in the content view now; nothing can sit in a hidden titlebar.
    var supportsUpdateAccessory: Bool { false }

    /// Gets the terminal controller from the window controller.
    var terminalController: TerminalController? {
        windowController as? TerminalController
    }

    /// The color assigned to this window's tab; the tab strip reads it on change.
    var tabColor: TerminalTabColor = .none {
        didSet {
            guard tabColor != oldValue else { return }
            invalidateRestorableState()
            postTabStateDidChange()
        }
    }

    /// The keyboard shortcut that activates this tab, shown in the tab strip.
    var keyEquivalent: String? {
        didSet {
            guard keyEquivalent != oldValue else { return }
            postTabStateDidChange()
        }
    }

    /// This window's Claude session state, shown in the tab strip.
    var claudeActivity: ClaudeLiveSession.Activity? {
        didSet {
            guard claudeActivity != oldValue else { return }
            postTabStateDidChange()
        }
    }

    /// Set to true if a surface is currently zoomed to show the reset zoom button.
    var surfaceIsZoomed: Bool = false {
        didSet {
            guard surfaceIsZoomed != oldValue else { return }
            postTabStateDidChange()
        }
    }

    /// KVO on the tab group, rebound whenever the group changes under us.
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupWindowsObservation: NSKeyValueObservation?
    private var tabBarVisibleObservation: NSKeyValueObservation?

    /// True once the titlebar's visual effect view has been hidden on macOS 13 to 15.
    private var effectViewIsHidden = false

    /// AppKit repaints the titlebar when the system appearance flips, undoing our hiding.
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: NSWindow Overrides

    override func awakeFromNib() {
        // Notify that this terminal window has loaded
        NotificationCenter.default.post(name: Self.terminalDidAwake, object: self)

        // This is required so that window restoration properly creates our tabs
        // again. I'm not sure why this is required. If you don't do this, then
        // tabs restore as separate windows.
        tabbingMode = .preferred
        DispatchQueue.main.async {
            self.tabbingMode = .automatic
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fullscreenDidExit(_:)),
            name: .fullscreenDidExit,
            object: nil)

        // All new windows are based on the app config at the time of creation.
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let config = appDelegate.ghostty.config

        // Setup our initial config
        derivedConfig = .init(config)

        // If there is a hardcoded title in the configuration, we set that
        // immediately. Future `set_title` apprt actions will override this
        // if necessary but this ensures our window loads with the proper
        // title immediately rather than on another event loop tick (see #5934)
        if let title = derivedConfig.title {
            self.title = title
        }

        // If window decorations are disabled, remove our title
        if !config.windowDecorations { styleMask.remove(.titled) }

        applyChromeStyle()

        // If our traffic buttons should be hidden, then hide them
        if config.macosWindowButtons == .hidden {
            hideWindowButtons()
        }

        setupTabGroupKVO()

        appearanceObservation = observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.effectViewIsHidden = false
                self?.hideTitlebarBackground()
                self?.layoutWindowButtons()
            }
        }

        // Get our saved level
        level = UserDefaults.ghostty.value(forKey: Self.defaultLevelKey) as? NSWindow.Level ?? .normal
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        tabGroupWindowsObservation?.invalidate()
        tabBarVisibleObservation?.invalidate()
        appearanceObservation?.invalidate()
    }

    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }

    override func close() {
        NotificationCenter.default.post(name: Self.terminalWillCloseNotification, object: self)
        super.close()
    }

    override func becomeKey() {
        super.becomeKey()
        layoutWindowButtons()
        postTabStateDidChange()
    }

    override func resignKey() {
        super.resignKey()
        postTabStateDidChange()
    }

    override func becomeMain() {
        super.becomeMain()
        setupTabGroupKVO()
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        layoutWindowButtons()
    }

    override func mergeAllWindows(_ sender: Any?) {
        super.mergeAllWindows(sender)

        // It takes an event loop cycle to merge all the windows so we set a
        // short timer to relabel the tabs (issue #1902)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.terminalController?.relabelTabs()
        }
    }

    override var title: String {
        didSet {
            // Setting the title reveals the native title view on macOS 15+, so re-hide it.
            applyChromeStyle()
            postTabStateDidChange()
        }
    }

    // We override this so that the hidden titlebar area is not a drag region by default.
    override var contentLayoutRect: CGRect {
        var rect = super.contentLayoutRect
        rect.origin.y = 0
        rect.size.height = self.frame.height
        return rect
    }

    // MARK: Chrome

    private static let chromeStyleMask: NSWindow.StyleMask = [
        .titled,
        .fullSizeContentView,
        .resizable,
        .closable,
        .miniaturizable,
    ]

    /// The desktop-app look: content under a transparent, title-less titlebar that keeps only the traffic lights.
    private func applyChromeStyle() {
        guard styleMask.contains(.titled) else { return }

        // Reapplying the mask during fullscreen breaks non-native fullscreen (ghostty#8415).
        if terminalController?.fullscreenStyle?.isFullscreen ?? false { return }

        if styleMask.contains(.fullScreen) {
            styleMask = Self.chromeStyleMask.union([.fullScreen])
        } else {
            styleMask = Self.chromeStyleMask
        }

        // Never pin an appearance: the whole window follows the system.
        appearance = nil
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        titlebarSeparatorStyle = .none
        toolbar = nil

        // AppKit moves NSScrollPocket into the titlebar on macOS 27 where it would cover the terminal.
        if #available(macOS 27, *),
           let themeFrame = contentView?.superview,
           let scrollPocket = themeFrame.firstDescendant(withClassName: "NSScrollPocket") {
            scrollPocket.isHidden = true
        }

        hideTitlebarBackground()
        layoutWindowButtons()
    }

    /// Clears every layer the titlebar would otherwise paint, so the window background shows through.
    private func hideTitlebarBackground() {
        guard let titlebarContainer else { return }
        if #available(macOS 26.0, *) {
            titlebarContainer.firstDescendant(withClassName: "NSTitlebarBackgroundView")?.isHidden = true
            if let titlebarView = titlebarContainer.firstDescendant(withClassName: "NSTitlebarView") {
                titlebarView.wantsLayer = true
                titlebarView.layer?.backgroundColor = NSColor.clear.cgColor
            }
        } else if !effectViewIsHidden,
                  let effectView = titlebarContainer.descendants(withClassName: "NSVisualEffectView").first {
            effectView.isHidden = true
            effectViewIsHidden = true
        }
    }

    /// Pins the traffic lights to the sidebar header's corner; AppKit re-centers them on every relayout.
    private func layoutWindowButtons() {
        guard styleMask.contains(.titled), !styleMask.contains(.fullScreen) else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type), let container = button.superview else { continue }
            let origin = NSPoint(
                x: Self.windowButtonsLeading + CGFloat(i) * Self.windowButtonsSpacing,
                y: container.bounds.height - Self.windowButtonsTopInset - button.frame.height)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }

    @objc private func fullscreenDidExit(_ notification: Notification) {
        guard let fullscreen = notification.object as? FullscreenBase else { return }
        guard fullscreen.window == self else { return }
        applyChromeStyle()
    }

    // MARK: Tab Bar

    /// This identifier is attached to the tab bar view controller when we detect it being
    /// added.
    static let tabBarIdentifier: NSUserInterfaceItemIdentifier = .init("_ghosttyTabBar")

    var hasMoreThanOneTabs: Bool {
        /// accessing ``tabGroup?.windows`` here
        /// will cause other edge cases, be careful
        (tabbedWindows?.count ?? 0) > 1
    }

    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        super.addTitlebarAccessoryViewController(childViewController)

        // The native tab bar arrives as a titlebar accessory; the SwiftUI tab strip replaces it.
        guard isTabBar(childViewController) else { return }
        childViewController.identifier = Self.tabBarIdentifier
        childViewController.isHidden = true
        childViewController.view.isHidden = true
        DispatchQueue.main.async { [weak self] in
            self?.hideNativeTabBar()
        }
    }

    func isTabBar(_ childViewController: NSTitlebarAccessoryViewController) -> Bool {
        if childViewController.identifier == nil {
            // The good case
            if childViewController.view.contains(className: "NSTabBar") {
                return true
            }

            // When a new window is attached to an existing tab group, AppKit adds
            // an empty NSView as an accessory view and adds the tab bar later. If
            // we're at the bottom and are a single NSView we assume its a tab bar.
            if childViewController.layoutAttribute == .bottom &&
                childViewController.view.className == "NSView" &&
                childViewController.view.subviews.isEmpty {
                return true
            }

            return false
        }

        // View controllers should be tagged with this as soon as possible to
        // increase our accuracy. We do this manually.
        return childViewController.identifier == Self.tabBarIdentifier
    }

    /// Turns the native tab bar off wherever AppKit surfaced it, then restores our chrome.
    private func hideNativeTabBar() {
        if let tabGroup, tabGroup.isTabBarVisible {
            toggleTabBar(nil)
        }
        for vc in titlebarAccessoryViewControllers where isTabBar(vc) {
            vc.isHidden = true
            vc.view.isHidden = true
        }
        if let bar = titlebarContainer?.firstDescendant(withClassName: "NSTabBar") {
            bar.superview?.isHidden = true
        }
        applyChromeStyle()
    }

    /// Rebinds KVO on the current tab group; AppKit swaps groups when windows join or leave.
    private func setupTabGroupKVO() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let currentTabGroup = self.tabGroup
            let observationsValid = currentTabGroup == nil || (
                self.tabGroupWindowsObservation != nil && self.tabBarVisibleObservation != nil)
            guard self.observedTabGroup !== currentTabGroup || !observationsValid else { return }

            self.observedTabGroup = currentTabGroup
            self.tabGroupWindowsObservation?.invalidate()
            self.tabBarVisibleObservation?.invalidate()
            self.tabGroupWindowsObservation = nil
            self.tabBarVisibleObservation = nil
            guard let currentTabGroup else { return }

            self.tabGroupWindowsObservation = currentTabGroup.observe(\.windows, options: [.new]) { [weak self] _, _ in
                self?.hideNativeTabBar()
                self?.postTabStateDidChange()
            }
            self.tabBarVisibleObservation = currentTabGroup.observe(\.isTabBarVisible, options: [.new]) { [weak self] group, _ in
                guard group.isTabBarVisible else { return }
                DispatchQueue.main.async { self?.hideNativeTabBar() }
            }
        }
    }

    private func postTabStateDidChange() {
        NotificationCenter.default.post(name: Self.tabStateDidChangeNotification, object: self)
    }

    // MARK: Title Text

    var titlebarContainer: NSView? {
        // If we aren't fullscreen then the titlebar container is part of our window.
        if !styleMask.contains(.fullScreen) {
            return contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        // If we are fullscreen, the titlebar container view is part of a separate
        // "fullscreen window", we need to find the window and then get the view.
        for window in NSApplication.shared.windows {
            // This is the private window class that contains the toolbar
            guard window.className == "NSToolbarFullScreenWindow" else { continue }

            // The parent will match our window. This is used to filter the correct
            // fullscreen window if we have multiple.
            guard window.parent == self else { continue }

            return window.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    // MARK: Positioning And Styling

    /// This is called by the controller when there is a need to reset the window appearance.
    func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // If our window is not visible, then we do nothing. Some things such as blurring
        // have no effect if the window is not visible. Ultimately, we'll have this called
        // at some point when a surface becomes focused.
        guard isVisible else { return }
        defer { updateColorSchemeForSurfaceTree() }

        // The app follows the system appearance; the bundled themes switch with it.
        appearance = nil
        hasShadow = surfaceConfig.macosWindowShadow

        // Always opaque: a translucent pane shows a different backdrop than its neighbors.
        isOpaque = true
        let backgroundColor = preferredBackgroundColor ?? NSColor(surfaceConfig.backgroundColor)
        self.backgroundColor = backgroundColor.withAlphaComponent(1)

        hideTitlebarBackground()
    }

    /// The preferred window background color. The current window background color may not be set
    /// to this, since this is dynamic based on the state of the surface tree.
    ///
    /// This background color will include alpha transparency if set. If the caller doesn't want that,
    /// change the alpha channel again manually.
    var preferredBackgroundColor: NSColor? {
        if let terminalController, !terminalController.surfaceTree.isEmpty {
            let surface: Ghostty.SurfaceView?

            // If our focused surface borders the top then we prefer its background color
            if let focusedSurface = terminalController.focusedSurface,
               let treeRoot = terminalController.surfaceTree.root,
               let focusedNode = treeRoot.node(view: focusedSurface),
               treeRoot.spatial().doesBorder(side: .up, from: focusedNode) {
                surface = focusedSurface
            } else {
                // If it doesn't border the top, we use the top-left leaf
                surface = terminalController.surfaceTree.root?.leftmostLeaf()
            }

            if let surface {
                let backgroundColor = surface.backgroundColor ?? surface.derivedConfig.backgroundColor
                return NSColor(backgroundColor)
            }
        }

        return derivedConfig.backgroundColor
    }

    func updateColorSchemeForSurfaceTree() {
        terminalController?.updateColorSchemeForSurfaceTree()
    }

    func setInitialWindowPosition(x: Int16?, y: Int16?) -> Bool {
        // If we don't have an X/Y then we try to use the previously saved window pos.
        guard let x = x, let y = y else {
            return false
        }

        // Prefer the screen our window is being placed on otherwise our primary screen.
        guard let screen = screen ?? NSScreen.screens.first else {
            return false
        }

        // Convert top-left coordinates to bottom-left origin using our utility extension
        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        // Clamp the origin to ensure the window stays fully visible on screen
        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        setFrameOrigin(safeOrigin)
        return true
    }

    private func hideWindowButtons() {
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // MARK: Config

    struct DerivedConfig {
        let title: String?
        let backgroundBlur: Ghostty.Config.BackgroundBlur
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let windowCornerRadius: CGFloat

        init() {
            self.title = nil
            self.backgroundColor = NSColor.windowBackgroundColor
            self.backgroundOpacity = 1
            self.macosWindowButtons = .visible
            self.backgroundBlur = .disabled
            self.windowCornerRadius = 16
        }

        init(_ config: Ghostty.Config) {
            self.title = config.title
            self.backgroundColor = NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.macosWindowButtons = config.macosWindowButtons
            self.backgroundBlur = config.backgroundBlur
            self.windowCornerRadius = 16
        }
    }
}
