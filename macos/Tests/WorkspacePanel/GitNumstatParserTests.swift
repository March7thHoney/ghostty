import Foundation
import Testing
@testable import Ghostty

@Suite
struct GitNumstatParserTests {
    private func parse(_ lines: [String]) -> GitLineStats {
        GitNumstatParser.parse(Data(lines.joined(separator: "\n").utf8))
    }

    @Test func sumsRows() {
        let stats = parse(["3\t1\tsrc/app.zig", "10\t0\tREADME.md", ""])
        #expect(stats.added == 13)
        #expect(stats.removed == 1)
        #expect(!stats.isZero)
    }

    @Test func skipsBinaryRows() {
        let stats = parse(["-\t-\timage.png", "2\t2\tsrc/app.zig"])
        #expect(stats.added == 2)
        #expect(stats.removed == 2)
    }

    @Test func countsRenameRows() {
        let stats = parse(["1\t1\tsrc/{old.zig => new.zig}"])
        #expect(stats.added == 1)
        #expect(stats.removed == 1)
    }

    @Test func keepsPathsWithTabs() {
        let stats = parse(["4\t5\tsrc/od\td.zig"])
        #expect(stats.added == 4)
        #expect(stats.removed == 5)
    }

    @Test func skipsMalformedRows() {
        let stats = parse(["not a numstat row", "7\tx\tsrc/app.zig", "1\t2"])
        #expect(stats.isZero)
    }

    @Test func handlesEmptyOutput() {
        #expect(parse([]) == GitLineStats())
        #expect(GitNumstatParser.parse(Data()).isZero)
    }
}
