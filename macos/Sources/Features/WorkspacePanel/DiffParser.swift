import Foundation

/// One renderable line of a unified diff.
struct DiffLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case meta, hunkHeader, context, addition, deletion
    }

    let id: Int
    let kind: Kind
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

/// One file's section of a possibly multi-file diff.
struct ParsedDiffFile: Identifiable, Equatable {
    var id: String { path }

    let path: String

    /// The pre-rename path, so a rename header can show "old → new".
    let origPath: String?

    let change: GitChange?

    let isBinary: Bool

    var lines: [DiffLine] = []

    /// This file's own widest line, so a collapsed neighbour cannot stretch it.
    var maxColumns = 0
}

/// A unified diff reduced to renderable lines.
struct ParsedDiff: Equatable {
    /// The per-file sections, which the commit view renders as separate collapsible blocks.
    var files: [ParsedDiffFile] = []

    var lines: [DiffLine] = []
    var isBinary = false
    var truncated = false

    /// The widest line's approximate visual columns, sizing the horizontal scroll extent.
    var maxColumns = 0

    var isEmpty: Bool { lines.isEmpty && !isBinary }
}

/// Pure parser turning `git diff` text into classified, line-numbered rows.
enum DiffParser {
    /// Render cap; diffs beyond this are marked truncated rather than laid out.
    static let maxLines = 4000

    nonisolated static func parse(_ text: String) -> ParsedDiff {
        var diff = ParsedDiff()
        var oldNext = 0
        var newNext = 0
        var inHunk = false
        var id = 0
        var header = FileHeader()
        // Counted as lines are emitted, because diff.lines only grows when a section closes.
        var emitted = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if emitted >= maxLines {
                diff.truncated = true
                break
            }

            let line = String(rawLine)
            defer { id += 1 }

            // A new file section returns us to preamble; hunk lines always start with +/-/space/backslash.
            if inHunk && line.hasPrefix("diff ") { inHunk = false }

            if !inHunk && line.hasPrefix("diff ") {
                flush(&header, into: &diff)
                header = FileHeader(diffLine: line)
                continue
            }

            if line.hasPrefix("@@"), let hunk = parseHunkHeader(line) {
                inHunk = true
                oldNext = hunk.oldStart
                newNext = hunk.newStart
                header.append(DiffLine(
                    id: id, kind: .hunkHeader, text: line, oldLine: nil, newLine: nil))
                emitted += 1
                continue
            }

            if !inHunk {
                header.readPreamble(line)
                if header.isBinary { diff.isBinary = true }
                // Other preamble noise (index lines, modes) is dropped; hunks carry the content.
                continue
            }

            switch line.first {
            case "+":
                header.append(DiffLine(
                    id: id, kind: .addition, text: String(line.dropFirst()),
                    oldLine: nil, newLine: newNext))
                emitted += 1
                newNext += 1
            case "-":
                header.append(DiffLine(
                    id: id, kind: .deletion, text: String(line.dropFirst()),
                    oldLine: oldNext, newLine: nil))
                emitted += 1
                oldNext += 1
            case "\\":
                header.append(DiffLine(
                    id: id, kind: .meta, text: line, oldLine: nil, newLine: nil))
                emitted += 1
            default:
                header.append(DiffLine(
                    id: id, kind: .context, text: String(line.dropFirst(min(1, line.count))),
                    oldLine: oldNext, newLine: newNext))
                emitted += 1
                oldNext += 1
                newNext += 1
            }
        }

        flush(&header, into: &diff)

        // The split yields one trailing empty "context" line after the final newline; drop it.
        if let last = diff.lines.last, last.kind == .context, last.text.isEmpty,
           text.hasSuffix("\n") {
            diff.lines.removeLast()
            trimLastFileLine(&diff)
        }

        diff.maxColumns = diff.files.reduce(0) { max($0, $1.maxColumns) }
        return diff
    }

    /// Close the section being built and append it, dropping the empty one before the first file.
    private static func flush(_ header: inout FileHeader, into diff: inout ParsedDiff) {
        guard let file = header.finish() else { return }
        diff.files.append(file)
        diff.lines.append(contentsOf: file.lines)
    }

    /// Keep the last section in step after the trailing blank line is dropped from the flat list.
    private static func trimLastFileLine(_ diff: inout ParsedDiff) {
        guard var last = diff.files.last, !last.lines.isEmpty else { return }
        last.lines.removeLast()
        last.maxColumns = last.lines.reduce(0) { max($0, visualColumns(of: $1.text)) }
        diff.files[diff.files.count - 1] = last
    }

    /// Approximate visual columns for width estimation: tabs count 4, non-ASCII glyphs 2.
    nonisolated static func visualColumns(of text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                count += 4
            } else {
                count += scalar.isASCII ? 1 : 2
            }
        }
        return count
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        // Shape: @@ -oldStart[,oldCount] +newStart[,newCount] @@ [context]
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        let oldStart = Int(parts[1].dropFirst().split(separator: ",")[0])
        let newStart = Int(parts[2].dropFirst().split(separator: ",")[0])
        guard let oldStart, let newStart else { return nil }
        return (oldStart, newStart)
    }
}

/// One file section under construction, collecting its preamble facts and then its hunk lines.
private struct FileHeader {
    /// Paths seen in the preamble, in the order we prefer them.
    private var plusPath: String?
    private var minusPath: String?
    private var renameTo: String?
    private var renameFrom: String?
    private var fallbackPath: String?

    private var change: GitChange?
    private var started = false
    private var lines: [DiffLine] = []

    private(set) var isBinary = false

    init() {}

    init(diffLine: String) {
        started = true
        fallbackPath = Self.pathFromDiffLine(diffLine)
    }

    mutating func append(_ line: DiffLine) {
        started = true
        lines.append(line)
    }

    /// Read one preamble line for the facts a section header needs.
    mutating func readPreamble(_ line: String) {
        if line.hasPrefix("+++ ") {
            plusPath = Self.strippingPrefix(String(line.dropFirst(4)), "b/")
        } else if line.hasPrefix("--- ") {
            minusPath = Self.strippingPrefix(String(line.dropFirst(4)), "a/")
        } else if line.hasPrefix("rename to ") {
            renameTo = String(line.dropFirst(10))
            change = .renamed
        } else if line.hasPrefix("rename from ") {
            renameFrom = String(line.dropFirst(12))
            change = .renamed
        } else if line.hasPrefix("copy to ") {
            renameTo = String(line.dropFirst(8))
            change = .copied
        } else if line.hasPrefix("copy from ") {
            renameFrom = String(line.dropFirst(10))
            change = .copied
        } else if line.hasPrefix("new file mode") {
            change = .added
        } else if line.hasPrefix("deleted file mode") {
            change = .deleted
        } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
            isBinary = true
        }
    }

    /// The finished section, or nil for the empty stretch before the first `diff --git`.
    func finish() -> ParsedDiffFile? {
        guard started else { return nil }
        // Renames, binaries and bare hunks all lack ---/+++, so an empty path is the last resort.
        let path = plusPath ?? minusPath ?? renameTo ?? fallbackPath ?? ""

        return ParsedDiffFile(
            path: path,
            origPath: renameFrom,
            change: change ?? .modified,
            isBinary: isBinary,
            lines: lines,
            maxColumns: lines.reduce(0) { max($0, DiffParser.visualColumns(of: $1.text)) })
    }

    /// `/dev/null` marks the absent side of an add or a delete, so it is not a path.
    private static func strippingPrefix(_ value: String, _ prefix: String) -> String? {
        guard value != "/dev/null" else { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `diff --git a/X b/Y` is ambiguous when a path contains a space, so prefer the halves matching.
    private static func pathFromDiffLine(_ line: String) -> String? {
        guard line.hasPrefix("diff --git a/") else { return nil }
        let rest = Substring(line.dropFirst("diff --git a/".count))

        var candidates: [String] = []
        var search = rest.startIndex
        while let found = rest.range(of: " b/", range: search..<rest.endIndex) {
            let left = String(rest[rest.startIndex..<found.lowerBound])
            let right = String(rest[found.upperBound...])
            // The overwhelmingly common case is one unchanged path repeated on both sides.
            if left == right { return left }
            candidates.append(right)
            search = found.upperBound
        }
        return candidates.last
    }
}
