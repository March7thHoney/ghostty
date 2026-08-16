import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitIgnoreIndexTests {
    private let root = "/repo"

    private func index(_ entries: [String]) -> GitIgnoreIndex {
        let data = Data(entries.joined(separator: "\0").utf8)
        return GitIgnoreIndex.parse(data, root: root)
    }

    @Test func ignoredDirectoryCoversItsWholeSubtree() {
        let index = index(["zig-out/"])
        #expect(index.isIgnored("/repo/zig-out"))
        #expect(index.isIgnored("/repo/zig-out/bin"))
        #expect(index.isIgnored("/repo/zig-out/bin/ghostty"))
    }

    @Test func ignoredFileMatchesOnlyItself() {
        let index = index(["macos/.DS_Store"])
        #expect(index.isIgnored("/repo/macos/.DS_Store"))
        #expect(!index.isIgnored("/repo/macos"))
        #expect(!index.isIgnored("/repo/macos/.DS_Store.bak"))
    }

    @Test func siblingsSharingAPrefixAreNotIgnored() {
        let index = index(["build/"])
        #expect(index.isIgnored("/repo/build/app"))
        #expect(!index.isIgnored("/repo/build-tools"))
        #expect(!index.isIgnored("/repo/build-tools/run.sh"))
    }

    @Test func pathsWithSpacesAndUnicodeSurviveTheNULSplit() {
        let index = index(["my docs/", "笔记 草稿.md"])
        #expect(index.isIgnored("/repo/my docs/notes.txt"))
        #expect(index.isIgnored("/repo/笔记 草稿.md"))
    }

    @Test func rootAndUnrelatedPathsAreNotIgnored() {
        let index = index(["zig-out/"])
        #expect(!index.isIgnored(root))
        #expect(!index.isIgnored("/repo/src/main.zig"))
        #expect(!index.isIgnored("/elsewhere/zig-out/bin"))
    }

    @Test func emptyOutputIgnoresNothing() {
        let index = index([])
        #expect(!index.isIgnored("/repo/zig-out"))
        #expect(GitIgnoreIndex.empty.isIgnored("/repo/zig-out") == false)
    }
}
