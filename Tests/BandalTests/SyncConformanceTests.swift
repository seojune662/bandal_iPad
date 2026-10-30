import XCTest
@testable import Bandal

/// Spec v2.1 conformance against the desktop's `sync-fixtures/` (pinned copy, see
/// `Tests/Fixtures/sync-fixtures/SOURCE`): every `root/` must parse and merge to its
/// `expected.json` exactly as the desktop's `tests/main/sync/conformance.test.ts` does.
final class SyncConformanceTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sync-fixtures")
    private static let names = ["01-basic", "02-same-id-both-edited", "03-delete-then-edit", "04-note-both-edited"]

    func testEveryFixtureFolderIsChecked() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.range(of: "^[0-9]{2}-", options: .regularExpression) != nil }
        XCTAssertEqual(folders.sorted(), Self.names)
    }

    func testRootsParseAndMergeToExpectedJSON() throws {
        for name in Self.names {
            let root = try Self.readRoot(name)
            var expected = try XCTUnwrap(SyncJSON.parse(Data(contentsOf: Self.fixtures.appendingPathComponent("\(name)/expected.json"))) as? [String: Any])
            XCTAssertEqual(expected.removeValue(forKey: "fixture") as? String, name)
            XCTAssertEqual(expected.removeValue(forKey: "spec") as? String, "2.1")
            let state = SyncMerge.merge(root.files)
            XCTAssertNil(state.blocked, name)
            var actual = Self.project(state)
            actual["ignored"] = root.ignored; actual["errors"] = root.errors
            Self.assertJSONEqual(actual, expected, name)
        }
    }

    /// M14, M15
    func testArrivalOrderAndRepeatedFilesDoNotChangeTheResult() throws {
        for name in Self.names {
            let files = try Self.readRoot(name).files, want = Self.project(SyncMerge.merge(files))
            for seed in 1...100 {
                let repeated = files + files.enumerated().filter { ($0.offset + seed) % 3 == 0 }.map(\.element)
                Self.assertJSONEqual(Self.project(SyncMerge.merge(Self.shuffled(repeated, seed: UInt32(seed)))), want, "\(name) seed \(seed)")
            }
        }
    }

    func testSyncAdapterRoundTripsEveryWinningDrawing() throws {
        for name in Self.names {
            for entry in SyncMerge.merge(try Self.readRoot(name).files).ink.values {
                let object = entry.object
                switch try SyncAdapter.importInkObject(object, imagePath: { "images/\($0.sha256).\($0.ext)" }) {
                case .delete(let deletedAt):
                    let row = SyncAdapter.DrawingRow(id: object.id, kind: "ink", page: object.page, dataJSON: "{}", styleJSON: "{}",
                                                     createdAt: deletedAt, updatedAt: deletedAt, deletedAt: deletedAt)
                    Self.assertJSONEqual(try XCTUnwrap(SyncAdapter.inkObject(row, t: object.t)), object.value, object.id)
                case let .upsert(kind, page, data, style, createdAt, updatedAt):
                    let row = SyncAdapter.DrawingRow(id: object.id, kind: kind, page: page,
                                                     dataJSON: try NativePDFRepositoryValidation.json(data), styleJSON: try NativePDFRepositoryValidation.json(style),
                                                     createdAt: createdAt, updatedAt: updatedAt, deletedAt: nil)
                    let image = ((object.value["data"] as? [String: Any])?["image"] as? [String: Any]).map {
                        SyncAdapter.AssetRef(sha256: $0["sha256"] as! String, ext: $0["ext"] as! String)
                    }
                    Self.assertJSONEqual(try XCTUnwrap(SyncAdapter.inkObject(row, t: object.t, image: image)), object.value, object.id)
                case .hold(let reason):
                    XCTFail("\(object.id) was not imported: \(reason)")
                }
            }
        }
    }

    /// R01: both renderers draw the same stroke width.
    func testV5DiameterFactorsMatchRenderFixture() throws {
        struct Case: Decodable { let points: [NativePDFPoint]; let width, aspect: Double; let highlighter: Bool; let expectedFactors: [Double] }
        struct Render: Decodable { let tolerance: Double; let cases: [Case] }
        let render = try JSONDecoder().decode(Render.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("render/v5-diameter.json")))
        XCTAssertFalse(render.cases.isEmpty)
        for sample in render.cases {
            let factors = NativePDFInkGeometryV5.widthFactors(points: sample.points, width: sample.width, aspect: sample.aspect, highlighter: sample.highlighter)
            XCTAssertEqual(factors.count, sample.expectedFactors.count)
            for (factor, expected) in zip(factors, sample.expectedFactors) { XCTAssertEqual(factor, expected, accuracy: render.tolerance) }
        }
    }

    // MARK: Helpers

    static func readRoot(_ name: String) throws -> SyncFormat.Root {
        let root = fixtures.appendingPathComponent("\(name)/root")
        let paths = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &directory) && !directory.boolValue
        }
        return SyncFormat.readRoot(try paths.map { ($0, try Data(contentsOf: root.appendingPathComponent($0))) })
    }

    /// The `expected.json` shape described in sync-fixtures/README.md.
    static func project(_ state: SyncMerge.State) -> [String: Any] {
        func pick(_ entity: SyncMerge.Entity, _ keys: [String]) -> [String: Any] {
            var result: [String: Any] = ["alive": entity.isAlive]
            for key in keys { if let register = entity.fields[key] { result[key] = register.value } }
            return result
        }
        func nullable(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }
        var ink: [String: [String: [String: Any]]] = [:]
        for (id, entry) in state.ink { ink[entry.doc, default: [:]][String(entry.object.page), default: [:]][id] = entry.object.value }
        return [
            "courses": state.courses.mapValues { pick($0, ["name", "sort", "color", "archived"]) },
            "docs": state.docs.mapValues { pick($0, ["course_id", "type", "name", "rel_path", "pdf_sha256", "md_hash"]) },
            "ink": ink,
            "notes": state.notes.mapValues { ["md_hash": $0.hash, "file": nullable($0.file)] },
            "conflict_copies": state.conflictCopies.map {
                ["id": $0.id, "of": $0.of, "course_id": $0.courseID, "rel_path": $0.relPath, "name": $0.name, "md_hash": $0.mdHash, "file": nullable($0.file)]
            },
        ]
    }

    /// Deterministic Fisher–Yates so a failing order can be replayed.
    static func shuffled<T>(_ items: [T], seed: UInt32) -> [T] {
        var result = items, state = seed
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            state = state &* 1_664_525 &+ 1_013_904_223
            result.swapAt(index, Int(state % UInt32(index + 1)))
        }
        return result
    }

    /// JSON value equality as the desktop's `toEqual` sees it: numbers by value (−0 ≠ 0),
    /// booleans never equal numbers, strings by UTF-16 code units.
    static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (a as NSNumber, b as NSNumber):
            let aIsBool = CFGetTypeID(a) == CFBooleanGetTypeID(), bIsBool = CFGetTypeID(b) == CFBooleanGetTypeID()
            guard aIsBool == bIsBool else { return false }
            return aIsBool ? a.boolValue == b.boolValue : a.doubleValue == b.doubleValue && a.doubleValue.sign == b.doubleValue.sign
        case let (a as String, b as String): return a.utf16.elementsEqual(b.utf16)
        case (is NSNull, is NSNull): return true
        case let (a as [Any], b as [Any]): return a.count == b.count && zip(a, b).allSatisfy(jsonEqual)
        case let (a as [String: Any], b as [String: Any]):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { jsonEqual(value, $0) } ?? false }
        default: return false
        }
    }

    static func assertJSONEqual(_ actual: Any, _ expected: Any, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard !jsonEqual(actual, expected) else { return }
        func text(_ value: Any) -> String {
            (try? NativePDFRepositoryValidation.json(value)) ?? "\(value)"
        }
        XCTFail("\(message)\nactual:   \(text(actual))\nexpected: \(text(expected))", file: file, line: line)
    }
}
