import Foundation
import XCTest
@testable import Bandal

final class NativeMediaDropBudgetTests: XCTestCase {
    func testAggregateBudgetRejectsOversizedEncodedAndDecodedBatches() throws {
        let bytes = NativeEditorMediaImport.Budget()
        try bytes.reserve(bytes: 60 * 1024 * 1024)
        XCTAssertThrowsError(try bytes.reserve(bytes: 41 * 1024 * 1024))
        let pixels = NativeEditorMediaImport.Budget()
        try pixels.reserve(pixels: 20_000_000)
        XCTAssertThrowsError(try pixels.reserve(pixels: 13_000_000))
        // A rejected reservation must not consume capacity.
        XCTAssertNoThrow(try pixels.reserve(pixels: 12_000_000))
    }

    func testLegacyFileURLRepresentationsNeverAcceptNetworkURLs() {
        let file = URL(fileURLWithPath: "/tmp/한글 사진.png")
        XCTAssertEqual(NativeEditorMediaImport.fileURL(from: file as NSURL), file)
        XCTAssertEqual(NativeEditorMediaImport.fileURL(from: file.absoluteString as NSString), file)
        XCTAssertEqual(NativeEditorMediaImport.fileURL(from: file.dataRepresentation as NSData), file)
        XCTAssertNil(NativeEditorMediaImport.fileURL(from: "https://example.com/a.png" as NSString))
    }
}
