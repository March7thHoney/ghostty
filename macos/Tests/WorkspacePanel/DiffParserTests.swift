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

/// The multi-file sections the commit view renders; single-file callers keep using `lines`.
@Suite
struct DiffParserFileSectionTests {
    private let twoFiles = """
    diff --git a/src/a.swift b/src/a.swift
    index 1111111..2222222 100644
    --- a/src/a.swift
    +++ b/src/a.swift
    @@ -1,2 +1,2 @@
     keep
    -old
    +new
    diff --git a/docs/b.md b/docs/b.md
    index 3333333..4444444 100644
    --- a/docs/b.md
    +++ b/docs/b.md
    @@ -1 +1,2 @@
     title
    +added
    """

    @Test func splitsAPatchIntoOneSectionPerFile() {
        let diff = DiffParser.parse(twoFiles)

        #expect(diff.files.map(\.path) == ["src/a.swift", "docs/b.md"])
        #expect(diff.files.allSatisfy { $0.change == .modified })
        #expect(diff.files[0].lines.map(\.kind) == [.hunkHeader, .context, .deletion, .addition])
        #expect(diff.files[1].lines.map(\.kind) == [.hunkHeader, .context, .addition])
        // The flat list stays the concatenation, which is what the single-file pane renders.
        #expect(diff.lines.count == diff.files.reduce(0) { $0 + $1.lines.count })
    }

    @Test func singleFilePatchStillYieldsOneSection() {
        let diff = DiffParser.parse("""
        diff --git a/hello.txt b/hello.txt
        --- a/hello.txt
        +++ b/hello.txt
        @@ -1 +1 @@
        -a
        +b
        """)

        #expect(diff.files.count == 1)
        #expect(diff.files[0].path == "hello.txt")
        #expect(diff.files[0].lines.count == diff.lines.count)
    }

    @Test func addedFileTakesItsPathFromThePlusSide() {
        let diff = DiffParser.parse("""
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1 @@
        +hello
        """)

        #expect(diff.files.map(\.path) == ["new.txt"])
        #expect(diff.files[0].change == .added)
    }

    @Test func deletedFileTakesItsPathFromTheMinusSide() {
        let diff = DiffParser.parse("""
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1111111..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        """)

        #expect(diff.files.map(\.path) == ["gone.txt"])
        #expect(diff.files[0].change == .deleted)
    }

    /// A 100% rename carries no ---/+++ lines and no hunks at all, so the path must come elsewhere.
    @Test func pureRenameHasNoHunksButStillResolves() {
        let diff = DiffParser.parse("""
        diff --git a/old/name.swift b/new/name.swift
        similarity index 100%
        rename from old/name.swift
        rename to new/name.swift
        """)

        #expect(diff.files.count == 1)
        #expect(diff.files[0].path == "new/name.swift")
        #expect(diff.files[0].origPath == "old/name.swift")
        #expect(diff.files[0].change == .renamed)
        #expect(diff.files[0].lines.isEmpty)
    }

    @Test func renameWithEditsKeepsBothPaths() {
        let diff = DiffParser.parse("""
        diff --git a/old.swift b/new.swift
        similarity index 90%
        rename from old.swift
        rename to new.swift
        --- a/old.swift
        +++ b/new.swift
        @@ -1 +1 @@
        -a
        +b
        """)

        #expect(diff.files[0].path == "new.swift")
        #expect(diff.files[0].origPath == "old.swift")
        #expect(diff.files[0].change == .renamed)
        #expect(diff.files[0].lines.count == 3)
    }

    /// A binary file has no ---/+++ either, so only the `diff --git` line names it.
    @Test func binaryFileFallsBackToTheDiffGitLine() {
        let diff = DiffParser.parse("""
        diff --git a/img/logo.png b/img/logo.png
        index 1111111..2222222 100644
        Binary files a/img/logo.png and b/img/logo.png differ
        """)

        #expect(diff.files.map(\.path) == ["img/logo.png"])
        #expect(diff.files[0].isBinary)
        #expect(diff.isBinary)
    }

    /// `diff --git a/X b/Y` is ambiguous with spaces, so the matching halves decide the split.
    @Test func pathWithSpacesResolvesFromTheMatchingHalves() {
        let diff = DiffParser.parse("""
        diff --git a/my docs/a b.md b/my docs/a b.md
        index 1111111..2222222 100644
        Binary files a/my docs/a b.md and b/my docs/a b.md differ
        """)

        #expect(diff.files.map(\.path) == ["my docs/a b.md"])
    }

    @Test func copyIsClassifiedSeparatelyFromRename() {
        let diff = DiffParser.parse("""
        diff --git a/src/a.swift b/src/b.swift
        similarity index 100%
        copy from src/a.swift
        copy to src/b.swift
        """)

        #expect(diff.files[0].change == .copied)
        #expect(diff.files[0].origPath == "src/a.swift")
    }

    @Test func eachSectionMeasuresItsOwnWidth() {
        let diff = DiffParser.parse("""
        diff --git a/short.txt b/short.txt
        --- a/short.txt
        +++ b/short.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/long.txt b/long.txt
        --- a/long.txt
        +++ b/long.txt
        @@ -1 +1 @@
        -aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        +bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        """)

        #expect(diff.files[0].maxColumns < diff.files[1].maxColumns)
        // The whole-diff width is the widest section, which sizes the shared horizontal scroll.
        #expect(diff.maxColumns == diff.files[1].maxColumns)
    }

    @Test func emptyPatchHasNoSections() {
        let diff = DiffParser.parse("")

        #expect(diff.files.isEmpty)
        #expect(diff.isEmpty)
    }
}
