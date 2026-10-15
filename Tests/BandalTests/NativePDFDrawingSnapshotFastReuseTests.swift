import XCTest
import Foundation
@testable import Bandal

@MainActor
final class NativePDFDrawingSnapshotFastReuseTests: XCTestCase {
    func testFreshContainersAndDiscardedNativeMarkersReuseOnlyAnExactRow() throws {
        let store = NativePDFDrawingSnapshotStore()
        let first = try store.makeRow(Self.object(), pageCount: 1)
        var fresh = Self.object()
        fresh["_nativeInk"] = NSObject()
        fresh["_nativeVisualToken"] = NSObject()
        let reused = try store.makeRow(fresh, pageCount: 1, previous: first)
        XCTAssertTrue(reused === first)
        XCTAssertTrue(reused.visualToken === first.visualToken)
        XCTAssertEqual(store.fastReuseCount, 1)
        XCTAssertEqual(store.fullPreparationCount, 1)

        fresh["updatedAt"] = "changed metadata"
        let changed = try store.makeRow(fresh, pageCount: 1, previous: first)
        XCTAssertFalse(changed === first, "Same ID cannot bypass any metadata change")
        XCTAssertEqual(changed.object["updatedAt"] as? String, "changed metadata")
        XCTAssertEqual(store.fullPreparationCount, 2)
        XCTAssertNil(changed.object["_nativeInk"])
        XCTAssertNil(changed.object["_nativeVisualToken"])
    }

    func testCanonicallyEquivalentStringValuesKeepTheirExactJSONSpelling() throws {
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed, "The fixture exercises Swift's canonical equivalence")
        XCTAssertFalse(composed.utf8.elementsEqual(decomposed.utf8))
        let store = NativePDFDrawingSnapshotStore()
        var firstPayload = Self.object(); firstPayload["extra"] = composed
        let first = try store.makeRow(firstPayload, pageCount: 1)
        var changedPayload = Self.object(); changedPayload["extra"] = decomposed
        let changed = try store.makeRow(changedPayload, pageCount: 1, previous: first)
        XCTAssertFalse(changed === first)
        let stored = try XCTUnwrap(changed.object["extra"] as? String)
        XCTAssertTrue(stored.utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(store.fastReuseCount, 0)
        XCTAssertEqual(store.fullPreparationCount, 2)
    }

    func testCanonicallyEquivalentDictionaryKeysKeepTheirExactJSONSpelling() throws {
        let composed = "\u{00E9}", decomposed = "e\u{0301}"
        let store = NativePDFDrawingSnapshotStore()
        var firstPayload = Self.object(); firstPayload["extra"] = [composed: "same value"]
        let first = try store.makeRow(firstPayload, pageCount: 1)
        var changedPayload = Self.object(); changedPayload["extra"] = [decomposed: "same value"]
        let changed = try store.makeRow(changedPayload, pageCount: 1, previous: first)
        XCTAssertFalse(changed === first)
        let nested = try XCTUnwrap(changed.object["extra"] as? [String: Any])
        let storedKey = try XCTUnwrap(nested.keys.first)
        XCTAssertTrue(storedKey.utf8.elementsEqual(decomposed.utf8))
        XCTAssertEqual(store.fastReuseCount, 0)
        XCTAssertEqual(store.fullPreparationCount, 2)
    }

    func testSameMutableNestedContainersAreRereadAndDetachedOnChange() throws {
        let point: NSMutableDictionary = ["x": 0.1, "y": 0.2, "p": 0.4, "t": 0.0]
        let data: NSMutableDictionary = ["inkVersion": 4, "points": NSMutableArray(object: point)]
        let style: NSMutableDictionary = ["color": "ink", "width": 0.003, "opacity": 1.0]
        var source = Self.object(); source["data"] = data; source["style"] = style
        let store = NativePDFDrawingSnapshotStore()
        let first = try store.makeRow(source, pageCount: 1)
        point["x"] = 0.75; style["width"] = 0.008
        let changed = try store.makeRow(source, pageCount: 1, previous: first)
        XCTAssertFalse(changed === first)
        XCTAssertEqual(store.fastReuseCount, 0)
        XCTAssertEqual(store.fullPreparationCount, 2)
        XCTAssertEqual(try Self.firstPoint(first)["x"] as? Double, 0.1)
        XCTAssertEqual(try Self.firstPoint(changed)["x"] as? Double, 0.75)
        point["x"] = 0.9
        XCTAssertEqual(try Self.firstPoint(changed)["x"] as? Double, 0.75)
    }

    func testBooleanAndNumericValuesRemainDifferent() throws {
        let store = NativePDFDrawingSnapshotStore()
        var boolean = Self.object(); boolean["extra"] = NSNumber(value: true)
        let first = try store.makeRow(boolean, pageCount: 1)
        var numeric = Self.object(); numeric["extra"] = NSNumber(value: 1)
        let second = try store.makeRow(numeric, pageCount: 1, previous: first)
        XCTAssertFalse(second === first)
        XCTAssertEqual(store.fastReuseCount, 0)
        XCTAssertEqual(store.fullPreparationCount, 2)
        let old = try XCTUnwrap(first.object["extra"] as? NSNumber)
        let new = try XCTUnwrap(second.object["extra"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(old), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(new), CFBooleanGetTypeID())
    }

    func testLargeIntegersAdjacentDoublesAndSignedZeroCannotFalselyFastReuse() throws {
        let store = NativePDFDrawingSnapshotStore()
        var left = Self.object(); left["extra"] = NSNumber(value: Int64(9_007_199_254_740_992))
        let a = try store.makeRow(left, pageCount: 1)
        var right = Self.object(); right["extra"] = NSNumber(value: Int64(9_007_199_254_740_993))
        let b = try store.makeRow(right, pageCount: 1, previous: a)
        XCTAssertFalse(a === b, "Distinct integer metadata must not collapse through Double")
        XCTAssertEqual((b.object["extra"] as? NSNumber)?.int64Value, 9_007_199_254_740_993)

        left["extra"] = NSNumber(value: 0.5)
        let c = try store.makeRow(left, pageCount: 1)
        right["extra"] = NSNumber(value: Double(0.5).nextUp)
        let d = try store.makeRow(right, pageCount: 1, previous: c)
        XCTAssertFalse(c === d)
        left["extra"] = NSNumber(value: -Double.zero)
        let zero = try store.makeRow(left, pageCount: 1)
        right["extra"] = NSNumber(value: Double.zero)
        let fullBefore = store.fullPreparationCount
        _ = try store.makeRow(right, pageCount: 1, previous: zero)
        XCTAssertEqual(store.fullPreparationCount, fullBefore + 1,
            "A signed-zero difference must use existing full preparation, regardless of its encoded dedup result")
        XCTAssertEqual(store.fastReuseCount, 0)
    }

    func testFoundationDecimalUsesTheSameFaithfulNormalizationAsStoredValues() throws {
        let value = 2.0 / 12_345.0
        var direct = Self.object(); direct["extra"] = NSNumber(value: value)
        let store = NativePDFDrawingSnapshotStore()
        let first = try store.makeRow(direct, pageCount: 1)
        var decimal = Self.object(); decimal["extra"] = NSDecimalNumber(string: String(value))
        let next = try store.makeRow(decimal, pageCount: 1, previous: first)
        XCTAssertTrue(next === first)
        XCTAssertEqual((next.object["extra"] as? NSNumber)?.doubleValue.bitPattern, value.bitPattern)
        XCTAssertEqual(store.fastReuseCount, 1)
        XCTAssertEqual(store.fullPreparationCount, 1)
    }

    func testUnsupportedAndNonFiniteValuesStillFailExistingValidationAtomically() throws {
        let store = NativePDFDrawingSnapshotStore()
        var good = Self.object(); good["extra"] = NSNull()
        try store.apply(["drawings": [good]], pageCount: 1)
        let first = try XCTUnwrap(store.orderedRows.first)
        let unsupported: [Any] = [Date(timeIntervalSince1970: 1), NSNumber(value: Double.nan), NSNumber(value: Double.infinity)]
        for invalid in unsupported {
            var bad = good; bad["extra"] = invalid
            XCTAssertThrowsError(try store.apply(["drawings": [bad]], pageCount: 1))
            XCTAssertTrue(store.orderedRows.first === first)
            XCTAssertEqual(store.order, ["row-0"])
            XCTAssertTrue(first.object["extra"] is NSNull)
        }
        XCTAssertEqual(store.fastReuseCount, 0)
        XCTAssertEqual(store.fullPreparationCount, 4)
    }

    /// Timing output is descriptive and belongs to the host running this test.
    /// No physical Pencil or universal millisecond threshold is inferred.
    func testPublicTwoHundredByNinetySixAvoidsRepeatedFreezeAndEncoding() throws {
        let store = NativePDFDrawingSnapshotStore()
        let initial = (0..<200).map { Self.object(index: $0, pointCount: 96) }
        let freshContainers = (0..<200).map { Self.object(index: $0, pointCount: 96) }
        let start = CFAbsoluteTimeGetCurrent()
        try store.apply(["drawings": initial], pageCount: 1)
        let firstMS = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        let original = store.orderedRows
        var reuseMS: [Double] = []
        for _ in 0..<5 {
            let began = CFAbsoluteTimeGetCurrent()
            try store.apply(["drawings": freshContainers], pageCount: 1)
            reuseMS.append((CFAbsoluteTimeGetCurrent() - began) * 1_000)
            XCTAssertTrue(zip(store.orderedRows, original).allSatisfy { $0 === $1 })
        }
        XCTAssertEqual(store.fullPreparationCount, 200)
        XCTAssertEqual(store.fastReuseCount, 1_000)
        XCTAssertEqual(store.replacementCount, 200)
        print("[STORE_FAST_REUSE] publicRows=200 pointsPerRow=96 firstMS=\(firstMS) repeatedMS=\(reuseMS) fullPreparation=\(store.fullPreparationCount) fastReuse=\(store.fastReuseCount)")
    }

    private static func firstPoint(_ row: NativePDFDrawingSnapshotStore.Row) throws -> [String: Any] {
        let data = try XCTUnwrap(row.object["data"] as? [String: Any])
        let points = try XCTUnwrap(data["points"] as? [[String: Any]])
        return try XCTUnwrap(points.first)
    }
    private static func object(index: Int = 0, pointCount: Int = 2) -> [String: Any] {
        var points: [[String: Any]] = []
        for sample in 0..<pointCount {
            let fraction = Double(sample) / Double(max(1, pointCount - 1))
            let x = 0.05 + fraction * 0.9
            let y = 0.1 + Double(index % 20) * 0.035 + sin(fraction * 3) * 0.01
            let pressure = 0.2 + fraction * 0.7
            let time = Double(sample * 4)
            points.append(["x": x, "y": y, "p": pressure, "t": time])
        }
        let data: [String: Any] = ["inkVersion": 4, "points": points]
        let style: [String: Any] = ["color": "ink", "width": 0.003, "opacity": 1.0]
        return ["id": "row-\(index)", "page": 1, "kind": "ink", "data": data,
                "style": style, "createdAt": "public-fixture", "updatedAt": "public-fixture"]
    }
}
