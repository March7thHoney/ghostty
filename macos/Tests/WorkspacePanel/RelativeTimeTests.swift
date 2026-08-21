import Foundation
import Testing
@testable import Ghostty

@Suite
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ seconds: TimeInterval) -> String {
        RelativeTime.compact(now.addingTimeInterval(-seconds), now: now)
    }

    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    @Test func belowAMinuteReadsAsNow() {
        #expect(ago(0) == "now")
        #expect(ago(59) == "now")
    }

    @Test func rollsOverAtEveryUnitBoundary() {
        #expect(ago(minute) == "1m ago")
        #expect(ago(59 * minute) == "59m ago")
        #expect(ago(hour) == "1h ago")
        #expect(ago(23 * hour) == "23h ago")
        #expect(ago(day) == "1d ago")
        #expect(ago(6 * day) == "6d ago")
        #expect(ago(7 * day) == "1w ago")
        #expect(ago(29 * day) == "4w ago")
        #expect(ago(30 * day) == "1mo ago")
        #expect(ago(364 * day) == "12mo ago")
        #expect(ago(365 * day) == "1y ago")
        #expect(ago(800 * day) == "2y ago")
    }

    /// A commit stamped in the future is a skewed clock, and "in 3 hours" would just look broken.
    @Test func futureTimestampsClampToNow() {
        #expect(RelativeTime.compact(now.addingTimeInterval(3 * hour), now: now) == "now")
    }
}
