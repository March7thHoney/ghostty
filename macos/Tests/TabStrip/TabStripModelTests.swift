import Foundation
import Testing
@testable import Ghostty

struct TabStripModelTests {
    @Test func moveLeftShiftsElement() {
        #expect(TabStripModel.reorder([1, 2, 3, 4], moving: 2, to: 0) == [3, 1, 2, 4])
    }

    @Test func moveRightShiftsElement() {
        #expect(TabStripModel.reorder([1, 2, 3, 4], moving: 0, to: 3) == [2, 3, 4, 1])
    }

    @Test func movingInPlaceChangesNothing() {
        #expect(TabStripModel.reorder([1, 2, 3], moving: 1, to: 1) == [1, 2, 3])
    }

    @Test func targetBeyondEndClampsToLast() {
        #expect(TabStripModel.reorder([1, 2, 3], moving: 0, to: 99) == [2, 3, 1])
    }

    @Test func invalidSourceIsIgnored() {
        #expect(TabStripModel.reorder([1, 2, 3], moving: 7, to: 0) == [1, 2, 3])
    }
}
