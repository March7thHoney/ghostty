import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeSidebarPagingTests {
    @Test func untouchedProjectsShowOnePage() {
        #expect(ClaudeSidebarState.visibleSessionCount(revealed: nil, total: 25) == 5)
    }

    /// Fewer sessions than a page means no padding and no "Show more" row.
    @Test func shortProjectsShowEverything() {
        #expect(ClaudeSidebarState.visibleSessionCount(revealed: nil, total: 3) == 3)
    }

    @Test func revealedCountIsHonored() {
        #expect(ClaudeSidebarState.visibleSessionCount(revealed: 10, total: 25) == 10)
    }

    /// A rescan that drops sessions must not leave the project claiming more than it has.
    @Test func revealedCountClampsToTotal() {
        #expect(ClaudeSidebarState.visibleSessionCount(revealed: 20, total: 8) == 8)
    }

    /// A stale count below one page still renders a full first page.
    @Test func revealedCountNeverFallsBelowOnePage() {
        #expect(ClaudeSidebarState.visibleSessionCount(revealed: 2, total: 25) == 5)
    }
}
