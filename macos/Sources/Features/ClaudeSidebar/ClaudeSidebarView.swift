import SwiftUI

/// The terminal's background at the terminal's opacity; a material or tint here reads as a foreign panel.
private func claudeSidebarFill(background: Color, opacity: Double) -> Color {
    background.opacity(opacity.clamped(to: 0.001...1))
}

/// Which highlight a session row gets; the focused tab outranks merely-open sessions.
enum ClaudeSessionHighlight {
    case none
    case open
    case active

    /// Activeness wins outright: the open set comes from a poll that can lag a tab switch.
    static func of(isOpen: Bool, isActive: Bool) -> ClaudeSessionHighlight {
        if isActive { return .active }
        return isOpen ? .open : .none
    }
}

/// Historical Claude Code sessions grouped by working directory, with live activity indicators.
struct ClaudeSidebarView: View {
    /// Fixed rather than draggable, so per-window widths can't drift and break the shared-panel illusion.
    static let width: CGFloat = 260

    @ObservedObject private var index = ClaudeSessionIndex.shared
    @ObservedObject private var monitor = ClaudeLiveSessionMonitor.shared
    @ObservedObject private var state = ClaudeSidebarState.shared

    /// The terminal theme's background and opacity, which paint the sidebar and pick its color scheme.
    let backgroundColor: Color
    let backgroundOpacity: Double

    /// The split divider color, used for the boundary and group separators.
    let dividerColor: Color

    /// The focused surface's foreground process, which marks this window's current tab.
    let activeForegroundPID: Int?

    /// Closures because the window and directory both change out from under a SwiftUI view.
    let hostWindow: () -> NSWindow?
    let currentPwd: () -> String?

    private var activePID: pid_t? {
        activeForegroundPID.flatMap { pid_t(exactly: $0) }
    }

    /// Both unwrapped, since two nil pids would otherwise compare equal and light up every row.
    private func isActive(_ live: ClaudeLiveSession?) -> Bool {
        guard let live, let activePID else { return false }
        return live.pid == activePID
    }

    /// Pinned projects in recency order, with pinned directories that have no transcripts yet at the end.
    private var displayProjects: [ClaudeProject] {
        let pinned = state.pinnedProjects
        guard !pinned.isEmpty else { return [] }
        let pinnedSet = Set(pinned)
        var projects = index.projects.filter { pinnedSet.contains($0.cwd) }
        let present = Set(projects.map(\.cwd))
        for cwd in pinned where !present.contains(cwd) {
            projects.append(ClaudeProject(cwd: cwd, sessions: []))
        }
        return projects
    }

    var body: some View {
        let projects = displayProjects

        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)

            if projects.isEmpty {
                emptyState
            } else {
                sessionList(projects)
            }
        }
        .frame(width: Self.width)
        .background(claudeSidebarFill(
            background: backgroundColor, opacity: backgroundOpacity))
        .environment(\.colorScheme, NSColor(backgroundColor).isLightColor ? .light : .dark)
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("Claude Code")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                ClaudeSidebarCoordinator.addProject(from: hostWindow())
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(ClaudeSidebarIconButtonStyle())
            .help("Add a project to the sidebar")

            Button {
                ClaudeSidebarCoordinator.newConversation(
                    cwd: currentPwd(), from: hostWindow())
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(ClaudeSidebarIconButtonStyle())
            .help("New Claude conversation in the current directory")

            Button {
                state.isVisible = false
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ClaudeSidebarIconButtonStyle())
            .help("Hide sidebar")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No projects yet")
                .font(.system(size: 13, weight: .medium))
            Text("Open a Claude session or add a project")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Project") {
                ClaudeSidebarCoordinator.addProject(from: hostWindow())
            }
            .controlSize(.small)
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func sessionList(_ projects: [ClaudeProject]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(projects) { project in
                    if project.id != projects.first?.id {
                        Rectangle()
                            .fill(dividerColor)
                            .frame(height: 1)
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                    }

                    ClaudeSidebarProjectHeader(project: project, hostWindow: hostWindow)

                    if project.sessions.isEmpty {
                        Text("No sessions yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }

                    let total = project.sessions.count
                    let shown = state.visibleSessionCount(for: project.cwd, total: total)

                    ForEach(project.sessions.prefix(shown), id: \.sessionID) { session in
                        let live = monitor.bySessionID[session.sessionID]
                        ClaudeSidebarSessionRow(
                            session: session,
                            live: live,
                            highlight: .of(
                                isOpen: monitor.openInAppSessionIDs.contains(session.sessionID),
                                isActive: isActive(live)),
                            hostWindow: hostWindow)
                    }

                    let hidden = total - shown
                    if hidden > 0 || shown > ClaudeSidebarState.sessionPageSize {
                        ClaudeSidebarShowMoreRow(
                            moreCount: min(hidden, ClaudeSidebarState.sessionPageSize),
                            canShowLess: shown > ClaudeSidebarState.sessionPageSize,
                            showMore: { state.revealMoreSessions(for: project.cwd, total: total) },
                            showLess: { state.collapseSessions(for: project.cwd) })
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }
}

/// The collapsed sidebar: a rail that keeps the sidebar discoverable without overlapping the terminal.
struct ClaudeSidebarRail: View {
    static let width: CGFloat = 28

    @ObservedObject private var state = ClaudeSidebarState.shared

    let backgroundColor: Color
    let backgroundOpacity: Double
    let hostWindow: () -> NSWindow?
    let currentPwd: () -> String?

    var body: some View {
        VStack(spacing: 10) {
            Button {
                state.isVisible = true
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(ClaudeSidebarIconButtonStyle())
            .help("Show sidebar")

            Button {
                ClaudeSidebarCoordinator.newConversation(
                    cwd: currentPwd(), from: hostWindow())
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(ClaudeSidebarIconButtonStyle())
            .help("New Claude conversation in the current directory")

            Spacer()
        }
        .padding(.top, 8)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(claudeSidebarFill(
            background: backgroundColor, opacity: backgroundOpacity))
        .environment(\.colorScheme, NSColor(backgroundColor).isLightColor ? .light : .dark)
    }
}

/// One project group header: the directory name plus a hover "+" that starts a conversation there.
private struct ClaudeSidebarProjectHeader: View {
    let project: ClaudeProject
    let hostWindow: () -> NSWindow?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(project.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project.cwd)

            Spacer(minLength: 4)

            // Always laid out, only revealed on hover: inserting it would resize the row under the pointer.
            Button {
                ClaudeSidebarCoordinator.newConversation(
                    cwd: project.cwd, from: hostWindow())
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(ClaudeSidebarIconButtonStyle(size: 10, frame: 18))
            .help("New Claude conversation in this project")
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                ClaudeSidebarCoordinator.revealInFinder(cwd: project.cwd)
            }
            Button("Open in VS Code") {
                ClaudeSidebarCoordinator.openInVSCode(cwd: project.cwd)
            }
            .disabled(ClaudeSidebarCoordinator.vsCodeURL == nil)
            Divider()
            Button("Remove from Sidebar") {
                ClaudeSidebarState.shared.unpinProject(project.cwd)
            }
        }
    }
}

/// One session row: title, relative time, and the live activity indicator.
private struct ClaudeSidebarSessionRow: View {
    let session: ClaudeTranscriptSummary
    let live: ClaudeLiveSession?

    /// Drives the accent bar and wash: none, open in a tab, or this window's current tab.
    let highlight: ClaudeSessionHighlight

    let hostWindow: () -> NSWindow?

    @State private var isHovering = false

    /// Ghostty's UI is English regardless of system locale.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Green separates this window's current tab from the other sessions merely open in tabs.
    private var accent: Color {
        highlight == .active ? Color.green : Color.accentColor
    }

    private var rowFill: Color {
        if highlight != .none { return accent.opacity(isHovering ? 0.20 : 0.14) }
        return isHovering ? Color.primary.opacity(0.08) : Color.clear
    }

    /// Explicit registry name > transcript title > derived registry name as a last resort.
    private var rowTitle: String {
        if let live, let name = live.name, !live.nameIsDerived { return name }
        return session.title ?? live?.name ?? "Untitled session"
    }

    var body: some View {
        Button {
            ClaudeSidebarCoordinator.openOrFocus(session: session, from: hostWindow())
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle)
                        .font(.system(size: 13, weight: highlight == .none ? .regular : .medium))
                        .lineLimit(1)

                    if let lastActivity = session.lastActivity {
                        Text(Self.relativeFormatter.localizedString(
                            for: lastActivity, relativeTo: Date()))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                ClaudeActivityIndicatorView(activity: live?.activity)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowFill)
                .overlay(alignment: .leading) {
                    if highlight != .none {
                        Capsule()
                            .fill(accent)
                            .frame(width: 3)
                            .padding(.vertical, 4)
                    }
                }
        )
        .onHover { isHovering = $0 }
    }
}

/// The per-project paging row: one page more on the left, back to the first page on the right.
private struct ClaudeSidebarShowMoreRow: View {
    let moreCount: Int
    let canShowLess: Bool
    let showMore: () -> Void
    let showLess: () -> Void

    @State private var hoveringMore = false
    @State private var hoveringLess = false

    var body: some View {
        HStack(spacing: 4) {
            if moreCount > 0 {
                pagingButton(
                    title: "Show \(moreCount) more",
                    icon: "chevron.down",
                    iconLeading: true,
                    isHovering: hoveringMore,
                    action: showMore
                )
                .onHover { hoveringMore = $0 }
            }

            Spacer(minLength: 4)

            if canShowLess {
                pagingButton(
                    title: "Show less",
                    icon: "chevron.up",
                    iconLeading: false,
                    isHovering: hoveringLess,
                    action: showLess
                )
                .onHover { hoveringLess = $0 }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
    }

    private func pagingButton(
        title: String,
        icon: String,
        iconLeading: Bool,
        isHovering: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if iconLeading { chevron(icon) }
                Text(title)
                    .font(.system(size: 11))
                if !iconLeading { chevron(icon) }
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chevron(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
    }
}

/// Icon buttons: secondary until pointed at, with a soft square so they read as controls without borders.
private struct ClaudeSidebarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 12

    /// The hit area, which also sets the height of whatever row the button sits in.
    var frame: CGFloat = 22

    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(
                isHovering || configuration.isPressed
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(.secondary))
            .frame(width: frame, height: frame)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0))))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

/// Spinner while Claude works, dot while it waits, nothing otherwise; shared with the tab accessory.
struct ClaudeActivityIndicatorView: View {
    let activity: ClaudeLiveSession.Activity?
    var small = false

    var body: some View {
        switch activity {
        case .busy:
            ProgressView()
                .controlSize(small ? .mini : .small)
        case .idle:
            Circle()
                .fill(.secondary)
                .frame(width: 6, height: 6)
        case nil:
            EmptyView()
        }
    }
}
