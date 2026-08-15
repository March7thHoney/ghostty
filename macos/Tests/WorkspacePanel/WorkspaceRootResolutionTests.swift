import Foundation
import Testing
@testable import Ghostty

@Suite
struct WorkspaceRootResolutionTests {
    /// A throwaway fixture directory, removed when the test ends.
    private func makeFixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func findsGitDirectoryInAncestor() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: false)
        let nested = dir.appendingPathComponent("src/deep")
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)

        let resolved = WorkspaceRegistry.resolveRoot(forPwd: nested.path)
        #expect(resolved.isGitRepo)
        #expect(resolved.root == dir.path)
    }

    /// Worktrees keep a `.git` file rather than a directory; both count.
    @Test func gitFileAlsoMarksARoot() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("gitdir: /elsewhere".utf8).write(to: dir.appendingPathComponent(".git"))

        let resolved = WorkspaceRegistry.resolveRoot(forPwd: dir.path)
        #expect(resolved.isGitRepo)
        #expect(resolved.root == dir.path)
    }

    @Test func nonRepoFallsBackToPwd() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = WorkspaceRegistry.resolveRoot(forPwd: dir.path)
        #expect(!resolved.isGitRepo)
        #expect(resolved.root == dir.path)
    }

    @Test func trailingSlashesNormalizeAway() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let resolved = WorkspaceRegistry.resolveRoot(forPwd: dir.path + "///")
        #expect(resolved.root == dir.path)
    }
}
