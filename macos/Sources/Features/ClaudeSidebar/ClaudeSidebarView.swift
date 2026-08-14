import SwiftUI

/// The Claude Code sessions sidebar: historical sessions grouped by working
/// directory, with live activity indicators.
///
/// Styling follows the command palette (CommandPalette.swift), the app's
/// reference for theme-aware SwiftUI: a material tinted with the terminal's
/// background color, a forced color scheme derived from that color's
/// lightness, and `.primary`/`.secondary` for all text so any theme stays
/// legible.
struct ClaudeSidebarView: View {
    /// The expanded sidebar width. Fixed rather than draggable: every native
    /// tab is its own window rendering its own copy of this sidebar, and
    /// per-window widths drifting apart would break the illusion that it's
    /// one shared panel.
    static let width: CGFloat = 260

    /// Sessions shown per project before the rest hides behind "Show more".
    static let collapsedSessionLimit = 5

    @ObservedObject private var index = ClaudeSessionIndex.shared
    @ObservedObject private var monitor = ClaudeLiveSessionMonitor.shared
    @ObservedObject private var state = ClaudeSidebarState.shared

    /// The terminal theme's background, used to tint the sidebar and pick
    /// the color scheme.
    let backgroundColor: Color

    /// The split divider color, used for the group separators.
    let dividerColor: Color

    /// The window to open tabs from, and the directory for the header's
    /// new-conversation button. Closures because both change out from under
    /// a SwiftUI view.
    let hostWindow: () -> NSWindow?
    let currentPwd: () -> String?

    var body: some View {
        let scheme: ColorScheme = NSColor(backgroundColor).isLightColor ? .light : .dark

        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(dividerColor)
                .frame(height: 1)
            if index.projects.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .frame(width: Self.width)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(backgroundColor).blendMode(.color)
            }
            .compositingGroup()
        )
        .environment(\.colorScheme, scheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Code")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                ClaudeSidebarCoordinator.newConversation(
                    cwd: currentPwd(), from: hostWindow())
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("New Claude conversation in the current directory")

            Button {
                state.isVisible = false
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Hide sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No Claude Code sessions yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(index.projects) { project in
                    if project.id != index.projects.first?.id {
                        Rectangle()
                            .fill(dividerColor)
                            .frame(height: 1)
                            .padding(.top, 10)
                    }

                    ClaudeSidebarProjectHeader(project: project, hostWindow: hostWindow)

                    let expanded = state.expandedProjects.contains(project.cwd)
                    let visible = expanded
                        ? project.sessions
                        : Array(project.sessions.prefix(Self.collapsedSessionLimit))

                    ForEach(visible, id: \.sessionID) { session in
                        ClaudeSidebarSessionRow(
                            session: session,
                            live: monitor.bySessionID[session.sessionID],
                            hostWindow: hostWindow)
                    }

                    if project.sessions.count > Self.collapsedSessionLimit {
                        ClaudeSidebarShowMoreRow(
                            expanded: expanded,
                            hiddenCount: project.sessions.count - Self.collapsedSessionLimit
                        ) {
                            if expanded {
                                state.expandedProjects.remove(project.cwd)
                            } else {
                                state.expandedProjects.insert(project.cwd)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }
}

/// The collapsed sidebar: a narrow rail whose buttons reopen the sidebar or
/// start a conversation. A persistent rail (rather than nothing) keeps the
/// sidebar discoverable and never overlaps terminal content.
struct ClaudeSidebarRail: View {
    static let width: CGFloat = 28

    @ObservedObject private var state = ClaudeSidebarState.shared

    let backgroundColor: Color
    let hostWindow: () -> NSWindow?
    let currentPwd: () -> String?

    var body: some View {
        let scheme: ColorScheme = NSColor(backgroundColor).isLightColor ? .light : .dark

        VStack(spacing: 14) {
            Button {
                state.isVisible = true
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("Show sidebar")

            Button {
                ClaudeSidebarCoordinator.newConversation(
                    cwd: currentPwd(), from: hostWindow())
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("New Claude conversation in the current directory")

            Spacer()
        }
        .padding(.top, 12)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(backgroundColor).blendMode(.color)
            }
            .compositingGroup()
        )
        .environment(\.colorScheme, scheme)
    }
}

/// One project group header: the directory name plus a hover "+" that starts
/// a conversation in that project.
private struct ClaudeSidebarProjectHeader: View {
    let project: ClaudeProject
    let hostWindow: () -> NSWindow?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(project.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project.cwd)

            Spacer()

            if isHovering {
                Button {
                    ClaudeSidebarCoordinator.newConversation(
                        cwd: project.cwd, from: hostWindow())
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("New Claude conversation in this project")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// One session row: title, relative time, and the live activity indicator.
private struct ClaudeSidebarSessionRow: View {
    let session: ClaudeTranscriptSummary
    let live: ClaudeLiveSession?
    let hostWindow: () -> NSWindow?

    @State private var isHovering = false

    /// Ghostty's UI is English regardless of system locale.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Button {
            ClaudeSidebarCoordinator.openOrFocus(session: session, from: hostWindow())
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    // A running session's registry name is fresher than
                    // anything in the transcript.
                    Text(live?.name ?? session.title ?? "Untitled session")
                        .font(.system(size: 13))
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.secondary.opacity(0.2) : Color.clear))
        .onHover { isHovering = $0 }
    }
}

/// The per-project "Show N more" / "Show less" toggle row.
private struct ClaudeSidebarShowMoreRow: View {
    let expanded: Bool
    let hiddenCount: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(expanded ? "Show less" : "Show \(hiddenCount) more")
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// The busy/idle indicator: a spinner while Claude is working, a dot while
/// it's alive but waiting, nothing otherwise. Shared between sidebar rows
/// and the tab bar accessory (where non-interactive SwiftUI is fine).
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
