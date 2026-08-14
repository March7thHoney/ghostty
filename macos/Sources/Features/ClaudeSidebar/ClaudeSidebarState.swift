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

    /// Projects showing all their sessions rather than the first few; shared across tabs, not persisted.
    @Published var expandedProjects: Set<String> = []

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
