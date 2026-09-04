import SwiftUI

/// The right-side workspace panel: a file tree and a read-only git status view.
struct WorkspacePanelView: View {
    /// Fixed rather than draggable, so per-window widths can't drift and break the shared-panel illusion.
    static let width: CGFloat = 320

    @ObservedObject private var state = WorkspacePanelState.shared

    /// The focused surface's working directory, which decides the workspace shown.
    let pwd: String?

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    /// The workspace this panel renders; also the directory the VS Code button opens.
    @State private var model: WorkspaceModel?

    var body: some View {
        VStack(spacing: 0) {
            header

            AppDivider()

            if let model {
                WorkspacePanelContent(model: model)
                    .id(model.root.path)
            } else {
                waitingState
            }
        }
        .frame(width: Self.width)
        // SwiftUI does not clip overflow, so one runaway width would otherwise paint over the terminal.
        .clipped()
        .background(palette.surface)
        .environment(\.colorScheme, appearance.colorScheme)
        // Resolving pwd's repository root walks the filesystem, so it stays off the render pass.
        .task(id: pwd) { model = await WorkspaceRegistry.shared.model(forPwd: pwd) }
    }

    /// Finder's bundled .icns, which only has a light face; icon services bakes the system's dark variant.
    private static let finderIcon: NSImage = {
        let finder = "/System/Library/CoreServices/Finder.app"
        if let icns = NSImage(contentsOfFile: finder + "/Contents/Resources/Finder.icns") {
            return icns
        }
        // Without the .icns, the drawing appearance is the only lever left, weak as it is.
        let icon = NSWorkspace.shared.icon(forFile: finder)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
                icon.draw(in: rect)
            }
            return true
        }
    }()

    private var header: some View {
        HStack(spacing: 2) {
            Button {
                state.selectedTab = .files
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(AppIconButtonStyle(isActive: state.selectedTab == .files))
            .help("Files")

            Button {
                state.selectedTab = .git
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .buttonStyle(AppIconButtonStyle(isActive: state.selectedTab == .git))
            .help("Git status")

            if let root = model?.root, ClaudeSidebarCoordinator.vsCodeURL != nil {
                Button {
                    ClaudeSidebarCoordinator.openInVSCode(cwd: root.path)
                } label: {
                    // Smaller than the 12pt symbols beside it: a solid mark carries more visual weight.
                    VSCodeLogo()
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(AppIconButtonStyle())
                .help("Open in VS Code")
            }

            if let root = model?.root {
                Button {
                    ClaudeSidebarCoordinator.revealInFinder(cwd: root.path)
                } label: {
                    // Finder's own icon, so the button can't be mistaken for the Files tab.
                    Image(nsImage: Self.finderIcon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(AppIconButtonStyle())
                .help("Reveal in Finder")
            }

            if let model {
                WorkspaceGitHubButton(model: model)
            }

            Spacer()

            Button {
                state.isVisible = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(AppIconButtonStyle())
            .help("Hide panel")
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: AppMetrics.topBarHeight)
        .background(WindowDragRegion())
    }

    private var waitingState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No working directory yet")
                .font(.system(size: 13, weight: .medium))
            Text("The panel follows the focused terminal's directory")
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

/// The collapsed panel: a rail that keeps it discoverable without overlapping the terminal.
struct WorkspacePanelRail: View {
    static let width: CGFloat = 28

    @ObservedObject private var state = WorkspacePanelState.shared
    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    var body: some View {
        VStack(spacing: 10) {
            Button {
                state.isVisible = true
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(AppIconButtonStyle())
            .help("Show panel")

            Spacer()
        }
        .padding(.top, (AppMetrics.topBarHeight - 22) / 2)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(palette.surfaceSunken)
        .environment(\.colorScheme, appearance.colorScheme)
    }
}

/// The panel body for one resolved workspace: breadcrumb, active tab, and optional preview split.
/// Observes the model itself, since the remote URL lands after the header's first render.
private struct WorkspaceGitHubButton: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if let url = model.githubURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                // A solid disc reads heavier than the outline symbols, so it sits a touch smaller.
                GitHubLogo()
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(AppIconButtonStyle())
            .help("Open on GitHub")
        }
    }
}

private struct WorkspacePanelContent: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var state = WorkspacePanelState.shared

    @ObservedObject private var appearance = AppAppearance.shared
    private var palette: AppPalette { AppPalette.resolve(appearance.colorScheme) }

    /// Whether the active tab currently has a selection driving the bottom preview pane.
    private var hasSelection: Bool {
        switch state.selectedTab {
        case .files:
            return model.selectedFilePath != nil
        case .git:
            switch state.gitMode {
            case .changes: return model.selectedGitEntry != nil
            case .history: return model.selectedCommitSha != nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb

            if hasSelection {
                SplitView(.vertical, $state.previewSplit, dividerColor: palette.divider) {
                    listArea
                } right: {
                    WorkspacePreviewView(
                        model: model, tab: state.selectedTab, gitMode: state.gitMode,
                        dividerColor: palette.divider)
                } onEqualize: {
                    state.previewSplit = 0.5
                }
            } else {
                listArea
            }
        }
        .onAppear { model.start() }
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            // The path tooltip covers only the name, so hovering the reload button doesn't raise it.
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.textSecondary)

                Text(model.root.lastPathComponent)
                    .font(.system(size: AppMetrics.headerFontSize, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .nativeTooltip(model.root.path)

            Spacer(minLength: 4)

            Button {
                model.reloadWorkspace()
            } label: {
                if model.refreshing || model.historyLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(AppIconButtonStyle(size: 10, frame: 18))
            .disabled(model.refreshing || model.historyLoading)
            .help("Reload")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var listArea: some View {
        switch state.selectedTab {
        case .files:
            WorkspaceFileTreeView(model: model)
        case .git:
            WorkspaceGitView(model: model, dividerColor: palette.divider)
        }
    }
}
