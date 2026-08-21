import Foundation

/// One decoration from `%D`, already classified so the row can style it.
enum GitRef: Equatable, Identifiable {
    /// The checked-out branch, or nil when HEAD is detached.
    case head(String?)
    case branch(String)
    case remote(String)
    case tag(String)

    var id: String {
        switch self {
        case .head(let name): return "head:\(name ?? "")"
        case .branch(let name): return "branch:\(name)"
        case .remote(let name): return "remote:\(name)"
        case .tag(let name): return "tag:\(name)"
        }
    }

    /// The text shown on the badge; a detached HEAD has no branch to name.
    var label: String {
        switch self {
        case .head(let name): return name ?? "HEAD"
        case .branch(let name), .remote(let name), .tag(let name): return name
        }
    }

    var isHead: Bool {
        if case .head = self { return true }
        return false
    }

    /// Ordering for the badge row: where you are, then what is here, then what is elsewhere.
    var sortRank: Int {
        switch self {
        case .head: return 0
        case .branch: return 1
        case .tag: return 2
        case .remote: return 3
        }
    }
}

/// One commit from `git log`, carrying everything a history row and its detail pane draw.
struct GitCommit: Identifiable, Equatable {
    var id: String { sha }

    let sha: String
    let shortSha: String
    let parents: [String]
    let author: String
    let authorEmail: String

    /// Nil only when git handed back a timestamp we could not read.
    let date: Date?

    let refs: [GitRef]
    let subject: String

    /// The full message, which the row cannot fit but the detail pane shows.
    let body: String

    /// From `--shortstat`; nil for merges and empty commits, which print no such line.
    let stats: GitLineStats?

    /// How many files the commit touched, also from `--shortstat`.
    let filesChanged: Int?

    var isMerge: Bool { parents.count > 1 }

    var isHead: Bool { refs.contains(where: \.isHead) }

    var graphNode: GitGraphNode { GitGraphNode(sha: sha, parents: parents) }
}

/// The one `git log` invocation the history view makes, kept beside the parser that reads it.
enum GitLogFormat {
    static let recordSeparator: Character = "\u{1e}"
    static let fieldSeparator: Character = "\u{1f}"

    /// %x1e opens a record and %x1f closes every field, so the --shortstat tail lands after the last one.
    static let format =
        "%x1e%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%D%x1f%s%x1f%B%x1f"

    /// Fixed fields before the body, which is the last one that can contain anything.
    static let fixedFieldCount = 8

    static func args(revision: String, maxCount: Int, skip: Int) -> [String] {
        var args = [
            "log", revision,
            "--max-count=\(maxCount)",
            "--topo-order",
            "--no-show-signature",
            // color.ui=always would otherwise inject ANSI escapes into %D.
            "--no-color",
            // i18n.logOutputEncoding would otherwise hand back a non-UTF-8 subject.
            "--encoding=UTF-8",
            // log.decorate=full would otherwise turn %D into refs/heads/main.
            "--decorate=short",
            "--shortstat",
            "--format=\(format)",
        ]
        if skip > 0 { args.insert("--skip=\(skip)", at: 2) }
        return args
    }
}

/// Pure parser for the record-separated `git log` output above.
enum GitLogParser {
    nonisolated static func parse(_ data: Data) -> [GitCommit] {
        String(decoding: data, as: UTF8.self)
            .split(separator: GitLogFormat.recordSeparator, omittingEmptySubsequences: true)
            .compactMap { parseRecord(String($0)) }
    }

    nonisolated static func parseRecord(_ record: String) -> GitCommit? {
        // Empty decorations produce two separators in a row, so empty fields must survive the split.
        let fields = record.split(
            separator: GitLogFormat.fieldSeparator,
            maxSplits: GitLogFormat.fixedFieldCount,
            omittingEmptySubsequences: false)
        guard fields.count == GitLogFormat.fixedFieldCount + 1 else { return nil }

        let sha = String(fields[0])
        guard !sha.isEmpty else { return nil }

        // The trailing piece is the body plus the shortstat tail; only the tail is separator-free.
        let trailing = fields[GitLogFormat.fixedFieldCount]
        let body: String
        let tail: String
        if let cut = trailing.lastIndex(of: GitLogFormat.fieldSeparator) {
            body = String(trailing[..<cut])
            tail = String(trailing[trailing.index(after: cut)...])
        } else {
            body = String(trailing)
            tail = ""
        }

        return GitCommit(
            sha: sha,
            shortSha: String(fields[1]),
            parents: fields[2].split(separator: " ").map(String.init),
            author: String(fields[3]),
            authorEmail: String(fields[4]),
            date: parseDate(String(fields[5])),
            refs: parseRefs(String(fields[6])),
            subject: String(fields[7]),
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            stats: parseShortstat(tail),
            filesChanged: parseFilesChanged(tail))
    }

    // MARK: - Fields

    /// `%D` is already short-form, so a slash is enough to tell a remote from a local branch.
    nonisolated static func parseRefs(_ decoration: String) -> [GitRef] {
        decoration
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { entry in
                if entry == "HEAD" { return .head(nil) }
                if let arrow = entry.range(of: " -> ") {
                    return .head(String(entry[arrow.upperBound...]))
                }
                if entry.hasPrefix("tag: ") { return .tag(String(entry.dropFirst(5))) }
                return entry.contains("/") ? .remote(entry) : .branch(entry)
            }
    }

    /// Trim the decorations down to what fits a 320pt row without losing the ones that matter.
    nonisolated static func displayRefs(_ refs: [GitRef], limit: Int = 2) -> [GitRef] {
        // A local name already on this commit says everything its remote copy would.
        let localNames = Set(refs.compactMap { ref -> String? in
            switch ref {
            case .head(let name): return name
            case .branch(let name): return name
            case .remote, .tag: return nil
            }
        })

        let kept = refs.filter { ref in
            guard case .remote(let name) = ref else { return true }
            let leaf = name.split(separator: "/").last.map(String.init) ?? name
            // origin/HEAD is a symref alias, never a place you can be.
            return leaf != "HEAD" && !localNames.contains(leaf)
        }

        return Array(
            kept.enumerated()
                .sorted { lhs, rhs in
                    lhs.element.sortRank == rhs.element.sortRank
                        ? lhs.offset < rhs.offset
                        : lhs.element.sortRank < rhs.element.sortRank
                }
                .map(\.element)
                .prefix(limit))
    }

    /// Merges and empty commits print no shortstat, and nil keeps that distinct from "changed nothing".
    nonisolated static func parseShortstat(_ tail: String) -> GitLineStats? {
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var stats = GitLineStats()
        var matched = false
        for part in trimmed.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard let value = Int(piece.prefix(while: \.isNumber)) else { continue }
            // Singular forms and a missing half are both normal, so match on the stem.
            if piece.contains("insertion") {
                stats.added = value
                matched = true
            } else if piece.contains("deletion") {
                stats.removed = value
                matched = true
            }
        }
        return matched ? stats : nil
    }

    /// The leading "N file(s) changed" clause, which the detail pane shows without a second git call.
    nonisolated static func parseFilesChanged(_ tail: String) -> Int? {
        for part in tail.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard piece.contains("file"), piece.contains("changed") else { continue }
            return Int(piece.prefix(while: \.isNumber))
        }
        return nil
    }

    private nonisolated static func parseDate(_ raw: String) -> Date? {
        formatter.date(from: raw)
    }

    /// %aI is strict ISO 8601 with an offset, which is exactly the default option set.
    private static let formatter = ISO8601DateFormatter()
}
