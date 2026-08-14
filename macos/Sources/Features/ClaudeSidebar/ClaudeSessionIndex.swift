import Foundation
import CoreServices

/// One working directory's worth of Claude Code sessions.
struct ClaudeProject: Identifiable, Equatable {
    var id: String { cwd }

    let cwd: String

    /// Sessions, most recently active first.
    var sessions: [ClaudeTranscriptSummary]

    var displayName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    var lastActivity: Date? {
        sessions.compactMap(\.lastActivity).max()
    }
}

/// The index of historical Claude Code sessions the sidebar shows, built by
/// scanning the transcripts under `~/.claude/projects`.
///
/// The initial scan runs off the main actor and is incremental afterwards: a
/// transcript is only re-parsed when its size or mtime moved (mtime is fine
/// for cache invalidation; it's only ordering that can't trust it). An
/// FSEvents watch on the projects directory triggers rescans, which also
/// covers Claude's ~30-day garbage collection deleting transcripts out from
/// under us.
@MainActor
final class ClaudeSessionIndex: ObservableObject {
    static let shared = ClaudeSessionIndex()

    /// Projects, most recently active first.
    @Published private(set) var projects: [ClaudeProject] = []

    private var started = false
    private var eventStream: FSEventStreamRef?
    private var rescanPending = false
    private var rescanRunning = false

    /// Parse results keyed by transcript path. A nil summary records that a
    /// file was unparseable so we don't retry it every scan.
    nonisolated(unsafe) private var cache: [String: CacheEntry] = [:]
    private struct CacheEntry {
        let size: Int64
        let mtime: Date
        let summary: ClaudeTranscriptSummary?
    }

    /// Begin the initial scan and directory watch. Safe to call repeatedly.
    func start() {
        guard !started else { return }
        started = true
        startWatching()
        scheduleRescan()
    }

    /// Coalesce rescan requests: one at a time, at most one queued behind it.
    func scheduleRescan() {
        guard !rescanRunning else {
            rescanPending = true
            return
        }
        rescanRunning = true
        Task { [weak self] in
            guard let self else { return }
            let projects = await self.rescan()
            self.projects = projects
            self.rescanRunning = false
            if self.rescanPending {
                self.rescanPending = false
                self.scheduleRescan()
            }
        }
    }

    // MARK: - Scanning

    nonisolated private static var projectsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Nonisolated so the scan runs off the main actor. Only `scheduleRescan`
    /// calls this, one at a time, which is what makes the cache access safe.
    nonisolated private func rescan() async -> [ClaudeProject] {
        let fileManager = FileManager.default
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: Self.projectsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }

        var summaries: [ClaudeTranscriptSummary] = []
        var seenPaths: Set<String> = []
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

        for dir in projectDirs {
            // A project dir holds the transcripts plus same-named sidecar
            // directories and a memory/ directory; only regular *.jsonl
            // files are transcripts.
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true
                else { continue }

                let path = file.path
                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate ?? .distantPast
                seenPaths.insert(path)

                if let entry = cache[path], entry.size == size, entry.mtime == mtime {
                    if let summary = entry.summary { summaries.append(summary) }
                    continue
                }

                let summary = ClaudeTranscriptParser.parse(fileURL: file)
                cache[path] = CacheEntry(size: size, mtime: mtime, summary: summary)
                if let summary { summaries.append(summary) }
            }
        }

        // Deleted transcripts must not linger in the cache.
        cache = cache.filter { seenPaths.contains($0.key) }

        return Self.group(summaries)
    }

    /// Group summaries into projects by their recorded working directory,
    /// everything ordered most recent first.
    nonisolated static func group(_ summaries: [ClaudeTranscriptSummary]) -> [ClaudeProject] {
        let grouped: [String: [ClaudeTranscriptSummary]] = Dictionary(
            grouping: summaries, by: { $0.cwd })

        var projects: [ClaudeProject] = grouped.map { cwd, sessions in
            let sorted = sessions.sorted { lhs, rhs in
                (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
            }
            return ClaudeProject(cwd: cwd, sessions: sorted)
        }

        // Sessions are sorted, so a project's recency is its first session's.
        projects.sort { lhs, rhs in
            (lhs.sessions.first?.lastActivity ?? .distantPast)
                > (rhs.sessions.first?.lastActivity ?? .distantPast)
        }
        return projects
    }

    // MARK: - Directory watching

    private func startWatching() {
        guard eventStream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)

        // FSEvents watches recursively, so one stream on the projects root
        // sees new transcripts, appends, and garbage collection everywhere
        // beneath it.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let index = Unmanaged<ClaudeSessionIndex>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in index.scheduleRescan() }
            },
            &context,
            [Self.projectsURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
