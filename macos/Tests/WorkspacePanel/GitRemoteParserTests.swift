import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitRemoteParserTests {
    private func web(_ remote: String) -> String? {
        GitRemoteParser.githubWebURL(from: remote)?.absoluteString
    }

    @Test func httpsForms() {
        #expect(web("https://github.com/acme/widget.git") == "https://github.com/acme/widget")
        #expect(web("https://github.com/acme/widget") == "https://github.com/acme/widget")
        #expect(web("https://github.com/acme/widget/") == "https://github.com/acme/widget")
        #expect(web("https://token@github.com/acme/widget.git") == "https://github.com/acme/widget")
        #expect(web("https://www.github.com/acme/widget") == "https://github.com/acme/widget")
        #expect(web("HTTPS://GitHub.com/acme/widget") == "https://github.com/acme/widget")
    }

    @Test func sshForms() {
        #expect(web("git@github.com:acme/widget.git") == "https://github.com/acme/widget")
        #expect(web("git@github.com:acme/widget") == "https://github.com/acme/widget")
        #expect(web("ssh://git@github.com/acme/widget.git") == "https://github.com/acme/widget")
        #expect(web("ssh://git@github.com:22/acme/widget.git") == "https://github.com/acme/widget")
        #expect(web("git://github.com/acme/widget.git") == "https://github.com/acme/widget")
    }

    @Test func ignoresExtraPathSegments() {
        #expect(web("https://github.com/acme/widget/tree/main") == "https://github.com/acme/widget")
    }

    @Test func rejectsOtherHosts() {
        #expect(web("https://gitlab.com/acme/widget.git") == nil)
        #expect(web("git@bitbucket.org:acme/widget.git") == nil)
        #expect(web("git@github-work:acme/widget.git") == nil)
        #expect(web("https://github.com.evil.example/acme/widget") == nil)
    }

    @Test func rejectsMalformed() {
        #expect(web("") == nil)
        #expect(web("https://github.com/acme") == nil)
        #expect(web("https://github.com") == nil)
        #expect(web("/srv/git/widget.git") == nil)
        #expect(web("../widget") == nil)
    }

    private func remotes(_ lines: [String]) -> [GitRemoteParser.Remote] {
        GitRemoteParser.parseRemotes(Data(lines.joined(separator: "\n").utf8))
    }

    @Test func parsesConfigLines() {
        let parsed = remotes([
            "remote.origin.url https://github.com/acme/widget.git",
            "remote.upstream.url git@github.com:acme/widget.git",
            "",
        ])
        #expect(parsed == [
            .init(name: "origin", url: "https://github.com/acme/widget.git"),
            .init(name: "upstream", url: "git@github.com:acme/widget.git"),
        ])
    }

    @Test func skipsMalformedConfigLines() {
        let parsed = remotes(["remote.origin.url", "core.bare false", "remote..url x", "junk"])
        #expect(parsed.isEmpty)
    }

    @Test func originWinsWhenOnGitHub() {
        let url = GitRemoteParser.githubWebURL(remotes: remotes([
            "remote.upstream.url https://github.com/acme/widget.git",
            "remote.origin.url https://github.com/fork/widget.git",
        ]))
        #expect(url?.absoluteString == "https://github.com/fork/widget")
    }

    @Test func fallsBackToFirstGitHubRemote() {
        let url = GitRemoteParser.githubWebURL(remotes: remotes([
            "remote.origin.url https://gitlab.com/acme/widget.git",
            "remote.mirror.url https://github.com/acme/widget.git",
            "remote.other.url https://github.com/other/widget.git",
        ]))
        #expect(url?.absoluteString == "https://github.com/acme/widget")
    }

    @Test func nilWithoutGitHubRemotes() {
        #expect(GitRemoteParser.githubWebURL(remotes: []) == nil)
        #expect(GitRemoteParser.githubWebURL(remotes: remotes([
            "remote.origin.url https://gitlab.com/acme/widget.git",
        ])) == nil)
    }
}
