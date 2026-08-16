import AppKit

/// App-wide sidebar state; every window renders from it, so tabs look like one shared panel.
@MainActor
final class ClaudeSidebarState: ObservableObject {
    static let shared = ClaudeSidebarState()

    private static let visibleKey = "ClaudeSidebarVisible"
    private static let pinnedKey = "ClaudePinnedProjects"

    /// Whether the sidebar is expanded. Defaults to visible.
    @Published var isVisible: Bool {
        didSet { UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey) }
    }

    /// Sessions a project shows before "Show more", and how many each click adds.
    nonisolated static let sessionPageSize = 5

    /// Sessions revealed per project, keyed by cwd; shared across tabs, not persisted.
    @Published private var revealedSessions: [String: Int] = [:]

    /// Directories the sidebar shows, in the order added; it starts empty and each stays until removed.
    @Published private(set) var pinnedProjects: [String] {
        didSet { UserDefaults.ghostty.set(pinnedProjects, forKey: Self.pinnedKey) }
    }

    private init() {
        isVisible = UserDefaults.ghostty.object(forKey: Self.visibleKey) as? Bool ?? true
        pinnedProjects = UserDefaults.ghostty.array(forKey: Self.pinnedKey) as? [String] ?? []
    }

    /// Paths are normalized so the registry, transcripts, and the open panel all compare equal.
    func pinProject(_ cwd: String) {
        let normalized = Self.normalize(cwd)
        guard !normalized.isEmpty, !pinnedProjects.contains(normalized) else { return }
        pinnedProjects.append(normalized)
    }

    /// Removal sticks: already-open sessions don't re-pin, only newly opened ones do.
    func unpinProject(_ cwd: String) {
        let normalized = Self.normalize(cwd)
        pinnedProjects.removeAll { $0 == normalized }
    }

    private static func normalize(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: - Session paging

    /// Clamped so a rescan that removes sessions can't leave a project claiming more than it has.
    nonisolated static func visibleSessionCount(revealed: Int?, total: Int) -> Int {
        min(max(revealed ?? sessionPageSize, sessionPageSize), total)
    }

    func visibleSessionCount(for cwd: String, total: Int) -> Int {
        Self.visibleSessionCount(revealed: revealedSessions[cwd], total: total)
    }

    /// One page more, so a project with many sessions grows in steps rather than all at once.
    func revealMoreSessions(for cwd: String, total: Int) {
        let shown = visibleSessionCount(for: cwd, total: total)
        revealedSessions[cwd] = min(shown + Self.sessionPageSize, total)
    }

    func collapseSessions(for cwd: String) {
        revealedSessions[cwd] = nil
    }

    // MARK: - Conversation clipboard

    /// What "Copy Conversation" grabbed; in-memory only, so a stale ID can't survive a relaunch.
    struct CopiedConversation: Equatable {
        let sessionID: String
        let title: String
        let sourceCwd: String
    }

    /// Kept after paste, so one copy can seed several projects.
    @Published private(set) var copiedConversation: CopiedConversation?

    func copyConversation(sessionID: String, title: String, sourceCwd: String) {
        copiedConversation = CopiedConversation(
            sessionID: sessionID, title: title, sourceCwd: sourceCwd)
    }

    /// Deleting the copied conversation empties the clipboard, so paste can't fork a missing file.
    func forgetCopiedConversation(sessionID: String) {
        guard copiedConversation?.sessionID == sessionID else { return }
        copiedConversation = nil
    }

    /// Menus don't truncate, so a long title is clipped here rather than stretching the item.
    nonisolated static func pasteMenuTitle(copiedTitle: String?) -> String {
        guard let copiedTitle else { return "Paste Conversation" }
        let clipped = copiedTitle.count > 40
            ? copiedTitle.prefix(40) + "…"
            : copiedTitle[...]
        return "Paste Conversation \u{201C}\(clipped)\u{201D}"
    }

    // MARK: - Pending spawns

    /// A tab whose Claude is still starting, so the pid search can't find it and a second click would duplicate it.
    struct PendingSpawn {
        weak var controller: TerminalController?
        let spawnedAt: Date
    }

    /// Keyed by session ID.
    private(set) var pendingSpawns: [String: PendingSpawn] = [:]

    /// Bounded so a Claude that never registers doesn't capture the row's clicks forever.
    private static let pendingSpawnLifetime: TimeInterval = 60

    func notePendingSpawn(sessionID: String, controller: TerminalController) {
        pendingSpawns[sessionID] = PendingSpawn(controller: controller, spawnedAt: Date())
    }

    /// The still-valid pending tab for a session, pruning as a side effect.
    func pendingSpawnController(for sessionID: String) -> TerminalController? {
        prunePendingSpawns()
        return pendingSpawns[sessionID]?.controller
    }

    /// Drop entries whose tab is gone, whose session has registered, or that have expired.
    func prunePendingSpawns() {
        let live = ClaudeLiveSessionMonitor.shared.bySessionID
        pendingSpawns = pendingSpawns.filter { sessionID, pending in
            pending.controller != nil
                && live[sessionID] == nil
                && Date().timeIntervalSince(pending.spawnedAt) < Self.pendingSpawnLifetime
        }
    }
}
