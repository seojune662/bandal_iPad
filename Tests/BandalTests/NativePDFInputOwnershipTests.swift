import XCTest
@testable import Bandal

@MainActor
final class NativePDFInputOwnershipTests: XCTestCase {
    func testOnlyOrphanedMeasuredInputCanBeRecoveredByAnotherPane() {
        let ownership = NativePDFInputOwnership(), root = URL(fileURLWithPath: "/tmp/pdf-ownership-\(UUID())")
        var a: NSObject? = NSObject(); let b = NSObject()
        let mutation = UUID().uuidString
        XCTAssertTrue(ownership.claim(root: root, course: "c", path: "a.pdf", mutation: mutation, owner: a!))
        XCTAssertFalse(ownership.claim(root: root, course: "c", path: "a.pdf", mutation: mutation, owner: b))
        ownership.release(root: root, course: "c", path: "a.pdf", mutation: mutation, owner: b)
        XCTAssertFalse(ownership.claim(root: root, course: "c", path: "a.pdf", mutation: mutation, owner: b), "A peer cannot release a live contact's claim")
        XCTAssertTrue(ownership.claim(root: root, course: "c", path: "other.pdf", mutation: mutation, owner: b))
        a = nil
        XCTAssertTrue(ownership.claim(root: root, course: "c", path: "a.pdf", mutation: mutation, owner: b), "After the old owner exits, the exact same durable receipt becomes recoverable")
    }
}
