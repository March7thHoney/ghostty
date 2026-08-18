import Foundation
import CoreServices

/// One repository's condition in the git tab.
enum GitState: Equatable {
    case gitUnavailable(String)
    case failed(String)
    case ready(GitStatusSnapshot)
}

/// One discovered repository paired with the status read from it.
struct RepoStatus: Identifiable, Equatable {
    var id: String { repo.root }

    let repo: GitRepo
    let state: GitState

    /// The parsed status, or nil when the read failed.
    var snapshot: GitStatusSnapshot? {
        guard case .ready(let snapshot) = state else { return nil }
        return snapshot
    }

    /// True when the repository reports no changes at all, which collapses it to one row.
    var isClean: Bool { snapshot?.isClean ?? false }
}

/// The git tab's top-level condition across every repository in the workspace.
enum WorkspaceGitState: Equatable {
    case loading
    case noRepos
    case ready([RepoStatus])
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

    /// The repository the diff runs in, which is not always the workspace root.
    let repoRoot: String

    let section: Section

    /// Relative to `repoRoot`, the way git reported it.
    let path: String

    let origPath: String?

    /// The file's absolute path, for revealing and copying.
    var absolutePath: String {
        (repoRoot as NSString).appendingPathComponent(path)
    }
}

/// What the file tab's preview pane shows for the selected file.
enum FilePreviewMode: Equatable {
    case content, changes
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

    /// Whether the selected file's preview shows its contents or its diff.
    @Published private(set) var previewMode: FilePreviewMode = .content

    /// The selected file's diff against HEAD, shown by the files tab.
    @Published private(set) var fileDiff: DiffState = .none

    @Published private(set) var git: WorkspaceGitState = .loading

    /// Repository roots the git tab folds away, kept here so same-root windows agree.
    @Published private(set) var collapsedRepos: Set<String> = []

    /// Per-path git badges for the file tree, rebuilt with every status refresh.
    @Published private(set) var gitIndex = GitStatusIndex.empty

    /// The ignored paths the file tree dims, rebuilt with every status refresh.
    @Published private(set) var ignoreIndex = GitIgnoreIndex.empty

    @Published private(set) var selectedGitEntry: GitDiffEntry?
    @Published private(set) var diff: DiffState = .none

    /// How long a repository walk stands in for the next one; checkouts appear and vanish rarely.
    private static let discoveryTTL: TimeInterval = 30

    private var discoveredRepos: [GitRepo] = []
    private var lastDiscovery: Date?

    private var started = false
    private var refreshPending = false
    private var refreshRunning = false
    private var previewGeneration = 0
    private var diffGeneration = 0
    private var fileDiffGeneration = 0

    /// Touched from deinit, which is nonisolated; only stop()/deinit ever clear it.
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?

    init(root: URL, isGitRepo: Bool) {
        self.root = root
        self.isGitRepo = isGitRepo
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
        async let ignored = Self.fetchIgnored(root: root, isGitRepo: isGitRepo)
        let repos = await currentRepos()
        let statuses = await Self.fetchStatuses(repos: repos)

        let (children, denied) = await scanned
        childrenByDir = children
        deniedDirs = denied
        ignoreIndex = await ignored
        git = statuses.isEmpty ? .noRepos : .ready(statuses)
        gitIndex = GitStatusIndex.build(statuses: statuses, workspaceRoot: root.path)

        await reconcileSelections(after: statuses)
    }

    /// Keep the preview and diff panes truthful after the world changed underneath them.
    private func reconcileSelections(after statuses: [RepoStatus]) async {
        if let selected = selectedFilePath {
            // One stat costs hundreds of milliseconds on a network mount, so it runs off-thread.
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: selected)
            }.value
            // The selection can move while that runs, in which case the newer one stands.
            if selected == selectedFilePath {
                if exists {
                    loadPreview(for: selected)
                    reconcileFileDiff(for: selected)
                } else {
                    selectFile(nil)
                }
            }
        }

        guard let entry = selectedGitEntry else { return }
        guard let status = statuses.first(where: { $0.repo.root == entry.repoRoot }),
              case .ready(let snapshot) = status.state,
              files(in: entry.section, of: snapshot).contains(where: { $0.path == entry.path })
        else {
            selectGitEntry(nil)
            return
        }
        fetchDiff(for: entry)
    }

    private func files(in section: GitDiffEntry.Section, of snapshot: GitStatusSnapshot) -> [GitFileStatus] {
        switch section {
        case .staged: return snapshot.stagedFiles
        case .unstaged: return snapshot.unstagedFiles
        case .untracked: return snapshot.untrackedFiles
        }
    }

    /// The innermost discovered repository containing an absolute path.
    func repo(containing path: String) -> RepoStatus? {
        guard case .ready(let statuses) = git else { return nil }

        var best: RepoStatus?
        for status in statuses {
            let repoRoot = status.repo.root
            guard path == repoRoot || path.hasPrefix(repoRoot + "/") else { continue }
            if best == nil || repoRoot.count > best!.repo.root.count { best = status }
        }
        return best
    }

    func toggleRepoCollapsed(_ repoRoot: String) {
        if collapsedRepos.contains(repoRoot) {
            collapsedRepos.remove(repoRoot)
        } else {
            collapsedRepos.insert(repoRoot)
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

    /// The workspace's repositories, re-walked only once the cached list goes stale.
    private func currentRepos() async -> [GitRepo] {
        if let lastDiscovery, Date().timeIntervalSince(lastDiscovery) < Self.discoveryTTL {
            return discoveredRepos
        }

        let root = root
        let isGitRepo = isGitRepo
        discoveredRepos = await Task.detached(priority: .utility) {
            GitRepoDiscovery.discover(root: root, isGitRepo: isGitRepo)
        }.value
        lastDiscovery = Date()
        return discoveredRepos
    }

    /// Read every repository's status concurrently.
    nonisolated private static func fetchStatuses(repos: [GitRepo]) async -> [RepoStatus] {
        guard !repos.isEmpty else { return [] }

        var states: [String: GitState] = [:]
        await withTaskGroup(of: (String, GitState).self) { group in
            for repo in repos {
                group.addTask {
                    (repo.root, await fetchStatus(root: URL(fileURLWithPath: repo.root)))
                }
            }
            for await (repoRoot, state) in group { states[repoRoot] = state }
        }

        let nested = Set(repos.filter { !$0.isWorkspaceRoot }.map(\.root))
        return repos.map { repo in
            var state = states[repo.root] ?? .failed("git status failed")
            if repo.isWorkspaceRoot, case .ready(var snapshot) = state {
                snapshot.files = filteringNested(snapshot.files, repoRoot: repo.root, nested: nested)
                state = .ready(snapshot)
            }
            return RepoStatus(repo: repo, state: state)
        }
    }

    /// Drop the single untracked directory git reports for a nested repo listed on its own.
    nonisolated private static func filteringNested(
        _ files: [GitFileStatus],
        repoRoot: String,
        nested: Set<String>
    ) -> [GitFileStatus] {
        guard !nested.isEmpty else { return files }
        return files.filter { file in
            guard file.isUntracked, file.path.hasSuffix("/") else { return true }
            var absolute = (repoRoot as NSString).appendingPathComponent(file.path)
            while absolute.count > 1 && absolute.hasSuffix("/") { absolute.removeLast() }
            return !nested.contains(absolute)
        }
    }

    nonisolated private static func fetchStatus(root: URL) async -> GitState {
        do {
            // -uall lists untracked files individually, so each row has a previewable diff.
            let output = try await GitRunner.run(
                ["status", "--porcelain=v2", "--branch", "-uall", "-z"], in: root)
            guard output.exitCode == 0 else {
                return .failed(output.stderr.isEmpty ? "git status failed" : output.stderr)
            }
            var snapshot = GitStatusParser.parse(output.stdout)
            if !snapshot.isClean {
                snapshot.lineStats = await fetchLineStats(root: root, hasCommits: snapshot.hasCommits)
            }
            return .ready(snapshot)
        } catch GitRunner.RunError.gitUnavailable(let reason) {
            return .gitUnavailable(reason)
        } catch GitRunner.RunError.timedOut {
            return .failed("git status timed out")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The ignored paths; dimming is decoration only, so any failure just yields nothing.
    nonisolated private static func fetchIgnored(root: URL, isGitRepo: Bool) async -> GitIgnoreIndex {
        guard isGitRepo else { return .empty }
        // --directory folds a wholly ignored tree into one entry, so build dirs stay cheap.
        guard let output = try? await GitRunner.run(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
            in: root),
            output.exitCode == 0
        else { return .empty }
        return GitIgnoreIndex.parse(output.stdout, root: root.path)
    }

    /// Totals against HEAD; a failure here costs the counter only, never the status list.
    nonisolated private static func fetchLineStats(root: URL, hasCommits: Bool) async -> GitLineStats {
        // Without a first commit HEAD does not resolve, so the index stands in as the base.
        let base = hasCommits ? "HEAD" : "--cached"
        guard let output = try? await GitRunner.run(
            ["diff", "--numstat", "--no-color", "--no-ext-diff", base], in: root),
            output.exitCode == 0 || output.exitCode == 1
        else { return GitLineStats() }
        return GitNumstatParser.parse(output.stdout)
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
        fileDiffGeneration += 1
        selectedFilePath = path
        filePreview = nil
        fileDiff = .none
        previewMode = .content
        guard let path else { return }

        loadPreview(for: path)
        // A changed file opens on its diff, which is usually why it was opened at all.
        if gitIndex.badge(for: path) != nil {
            previewMode = .changes
            fetchFileDiff(for: path)
        }
    }

    func setPreviewMode(_ mode: FilePreviewMode) {
        guard previewMode != mode else { return }
        previewMode = mode
        guard mode == .changes, fileDiff == .none, let path = selectedFilePath else { return }
        fileDiffGeneration += 1
        fetchFileDiff(for: path)
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

    /// Keep the files tab's diff pane in step with the file's current git state.
    private func reconcileFileDiff(for path: String) {
        fileDiffGeneration += 1
        guard gitIndex.badge(for: path) != nil else {
            previewMode = .content
            fileDiff = .none
            return
        }
        // Staying in content mode drops the stale diff, so a later toggle reloads it.
        if previewMode == .changes {
            fetchFileDiff(for: path)
        } else {
            fileDiff = .none
        }
    }

    private func fetchFileDiff(for path: String) {
        guard let (args, repoRoot) = treeDiffArgs(for: path) else {
            fileDiff = .none
            return
        }

        let generation = fileDiffGeneration
        fileDiff = .loading
        Task.detached(priority: .userInitiated) { [weak self] in
            let state = await Self.runDiff(args: args, root: URL(fileURLWithPath: repoRoot))
            await self?.publishFileDiff(state, path: path, generation: generation)
        }
    }

    private func publishFileDiff(_ state: DiffState, path: String, generation: Int) {
        guard generation == fileDiffGeneration, path == selectedFilePath else { return }
        fileDiff = state
    }

    /// Untracked files diff against /dev/null; everything else against HEAD, staged changes included.
    private func treeDiffArgs(for path: String) -> (args: [String], repoRoot: String)? {
        // Whichever repository owns the file runs the diff, nested checkouts included.
        guard let status = repo(containing: path) else { return nil }
        let repoRoot = status.repo.root
        let prefix = repoRoot.hasSuffix("/") ? repoRoot : repoRoot + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        guard !relative.isEmpty else { return nil }

        if gitIndex.badge(for: path) == .untracked {
            return (
                ["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null", relative],
                repoRoot)
        }

        var hasCommits = true
        if case .ready(let snapshot) = status.state { hasCommits = snapshot.hasCommits }
        return (
            [
                "diff", hasCommits ? "HEAD" : "--cached",
                "--no-color", "--no-ext-diff", "--", relative,
            ],
            repoRoot)
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let state: DiffState
            if let args = Self.diffArgs(for: entry) {
                state = await Self.runDiff(args: args, root: URL(fileURLWithPath: entry.repoRoot))
            } else {
                state = .failed("Untracked directory; expand it in the file tree")
            }
            await self?.publishDiff(state, entry: entry, generation: generation)
        }
    }

    private func publishDiff(_ state: DiffState, entry: GitDiffEntry, generation: Int) {
        guard generation == diffGeneration, entry == selectedGitEntry else { return }
        diff = state
    }

    /// The git args for one selected entry, or nil when it has no single-file diff.
    nonisolated private static func diffArgs(for entry: GitDiffEntry) -> [String]? {
        // Collapsed untracked directories have no single-file diff.
        if entry.section == .untracked && entry.path.hasSuffix("/") { return nil }

        var args: [String]
        switch entry.section {
        case .staged:
            args = ["diff", "--cached", "--no-color", "--no-ext-diff", "--"]
        case .unstaged:
            args = ["diff", "--no-color", "--no-ext-diff", "--"]
        case .untracked:
            args = ["diff", "--no-index", "--no-color", "--no-ext-diff", "--", "/dev/null"]
        }
        if let origPath = entry.origPath { args.append(origPath) }
        args.append(entry.path)
        return args
    }

    nonisolated private static func runDiff(args: [String], root: URL) async -> DiffState {
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
