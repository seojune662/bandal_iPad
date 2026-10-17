import XCTest
@testable import Bandal

final class NativePDFPageEditingTests: XCTestCase {
    func testReorderUsesOriginalPageNumbersAndInsertionSlots() {
        XCTAssertEqual(NativePDFPageEditing.moved(count: 4, from: 1, insertionSlot: 5), [2, 3, 4, 1])
        XCTAssertEqual(NativePDFPageEditing.moved(count: 4, from: 4, insertionSlot: 2), [1, 4, 2, 3])
        XCTAssertEqual(NativePDFPageEditing.moved(count: 3, from: 1, to: 2), [2, 1, 3])
        XCTAssertNil(NativePDFPageEditing.moved(count: 3, from: 2, insertionSlot: 2))
        XCTAssertNil(NativePDFPageEditing.moved(count: 3, from: 2, insertionSlot: 3))
    }
    func testInvalidAndNoOpDropsCannotProduceDestructiveRecipes() {
        for value in [0, 4, -1] { XCTAssertNil(NativePDFPageEditing.moved(count: 3, from: value, to: 2)) }
        XCTAssertNil(NativePDFPageEditing.moved(count: 3, from: 1, to: 4))
        XCTAssertNil(NativePDFPageEditing.moved(count: 3, from: 1, insertionSlot: 5))
        XCTAssertNil(NativePDFPageEditing.moved(count: 0, from: 1, insertionSlot: 1))
    }
    func testDeleteCannotRemoveLastPageAndPreservesStableSourceOrder() {
        XCTAssertNil(NativePDFPageEditing.deleted(count: 1, page: 1))
        XCTAssertNil(NativePDFPageEditing.deleted(count: 0, page: 1))
        XCTAssertNil(NativePDFPageEditing.deleted(count: 3, page: 4))
        XCTAssertEqual(NativePDFPageEditing.deleted(count: 4, page: 2), [1, 3, 4])
    }
    func testViewportFollowsSameSurvivingPageOrNearestEarlierPage() {
        XCTAssertEqual(NativePDFPageEditing.remapped(1, pageMap: [[2], [], [1]]), 2)
        XCTAssertEqual(NativePDFPageEditing.remapped(2, pageMap: [[2], [], [1]]), 2)
        XCTAssertEqual(NativePDFPageEditing.remapped(1, pageMap: [[], [1]]), 1)
        XCTAssertEqual(NativePDFPageEditing.remapped(3, pageMap: []), 1)
    }
}
