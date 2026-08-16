import Foundation

/// The paths git ignores, so the file tree can dim them the way VS Code does.
struct GitIgnoreIndex: Equatable {
    static let empty = GitIgnoreIndex()

    private var root = ""

    /// Absolute paths of individually ignored files.
    private var files: Set<String> = []

    /// Absolute paths of directories whose whole subtree is ignored.
    private var dirs: Set<String> = []

    /// True when the path is ignored itself or sits under an ignored directory.
    func isIgnored(_ absolutePath: String) -> Bool {
        let path = Self.trimmingTrailingSlashes(absolutePath)
        if files.contains(path) || dirs.contains(path) { return true }

        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > root.count, parent.hasPrefix(root) {
            if dirs.contains(parent) { return true }
            // The walk bottoms out at "/", which is its own parent, so stop when it stops shrinking.
            let next = (parent as NSString).deletingLastPathComponent
            guard next.count < parent.count else { break }
            parent = next
        }
        return false
    }

    /// Parse NUL-delimited `git ls-files` output whose paths are relative to `root`.
    nonisolated static func parse(_ data: Data, root: String) -> GitIgnoreIndex {
        var index = GitIgnoreIndex()
        index.root = trimmingTrailingSlashes(root)
        let prefix = index.root.hasSuffix("/") ? index.root : index.root + "/"

        let entries = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)

        for entry in entries {
            // `--directory` marks a fully ignored directory with a trailing slash.
            let isDir = entry.hasSuffix("/")
            let relative = trimmingTrailingSlashes(entry)
            guard !relative.isEmpty, relative != "." else { continue }

            let absolute = prefix + relative
            if isDir {
                index.dirs.insert(absolute)
            } else {
                index.files.insert(absolute)
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
