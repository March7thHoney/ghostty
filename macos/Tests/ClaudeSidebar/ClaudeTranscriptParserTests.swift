import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeTranscriptParserTests {
    private static let sessionID = "11111111-2222-3333-4444-555555555555"
    private static let fileURL = URL(fileURLWithPath: "/tmp/fixtures/\(sessionID).jsonl")

    private func parse(_ lines: [String]) -> ClaudeTranscriptSummary? {
        ClaudeTranscriptParser.parse(
            data: Data((lines.joined(separator: "\n") + "\n").utf8),
            sessionID: Self.sessionID,
            fileURL: Self.fileURL)
    }

    // MARK: - cwd

    /// Transcripts can open with records that carry no cwd (queue
    /// operations); the scan has to keep going until one does.
    @Test func cwdBehindLeadingRecordsWithoutOne() {
        let summary = parse([
            #"{"type":"queue-operation","operation":"enqueue"}"#,
            #"{"type":"queue-operation","operation":"dequeue"}"#,
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"hello"}}"#,
        ])
        #expect(summary?.cwd == "/projects/alpha")
    }

    /// No record naming a cwd means the transcript is unusable for the
    /// sidebar: without it there is nowhere to resume the session.
    @Test func missingCwdFails() {
        #expect(parse([#"{"type":"queue-operation"}"#]) == nil)
    }

    // MARK: - Title fallback chain

    @Test func aiTitleWinsAndLastOccurrenceIsUsed() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","slug":"some-slug","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"first message"}}"#,
            #"{"type":"ai-title","aiTitle":"Early title","sessionId":"x"}"#,
            #"{"type":"assistant","timestamp":"2026-01-02T03:05:00.000Z","message":{"role":"assistant"}}"#,
            #"{"type":"ai-title","aiTitle":"Later title","sessionId":"x"}"#,
            #"{"type":"last-prompt","lastPrompt":"a prompt","leafUuid":"y"}"#,
        ])
        #expect(summary?.title == "Later title")
    }

    /// The byte search may land inside a message that merely talks about
    /// aiTitle records; only a real ai-title record counts.
    @Test func aiTitleMentionedInMessageTextIsIgnored() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"real question"}}"#,
            #"{"type":"ai-title","aiTitle":"Actual title","sessionId":"x"}"#,
            #"{"type":"user","timestamp":"2026-01-02T03:06:00.000Z","message":{"role":"user","content":"explain the \"aiTitle\" record format"}}"#,
        ])
        #expect(summary?.title == "Actual title")
    }

    @Test func slugWhenNoAiTitle() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","slug":"tidy-slug","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"hello"}}"#,
        ])
        #expect(summary?.title == "tidy-slug")
    }

    @Test func lastPromptWhenNoAiTitleOrSlug() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","isMeta":true,"message":{"role":"user","content":"meta noise"}}"#,
            #"{"type":"last-prompt","lastPrompt":"the last thing typed","leafUuid":"y"}"#,
        ])
        #expect(summary?.title == "the last thing typed")
    }

    @Test func firstUserMessageAsFinalFallback() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","isMeta":true,"message":{"role":"user","content":"meta noise"}}"#,
            #"{"type":"user","timestamp":"2026-01-02T03:04:06.000Z","isSidechain":true,"message":{"role":"user","content":"subagent chatter"}}"#,
            #"{"type":"user","timestamp":"2026-01-02T03:04:07.000Z","message":{"role":"user","content":"<command-name>/status</command-name>"}}"#,
            #"{"type":"user","timestamp":"2026-01-02T03:04:08.000Z","message":{"role":"user","content":"please fix the build"}}"#,
        ])
        #expect(summary?.title == "please fix the build")
    }

    @Test func untitledWhenNothingUsable() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
        ])
        #expect(summary?.title == nil)
    }

    @Test func blockArrayContentIsReadable() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":[{"type":"text","text":"from a block"}]}}"#,
        ])
        #expect(summary?.title == "from a block")
    }

    @Test func titlesCollapseToOneBoundedLine() {
        let long = String(repeating: "x", count: 300)
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"line one\nline two"}}"#,
        ])
        #expect(summary?.title == "line one")

        let longSummary = parse([
            "{\"type\":\"user\",\"cwd\":\"/projects/alpha\",\"timestamp\":\"2026-01-02T03:04:05.678Z\",\"message\":{\"role\":\"user\",\"content\":\"\(long)\"}}",
        ])
        #expect(longSummary?.title?.count == 120)
    }

    // MARK: - lastActivity

    /// The literal last line can be a record with no timestamp at all.
    @Test func lastActivitySkipsTimestamplessTail() throws {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","timestamp":"2026-01-02T03:09:10.500Z","message":{"role":"assistant"}}"#,
            #"{"type":"last-prompt","lastPrompt":"tail","leafUuid":"y"}"#,
        ])
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-01-02T03:09:10Z"))
        let activity = try #require(summary?.lastActivity)
        #expect(abs(activity.timeIntervalSince(expected) - 0.5) < 0.001)
    }

    @Test func wholeSecondTimestampsParse() {
        let summary = parse([
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05Z","message":{"role":"user","content":"hello"}}"#,
        ])
        #expect(summary?.lastActivity == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
    }

    // MARK: - Robustness

    @Test func malformedLinesAreSkipped() {
        let summary = parse([
            "not json at all {{{",
            #"{"type":"user","cwd":"/projects/alpha","timestamp":"2026-01-02T03:04:05.678Z","message":{"role":"user","content":"hello"}}"#,
            "another bad line",
        ])
        #expect(summary?.cwd == "/projects/alpha")
        #expect(summary?.title == "hello")
    }

    @Test func nonUUIDFilenameIsRejected() {
        // parse(fileURL:) guards the filename; feed it a sidecar-style name.
        let url = URL(fileURLWithPath: "/tmp/fixtures/not-a-session.jsonl")
        #expect(ClaudeTranscriptParser.parse(fileURL: url) == nil)
    }
}
