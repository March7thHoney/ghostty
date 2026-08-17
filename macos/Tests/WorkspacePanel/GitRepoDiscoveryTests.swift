import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitRepoDiscoveryTests {
    /// A throwaway fixture directory, removed when the test ends.
    private func makeFixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-discovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create `relativePath` under `dir` and mark it as a repository.
    private func makeRepo(_ dir: URL, _ relativePath: String? = nil) throws {
        let repo = relativePath.map { dir.appendingPathComponent($0) } ?? dir
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    @Test func findsTheRootAndItsNestedRepos() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRepo(dir)
        try makeRepo(dir, "dev")
        try makeRepo(dir, "vendor/lua")

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: true)
        #expect(repos.map(\.relativePath) == [".", "dev", "vendor/lua"])
        #expect(repos[0].root == dir.path)
        #expect(repos[1].root == dir.appendingPathComponent("dev").path)
        #expect(repos[0].isWorkspaceRoot)
        #expect(!repos[1].isWorkspaceRoot)
    }

    @Test func stopsDescendingIntoADiscoveredRepo() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRepo(dir)
        try makeRepo(dir, "dev")
        try makeRepo(dir, "dev/inner")

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: true)
        #expect(repos.map(\.relativePath) == [".", "dev"])
    }

    @Test func skipsHeavyDirectories() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRepo(dir, "node_modules/pkg")
        try makeRepo(dir, ".build/checkout")
        try makeRepo(dir, "keep")

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: false)
        #expect(repos.map(\.relativePath) == ["keep"])
    }

    @Test func honorsTheDepthLimit() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRepo(dir, "a/b/c/deep")
        try makeRepo(dir, "a/b/c/d/tooDeep")

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: false)
        #expect(repos.map(\.relativePath) == ["a/b/c/deep"])
    }

    @Test func nonRepoRootReturnsOnlyNestedRepos() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRepo(dir, "one")
        try makeRepo(dir, "two")

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: false)
        #expect(repos.map(\.relativePath) == ["one", "two"])
    }

    /// Worktrees and submodules keep a `.git` file rather than a directory; both count.
    @Test func gitFileAlsoMarksARepo() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let worktree = dir.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: false)
        #expect(repos.map(\.relativePath) == ["worktree"])
    }

    /// A checkout linked in from elsewhere is still one of the workspace's repositories.
    @Test func symlinkedRepoIsFound() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: outside) }
        try makeRepo(outside, "checkout")
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("linked"),
            withDestinationURL: outside.appendingPathComponent("checkout"))

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: false)
        #expect(repos.map(\.relativePath) == ["linked"])
        #expect(repos[0].root == dir.appendingPathComponent("linked").path)
    }

    /// A link that is not itself a repo is never walked into, so a cycle cannot loop the search.
    @Test func symlinkedPlainDirectoryIsNotWalked() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeRepo(dir, "plain/buried")
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("loop"), withDestinationURL: dir)

        let repos = GitRepoDiscovery.discover(root: dir, isGitRepo: false)
        #expect(repos.map(\.relativePath) == ["plain/buried"])
    }

    @Test func emptyDirectoryHasNoRepos() throws {
        let dir = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(GitRepoDiscovery.discover(root: dir, isGitRepo: false).isEmpty)
    }
}
