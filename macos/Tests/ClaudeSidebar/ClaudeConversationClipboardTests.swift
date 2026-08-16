import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeConversationClipboardTests {
    /// Session IDs are UUIDs, which shlex-style quoting passes through bare.
    @Test func forkCommandLeavesUUIDsUnquoted() {
        #expect(ClaudeSidebarCoordinator.forkCommand(
            sessionID: "0f2a9c1e-1234-4abc-8def-0123456789ab")
            == "claude --resume 0f2a9c1e-1234-4abc-8def-0123456789ab --fork-session")
    }

    /// A hostile filename stem must not break out of the command.
    @Test func forkCommandQuotesUnsafeIDs() {
        #expect(ClaudeSidebarCoordinator.forkCommand(sessionID: "a b;rm")
            == "claude --resume 'a b;rm' --fork-session")
    }

    @Test func pasteTitleWithoutCopyIsPlain() {
        #expect(ClaudeSidebarState.pasteMenuTitle(copiedTitle: nil) == "Paste Conversation")
    }

    @Test func pasteTitleQuotesShortTitles() {
        #expect(ClaudeSidebarState.pasteMenuTitle(copiedTitle: "Fix parser")
            == "Paste Conversation \u{201C}Fix parser\u{201D}")
    }

    /// Long titles are clipped so the menu item can't grow unbounded.
    @Test func pasteTitleTruncatesLongTitles() {
        let long = String(repeating: "x", count: 60)
        let result = ClaudeSidebarState.pasteMenuTitle(copiedTitle: long)
        #expect(result == "Paste Conversation \u{201C}\(String(repeating: "x", count: 40))…\u{201D}")
    }
}
