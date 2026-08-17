import Foundation

/// One git repository found under a workspace root.
struct GitRepo: Identifiable, Hashable {
    var id: String { root }

    /// Absolute path of the repository root.
    let root: String

    /// Path relative to the workspace root; "." for the workspace root itself.
    let relativePath: String

    /// True for the workspace root's own repository, which owns the ignore rules.
    var isWorkspaceRoot: Bool { relativePath == "." }
}

/// Finds the repositories a workspace contains, so nested checkouts get their own status.
enum GitRepoDiscovery {
    /// How far below the root nested repositories are looked for.
    static let maxDepth = 4

    /// A ceiling on repositories, so a directory full of checkouts can't stall a refresh.
    static let maxRepos = 12

    /// Directories that never hold a repository worth showing but are expensive to walk.
    static let skippedDirs: Set<String> = [
        "node_modules", ".build", "build", "target", "venv", ".venv",
        "Pods", "DerivedData", ".cache", "zig-out", ".zig-cache", "zig-cache",
        "__pycache__", ".next", ".nuxt", ".gradle", ".tox", ".pytest_cache",
        ".mypy_cache", ".terraform",
    ]

    /// Breadth-first walk for `.git` entries; shallow repositories win when the cap is hit.
    nonisolated static func discover(root: URL, isGitRepo: Bool) -> [GitRepo] {
        let rootPath = trimmingTrailingSlashes(root.path)
        var repos: [GitRepo] = []
        if isGitRepo {
            repos.append(GitRepo(root: rootPath, relativePath: "."))
        }

        // The root is always descended into: its nested repositories are the point of this walk.
        var frontier: [(path: String, relative: String)] = [(rootPath, "")]
        var depth = 0
        while !frontier.isEmpty, depth < maxDepth, repos.count < maxRepos {
            var next: [(path: String, relative: String)] = []
            for dir in frontier {
                for child in childDirectories(of: dir.path) {
                    guard !skippedDirs.contains(child.name), child.name != ".git" else { continue }

                    // Relative paths are carried down, since trimming a symlinked root skews them.
                    let relative = dir.relative.isEmpty
                        ? child.name : dir.relative + "/" + child.name
                    let path = (rootPath as NSString).appendingPathComponent(relative)

                    if hasGitEntry(path) {
                        repos.append(GitRepo(root: path, relativePath: relative))
                        if repos.count >= maxRepos { break }
                        // A repository's own subtree belongs to it, so stop descending here.
                        continue
                    }
                    // A symlink is checked but never walked into, so a link cycle can't loop this.
                    if !child.isSymlink { next.append((path, relative)) }
                }
                if repos.count >= maxRepos { break }
            }
            frontier = next
            depth += 1
        }

        return sorted(repos)
    }

    /// The root's repository first, then the rest by path the way Finder would order them.
    private static func sorted(_ repos: [GitRepo]) -> [GitRepo] {
        repos.sorted { lhs, rhs in
            if lhs.isWorkspaceRoot != rhs.isWorkspaceRoot { return lhs.isWorkspaceRoot }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    /// A `.git` file counts too, which is how linked worktrees and submodules look.
    private static func hasGitEntry(_ dir: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
    }

    /// Child directories, symlinked ones included: a linked checkout is still a repository.
    private static func childDirectories(of dir: String) -> [(name: String, isSymlink: Bool)] {
        let url = URL(fileURLWithPath: dir)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
        else { return [] }

        return entries.compactMap { entry in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymlink = values?.isSymbolicLink == true
            // A symlink resolves to false for isDirectory, so its target is checked separately.
            guard values?.isDirectory == true || isSymlink else { return nil }
            if isSymlink {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                      isDir.boolValue
                else { return nil }
            }
            return (entry.lastPathComponent, isSymlink)
        }
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
