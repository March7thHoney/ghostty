import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitStatusParserTests {
    private func parse(_ records: [String]) -> GitStatusSnapshot {
        GitStatusParser.parse(Data((records.joined(separator: "\0") + "\0").utf8))
    }

    @Test func parsesBranchHeaders() {
        let snapshot = parse([
            "# branch.oid 1234abcd",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
        ])
        #expect(snapshot.branch == "main")
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 2)
        #expect(snapshot.behind == 1)
        #expect(snapshot.hasCommits)
        #expect(snapshot.isClean)
    }

    @Test func detectsInitialCommitState() {
        let snapshot = parse(["# branch.oid (initial)", "# branch.head main"])
        #expect(!snapshot.hasCommits)
    }

    /// A file staged and further edited shows up on both sides of the index.
    @Test func parsesStagedAndUnstagedSides() {
        let snapshot = parse([
            "1 MM N... 100644 100644 100644 aaaa bbbb src/app.zig",
        ])
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files[0].path == "src/app.zig")
        #expect(snapshot.files[0].staged == .modified)
        #expect(snapshot.files[0].unstaged == .modified)
        #expect(snapshot.stagedFiles.count == 1)
        #expect(snapshot.unstagedFiles.count == 1)
    }

    @Test func parsesStagedOnlyAddition() {
        let snapshot = parse([
            "1 A. N... 000000 100644 100644 0000 cccc docs/new file.md",
        ])
        #expect(snapshot.files[0].path == "docs/new file.md")
        #expect(snapshot.files[0].staged == .added)
        #expect(snapshot.files[0].unstaged == nil)
        #expect(snapshot.unstagedFiles.isEmpty)
    }

    /// Rename records carry the original path as the following NUL token.
    @Test func parsesRenameWithOriginalPath() {
        let snapshot = parse([
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 lib/renamed name.swift",
            "lib/old name.swift",
        ])
        #expect(snapshot.files.count == 1)
        #expect(snapshot.files[0].path == "lib/renamed name.swift")
        #expect(snapshot.files[0].origPath == "lib/old name.swift")
        #expect(snapshot.files[0].staged == .renamed)
    }

    @Test func parsesUnmergedAndUntracked() {
        let snapshot = parse([
            "u UU N... 100644 100644 100644 100644 aaaa bbbb cccc conflicted.txt",
            "? notes.txt",
        ])
        #expect(snapshot.files.count == 2)
        let unmerged = snapshot.files.first { $0.isUnmerged }
        let untracked = snapshot.files.first { $0.isUntracked }
        #expect(unmerged?.path == "conflicted.txt")
        #expect(untracked?.path == "notes.txt")
        #expect(snapshot.unstagedFiles.count == 1)
        #expect(snapshot.untrackedFiles.count == 1)
    }

    @Test func emptyOutputIsCleanSnapshot() {
        let snapshot = GitStatusParser.parse(Data())
        #expect(snapshot.isClean)
        #expect(snapshot.branch == nil)
    }

    @Test func filesSortByPath() {
        let snapshot = parse([
            "? zeta.txt",
            "? alpha.txt",
            "? item10.txt",
            "? item2.txt",
        ])
        #expect(snapshot.files.map(\.path) == ["alpha.txt", "item2.txt", "item10.txt", "zeta.txt"])
    }
}
