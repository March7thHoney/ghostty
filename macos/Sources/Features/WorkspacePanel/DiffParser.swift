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

/// A unified diff reduced to renderable lines.
struct ParsedDiff: Equatable {
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

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if diff.lines.count >= maxLines {
                diff.truncated = true
                break
            }

            let line = String(rawLine)
            defer { id += 1 }

            // A new file section returns us to preamble; hunk lines always start with +/-/space/backslash.
            if inHunk && line.hasPrefix("diff ") { inHunk = false }

            if line.hasPrefix("@@"), let header = parseHunkHeader(line) {
                inHunk = true
                oldNext = header.oldStart
                newNext = header.newStart
                diff.lines.append(DiffLine(
                    id: id, kind: .hunkHeader, text: line, oldLine: nil, newLine: nil))
                continue
            }

            if !inHunk {
                if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                    diff.isBinary = true
                }
                // Preamble noise (index lines, mode changes) is dropped; hunks carry the content.
                continue
            }

            switch line.first {
            case "+":
                diff.lines.append(DiffLine(
                    id: id, kind: .addition, text: String(line.dropFirst()),
                    oldLine: nil, newLine: newNext))
                newNext += 1
            case "-":
                diff.lines.append(DiffLine(
                    id: id, kind: .deletion, text: String(line.dropFirst()),
                    oldLine: oldNext, newLine: nil))
                oldNext += 1
            case "\\":
                diff.lines.append(DiffLine(
                    id: id, kind: .meta, text: line, oldLine: nil, newLine: nil))
            default:
                diff.lines.append(DiffLine(
                    id: id, kind: .context, text: String(line.dropFirst(min(1, line.count))),
                    oldLine: oldNext, newLine: newNext))
                oldNext += 1
                newNext += 1
            }
        }

        // The split yields one trailing empty "context" line after the final newline; drop it.
        if let last = diff.lines.last, last.kind == .context, last.text.isEmpty,
           text.hasSuffix("\n") {
            diff.lines.removeLast()
        }

        diff.maxColumns = diff.lines.reduce(0) { max($0, visualColumns(of: $1.text)) }
        return diff
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
