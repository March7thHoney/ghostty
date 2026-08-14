import AppKit

/// App-wide sidebar state. Every terminal window renders the sidebar from
/// this one object, which is what makes the sidebar look like a single shared
/// panel across native tabs (each tab is its own window): they all show the
/// same thing, and collapsing one collapses them all.
@MainActor
final class ClaudeSidebarState: ObservableObject {
    static let shared = ClaudeSidebarState()

    private static let visibleKey = "ClaudeSidebarVisible"
    private static let pinnedKey = "ClaudePinnedProjects"

    /// Whether the sidebar is expanded. Defaults to visible.
    @Published var isVisible: Bool {
        didSet { UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey) }
    }

    /// Projects (by cwd) showing all of their sessions instead of the first
    /// few. Shared so tabs — each its own window — stay in sync; deliberately
    /// not persisted.
    @Published var expandedProjects: Set<String> = []

    /// The working directories the sidebar shows, in the order they were
    /// added. The sidebar starts empty; a project earns its place by having
    /// a session opened, a conversation started, or being added by hand —
    /// and then stays until removed.
    @Published private(set) var pinnedProjects: [String] {
        didSet { UserDefaults.ghostty.set(pinnedProjects, forKey: Self.pinnedKey) }
    }

    private init() {
        isVisible = UserDefaults.ghostty.object(forKey: Self.visibleKey) as? Bool ?? true
        pinnedProjects = UserDefaults.ghostty.array(forKey: Self.pinnedKey) as? [String] ?? []
    }

    /// Add a project to the sidebar. Paths are normalized (no trailing
    /// slash) so directories arriving from the session registry, transcripts,
    /// and the open panel all compare equal.
    func pinProject(_ cwd: String) {
        let normalized = Self.normalize(cwd)
        guard !normalized.isEmpty, !pinnedProjects.contains(normalized) else { return }
        pinnedProjects.append(normalized)
    }

    /// Remove a project from the sidebar. It can return through pinProject,
    /// but not by the automatic re-pin of sessions that are already open.
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

    // MARK: - Pending spawns

    /// A tab we opened for a session that hasn't appeared in the live-session
    /// registry yet because Claude is still starting. Until it registers,
    /// the foreground-pid search can't find it, so without this a second
    /// click on the row would open a second tab.
    struct PendingSpawn {
        weak var controller: TerminalController?
        let spawnedAt: Date
    }

    /// Keyed by session ID.
    private(set) var pendingSpawns: [String: PendingSpawn] = [:]

    /// How long a spawn stays pending. If Claude never registers (resume
    /// failed, transcript gone), the entry must not capture the row's clicks
    /// forever.
    private static let pendingSpawnLifetime: TimeInterval = 60

    func notePendingSpawn(sessionID: String, controller: TerminalController) {
        pendingSpawns[sessionID] = PendingSpawn(controller: controller, spawnedAt: Date())
    }

    /// The still-valid pending tab for a session, pruning as a side effect.
    func pendingSpawnController(for sessionID: String) -> TerminalController? {
        prunePendingSpawns()
        return pendingSpawns[sessionID]?.controller
    }

    /// Drop entries whose tab is gone, whose session has registered (the
    /// normal lookup finds those), or that have outlived their usefulness.
    func prunePendingSpawns() {
        let live = ClaudeLiveSessionMonitor.shared.bySessionID
        pendingSpawns = pendingSpawns.filter { sessionID, pending in
            pending.controller != nil
                && live[sessionID] == nil
                && Date().timeIntervalSince(pending.spawnedAt) < Self.pendingSpawnLifetime
        }
    }
}
