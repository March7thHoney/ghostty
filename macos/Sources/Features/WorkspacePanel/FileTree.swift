import Foundation

/// One file-system entry shown in the tree.
struct FileTreeNode: Identifiable, Equatable {
    var id: String { path }

    let path: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
}

/// One rendered tree row: a node at a depth, or a placeholder under an unreadable directory.
struct FileTreeRow: Identifiable, Equatable {
    enum Content: Equatable {
        case node(FileTreeNode)
        case noAccess(dir: String)
    }

    let content: Content
    let depth: Int

    var id: String {
        switch content {
        case .node(let node): return node.path
        case .noAccess(let dir): return "no-access:\(dir)"
        }
    }
}

/// A read-only snapshot of one file's contents for the preview pane, already split into rows.
struct FilePreview: Equatable {
    let path: String
    let lines: [String]
    /// Widest row in visual columns, so the lazy pane can size its scroll content up front.
    let maxColumns: Int
    let isBinary: Bool
    let truncated: Bool

    static func empty(path: String, isBinary: Bool) -> FilePreview {
        FilePreview(path: path, lines: [], maxColumns: 0, isBinary: isBinary, truncated: false)
    }
}

/// Pure directory-scanning and flattening logic behind the file tree.
enum FileTreeScanner {
    /// Byte, line, and per-line caps keeping the preview pane responsive on large files.
    static let previewByteLimit = 1_000_000
    static let previewLineLimit = 5000
    static let previewLineLengthLimit = 4000

    /// One directory's entries in Finder order, or nil when it cannot be read.
    nonisolated static func children(of dir: URL) -> [FileTreeNode]? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [])
        else { return nil }

        var nodes: [FileTreeNode] = []
        for entry in entries {
            let name = entry.lastPathComponent
            // The .git directory is pure noise here; the git tab covers that ground.
            guard name != ".git" else { continue }
            let values = try? entry.resourceValues(forKeys: keys)
            let isSymlink = values?.isSymbolicLink ?? false
            nodes.append(FileTreeNode(
                path: entry.path,
                name: name,
                isDirectory: (values?.isDirectory ?? false) && !isSymlink,
                isSymlink: isSymlink))
        }

        nodes.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return nodes
    }

    /// Flatten the scanned directories into rows, descending only into expanded directories.
    nonisolated static func flatten(
        rootDir: String,
        childrenByDir: [String: [FileTreeNode]],
        expanded: Set<String>,
        denied: Set<String>
    ) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []

        func append(dir: String, depth: Int) {
            if denied.contains(dir) {
                rows.append(FileTreeRow(content: .noAccess(dir: dir), depth: depth))
                return
            }
            for node in childrenByDir[dir] ?? [] {
                rows.append(FileTreeRow(content: .node(node), depth: depth))
                if node.isDirectory && expanded.contains(node.path) {
                    append(dir: node.path, depth: depth + 1)
                }
            }
        }

        append(dir: rootDir, depth: 0)
        return rows
    }

    /// Read a capped, binary-sniffed snapshot of one file for the preview pane.
    nonisolated static func loadPreview(path: String) -> FilePreview {
        guard let handle = FileHandle(forReadingAtPath: path),
              let data = try? handle.read(upToCount: previewByteLimit + 1)
        else {
            return .empty(path: path, isBinary: false)
        }
        defer { try? handle.close() }

        // A NUL in the first 8KB is the classic text/binary sniff.
        if data.prefix(8192).contains(0) {
            return .empty(path: path, isBinary: true)
        }

        var truncated = data.count > previewByteLimit
        let text = String(decoding: data.prefix(previewByteLimit), as: UTF8.self)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        if rows.count > previewLineLimit {
            rows = Array(rows.prefix(previewLineLimit))
            truncated = true
        }

        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        var maxColumns = 0
        for row in rows {
            var line = String(row)
            // One multi-megabyte line would still stall layout, so rows get their own cap.
            if line.count > previewLineLengthLimit {
                line = String(line.prefix(previewLineLengthLimit)) + "…"
                truncated = true
            }
            maxColumns = max(maxColumns, DiffParser.visualColumns(of: line))
            lines.append(line)
        }
        return FilePreview(
            path: path, lines: lines, maxColumns: maxColumns, isBinary: false, truncated: truncated)
    }
}
