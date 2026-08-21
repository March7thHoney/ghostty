import SwiftUI

/// The terminal's background at the terminal's opacity; a material or tint here reads as a foreign panel.
private func workspacePanelFill(background: Color, opacity: Double) -> Color {
    background.opacity(opacity.clamped(to: 0.001...1))
}

/// The right-side workspace panel: a file tree and a read-only git status view.
struct WorkspacePanelView: View {
    /// Fixed rather than draggable, so per-window widths can't drift and break the shared-panel illusion.
    static let width: CGFloat = 320

    @ObservedObject private var state = WorkspacePanelState.shared

    /// The terminal theme's background and opacity, which paint the panel and pick its color scheme.
    let backgroundColor: Color
    let backgroundOpacity: Double

    /// The split divider color, used for the boundary and internal separators.
    let dividerColor: Color

    /// The focused surface's working directory, which decides the workspace shown.
    let pwd: String?

    /// The workspace this panel renders; also the directory the VS Code button opens.
    @State private var model: WorkspaceModel?

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            if let model {
                WorkspacePanelContent(model: model, dividerColor: dividerColor)
                    .id(model.root.path)
            } else {
                waitingState
            }
        }
        .frame(width: Self.width)
        // SwiftUI does not clip overflow, so one runaway width would otherwise paint over the terminal.
        .clipped()
        .background(workspacePanelFill(
            background: backgroundColor, opacity: backgroundOpacity))
        .environment(\.colorScheme, NSColor(backgroundColor).isLightColor ? .light : .dark)
        // Resolving pwd's repository root walks the filesystem, so it stays off the render pass.
        .task(id: pwd) { model = await WorkspaceRegistry.shared.model(forPwd: pwd) }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button {
                state.selectedTab = .files
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(WorkspacePanelIconButtonStyle(isActive: state.selectedTab == .files))
            .help("Files")

            Button {
                state.selectedTab = .git
            } label: {
                Image(systemName: "arrow.triangle.branch")
            }
            .buttonStyle(WorkspacePanelIconButtonStyle(isActive: state.selectedTab == .git))
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
                .buttonStyle(WorkspacePanelIconButtonStyle())
                .help("Open in VS Code")
            }

            Spacer()

            Button {
                state.isVisible = false
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(WorkspacePanelIconButtonStyle())
            .help("Hide panel")
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private var waitingState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No working directory yet")
                .font(.system(size: 13, weight: .medium))
            Text("The panel follows the focused terminal's directory")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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

    let backgroundColor: Color
    let backgroundOpacity: Double

    var body: some View {
        VStack(spacing: 10) {
            Button {
                state.isVisible = true
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(WorkspacePanelIconButtonStyle())
            .help("Show panel")

            Spacer()
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(workspacePanelFill(
            background: backgroundColor, opacity: backgroundOpacity))
        .environment(\.colorScheme, NSColor(backgroundColor).isLightColor ? .light : .dark)
    }
}

/// The panel body for one resolved workspace: breadcrumb, active tab, and optional preview split.
private struct WorkspacePanelContent: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var state = WorkspacePanelState.shared

    let dividerColor: Color

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
                SplitView(.vertical, $state.previewSplit, dividerColor: dividerColor) {
                    listArea
                } right: {
                    WorkspacePreviewView(
                        model: model, tab: state.selectedTab, gitMode: state.gitMode,
                        dividerColor: dividerColor)
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
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(model.root.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.root.path)

            Spacer(minLength: 4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var listArea: some View {
        switch state.selectedTab {
        case .files:
            WorkspaceFileTreeView(model: model)
        case .git:
            WorkspaceGitView(model: model, dividerColor: dividerColor)
        }
    }
}

/// Segments that share the icon buttons' wash, because a stock Picker's material reads as foreign here.
struct WorkspacePanelSegmentStyle: ButtonStyle {
    var isActive = false

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(
                isActive || isHovering || configuration.isPressed
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.14 : (isActive ? 0.10 : (isHovering ? 0.08 : 0)))))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Icon buttons: secondary until pointed at, with a soft square so they read as controls without borders.
struct WorkspacePanelIconButtonStyle: ButtonStyle {
    var size: CGFloat = 12

    /// The hit area, which also sets the height of whatever row the button sits in.
    var frame: CGFloat = 22

    /// Keeps the active tab's button highlighted even when not hovered.
    var isActive = false

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(
                isActive || isHovering || configuration.isPressed
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(.secondary))
            .frame(width: frame, height: frame)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.14 : (isActive ? 0.10 : (isHovering ? 0.08 : 0)))))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}
