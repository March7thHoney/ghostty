import Foundation
import Testing
@testable import Ghostty

@Suite
struct FileTreeTests {
    /// A throwaway fixture directory, removed when the test ends.
    private func makeFixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func sortsDirectoriesFirstInFinderOrder() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: dir.appendingPathComponent("zeta"), withIntermediateDirectories: false)
        try fileManager.createDirectory(
            at: dir.appendingPathComponent("alpha"), withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent("beta.txt"))
        try Data().write(to: dir.appendingPathComponent("item10.txt"))
        try Data().write(to: dir.appendingPathComponent("item2.txt"))

        let nodes = try #require(FileTreeScanner.children(of: dir))
        #expect(nodes.map(\.name) == ["alpha", "zeta", "beta.txt", "item2.txt", "item10.txt"])
        #expect(nodes[0].isDirectory)
        #expect(!nodes[2].isDirectory)
    }

    @Test func hidesGitDirectoryButShowsDotfiles() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: false)
        try Data().write(to: dir.appendingPathComponent(".gitignore"))

        let nodes = try #require(FileTreeScanner.children(of: dir))
        #expect(nodes.map(\.name) == [".gitignore"])
    }

    /// Directory symlinks stay leaves, which makes cycles structurally impossible.
    @Test func symlinkedDirectoryIsALeaf() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("alias"), withDestinationURL: target)

        let nodes = try #require(FileTreeScanner.children(of: dir))
        let alias = try #require(nodes.first { $0.name == "alias" })
        #expect(alias.isSymlink)
        #expect(!alias.isDirectory)
    }

    @Test func unreadableDirectoryReturnsNil() {
        #expect(FileTreeScanner.children(of: URL(fileURLWithPath: "/nonexistent-fixture-path")) == nil)
    }

    @Test func flattenDescendsOnlyExpandedDirs() {
        let root = "/fixture"
        let children: [String: [FileTreeNode]] = [
            root: [
                FileTreeNode(path: "/fixture/open", name: "open", isDirectory: true, isSymlink: false),
                FileTreeNode(path: "/fixture/shut", name: "shut", isDirectory: true, isSymlink: false),
                FileTreeNode(path: "/fixture/a.txt", name: "a.txt", isDirectory: false, isSymlink: false),
            ],
            "/fixture/open": [
                FileTreeNode(path: "/fixture/open/inner.txt", name: "inner.txt", isDirectory: false, isSymlink: false),
            ],
            "/fixture/shut": [
                FileTreeNode(path: "/fixture/shut/hidden.txt", name: "hidden.txt", isDirectory: false, isSymlink: false),
            ],
        ]

        let rows = FileTreeScanner.flatten(
            rootDir: root, childrenByDir: children,
            expanded: ["/fixture/open"], denied: [])
        #expect(rows.map(\.id) == [
            "/fixture/open", "/fixture/open/inner.txt", "/fixture/shut", "/fixture/a.txt",
        ])
        #expect(rows[1].depth == 1)
        #expect(rows[2].depth == 0)
    }

    @Test func flattenMarksDeniedDirs() {
        let root = "/fixture"
        let children: [String: [FileTreeNode]] = [
            root: [
                FileTreeNode(path: "/fixture/locked", name: "locked", isDirectory: true, isSymlink: false),
            ],
        ]
        let rows = FileTreeScanner.flatten(
            rootDir: root, childrenByDir: children,
            expanded: ["/fixture/locked"], denied: ["/fixture/locked"])
        #expect(rows.count == 2)
        #expect(rows[1].content == .noAccess(dir: "/fixture/locked"))
        #expect(rows[1].depth == 1)
    }

    @Test func previewSniffsBinaryAndCapsLines() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("blob.bin")
        try Data([0x00, 0x01, 0x02]).write(to: binary)
        #expect(FileTreeScanner.loadPreview(path: binary.path).isBinary)

        let long = dir.appendingPathComponent("long.txt")
        let text = Array(repeating: "line", count: FileTreeScanner.previewLineLimit + 10)
            .joined(separator: "\n")
        try Data(text.utf8).write(to: long)
        let preview = FileTreeScanner.loadPreview(path: long.path)
        #expect(preview.truncated)
        #expect(!preview.isBinary)

        let small = dir.appendingPathComponent("small.txt")
        try Data("hello\nworld".utf8).write(to: small)
        let smallPreview = FileTreeScanner.loadPreview(path: small.path)
        #expect(smallPreview.text == "hello\nworld")
        #expect(!smallPreview.truncated)
    }
}
