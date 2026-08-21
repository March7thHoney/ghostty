import Foundation

/// One repository offered by the history view's picker.
struct GitHistoryRepo: Identifiable, Equatable {
    var id: String { root }

    let root: String

    /// What the picker shows: the workspace folder for its own repo, the relative path otherwise.
    let name: String

    let branch: String?

    /// Nil for a repository with no commits yet, which has no history to read.
    let headOid: String?
}

/// One loaded stretch of history, tagged with what it was read from so staleness is decidable.
struct GitHistoryPage: Equatable {
    let repoRoot: String

    /// The HEAD this was read at; pagination stays anchored to it even if HEAD moves.
    let headOid: String

    /// Tracked separately because checking out a branch at the same commit leaves the oid alone.
    let branch: String?

    /// How deep the caller asked to go, which "Load more" raises.
    let requestedCount: Int

    var commits: [GitCommit]

    /// Rebuilt over every loaded commit, so lanes never break at a page seam.
    var graph: GitGraph

    var hasMore: Bool
}

/// The history view's condition for the selected repository.
enum GitHistoryState: Equatable {
    case idle
    case loading
    case failed(String)
    case noCommits
    case ready(GitHistoryPage)
}

/// Whether a selected commit shows its metadata or its diff, mirroring FilePreviewMode.
enum CommitPreviewMode: Equatable {
    case details, changes
}

/// One page of commits as git handed them back, before the model merges them into a page.
struct GitHistoryFetch: Equatable {
    let commits: [GitCommit]
    let hasMore: Bool
}

/// The git side of the history view: one log per page, one show per expanded commit.
enum GitHistoryLoader {
    /// One page's depth, matching VS Code's own graph page size.
    static let pageSize = 50

    enum FetchResult: Equatable {
        case ready(GitHistoryFetch)
        case failed(String)
    }

    /// Read one page anchored at `revision`, asking for one extra row to detect a next page.
    nonisolated static func fetch(
        root: URL, revision: String, skip: Int, pageSize: Int = pageSize
    ) async -> FetchResult {
        do {
            let output = try await GitRunner.run(
                GitLogFormat.args(revision: revision, maxCount: pageSize + 1, skip: skip), in: root)
            guard output.exitCode == 0 else {
                return .failed(output.stderr.isEmpty ? "git log failed" : output.stderr)
            }

            var commits = GitLogParser.parse(output.stdout)
            let hasMore = commits.count > pageSize
            if hasMore { commits.removeLast(commits.count - pageSize) }
            return .ready(GitHistoryFetch(commits: commits, hasMore: hasMore))
        } catch GitRunner.RunError.gitUnavailable(let reason) {
            return .failed(reason)
        } catch GitRunner.RunError.timedOut {
            return .failed("git log timed out")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The whole commit's patch, which already names every file it touched.
    nonisolated static func commitDiffArgs(sha: String) -> [String] {
        [
            // core.quotePath defaults on and would escape non-ASCII paths into backslash octets.
            "-c", "core.quotePath=false",
            "show", "--format=", "--first-parent", "--no-color", "--no-ext-diff",
            "--find-renames", sha,
        ]
    }
}
