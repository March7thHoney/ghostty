import SwiftUI

/// One path's git presence in a list row: a single letter and a tint.
enum GitBadge: Equatable {
    case change(GitChange)
    case untracked
    case conflicted

    /// The letter shown on a file row.
    var glyph: String {
        switch self {
        case .change(let change): return change.glyph
        case .untracked: return "U"
        case .conflicted: return "!"
        }
    }

    var color: Color {
        switch self {
        case .untracked: return .green
        case .conflicted: return .red
        case .change(let change):
            switch change {
            case .added: return .green
            case .modified: return .orange
            case .deleted: return .red
            case .renamed, .copied: return .blue
            case .typeChanged: return .purple
            }
        }
    }

    /// Who wins when a directory rolls up several children.
    var rollupRank: Int {
        switch self {
        case .conflicted: return 2
        case .change: return 1
        case .untracked: return 0
        }
    }

    /// The badge a file row shows: the worktree side first, the index side as a fallback.
    init?(file: GitFileStatus) {
        if file.isUnmerged {
            self = .conflicted
        } else if file.isUntracked {
            self = .untracked
        } else if let change = file.unstaged ?? file.staged {
            self = .change(change)
        } else {
            return nil
        }
    }
}

/// Git badges keyed by absolute path, covering changed files and every ancestor directory.
struct GitStatusIndex: Equatable {
    static let empty = GitStatusIndex()

    private var badges: [String: GitBadge] = [:]

    func badge(for absolutePath: String) -> GitBadge? { badges[absolutePath] }

    /// Build from every repository in the workspace, each reporting paths relative to its own root.
    static func build(statuses: [RepoStatus], workspaceRoot: String) -> GitStatusIndex {
        let workspaceRoot = trimmingTrailingSlashes(workspaceRoot)
        var index = GitStatusIndex()

        for status in statuses {
            guard case .ready(let snapshot) = status.state else { continue }
            let repoRoot = trimmingTrailingSlashes(status.repo.root)
            let prefix = repoRoot.hasSuffix("/") ? repoRoot : repoRoot + "/"

            for file in snapshot.files {
                guard let badge = GitBadge(file: file) else { continue }
                let relative = trimmingTrailingSlashes(file.path)
                guard !relative.isEmpty else { continue }

                let absolute = prefix + relative
                index.badges[absolute] = badge

                // Roll up to the workspace root, not the repo's, so nested repos mark their folders.
                var parent = (absolute as NSString).deletingLastPathComponent
                while parent.count > workspaceRoot.count, parent.hasPrefix(workspaceRoot) {
                    if let existing = index.badges[parent], existing.rollupRank >= badge.rollupRank {
                        break
                    }
                    index.badges[parent] = badge
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }

        return index
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
