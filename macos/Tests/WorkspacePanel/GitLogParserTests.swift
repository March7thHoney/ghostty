import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitLogParserTests {
    private static let unit = "\u{1f}"
    private static let recordMark = "\u{1e}"

    private func record(
        sha: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        short: String = "aaaaaaa",
        parents: String = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        author: String = "Ada Byron",
        email: String = "ada@example.com",
        date: String = "2026-08-18T16:51:30+08:00",
        refs: String = "",
        subject: String = "feat: add a thing",
        body: String = "feat: add a thing",
        tail: String = ""
    ) -> String {
        let fields = [sha, short, parents, author, email, date, refs, subject, body]
        return Self.recordMark + fields.joined(separator: Self.unit) + Self.unit + tail
    }

    private func parse(_ records: String...) -> [GitCommit] {
        GitLogParser.parse(Data(records.joined().utf8))
    }

    @Test func parsesEveryFieldOfOneRecord() {
        let commits = parse(record())

        #expect(commits.count == 1)
        let commit = commits[0]
        #expect(commit.sha == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        #expect(commit.shortSha == "aaaaaaa")
        #expect(commit.parents == ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        #expect(commit.author == "Ada Byron")
        #expect(commit.authorEmail == "ada@example.com")
        #expect(commit.date != nil)
        #expect(commit.subject == "feat: add a thing")
        // Counts arrive later from the stats pass, so the first pass leaves them empty.
        #expect(commit.stats == nil)
        #expect(!commit.isMerge)
    }

    /// An undecorated commit emits two separators in a row, which a greedy split would swallow.
    @Test func emptyDecorationDoesNotShiftTheFields() {
        let commits = parse(record(refs: "", subject: "chore: quiet commit"))

        #expect(commits.count == 1)
        #expect(commits[0].refs.isEmpty)
        #expect(commits[0].subject == "chore: quiet commit")
    }

    @Test func parsesSeveralParents() {
        let commits = parse(record(parents: "cccccccc dddddddd"))

        #expect(commits.count == 1)
        #expect(commits[0].isMerge)
        #expect(commits[0].parents == ["cccccccc", "dddddddd"])
    }

    @Test func parsesSingularAndPartialShortstat() {
        #expect(
            GitLogParser.parseShortstat("\n 1 file changed, 1 insertion(+)\n")
                == GitLineStats(added: 1, removed: 0))
        #expect(
            GitLogParser.parseShortstat("\n 1 file changed, 1 deletion(-)\n")
                == GitLineStats(added: 0, removed: 1))
        #expect(
            GitLogParser.parseShortstat("\n 2 files changed, 3 insertions(+), 4 deletions(-)\n")
                == GitLineStats(added: 3, removed: 4))
        // A file-count-only line carries no numbers we display, so it reads as absent.
        #expect(GitLogParser.parseShortstat("\n 1 file changed\n") == nil)
        #expect(GitLogParser.parseShortstat("   \n") == nil)
    }

    @Test func statsPassMapsShasToTheirCounts() {
        let mark = Self.recordMark
        let unit = Self.unit
        let data = Data((
            mark + "aaaa" + unit + "\n 4 files changed, 116 insertions(+), 32 deletions(-)\n"
                + mark + "bbbb" + unit + "\n 1 file changed, 1 insertion(+)\n"
                // A merge prints no shortstat, so it simply has no entry to find.
                + mark + "cccc" + unit + "\n"
        ).utf8)

        let stats = GitLogParser.parseStats(data)

        #expect(stats.count == 2)
        #expect(stats["aaaa"] == GitCommitStats(
            lines: GitLineStats(added: 116, removed: 32), filesChanged: 4))
        #expect(stats["bbbb"] == GitCommitStats(
            lines: GitLineStats(added: 1, removed: 0), filesChanged: 1))
        #expect(stats["cccc"] == nil)
    }

    @Test func parsesTheFileCountInBothSingularAndPlural() {
        #expect(GitLogParser.parseFilesChanged("\n 1 file changed, 1 insertion(+)\n") == 1)
        #expect(
            GitLogParser.parseFilesChanged("\n 4 files changed, 116 insertions(+), 32 deletions(-)\n")
                == 4)
        #expect(GitLogParser.parseFilesChanged("\n") == nil)
    }

    @Test func multilineBodySurvivesTheRecordSplit() {
        let body = "feat: add a thing\n\nWhy it matters\nand a second line."
        let commits = parse(record(body: body))

        #expect(commits.count == 1)
        #expect(commits[0].body == body)
    }

    /// The tail is cut from the last separator, so a body containing one cannot hide it.
    @Test func bodyContainingASeparatorStillFindsTheTail() {
        let commits = parse(record(body: "subject\n\nweird \u{1f} body"))

        #expect(commits.count == 1)
        #expect(commits[0].body == "subject\n\nweird \u{1f} body")
    }

    @Test func parsesSeveralRecords() {
        let commits = parse(
            record(sha: "1111111111111111111111111111111111111111", subject: "one"),
            record(sha: "2222222222222222222222222222222222222222", subject: "two"))

        #expect(commits.map(\.subject) == ["one", "two"])
    }

    @Test func malformedRecordIsSkippedNotFatal() {
        let broken = Self.recordMark + "short" + Self.unit + "record"
        let commits = GitLogParser.parse(Data((broken + record(subject: "good")).utf8))

        #expect(commits.map(\.subject) == ["good"])
    }

    @Test func emptyOutputYieldsNoCommits() {
        #expect(GitLogParser.parse(Data()).isEmpty)
    }

    // MARK: - Decorations

    @Test func classifiesHeadBranchTagAndRemote() {
        let refs = GitLogParser.parseRefs("HEAD -> main, origin/main, tag: v1.0, topic")

        #expect(refs == [.head("main"), .remote("origin/main"), .tag("v1.0"), .branch("topic")])
    }

    @Test func detachedHeadHasNoBranchName() {
        let refs = GitLogParser.parseRefs("HEAD, tag: v1.0")

        #expect(refs.first == .head(nil))
        #expect(refs.first?.label == "HEAD")
    }

    @Test func dropsRemoteHeadAndRemotesThatDuplicateALocalName() {
        let refs = GitLogParser.parseRefs("HEAD -> main, origin/main, origin/HEAD")

        // origin/main says nothing main does not, and origin/HEAD is only a symref alias.
        #expect(GitLogParser.displayRefs(refs) == [.head("main")])
    }

    @Test func sortsHeadFirstAndCapsTheBadgeCount() {
        let refs = GitLogParser.parseRefs("tag: v1.0, upstream/topic, HEAD -> main")

        #expect(GitLogParser.displayRefs(refs, limit: 2) == [.head("main"), .tag("v1.0")])
    }

    @Test func keepsARemoteThatHasNoLocalCounterpart() {
        let refs = GitLogParser.parseRefs("upstream/main")

        #expect(GitLogParser.displayRefs(refs) == [.remote("upstream/main")])
    }

    // MARK: - Arguments

    @Test func skipIsOmittedForTheFirstPage() {
        let first = GitLogFormat.args(revision: "abc123", maxCount: 51, skip: 0)
        let second = GitLogFormat.args(revision: "abc123", maxCount: 51, skip: 50)

        #expect(!first.contains { $0.hasPrefix("--skip") })
        #expect(second.contains("--skip=50"))
        // The config-proofing flags are load-bearing, not decoration.
        for flag in ["--decorate=short", "--no-color", "--encoding=UTF-8", "--topo-order"] {
            #expect(first.contains(flag))
        }
        // --shortstat diffs every commit, which is minutes on a binary-heavy repository.
        #expect(!first.contains("--shortstat"))
        #expect(GitLogFormat.statsArgs(revision: "abc123", maxCount: 50).contains("--shortstat"))
    }
}
