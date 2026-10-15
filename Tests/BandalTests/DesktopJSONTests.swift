import XCTest
import JavaScriptCore
import CoreGraphics
@testable import Bandal

@MainActor
final class DesktopJSONTests: XCTestCase {
    func testMeasuredDoubleBitsSurviveJournalHostJavaScriptAndSnapshotRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("numeric-bridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let normalized = [0.0, Double.leastNonzeroMagnitude, Double.leastNormalMagnitude,
                          Double.leastNormalMagnitude.nextDown, 0.5.nextDown, 0.5, 0.5.nextUp,
                          1.0.nextDown, 1.0, 17.0 / 12345] + (1...1000).map { Double($0) / 12345 }
        var points = normalized.map { NativePDFPoint(x: $0, y: $0, p: $0, t: $0, tiltX: $0, tiltY: $0) }
        let optionalLimits = [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                              Double.leastNonzeroMagnitude, -Double.leastNonzeroMagnitude,
                              Double.pi, -Double.pi, 1e-200, 1e200, 9007199254740992.0.nextUp]
        points += optionalLimits.map { .init(x: 0.4, y: 0.6, p: 0.5, t: $0, tiltX: $0, tiltY: $0) }
        points.append(.init(x: 0.2, y: 0.3, p: 0.4))
        let input = stroke(points)
        let journal = try NativePDFJournal(root: root)
        try journal.checkpoint(input, documentRevision: "fixture")
        try journal.append(input, documentRevision: "fixture")
        let recovered = try XCTUnwrap(journal.pending(courseID: "fixture", relativePath: "paper.pdf").first?.input)
        assertBits(recovered, input)
        var payload = try NativePDFHost.json(recovered)
        assertRawBits(payload, input)
        let store = NativePDFDrawingSnapshotStore()
        func checkRow(_ payload: [String: Any]) throws {
            var row = payload; row["id"] = "canonical"
            try store.apply(["drawings": [row]], pageCount: 1)
            let object = try XCTUnwrap(store.row(id: "canonical")?.object)
            assertRawBits(object, input)
            assertBits(try JSONDecoder().decode(NativePDFStrokeInput.self,
                from: JSONSerialization.data(withJSONObject: object)), input)
        }
        try checkRow(payload)
        let context = try XCTUnwrap(JSContext())
        for _ in 0..<3 {
            context.setObject(payload, forKeyedSubscript: "payload" as NSString)
            // The backend completion is a JSON string, then the decoded
            // Foundation tree crosses into WebKit again before snapshotting.
            let encoded = try XCTUnwrap(context.evaluateScript("JSON.stringify(payload)")?.toString())
            payload = try XCTUnwrap(DesktopJSON.decode(Data(encoded.utf8)) as? [String: Any])
            assertRawBits(payload, input)
            context.setObject(payload, forKeyedSubscript: "payload" as NSString)
            payload = try XCTUnwrap(context.evaluateScript("JSON.parse(JSON.stringify(payload))")?.toDictionary() as? [String: Any])
            XCTAssertNil(context.exception)
            try checkRow(payload)
        }
    }

    func testPreparedPathUsesTheSameMeasuredValuesAsTypedInput() throws {
        let input = stroke([
            .init(x: 1.0 / 12345, y: 0.2, p: 1.0 / 12345, t: 0),
            .init(x: 0.3, y: 0.4, p: 2.0 / 12345, t: 8.0.nextUp),
            .init(x: 0.6, y: 0.7, p: 17.0 / 12345, t: 16),
            .init(x: 0.9, y: 0.8, p: 0.5.nextUp, t: 24)
        ])
        let cache = NativePDFInkPathCache()
        let expected = try XCTUnwrap(cache.prepare(input, aspect: 842.0 / 595))
        let store = NativePDFDrawingSnapshotStore()
        var payload = try NativePDFHost.json(input); payload["id"] = "canonical"
        // Include the actual generic JSON reader used for backend completions.
        let parsed = try XCTUnwrap(DesktopJSON.decode(JSONSerialization.data(withJSONObject: payload)) as? [String: Any])
        try store.apply(["drawings": [parsed]], pageCount: 1)
        let row = try XCTUnwrap(store.row(id: "canonical"))
        let actual = try XCTUnwrap(row.prepared(aspect: 842.0 / 595)["_nativeInk"] as? NativePDFPreparedInk)
        XCTAssertEqual(pathBits(actual.path), pathBits(expected.path))
        assertRawBits(row.object, input)
    }

    func testImmutableCopyDetachesContainersAndPreservesJSONTypes() throws {
        let style = NSMutableDictionary(dictionary: ["width": 2.0 / 12345, "enabled": true])
        let array = NSMutableArray(array: [style, NSNull()])
        let source = NSMutableDictionary(dictionary: ["array": array, "integer": NSNumber(value: Int64.max)])
        let frozen = try XCTUnwrap(DesktopJSON.immutableCopy(source) as? [String: Any])
        style["width"] = 0.9; style["enabled"] = false; array.add("later"); source["integer"] = 0
        let values = try XCTUnwrap(frozen["array"] as? [Any])
        let object = try XCTUnwrap(values.first as? [String: Any])
        XCTAssertEqual(values.count, 2); XCTAssertTrue(values[1] is NSNull)
        XCTAssertEqual((object["width"] as? NSNumber)?.doubleValue.bitPattern, (2.0 / 12345).bitPattern)
        let boolean = try XCTUnwrap(object["enabled"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(boolean), CFBooleanGetTypeID()); XCTAssertTrue(boolean.boolValue)
        let integer = try XCTUnwrap(frozen["integer"] as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(integer), CFBooleanGetTypeID()); XCTAssertEqual(integer.int64Value, Int64.max)
        let decoded = try XCTUnwrap(DesktopJSON.decode(Data("{\"boolean\":true,\"integer\":1,\"null\":null}".utf8)) as? [String: Any])
        XCTAssertEqual(CFGetTypeID(try XCTUnwrap(decoded["boolean"] as? NSNumber)), CFBooleanGetTypeID())
        XCTAssertNotEqual(CFGetTypeID(try XCTUnwrap(decoded["integer"] as? NSNumber)), CFBooleanGetTypeID())
        XCTAssertTrue(decoded["null"] is NSNull)
        for value: Any in [Double.nan, Double.infinity, -Double.infinity, Date()] {
            XCTAssertThrowsError(try DesktopJSON.immutableCopy(["bad": value]))
        }
        XCTAssertThrowsError(try DesktopJSON.decode(Data("{\"bad\":NaN}".utf8)))
    }

    func testNegativeZeroIsPreservedNativelyAndStandardJSONStringifyBoundaryIsExplicit() throws {
        // JSON.stringify intentionally emits 0 for -0. No numeric-only JSON
        // bridge can promise signed-zero bit preservation across that stage.
        let input = stroke([.init(x: -0.0, y: -0.0, p: -0.0, t: -0.0, tiltX: -0.0, tiltY: -0.0)])
        let host = try NativePDFHost.json(input)
        assertRawBits(host, input)
        let store = NativePDFDrawingSnapshotStore()
        var row = host; row["id"] = "negative-zero"
        try store.apply(["drawings": [row]], pageCount: 1)
        let object = try XCTUnwrap(store.row(id: "negative-zero")?.object)
        assertRawBits(object, input)
        assertBits(try JSONDecoder().decode(NativePDFStrokeInput.self, from: JSONSerialization.data(withJSONObject: object)), input)
        let context = try XCTUnwrap(JSContext())
        context.setObject(host, forKeyedSubscript: "payload" as NSString)
        XCTAssertTrue(context.evaluateScript("Object.is(payload.data.points[0].p, -0)")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("JSON.stringify(payload.data.points[0].p)")?.toString(), "0")
    }

    private func stroke(_ points: [NativePDFPoint]) -> NativePDFStrokeInput {
        .init(courseId: "fixture", relPath: "paper.pdf", page: 1, kind: "ink", data: .init(points: points),
              style: .init(color: "blue", width: 2.0 / 12345, opacity: 17.0 / 12345),
              clientMutationId: UUID().uuidString, documentRevision: "fixture")
    }
    private func assertBits(_ actual: NativePDFStrokeInput, _ expected: NativePDFStrokeInput,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.data.points.count, expected.data.points.count, file: file, line: line)
        for (index, pair) in zip(actual.data.points, expected.data.points).enumerated() {
            let a = [pair.0.x, pair.0.y, pair.0.p, pair.0.t, pair.0.tiltX, pair.0.tiltY]
            let b = [pair.1.x, pair.1.y, pair.1.p, pair.1.t, pair.1.tiltX, pair.1.tiltY]
            XCTAssertEqual(a.map { $0?.bitPattern }, b.map { $0?.bitPattern }, "point \(index)", file: file, line: line)
        }
        XCTAssertEqual(actual.style.width.bitPattern, expected.style.width.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.style.opacity.bitPattern, expected.style.opacity.bitPattern, file: file, line: line)
    }
    private func assertRawBits(_ object: [String: Any], _ expected: NativePDFStrokeInput,
                               file: StaticString = #filePath, line: UInt = #line) {
        let points = (object["data"] as? [String: Any])?["points"] as? [[String: Any]] ?? []
        XCTAssertEqual(points.count, expected.data.points.count, file: file, line: line)
        for (index, pair) in zip(points, expected.data.points).enumerated() {
            let values: [Double?] = [pair.1.x, pair.1.y, pair.1.p, pair.1.t, pair.1.tiltX, pair.1.tiltY]
            for (key, value) in zip(["x", "y", "p", "t", "tiltX", "tiltY"], values) {
                XCTAssertEqual((pair.0[key] as? NSNumber)?.doubleValue.bitPattern, value?.bitPattern,
                               "point \(index).\(key)", file: file, line: line)
            }
        }
        let style = object["style"] as? [String: Any] ?? [:]
        XCTAssertEqual((style["width"] as? NSNumber)?.doubleValue.bitPattern, expected.style.width.bitPattern, file: file, line: line)
        XCTAssertEqual((style["opacity"] as? NSNumber)?.doubleValue.bitPattern, expected.style.opacity.bitPattern, file: file, line: line)
    }
    private func pathBits(_ path: CGPath) -> [UInt64] {
        var result: [UInt64] = []
        path.applyWithBlock { entry in
            let element = entry.pointee
            result.append(UInt64(element.type.rawValue))
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: count = 0
            }
            for index in 0..<count {
                result += [Double(element.points[index].x).bitPattern, Double(element.points[index].y).bitPattern]
            }
        }
        return result
    }
}
