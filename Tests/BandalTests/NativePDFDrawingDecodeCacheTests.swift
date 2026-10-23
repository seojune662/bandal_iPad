import XCTest
@testable import Bandal

final class NativePDFDrawingDecodeCacheTests: XCTestCase {
    private func row(_ id: String = "same", data: String = #"{"points":[{"x":0.1,"y":0.2,"p":0.8}]}"#,
                     style: String = #"{"color":"blue","width":0.003}"#) -> [String: Any] {
        ["id": id, "data_json": data, "style_json": style, "updated_at": "unchanged"]
    }
    func testUnchangedStoredJSONReusesDecodeAndEditsIgnoreUnchangedTimestamp() throws {
        let cache = NativePDFDrawingDecodeCache()
        let original = try cache.decode(row())
        _ = try cache.decode(row())
        XCTAssertEqual(cache.decodeCount, 1)
        let revised = try cache.decode(row(style: #"{"color":"red","width":0.003}"#))
        XCTAssertEqual((original.style as? [String: Any])?["color"] as? String, "blue")
        XCTAssertEqual((revised.style as? [String: Any])?["color"] as? String, "red")
        XCTAssertEqual(cache.decodeCount, 2)
        _ = try cache.decode(row())
        XCTAssertEqual(cache.decodeCount, 3, "Undo and external writes must reread exact saved bytes")
    }
    func testCanonicallyEquivalentUnicodeAndSignedZeroAreNotCacheHits() throws {
        let cache = NativePDFDrawingDecodeCache()
        let a = try cache.decode(row(data: "{\"text\":\"é\",\"x\":-0.0}"))
        let b = try cache.decode(row(data: "{\"text\":\"e\u{301}\",\"x\":0.0}"))
        XCTAssertEqual(cache.decodeCount, 2)
        let old = try XCTUnwrap(a.data as? [String: Any]), new = try XCTUnwrap(b.data as? [String: Any])
        XCTAssertNotEqual(Array((old["text"] as! String).utf8), Array((new["text"] as! String).utf8))
        XCTAssertNotEqual((old["x"] as! NSNumber).doubleValue.sign, (new["x"] as! NSNumber).doubleValue.sign)
    }
    func testEvictionInvalidJSONAndPressureReleaseNeverReturnOldPayload() throws {
        let cache = NativePDFDrawingDecodeCache(costLimit: 2048, countLimit: 2)
        _ = try cache.decode(row("first")); _ = try cache.decode(row("second"))
        _ = try cache.decode(row("first")); _ = try cache.decode(row("third"))
        XCTAssertEqual(cache.decodeCount, 3)
        _ = try cache.decode(row("second")); XCTAssertEqual(cache.decodeCount, 4)
        XCTAssertLessThanOrEqual(cache.retainedCost, cache.costLimit)
        XCTAssertThrowsError(try cache.decode(row("second", data: "{broken")))
        _ = try cache.decode(row("second")); XCTAssertEqual(cache.decodeCount, 5)
        cache.removeAll(); XCTAssertEqual(cache.retainedCost, 0)
        _ = try cache.decode(row("second")); XCTAssertEqual(cache.decodeCount, 6)
        let tiny = NativePDFDrawingDecodeCache(costLimit: 1)
        _ = try tiny.decode(row()); _ = try tiny.decode(row())
        XCTAssertEqual(tiny.retainedCost, 0); XCTAssertEqual(tiny.decodeCount, 2)
    }
}
