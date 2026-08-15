import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeSessionHighlightTests {
    @Test func closedSessionsGetNoHighlight() {
        #expect(ClaudeSessionHighlight.of(isOpen: false, isActive: false) == .none)
    }

    @Test func openSessionsGetTheAccentHighlight() {
        #expect(ClaudeSessionHighlight.of(isOpen: true, isActive: false) == .open)
    }

    @Test func theFocusedTabGetsItsOwnHighlight() {
        #expect(ClaudeSessionHighlight.of(isOpen: true, isActive: true) == .active)
    }

    /// The open set is polled, so a fresh tab switch can be active before it is known to be open.
    @Test func activenessWinsBeforeThePollCatchesUp() {
        #expect(ClaudeSessionHighlight.of(isOpen: false, isActive: true) == .active)
    }
}
