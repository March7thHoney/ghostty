import Foundation

/// A Claude Code session that is currently running somewhere on this machine.
struct ClaudeLiveSession: Equatable {
    enum Activity: Equatable {
        /// Actively working. Rendered as a spinner.
        case busy

        /// Alive but waiting; any registry status other than "busy" lands here.
        case idle
    }

    let pid: pid_t
    let sessionID: String
    let cwd: String
    let name: String?
    /// True when the registry name is an auto-derived placeholder like "myproject-5c".
    let nameIsDerived: Bool
    let activity: Activity
    let updatedAt: Date
}

/// Watches `~/.claude/sessions/<pid>.json`, Claude's registry of running interactive sessions.
@MainActor
final class ClaudeLiveSessionMonitor: ObservableObject {
    static let shared = ClaudeLiveSessionMonitor()

    @Published private(set) var bySessionID: [String: ClaudeLiveSession] = [:]
    @Published private(set) var byPID: [pid_t: ClaudeLiveSession] = [:]

    /// Sessions whose pid is the foreground process of one of our surfaces, so open in our own tabs.
    @Published private(set) var openInAppSessionIDs: Set<String> = []

    /// Previous poll's open set, so pinning is edge-triggered and a removal isn't undone next poll.
    private var previouslyOpenSessionIDs: Set<String> = []

    private var pollTask: Task<Void, Never>?

    /// Begin polling. Safe to call repeatedly.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let sessions = await Self.readRegistry()
                guard let self else { return }
                self.apply(sessions)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func apply(_ sessions: [ClaudeLiveSession]) {
        let newBySessionID = Dictionary(sessions.map { ($0.sessionID, $0) }) { _, last in last }

        // Which of these sessions are running in our own tabs.
        var foregroundPIDs: Set<pid_t> = []
        for controller in TerminalController.all {
            for surface in controller.surfaceTree {
                if let pid = surface.surfaceModel?.foregroundPID,
                   let pid32 = pid_t(exactly: pid) {
                    foregroundPIDs.insert(pid32)
                }
            }
        }
        let newOpen = Set(sessions.filter { foregroundPIDs.contains($0.pid) }.map(\.sessionID))

        // A session becoming open earns its project a place, however the session was started.
        for sessionID in newOpen.subtracting(previouslyOpenSessionIDs) {
            if let live = newBySessionID[sessionID] {
                ClaudeSidebarState.shared.pinProject(live.cwd)
            }
        }
        previouslyOpenSessionIDs = newOpen

        // Publish only on real change so an idle system doesn't invalidate observers every poll.
        if newOpen != openInAppSessionIDs {
            openInAppSessionIDs = newOpen
        }
        guard newBySessionID != bySessionID else { return }
        bySessionID = newBySessionID
        byPID = Dictionary(sessions.map { ($0.pid, $0) }) { _, last in last }
    }

    /// Synchronous one-shot lookup of the session a process is running, for session snapshotting.
    nonisolated static func sessionID(forPID pid: pid_t) -> String? {
        let url = registryURL.appendingPathComponent("\(pid).json")
        guard let entry = readEntry(at: url), entry.pid == pid else { return nil }
        return entry.sessionId
    }

    // MARK: - Registry reading

    nonisolated private static var registryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }

    /// One registry entry; the `<pid>.<hash>.key` credential files beside them are never read.
    private struct RegistryEntry: Decodable {
        let pid: pid_t
        let sessionId: String
        let cwd: String
        let status: String?
        let name: String?
        let nameSource: String?
        let updatedAt: Double?
    }

    /// Nonisolated so the file IO runs off the main actor.
    nonisolated private static func readRegistry() async -> [ClaudeLiveSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: registryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let entry = readEntry(at: url), processExists(entry.pid) else { return nil }
                return ClaudeLiveSession(
                    pid: entry.pid,
                    sessionID: entry.sessionId,
                    cwd: entry.cwd,
                    name: entry.name,
                    nameIsDerived: entry.nameSource == "derived",
                    activity: entry.status == "busy" ? .busy : .idle,
                    updatedAt: Date(timeIntervalSince1970: (entry.updatedAt ?? 0) / 1000))
            }
    }

    nonisolated private static func readEntry(at url: URL) -> RegistryEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistryEntry.self, from: data)
    }

    /// Whether a pid is alive; EPERM counts, meaning it exists but belongs to someone else.
    nonisolated private static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
