import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)

    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }

    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }

    /// Whether the Claude sessions sidebar may be shown here; false for the quick terminal.
    var isClaudeSidebarSupported: Bool { get }

    /// Whether the workspace panel may be shown here; false for the quick terminal.
    var isWorkspacePanelSupported: Bool { get }

    /// The window hosting this view, used by the sidebar to open tabs.
    var hostWindow: NSWindow? { get }

    /// The controller's own focused surface, which is set on paths SwiftUI focus never reports.
    var focusedSurface: Ghostty.SurfaceView? { get }

    /// Whether the content extends under the hidden titlebar; false for the quick terminal panel.
    var extendsUnderTitlebar: Bool { get }

    /// Window chrome facts for the top bars.
    var chrome: WindowChromeModel { get }

    /// The tab strip's data source; nil where tabs are not supported.
    var tabStrip: TabStripModel? { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)?

    // The Claude sessions sidebar visibility, shared across all windows.
    @ObservedObject private var sidebarState = ClaudeSidebarState.shared

    // The workspace panel visibility, shared across all windows.
    @ObservedObject private var workspaceState = WorkspacePanelState.shared

    /// The most recently focused surface, equal to `focusedSurface` when it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView>?

    /// The system appearance picks the palette; the bundled terminal themes follow the same switch.
    @ObservedObject private var appearance = AppAppearance.shared

    /// Resolved here rather than read from the environment, since this view is what injects it.
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    /// The width of everything left of the tab strip, so it can clear the traffic lights.
    private var leadingBarWidth: CGFloat {
        guard viewModel.isClaudeSidebarSupported else { return 0 }
        return (sidebarState.isVisible ? ClaudeSidebarView.width : ClaudeSidebarRail.width) + 1
    }

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    /// The surface the chrome follows: SwiftUI focus once it arrives, the controller's own until then.
    private var chromeSurface: Ghostty.SurfaceView? {
        lastFocusedSurface?.value ?? viewModel.focusedSurface
    }

    /// The focused value drives updates; the weak fallback covers moments the panel itself has focus.
    private var panelPwd: String? {
        surfacePwd ?? chromeSurface?.pwd
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            HStack(spacing: 0) {
                if viewModel.isClaudeSidebarSupported {
                    HStack(spacing: 0) {
                        if sidebarState.isVisible {
                            ClaudeSidebarView(
                                chrome: viewModel.chrome,
                                activeSurface: chromeSurface,
                                hostWindow: { viewModel.hostWindow },
                                currentPwd: { chromeSurface?.pwd })
                        } else {
                            ClaudeSidebarRail(
                                chrome: viewModel.chrome,
                                hostWindow: { viewModel.hostWindow },
                                currentPwd: { chromeSurface?.pwd })
                        }
                        AppDivider(.vertical)
                    }
                    // Match the terminal's hidden-titlebar treatment so the sidebar extends under it too.
                    .ignoresSafeArea(.container, edges: viewModel.extendsUnderTitlebar ? .top : [])
                    .onAppear {
                        ClaudeSessionIndex.shared.start()
                        ClaudeLiveSessionMonitor.shared.start()
                    }
                }

                terminalContent

                if viewModel.isWorkspacePanelSupported {
                    HStack(spacing: 0) {
                        AppDivider(.vertical)
                        if workspaceState.isVisible {
                            WorkspacePanelView(pwd: panelPwd)
                        } else {
                            WorkspacePanelRail()
                        }
                    }
                    // Match the terminal's hidden-titlebar treatment so the panel extends under it too.
                    .ignoresSafeArea(.container, edges: viewModel.extendsUnderTitlebar ? .top : [])
                }
            }
            // The ground the terminal sits on; flanking panes step down from it.
            .background(palette.background)
            .environment(\.colorScheme, appearance.colorScheme)
        }
    }

    private var terminalContent: some View {
        ZStack {
            VStack(spacing: 0) {
                if let tabStrip = viewModel.tabStrip {
                    TabStripView(
                        model: tabStrip,
                        chrome: viewModel.chrome,
                        leadingBarWidth: leadingBarWidth)

                    AppDivider()
                }

                // If we're running in debug mode we show a warning so that users
                // know that performance will be degraded.
                if Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
                    DebugBuildWarningView()
                }

                TerminalSplitTreeView(
                    tree: viewModel.surfaceTree,
                    action: { delegate?.performSplitAction($0) })
                    .environmentObject(ghostty)
                    .ghosttyLastFocusedSurface(lastFocusedSurface)
                    .focused($focused)
                    .onAppear { self.focused = true }
                    .onChange(of: focusedSurface) { newValue in
                        // We want to keep track of our last focused surface so even if
                        // we lose focus we keep this set to the last non-nil value.
                        if newValue != nil {
                            lastFocusedSurface = .init(newValue)
                            self.delegate?.focusedSurfaceDidChange(to: newValue)
                        }
                    }
                    .onChange(of: pwdURL) { newValue in
                        self.delegate?.pwdDidChange(to: newValue)
                    }
                    .onChange(of: cellSize) { newValue in
                        guard let size = newValue else { return }
                        self.delegate?.cellSizeDidChange(to: size)
                    }
            }
            // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
            .ignoresSafeArea(.container, edges: viewModel.extendsUnderTitlebar ? .top : [])

            if let surfaceView = lastFocusedSurface?.value {
                TerminalCommandPaletteView(
                    surfaceView: surfaceView,
                    isPresented: $viewModel.commandPaletteIsShowing,
                    updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                    self.delegate?.performAction(action, on: surfaceView)
                }
            }

            // Show update information above all else.
            if viewModel.updateOverlayIsVisible {
                UpdateOverlay()
            }
        }
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
    }
}

private struct UpdateOverlay: View {
    var body: some View {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            VStack {
                Spacer()

                HStack {
                    Spacer()
                    UpdatePill(model: appDelegate.updateViewModel)
                        .padding(.bottom, 9)
                        .padding(.trailing, 9)
                }
            }
        }
    }
}

struct DebugBuildWarningView: View {
    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    @State private var isPopover = false

    var body: some View {
        VStack(spacing: 0) {
            banner

            AppDivider()
        }
    }

    private var banner: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(palette.surface)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
