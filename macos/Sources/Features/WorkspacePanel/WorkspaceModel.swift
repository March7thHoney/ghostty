import Foundation
import CoreServices

/// The git tab's top-level condition.
enum GitState: Equatable {
    case loading
    case notARepo
    case gitUnavailable(String)
    case failed(String)
    case ready(GitStatusSnapshot)
}

/// The diff pane's condition for the selected git entry.
enum DiffState: Equatable {
    case none
    case loading
    case failed(String)
    case ready(ParsedDiff)
}

/// One selected changed file; the section decides which diff base to show.
struct GitDiffEntry: Equatable {
    enum Section: Equatable {
        case staged, unstaged, untracked
    }

    let section: Section
    let path: String
    let origPath: String?
}

/// One workspace root's file tree and git status, shared by every window on the same root.
@MainActor
final class WorkspaceModel: ObservableObject {
    let root: URL
    let isGitRepo: Bool

    @Published private(set) var childrenByDir: [String: [FileTreeNode]] = [:]
    @Published private(set) var deniedDirs: Set<String> = []
    @Published private(set) var expandedDirs: Set<String> = []
    @Published private(set) var selectedFilePath: String?
    @Published private(set) var filePreview: FilePreview?

    @Published private(set) var git: GitState = .loading
    @Published private(set) var selectedGitEntry: GitDiffEntry?
    @Published private(set) var diff: DiffState = .none

    private var started = false
    private var refreshPending = false
    private var refreshRunning = false
    private var previewGeneration = 0
    private var diffGeneration = 0

    /// Touched from deinit, which is nonisolated; only stop()/deinit ever clear it.
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?

    init(root: URL, isGitRepo: Bool) {
        self.root = root
        self.isGitRepo = isGitRepo
        if !isGitRepo { git = .notARepo }
    }

    deinit {
        Self.stopStream(&eventStream)
    }

    /// Begin (or re-trigger) watching and refreshing. Safe to call repeatedly.
    func start() {
        if !started {
            started = true
            startWatching()
        }
        scheduleRefresh()
    }

    /// Stop watching; the registry calls this when it evicts the model.
    func stop() {
        Self.stopStream(&eventStream)
        started = false
    }

    // MARK: - Refresh

    /// Coalesce refresh requests: one at a time, at most one queued behind it.
    func scheduleRefresh() {
        guard !refreshRunning else {
            refreshPending = true
            return
        }
        refreshRunning = true
        Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            self.refreshRunning = false
            if self.refreshPending {
                self.refreshPending = false
                self.scheduleRefresh()
            }
        }
    }

    private func refresh() async {
        let dirs = [root.path] + expandedDirs.sorted()
        async let scanned = Self.scan(dirs: dirs)
        let newGit = isGitRepo ? await Self.fetchStatus(root: root) : GitState.notARepo

        let (children, denied) = await scanned
        childrenByDir = children
        deniedDirs = denied
        git = newGit

        reconcileSelections(after: newGit)
    }

    /// Keep the preview and diff panes truthful after the world changed underneath them.
    private func reconcileSelections(after newGit: GitState) {
        if let selected = selectedFilePath {
            if FileManager.default.fileExists(atPath: selected) {
                loadPreview(for: selected)
            } else {
                selectFile(nil)
            }
        }

        guard let entry = selectedGitEntry else { return }
        if case .ready(let snapshot) = newGit, files(in: entry.section, of: snapshot)
            .contains(where: { $0.path == entry.path }) {
            fetchDiff(for: entry)
        } else {
            selectGitEntry(nil)
        }
    }

    private func files(in section: GitDiffEntry.Section, of snapshot: GitStatusSnapshot) -> [GitFileStatus] {
        switch section {
        case .staged: return snapshot.stagedFiles
        case .unstaged: return snapshot.unstagedFiles
        case .untracked: return snapshot.untrackedFiles
        }
    }

    nonisolated private static func scan(
        dirs: [String]
    ) async -> ([String: [FileTreeNode]], Set<String>) {
        await Task.detached(priority: .utility) {
            var children: [String: [FileTreeNode]] = [:]
            var denied: Set<String> = []
            for dir in dirs {
                if let nodes = FileTreeScanner.children(of: URL(fileURLWithPath: dir)) {
                    children[dir] = nodes
                } else {
                    denied.insert(dir)
                }
            }
            return (children, denied)
        }.value
    }

    nonisolated private static func fetchStatus(root: URL) async -> GitState {
        do {
            // -uall lists untracked files individually, so each row has a previewable diff.
            let output = try await GitRunner.run(
                ["status", "--porcelain=v2", "--branch", "-uall", "-z"], in: root)
            guard output.exitCode == 0 else {
                return .failed(output.stderr.isEmpty ? "git status failed" : output.stderr)
            }
            return .ready(GitStatusParser.parse(output.stdout))
        } catch GitRunner.RunError.gitUnavailable(let reason) {
            return .gitUnavailable(reason)
        } catch GitRunner.RunError.timedOut {
            return .failed("git status timed out")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - File tree selection

    func toggleExpanded(_ dir: String) {
        if expandedDirs.contains(dir) {
            expandedDirs.remove(dir)
        } else {
            expandedDirs.insert(dir)
            // Newly expanded directories haven't been scanned yet.
            if childrenByDir[dir] == nil { scheduleRefresh() }
        }
    }

    func selectFile(_ path: String?) {
        previewGeneration += 1
        selectedFilePath = path
        filePreview = nil
        if let path { loadPreview(for: path) }
    }

    private func loadPreview(for path: String) {
        let generation = previewGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let preview = FileTreeScanner.loadPreview(path: path)
            await self?.publishPreview(preview, generation: generation)
        }
    }

    private func publishPreview(_ preview: FilePreview, generation: Int) {
        guard generation == previewGeneration, preview.path == selectedFilePath else { return }
        filePreview = preview
    }

    // MARK: - Diff selection

    func selectGitEntry(_ entry: GitDiffEntry?) {
        diffGeneration += 1
        selectedGitEntry = entry
        guard let entry else {
            diff = .none
            return
        }
        diff = .loading
        fetchDiff(for: entry)
    }

    private func fetchDiff(for entry: GitDiffEntry) {
        let generation = diffGeneration
        let root = root
        Task.detached(priority: .userInitiated) { [weak self] in
            let state = await Self.loadDiff(entry: entry, root: root)
            await self?.publishDiff(state, entry: entry, generation: generation)
        }
    }

    private func publishDiff(_ state: DiffState, entry: GitDiffEntry, generation: Int) {
        guard generation == diffGeneration, entry == selectedGitEntry else { return }
        diff = state
    }

    nonisolated private static func loadDiff(entry: GitDiffEntry, root: URL) async -> DiffState {
        // Collapsed untracked directories have no single-file diff.
        if entry.section == .untracked && entry.path.hasSuffix("/") {
            return .failed("Untracked directory; expand it in the file tree")
        }

        var args: [String]
        switch entry.section {
        case .staged:
            args = ["diff", "--cached", "--no-color", "--no-ext-diff", "--"]
        case .unstaged:
            args = ["diff", "--no-color", "--no-ext-diff", "--"]
        case .untracked:
            args = ["diff", "--no-index", "--no-color", "--", "/dev/null"]
        }
        if let origPath = entry.origPath { args.append(origPath) }
        args.append(entry.path)

        do {
            let output = try await GitRunner.run(args, in: root)
            // The diff family exits 1 to mean "has differences", which is success here.
            guard output.exitCode == 0 || output.exitCode == 1 else {
                return .failed(output.stderr.isEmpty ? "git diff failed" : output.stderr)
            }
            return .ready(DiffParser.parse(String(decoding: output.stdout, as: UTF8.self)))
        } catch GitRunner.RunError.gitUnavailable(let reason) {
            return .failed(reason)
        } catch GitRunner.RunError.timedOut {
            return .failed("git diff timed out")
        } catch {
            return .failed(error.localizedDescription)
        }
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

        // FSEvents is recursive, so one stream covers edits anywhere under the root, .git included.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let model = Unmanaged<WorkspaceModel>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in model.scheduleRefresh() }
            },
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer))
        else { return }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    nonisolated private static func stopStream(_ stream: inout FSEventStreamRef?) {
        guard let existing = stream else { return }
        FSEventStreamStop(existing)
        FSEventStreamInvalidate(existing)
        FSEventStreamRelease(existing)
        stream = nil
    }
}
