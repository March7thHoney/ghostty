import Foundation
import Testing
@testable import Ghostty

@Suite
struct DiffParserTests {
    private let sample = """
    diff --git a/hello.txt b/hello.txt
    index 1111111..2222222 100644
    --- a/hello.txt
    +++ b/hello.txt
    @@ -1,3 +1,3 @@
     first
    -second
    +second changed
     third
    """

    @Test func classifiesAndNumbersHunkLines() {
        let diff = DiffParser.parse(sample)
        #expect(!diff.isBinary)
        #expect(!diff.truncated)
        #expect(diff.lines.map(\.kind) == [.hunkHeader, .context, .deletion, .addition, .context])

        let context = diff.lines[1]
        #expect(context.text == "first")
        #expect(context.oldLine == 1)
        #expect(context.newLine == 1)

        let deletion = diff.lines[2]
        #expect(deletion.text == "second")
        #expect(deletion.oldLine == 2)
        #expect(deletion.newLine == nil)

        let addition = diff.lines[3]
        #expect(addition.text == "second changed")
        #expect(addition.oldLine == nil)
        #expect(addition.newLine == 2)
    }

    @Test func secondHunkRestartsNumbering() {
        let diff = DiffParser.parse("""
        @@ -1,1 +1,1 @@
        -old
        +new
        @@ -10,1 +12,1 @@
         tenth
        """)
        #expect(diff.lines[3].kind == .hunkHeader)
        #expect(diff.lines[4].oldLine == 10)
        #expect(diff.lines[4].newLine == 12)
    }

    @Test func detectsBinaryDiff() {
        let diff = DiffParser.parse("""
        diff --git a/image.png b/image.png
        Binary files a/image.png and b/image.png differ
        """)
        #expect(diff.isBinary)
        #expect(diff.lines.isEmpty)
    }

    @Test func preambleIsDroppedNotMisclassified() {
        let diff = DiffParser.parse(sample)
        #expect(!diff.lines.contains { $0.text.hasPrefix("++ b/") })
        #expect(!diff.lines.contains { $0.kind == .deletion && $0.text.hasPrefix("-- a/") })
    }

    /// A second file section after a hunk returns the parser to preamble mode.
    @Test func multiFileDiffResetsAtBoundary() {
        let diff = DiffParser.parse("""
        @@ -1,1 +1,1 @@
        -one
        +uno
        diff --git a/other.txt b/other.txt
        --- a/other.txt
        +++ b/other.txt
        @@ -5,1 +5,1 @@
         five
        """)
        #expect(diff.lines.map(\.kind) == [.hunkHeader, .deletion, .addition, .hunkHeader, .context])
        #expect(diff.lines[4].oldLine == 5)
    }

    @Test func noNewlineMarkerIsMeta() {
        let diff = DiffParser.parse("""
        @@ -1,1 +1,1 @@
        -old
        +new
        \\ No newline at end of file
        """)
        #expect(diff.lines.last?.kind == .meta)
    }

    @Test func truncatesBeyondCap() {
        var text = "@@ -1,\(DiffParser.maxLines + 10) +1,\(DiffParser.maxLines + 10) @@\n"
        text += Array(repeating: " x", count: DiffParser.maxLines + 10).joined(separator: "\n")
        let diff = DiffParser.parse(text)
        #expect(diff.truncated)
        #expect(diff.lines.count == DiffParser.maxLines)
    }

    @Test func emptyInputIsEmptyDiff() {
        let diff = DiffParser.parse("")
        #expect(diff.isEmpty)
    }

    /// Width estimation drives the horizontal scroll extent, so widths must track the widest line.
    @Test func tracksWidestLineInColumns() {
        let diff = DiffParser.parse("""
        @@ -1,2 +1,2 @@
        -short
        +a much longer replacement line
        """)
        #expect(diff.maxColumns == "a much longer replacement line".count)

        #expect(DiffParser.visualColumns(of: "abc") == 3)
        #expect(DiffParser.visualColumns(of: "\tx") == 5)
        #expect(DiffParser.visualColumns(of: "宽字符") == 6)
    }
}
