import Foundation

/// The hover text for a history row: everything the 320pt row had to leave out.
enum GitCommitTooltip {
    /// A tooltip is not the detail pane; the rest of the body is dropped.
    static let bodyLineLimit = 8

    nonisolated static func text(for commit: GitCommit) -> String {
        var lines = ["\(commit.shortSha)  \(commit.subject)"]

        lines.append(author(commit))

        if let date = commit.date {
            lines.append(RelativeTime.absolute(date))
        }

        // Every decoration, unlike the row, which keeps only the two that fit.
        let refs = GitLogParser.displayRefs(commit.refs, limit: .max)
        if !refs.isEmpty {
            lines.append(refs.map(label).joined(separator: ", "))
        }

        if let summary = changeSummary(commit) {
            lines.append(summary)
        }

        let body = commit.trailingBody
        if !body.isEmpty {
            lines.append("")
            lines.append(truncatedBody(body))
        }

        return lines.joined(separator: "\n")
    }

    private static func author(_ commit: GitCommit) -> String {
        guard !commit.authorEmail.isEmpty else { return commit.author }
        return "\(commit.author) <\(commit.authorEmail)>"
    }

    /// A detached HEAD has no branch to point at, so it stands alone.
    private static func label(_ ref: GitRef) -> String {
        guard case .head(let name) = ref, let name else { return ref.label }
        return "HEAD -> \(name)"
    }

    /// Merges and empty commits carry no stats, and a clean stat pair says nothing.
    private static func changeSummary(_ commit: GitCommit) -> String? {
        var parts: [String] = []

        if let count = commit.filesChanged {
            parts.append(count == 1 ? "1 file changed" : "\(count) files changed")
        }
        if let stats = commit.stats, !stats.isZero {
            parts.append("+\(stats.added) −\(stats.removed)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func truncatedBody(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > bodyLineLimit else { return body }
        return (lines.prefix(bodyLineLimit).map(String.init) + ["…"]).joined(separator: "\n")
    }
}
