import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitCommitTooltipTests {
    private func commit(
        sha: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        short: String = "aaaaaaa",
        parents: [String] = ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
        author: String = "Ada Byron",
        email: String = "ada@example.com",
        date: Date? = Date(timeIntervalSince1970: 1_755_500_000),
        refs: [GitRef] = [],
        subject: String = "feat: add a thing",
        body: String = "feat: add a thing",
        stats: GitLineStats? = nil,
        filesChanged: Int? = nil
    ) -> GitCommit {
        GitCommit(
            sha: sha, shortSha: short, parents: parents, author: author, authorEmail: email,
            date: date, refs: refs, subject: subject, body: body,
            stats: stats, filesChanged: filesChanged)
    }

    private func lines(_ commit: GitCommit) -> [String] {
        GitCommitTooltip.text(for: commit).components(separatedBy: "\n")
    }

    @Test func rendersEveryFieldItHas() {
        let rendered = lines(commit(
            refs: [.head("main"), .remote("upstream/dev")],
            body: "feat: add a thing\n\nWhy it matters.",
            stats: GitLineStats(added: 182, removed: 45),
            filesChanged: 7))

        #expect(rendered[0] == "aaaaaaa  feat: add a thing")
        #expect(rendered[1] == "Ada Byron <ada@example.com>")
        #expect(rendered[2] == RelativeTime.absolute(Date(timeIntervalSince1970: 1_755_500_000)))
        #expect(rendered[3] == "HEAD -> main, upstream/dev")
        #expect(rendered[4] == "7 files changed, +182 −45")
        #expect(rendered[5] == "")
        #expect(rendered[6] == "Why it matters.")
    }

    @Test func dropsLinesItHasNoDataFor() {
        let rendered = lines(commit(date: nil))

        #expect(rendered == ["aaaaaaa  feat: add a thing", "Ada Byron <ada@example.com>"])
    }

    @Test func omitsTheAngleBracketsWhenTheEmailIsMissing() {
        #expect(lines(commit(email: ""))[1] == "Ada Byron")
    }

    @Test func stripsTheSubjectGitRepeatsAtTheHeadOfTheBody() {
        let rendered = lines(commit(body: "feat: add a thing\n\nfeat: add a thing again."))

        #expect(rendered.last == "feat: add a thing again.")
        #expect(rendered.filter { $0 == "feat: add a thing" }.isEmpty)
    }

    @Test func truncatesALongBody() {
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let rendered = lines(commit(subject: "s", body: body))

        #expect(rendered.suffix(2) == ["line \(GitCommitTooltip.bodyLineLimit)", "…"])
    }

    @Test func namesADetachedHeadWithoutAnArrow() {
        #expect(lines(commit(refs: [.head(nil), .tag("v1.0")]))[3] == "HEAD, v1.0")
    }

    @Test func leavesOutTheStatsAMergeNeverReports() {
        let rendered = lines(commit(
            parents: ["b", "c"], stats: nil, filesChanged: nil))

        #expect(rendered.count == 3)
        #expect(!rendered.contains { $0.contains("+") })
    }

    @Test func countsOneFileInTheSingular() {
        let rendered = lines(commit(stats: GitLineStats(added: 1, removed: 0), filesChanged: 1))

        #expect(rendered[3] == "1 file changed, +1 −0")
    }

    @Test func skipsAnEmptyStatPair() {
        let rendered = lines(commit(stats: GitLineStats(), filesChanged: 2))

        #expect(rendered[3] == "2 files changed")
    }
}
