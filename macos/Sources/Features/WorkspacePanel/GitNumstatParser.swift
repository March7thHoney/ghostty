import Foundation

/// Added and removed line counts summed across a diff.
struct GitLineStats: Equatable {
    var added = 0
    var removed = 0

    var isZero: Bool { added == 0 && removed == 0 }
}

/// Pure parser summing `git diff --numstat` rows; binary (`-`) and malformed rows are skipped.
enum GitNumstatParser {
    nonisolated static func parse(_ data: Data) -> GitLineStats {
        var stats = GitLineStats()

        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let added = Int(fields[0]),
                  let removed = Int(fields[1])
            else { continue }

            stats.added += added
            stats.removed += removed
        }

        return stats
    }
}
