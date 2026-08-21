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

    // MARK: - History state

    /// The repositories the history picker offers, rebuilt with every status refresh.
    @Published private(set) var historyRepos: [GitHistoryRepo] = []

    /// The repository the history view reads; the workspace root's own repo by default.
    @Published private(set) var historyRepoRoot: String?

    @Published private(set) var history: GitHistoryState = .idle

    /// True while a log read is in flight, which the reload and load-more buttons show.
    @Published private(set) var historyLoading = false

    /// The commit the bottom pane is showing; one at a time, like the file tree's selection.
    @Published private(set) var selectedCommitSha: String?

    /// Whether a selected commit shows its metadata or its diff, mirroring previewMode.
    @Published private(set) var commitPreviewMode: CommitPreviewMode = .changes

    @Published private(set) var commitDiff: DiffState = .none

    /// How deep the loaded history goes; "Load more" raises it.
    private var historyRequestedCount = GitHistoryLoader.pageSize

    /// False while the history view is off screen, where running git log would be pure waste.
    private var historyActive = false

    /// Repositories whose stats pass ran out of time; retrying it every refresh would be pure waste.
    private var historyStatsUnavailable: Set<String> = []

    private var historyGeneration = 0
    private var commitDiffGeneration = 0

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
        syncHistory(statuses: statuses)

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

    nonisolated private static func runDiff(
        args: [String], root: URL, maxOutputBytes: Int? = nil
    ) async -> DiffState {
        do {
            let output = try await GitRunner.run(args, in: root, maxOutputBytes: maxOutputBytes)
            // A run stopped at its byte cap was killed mid-write, so its exit code means nothing.
            guard output.truncated || output.exitCode == 0 || output.exitCode == 1 else {
                return .failed(output.stderr.isEmpty ? "git diff failed" : output.stderr)
            }
            var diff = DiffParser.parse(String(decoding: output.stdout, as: UTF8.self))
            if output.truncated { diff.truncated = true }
            return .ready(diff)
        } catch GitRunner.RunError.gitUnavailable(let reason) {
            return .failed(reason)
        } catch GitRunner.RunError.timedOut {
            return .failed("git diff timed out")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - History

    /// Fold a status refresh into the picker, re-reading the log only when the shown page went stale.
    private func syncHistory(statuses: [RepoStatus]) {
        historyRepos = statuses.map { status in
            GitHistoryRepo(
                root: status.repo.root,
                name: status.repo.isWorkspaceRoot ? root.lastPathComponent : status.repo.relativePath,
                branch: status.snapshot?.branch,
                headOid: status.snapshot?.headOid)
        }

        // The selected repository can vanish when checkouts appear or disappear underneath us.
        if historyRepoRoot == nil || !historyRepos.contains(where: { $0.root == historyRepoRoot }) {
            historyRepoRoot = historyRepos.first(where: { $0.root == root.path })?.root
                ?? historyRepos.first?.root
        }

        guard historyActive, isHistoryStale else { return }
        loadHistory()
    }

    /// A loaded page expires when its repository, HEAD, branch or depth no longer matches.
    private var isHistoryStale: Bool {
        guard let repo = historyRepos.first(where: { $0.root == historyRepoRoot }) else {
            return false
        }
        guard case .ready(let page) = history else { return true }
        return page.repoRoot != repo.root
            || page.headOid != repo.headOid
            || page.branch != repo.branch
            || page.requestedCount != historyRequestedCount
    }

    /// The history view came on screen; refs can move without HEAD, so this is a reload point.
    func activateHistory() {
        historyActive = true
        loadHistory()
    }

    func deactivateHistory() {
        historyActive = false
    }

    /// The reload button, which re-runs git log locally and never touches the network.
    func reloadHistory() {
        // A manual reload is also the way to retry stats on a repository we gave up on.
        historyStatsUnavailable.removeAll()
        loadHistory()
    }

    func selectHistoryRepo(_ repoRoot: String) {
        guard repoRoot != historyRepoRoot else { return }
        historyRepoRoot = repoRoot
        // Another repository is another history, so depth and selection do not carry over.
        historyRequestedCount = GitHistoryLoader.pageSize
        clearHistorySelection()
        history = .loading
        loadHistory()
    }

    func loadMoreHistory() {
        guard case .ready(let page) = history, page.hasMore, !historyLoading else { return }
        historyRequestedCount += GitHistoryLoader.pageSize
        loadHistory(skip: page.commits.count)
    }

    private func loadHistory(skip: Int = 0) {
        guard let repoRoot = historyRepoRoot,
              let repo = historyRepos.first(where: { $0.root == repoRoot })
        else {
            history = .idle
            return
        }
        guard let headOid = repo.headOid else {
            history = .noCommits
            return
        }

        historyGeneration += 1
        let generation = historyGeneration
        historyLoading = true
        // The old page stays up while a deeper one loads, so the list never flashes empty.
        if case .ready = history {} else { history = .loading }

        let request = HistoryRequest(
            repoRoot: repoRoot,
            headOid: headOid,
            branch: repo.branch,
            requestedCount: historyRequestedCount,
            appending: skip > 0,
            generation: generation)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = await GitHistoryLoader.fetch(
                root: URL(fileURLWithPath: repoRoot), revision: headOid, skip: skip)
            await self?.publishHistory(result, request: request)
        }
    }

    /// What a log read was issued against, carried through so its result can be validated on arrival.
    private struct HistoryRequest: Sendable {
        let repoRoot: String
        let headOid: String
        let branch: String?
        let requestedCount: Int
        let appending: Bool
        let generation: Int
    }

    private func publishHistory(
        _ result: GitHistoryLoader.FetchResult, request: HistoryRequest
    ) {
        guard request.generation == historyGeneration else { return }
        historyLoading = false

        switch result {
        case .failed(let reason):
            history = .failed(reason)
        case .ready(let fetch):
            var commits = fetch.commits
            // Appending keeps the earlier pages, which is what makes the lanes continuous.
            if request.appending, case .ready(let page) = history,
               page.repoRoot == request.repoRoot {
                commits = page.commits + commits
            }
            history = .ready(GitHistoryPage(
                repoRoot: request.repoRoot,
                headOid: request.headOid,
                branch: request.branch,
                requestedCount: request.requestedCount,
                commits: commits,
                graph: GitGraphBuilder.build(commits.map(\.graphNode)),
                hasMore: fetch.hasMore))
            reconcileHistorySelection(commits: commits)
            loadHistoryStats(
                repoRoot: request.repoRoot, headOid: request.headOid,
                count: commits.count, generation: request.generation)
        }
    }

    /// The counts git only produces by diffing every commit, fetched apart so the list never waits.
    private func loadHistoryStats(
        repoRoot: String, headOid: String, count: Int, generation: Int
    ) {
        guard count > 0, !historyStatsUnavailable.contains(repoRoot) else { return }

        Task.detached(priority: .utility) { [weak self] in
            let stats = await GitHistoryLoader.stats(
                root: URL(fileURLWithPath: repoRoot), revision: headOid, count: count)
            await self?.publishHistoryStats(stats, repoRoot: repoRoot, generation: generation)
        }
    }

    private func publishHistoryStats(
        _ stats: [String: GitCommitStats]?, repoRoot: String, generation: Int
    ) {
        guard generation == historyGeneration else { return }
        guard let stats else {
            // Too slow once is too slow every time, until the user asks for a reload.
            historyStatsUnavailable.insert(repoRoot)
            return
        }
        guard case .ready(var page) = history, page.repoRoot == repoRoot else { return }

        for index in page.commits.indices {
            guard let found = stats[page.commits[index].sha] else { continue }
            page.commits[index].stats = found.lines
            page.commits[index].filesChanged = found.filesChanged
        }
        history = .ready(page)
    }

    /// A rebase can retire the commit the pane is showing, and a stale pane lies.
    private func reconcileHistorySelection(commits: [GitCommit]) {
        guard let sha = selectedCommitSha,
              !commits.contains(where: { $0.sha == sha })
        else { return }
        clearHistorySelection()
    }

    // MARK: - History selection

    /// Selecting a commit opens the bottom pane on it; selecting it again closes the pane.
    func selectCommit(_ sha: String?) {
        commitDiffGeneration += 1
        commitDiff = .none

        guard let sha, sha != selectedCommitSha else {
            selectedCommitSha = nil
            return
        }
        selectedCommitSha = sha

        // Details costs nothing, so only the Changes mode has to reach for git.
        guard commitPreviewMode == .changes, let repoRoot = historyRepoRoot else { return }
        commitDiff = .loading
        fetchCommitDiff(sha: sha, repoRoot: repoRoot)
    }

    func clearHistorySelection() {
        selectedCommitSha = nil
        commitDiffGeneration += 1
        commitDiff = .none
    }

    func setCommitPreviewMode(_ mode: CommitPreviewMode) {
        guard commitPreviewMode != mode else { return }
        commitPreviewMode = mode
        guard mode == .changes, commitDiff == .none,
              let sha = selectedCommitSha,
              let repoRoot = historyRepoRoot
        else { return }

        commitDiffGeneration += 1
        commitDiff = .loading
        fetchCommitDiff(sha: sha, repoRoot: repoRoot)
    }

    private func fetchCommitDiff(sha: String, repoRoot: String) {
        let generation = commitDiffGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let state = await Self.runDiff(
                args: GitHistoryLoader.commitDiffArgs(sha: sha),
                root: URL(fileURLWithPath: repoRoot),
                maxOutputBytes: GitHistoryLoader.maxDiffBytes)
            await self?.publishCommitDiff(state, sha: sha, generation: generation)
        }
    }

    private func publishCommitDiff(_ state: DiffState, sha: String, generation: Int) {
        guard generation == commitDiffGeneration, sha == selectedCommitSha else { return }
        commitDiff = state
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
