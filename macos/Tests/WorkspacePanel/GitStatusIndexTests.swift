import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitStatusIndexTests {
    private let root = "/repo"

    private func index(_ files: [GitFileStatus]) -> GitStatusIndex {
        var snapshot = GitStatusSnapshot()
        snapshot.files = files
        return GitStatusIndex.build(snapshot: snapshot, root: root)
    }

    private func changed(
        _ path: String,
        staged: GitChange? = nil,
        unstaged: GitChange? = nil
    ) -> GitFileStatus {
        GitFileStatus(
            path: path, origPath: nil, staged: staged, unstaged: unstaged,
            isUntracked: false, isUnmerged: false)
    }

    private func untracked(_ path: String) -> GitFileStatus {
        GitFileStatus(
            path: path, origPath: nil, staged: nil, unstaged: nil,
            isUntracked: true, isUnmerged: false)
    }

    private func unmerged(_ path: String) -> GitFileStatus {
        GitFileStatus(
            path: path, origPath: nil, staged: nil, unstaged: nil,
            isUntracked: false, isUnmerged: true)
    }

    @Test func prefersWorktreeChangeOverIndexChange() {
        let index = index([changed("src/app.zig", staged: .added, unstaged: .modified)])
        #expect(index.badge(for: "/repo/src/app.zig") == .change(.modified))
    }

    @Test func fallsBackToStagedChange() {
        let index = index([changed("src/app.zig", staged: .added)])
        #expect(index.badge(for: "/repo/src/app.zig") == .change(.added))
        #expect(index.badge(for: "/repo/src/app.zig")?.glyph == "A")
    }

    @Test func marksUntrackedAndUnmerged() {
        let index = index([untracked("new.txt"), unmerged("conflict.txt")])
        #expect(index.badge(for: "/repo/new.txt") == .untracked)
        #expect(index.badge(for: "/repo/new.txt")?.glyph == "U")
        #expect(index.badge(for: "/repo/conflict.txt") == .conflicted)
        #expect(index.badge(for: "/repo/conflict.txt")?.glyph == "!")
    }

    @Test func rollsUpThroughEveryAncestor() {
        let index = index([changed("a/b/c/file.zig", unstaged: .modified)])
        #expect(index.badge(for: "/repo/a") == .change(.modified))
        #expect(index.badge(for: "/repo/a/b") == .change(.modified))
        #expect(index.badge(for: "/repo/a/b/c") == .change(.modified))
    }

    @Test func trackedChangeWinsOverUntrackedInDirectory() {
        let index = index([
            untracked("src/notes.txt"),
            changed("src/app.zig", unstaged: .modified),
        ])
        #expect(index.badge(for: "/repo/src") == .change(.modified))
    }

    @Test func conflictWinsOverEverythingInDirectory() {
        let index = index([
            changed("src/app.zig", unstaged: .modified),
            unmerged("src/merge.zig"),
        ])
        #expect(index.badge(for: "/repo/src") == .conflicted)
    }

    @Test func rootAndUnrelatedPathsHaveNoBadge() {
        let index = index([changed("src/app.zig", unstaged: .modified)])
        #expect(index.badge(for: root) == nil)
        #expect(index.badge(for: "/repo/other") == nil)
        #expect(index.badge(for: "/elsewhere/src/app.zig") == nil)
    }

    @Test func deletedFileStillMarksItsAncestors() {
        let index = index([changed("src/gone.zig", unstaged: .deleted)])
        #expect(index.badge(for: "/repo/src/gone.zig") == .change(.deleted))
        #expect(index.badge(for: "/repo/src") == .change(.deleted))
    }

    @Test func emptySnapshotProducesNoBadges() {
        #expect(index([]) == GitStatusIndex.empty)
    }
}
