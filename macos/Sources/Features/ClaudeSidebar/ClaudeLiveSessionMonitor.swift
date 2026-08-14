import Foundation

/// A Claude Code session that is currently running somewhere on this machine.
struct ClaudeLiveSession: Equatable {
    enum Activity: Equatable {
        /// Actively working. Rendered as a spinner.
        case busy

        /// Process alive but waiting. Any registry status other than "busy"
        /// lands here, including states newer Claude versions may add.
        case idle
    }

    let pid: pid_t
    let sessionID: String
    let cwd: String
    let name: String?
    let activity: Activity
    let updatedAt: Date
}

/// Watches the live-session registry Claude Code maintains at
/// `~/.claude/sessions/<pid>.json`, one file per running interactive session.
///
/// The files are rewritten in place as a session's status changes, and stale
/// files for dead processes do occur, so each poll validates every pid with
/// `kill(pid, 0)`. The registry's `statusUpdatedAt` is event-driven rather
/// than a heartbeat — a session can sit idle for days without touching its
/// file — so staleness of the file itself means nothing.
///
/// `claude agents --json` reports the same data but spawns the full Claude
/// binary, far too slow to poll; the files are the hot path.
@MainActor
final class ClaudeLiveSessionMonitor: ObservableObject {
    static let shared = ClaudeLiveSessionMonitor()

    @Published private(set) var bySessionID: [String: ClaudeLiveSession] = [:]
    @Published private(set) var byPID: [pid_t: ClaudeLiveSession] = [:]

    /// Sessions running in one of this app's own tabs, as opposed to some
    /// other terminal: a session whose pid is the foreground process of one
    /// of our surfaces. These get the sidebar's "open" highlight.
    @Published private(set) var openInAppSessionIDs: Set<String> = []

    /// The previous poll's open set, for edge-triggered pinning: a project
    /// is pinned when a session in it *becomes* open, never continuously —
    /// otherwise removing a project while its session is open would undo
    /// itself two seconds later.
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

        // A session becoming open earns its project a permanent place in
        // the sidebar. This covers sessions the user starts by hand in a
        // tab just as well as ones the sidebar spawned.
        for sessionID in newOpen.subtracting(previouslyOpenSessionIDs) {
            if let live = newBySessionID[sessionID] {
                ClaudeSidebarState.shared.pinProject(live.cwd)
            }
        }
        previouslyOpenSessionIDs = newOpen

        // Publish only on real change so an idle system doesn't invalidate
        // SwiftUI observers every poll.
        if newOpen != openInAppSessionIDs {
            openInAppSessionIDs = newOpen
        }
        guard newBySessionID != bySessionID else { return }
        bySessionID = newBySessionID
        byPID = Dictionary(sessions.map { ($0.pid, $0) }) { _, last in last }
    }

    /// One-shot lookup of the session a process is running, for callers that
    /// need an answer synchronously (session snapshotting). Reads a single
    /// tiny file.
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

    /// The on-disk shape of one registry entry. Alongside these files live
    /// `<pid>.<hash>.key` credential files which are deliberately never read.
    private struct RegistryEntry: Decodable {
        let pid: pid_t
        let sessionId: String
        let cwd: String
        let status: String?
        let name: String?
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
                    activity: entry.status == "busy" ? .busy : .idle,
                    updatedAt: Date(timeIntervalSince1970: (entry.updatedAt ?? 0) / 1000))
            }
    }

    nonisolated private static func readEntry(at url: URL) -> RegistryEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RegistryEntry.self, from: data)
    }

    /// Whether a pid is alive. EPERM means the process exists but belongs to
    /// someone else, which still counts.
    nonisolated private static func processExists(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
