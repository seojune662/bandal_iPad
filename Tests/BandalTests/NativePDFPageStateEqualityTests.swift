import XCTest
@testable import Bandal

final class NativePDFPageStateEqualityTests: XCTestCase {
    func testScalarEqualityMatchesPersistedCanonicalBytes() throws {
        let values: [Any] = [NSNull(), "", "ink", "1", "true", "\u{00e9}", "e\u{0301}", "nul\u{0}byte", NSNumber(value: true), NSNumber(value: false), NSNumber(value: 1), NSNumber(value: 1.0), NSNumber(value: 0), NSNumber(value: 0.0), NSNumber(value: -0.0), NSNumber(value: 0.1), NSNumber(value: 9_007_199_254_740_993 as Int64)]
        for left in values { for right in values {
            let expected = try Data(NativeSyncFormat.canonical(left).utf8) == Data(NativeSyncFormat.canonical(right).utf8)
            XCTAssertEqual(try NativePDFPageStateEquality.scalar(left, right), expected)
        } }
        XCTAssertFalse(try NativePDFPageStateEquality.scalar(["nested": 1], ["nested": 1]))
        XCTAssertFalse(try NativePDFPageStateEquality.scalar(NSNumber(value: Double.nan), NSNumber(value: Double.nan)))
    }
    func testRowsPreserveOrderNullColumnsExactJSONAndUnicodeKeySpelling() throws {
        let a: [String: Any] = ["id": "a", "page": 1, "data_json": "{\"points\":[1,2]}", "deleted_at": NSNull()]
        let b: [String: Any] = ["deleted_at": NSNull(), "data_json": "{\"points\":[1,2]}", "page": 1.0, "id": "a"]
        XCTAssertTrue(try NativePDFPageStateEquality.row(a, b))
        XCTAssertTrue(try NativePDFPageStateEquality.rows([a, a], [b, b]))
        var changed = a; changed["data_json"] = "{\"points\":[1,3]}"
        XCTAssertFalse(try NativePDFPageStateEquality.rows([a], [changed]))
        XCTAssertFalse(try NativePDFPageStateEquality.rows([a, changed], [changed, a]))
        changed = a; changed.removeValue(forKey: "deleted_at")
        XCTAssertFalse(try NativePDFPageStateEquality.row(a, changed))
        XCTAssertFalse(try NativePDFPageStateEquality.row(["\u{00e9}": 1], ["e\u{0301}": 1]))
        XCTAssertFalse(try NativePDFPageStateEquality.row(["text": "\u{00e9}"], ["text": "e\u{0301}"]))
    }
}
