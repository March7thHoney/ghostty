import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeSessionGroupingTests {
    private func summary(
        id: String,
        cwd: String,
        lastActivity: Date?
    ) -> ClaudeTranscriptSummary {
        .init(
            sessionID: id,
            fileURL: URL(fileURLWithPath: "/tmp/fixtures/\(id).jsonl"),
            cwd: cwd,
            title: nil,
            lastActivity: lastActivity)
    }

    @Test func groupsByRecordedCwd() {
        let projects = ClaudeSessionIndex.group([
            summary(id: "a", cwd: "/projects/alpha", lastActivity: Date(timeIntervalSince1970: 100)),
            summary(id: "b", cwd: "/projects/beta", lastActivity: Date(timeIntervalSince1970: 200)),
            summary(id: "c", cwd: "/projects/alpha", lastActivity: Date(timeIntervalSince1970: 300)),
        ])
        #expect(projects.map(\.cwd) == ["/projects/alpha", "/projects/beta"])
        #expect(projects[0].sessions.map(\.sessionID) == ["c", "a"])
    }

    /// Projects order by their most recent session; sessions within a
    /// project order newest first.
    @Test func ordersProjectsAndSessionsByRecency() {
        let projects = ClaudeSessionIndex.group([
            summary(id: "old", cwd: "/projects/dormant", lastActivity: Date(timeIntervalSince1970: 50)),
            summary(id: "a", cwd: "/projects/active", lastActivity: Date(timeIntervalSince1970: 500)),
            summary(id: "b", cwd: "/projects/active", lastActivity: Date(timeIntervalSince1970: 400)),
        ])
        #expect(projects.map(\.cwd) == ["/projects/active", "/projects/dormant"])
        #expect(projects[0].sessions.map(\.sessionID) == ["a", "b"])
        #expect(projects[0].lastActivity == Date(timeIntervalSince1970: 500))
    }

    /// Sessions with no readable timestamp sink to the bottom rather than
    /// disappearing or floating to the top.
    @Test func timestamplessSessionsSortLast() {
        let projects = ClaudeSessionIndex.group([
            summary(id: "undated", cwd: "/projects/alpha", lastActivity: nil),
            summary(id: "dated", cwd: "/projects/alpha", lastActivity: Date(timeIntervalSince1970: 100)),
        ])
        #expect(projects[0].sessions.map(\.sessionID) == ["dated", "undated"])
    }

    /// Two directories that would collide under Claude's lossy directory-name
    /// mangling ("/a/b_c" and "/a/b-c" both become "-a-b-c") stay separate
    /// because grouping reads the cwd recorded inside the transcripts.
    @Test func manglingCollisionsStaySeparate() {
        let projects = ClaudeSessionIndex.group([
            summary(id: "a", cwd: "/projects/my_tool", lastActivity: Date(timeIntervalSince1970: 100)),
            summary(id: "b", cwd: "/projects/my-tool", lastActivity: Date(timeIntervalSince1970: 200)),
        ])
        #expect(projects.count == 2)
    }

    @Test func displayNameIsLastPathComponent() {
        let projects = ClaudeSessionIndex.group([
            summary(id: "a", cwd: "/projects/alpha", lastActivity: nil),
        ])
        #expect(projects[0].displayName == "alpha")
    }
}
