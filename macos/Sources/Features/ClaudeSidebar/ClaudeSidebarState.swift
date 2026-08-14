import AppKit

/// App-wide sidebar state. Every terminal window renders the sidebar from
/// this one object, which is what makes the sidebar look like a single shared
/// panel across native tabs (each tab is its own window): they all show the
/// same thing, and collapsing one collapses them all.
@MainActor
final class ClaudeSidebarState: ObservableObject {
    static let shared = ClaudeSidebarState()

    private static let visibleKey = "ClaudeSidebarVisible"

    /// Whether the sidebar is expanded. Defaults to visible.
    @Published var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: Self.visibleKey) }
    }

    /// Projects (by cwd) showing all of their sessions instead of the first
    /// few. Shared so tabs — each its own window — stay in sync; deliberately
    /// not persisted.
    @Published var expandedProjects: Set<String> = []

    private init() {
        isVisible = UserDefaults.standard.object(forKey: Self.visibleKey) as? Bool ?? true
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
