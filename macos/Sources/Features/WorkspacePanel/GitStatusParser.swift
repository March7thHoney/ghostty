import Foundation

/// One kind of change git can report for a path on either side of the index.
enum GitChange: Equatable {
    case added, modified, deleted, renamed, copied, typeChanged

    /// The single-letter glyph shown at the trailing edge of a changed-file row.
    var glyph: String {
        switch self {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .typeChanged: return "T"
        }
    }

    init?(porcelainCode: Character) {
        switch porcelainCode {
        case "A": self = .added
        case "M": self = .modified
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "T": self = .typeChanged
        default: return nil
        }
    }
}

/// One path from `git status`, carrying both its staged and unstaged classification.
struct GitFileStatus: Identifiable, Equatable {
    var id: String { path }

    let path: String

    /// The pre-rename path for renames and copies; nil otherwise.
    let origPath: String?

    let staged: GitChange?
    let unstaged: GitChange?
    let isUntracked: Bool
    let isUnmerged: Bool
}

/// A parsed `git status --porcelain=v2 --branch` result.
struct GitStatusSnapshot: Equatable {
    var branch: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?

    /// False until the repository has its first commit, which changes valid diff bases.
    var hasCommits = true

    /// Added and removed lines against HEAD, filled in separately after parsing.
    var lineStats = GitLineStats()

    var files: [GitFileStatus] = []

    var stagedFiles: [GitFileStatus] { files.filter { $0.staged != nil } }
    var unstagedFiles: [GitFileStatus] { files.filter { $0.unstaged != nil || $0.isUnmerged } }
    var untrackedFiles: [GitFileStatus] { files.filter(\.isUntracked) }

    var isClean: Bool { files.isEmpty }
}

/// Pure parser for NUL-delimited porcelain v2 output; `-z` keeps spacey and renamed paths intact.
enum GitStatusParser {
    nonisolated static func parse(_ data: Data) -> GitStatusSnapshot {
        var snapshot = GitStatusSnapshot()
        let records = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1

            switch record.first {
            case "#":
                parseHeader(record, into: &snapshot)
            case "1":
                if let file = parseChanged(record) { snapshot.files.append(file) }
            case "2":
                // Rename records carry the pre-rename path as the following NUL-separated token.
                let origPath = index < records.count ? records[index] : nil
                index += 1
                if let file = parseChanged(record, origPath: origPath) { snapshot.files.append(file) }
            case "u":
                if let path = pathDropping(fields: 10, from: record) {
                    snapshot.files.append(GitFileStatus(
                        path: path, origPath: nil, staged: nil, unstaged: nil,
                        isUntracked: false, isUnmerged: true))
                }
            case "?":
                if let path = pathDropping(fields: 1, from: record) {
                    snapshot.files.append(GitFileStatus(
                        path: path, origPath: nil, staged: nil, unstaged: nil,
                        isUntracked: true, isUnmerged: false))
                }
            default:
                break
            }
        }

        snapshot.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return snapshot
    }

    private static func parseHeader(_ record: String, into snapshot: inout GitStatusSnapshot) {
        let parts = record.split(separator: " ")
        guard parts.count >= 2 else { return }
        switch parts[1] {
        case "branch.oid":
            snapshot.hasCommits = parts.count > 2 && parts[2] != "(initial)"
        case "branch.head":
            snapshot.branch = parts.count > 2 ? String(parts[2]) : nil
        case "branch.upstream":
            snapshot.upstream = parts.count > 2 ? String(parts[2]) : nil
        case "branch.ab":
            for part in parts.dropFirst(2) {
                if part.hasPrefix("+") { snapshot.ahead = Int(part.dropFirst()) }
                if part.hasPrefix("-") { snapshot.behind = Int(part.dropFirst()) }
            }
        default:
            break
        }
    }

    /// Parse a `1`/`2` record: `<type> <XY> <sub> <mH> <mI> <mW> <hH> <hI> [<Xscore>] <path>`.
    private static func parseChanged(_ record: String, origPath: String? = nil) -> GitFileStatus? {
        let fixedFields = record.hasPrefix("2") ? 9 : 8
        guard let path = pathDropping(fields: fixedFields, from: record) else { return nil }

        let parts = record.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1].count == 2 else { return nil }
        let xy = Array(parts[1])

        return GitFileStatus(
            path: path,
            origPath: origPath,
            staged: GitChange(porcelainCode: xy[0]),
            unstaged: GitChange(porcelainCode: xy[1]),
            isUntracked: false,
            isUnmerged: false)
    }

    /// The record's path is everything after the fixed space-separated fields, spaces included.
    private static func pathDropping(fields: Int, from record: String) -> String? {
        var rest = Substring(record)
        for _ in 0..<fields {
            guard let space = rest.firstIndex(of: " ") else { return nil }
            rest = rest[rest.index(after: space)...]
        }
        return rest.isEmpty ? nil : String(rest)
    }
}
