import XCTest
import zlib
@testable import Bandal

/// Sync rules the shared fixtures do not cover yet: parser boundaries, the desktop
/// PR #4 proposals, naming rules and the SyncAdapter's clamping.
final class SyncFormatTests: XCTestCase {
    private let course = "c0000000-0000-4000-8000-000000000001", doc = "d0000000-0000-4000-8000-000000000001"
    private let deviceA = "aaaaaaaa-0000-4000-8000-000000000001", deviceB = "bbbbbbbb-0000-4000-8000-000000000002"
    private let t0: Int64 = 1_793_318_400_000

    func testJSONReadsLikeJavaScriptParse() {
        func parse(_ bytes: [UInt8]) -> Any? { try? SyncJSON.parse(Data(bytes)) }
        func parse(_ text: String) -> Any? { parse(Array(text.utf8)) }
        XCTAssertEqual((parse(#"{"a":1,"a":2}"#) as? [String: Any])?["a"] as? Double, 2)
        XCTAssertNil(parse([0xEF, 0xBB, 0xBF] + Array("[1]".utf8)))
        XCTAssertNil(parse(Array("[1]".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        for text in ["[1,]", #"{"a":1,}"#, "[01]", "[1.]", "[1e999]", "[NaN]", "[1]\u{A0}", "[\"a\tb\"]"] { XCTAssertNil(parse(text), text) }
        // Proposed on desktop PR #4 (item 3): invalid UTF-8, unpaired surrogates and deep nesting are unreadable.
        XCTAssertNil(parse([0x5B, 0x22, 0xFF, 0x22, 0x5D]))
        XCTAssertNil(parse([0x5B, 0x22, 0xED, 0xA0, 0x80, 0x22, 0x5D]))
        XCTAssertNil(parse(#"["\ud800"]"#))
        XCTAssertNil(parse(#"["\udc00\ud800"]"#))
        XCTAssertEqual((parse(#"["😀é\/"]"#) as? [Any])?.first as? String, "😀é/")
        XCTAssertNotNil(parse(String(repeating: "[", count: 64) + String(repeating: "]", count: 64)))
        XCTAssertNil(parse(String(repeating: "[", count: 65) + String(repeating: "]", count: 65)))
        let values = parse("[-0, 3.0, 1E+2, 0.1, 9007199254740993, true]") as? [Any]
        XCTAssertEqual(values?.prefix(5).map { ($0 as! NSNumber).doubleValue }, [0, 3, 100, 0.1, 9_007_199_254_740_992])
        XCTAssertEqual((values?.last as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true)
    }

    func testOnlySpecPathsAreRead() {
        let sha = String(repeating: "a", count: 64)
        let root = SyncFormat.readRoot([
            ("log/\(deviceA.uppercased())/00000001.json", Data("[]".utf8)),
            ("log/\(deviceA)/0000001.json", Data("[]".utf8)),
            ("log/\(deviceA)/٠٠٠٠٠٠٠١.json", Data("[]".utf8)),
            ("ink/\(doc)/0/\(deviceA)-00000001.json.gz", Data()),
            ("ink/\(doc)/01/\(deviceA)-00000001.json.gz", Data()),
            ("assets/\(sha).PNG", Data()),
            ("notes/\(doc)/.x.md.icloud", Data()),
            ("ink/\(doc)/100001/\(deviceA)-00000001.json.gz", Data()),
            ("notes/\(doc)/.\(deviceA)-00000002.md.icloud", Data()),
            ("log/\(deviceA)/00000002.json", Data([0xEF, 0xBB, 0xBF] + Array("[]".utf8))),
        ])
        XCTAssertEqual(root.ignored.count, 7)
        XCTAssertEqual(root.errors, ["ink/\(doc)/100001/\(deviceA)-00000001.json.gz", "log/\(deviceA)/00000002.json"])
        XCTAssertEqual(root.pending, ["notes/\(doc)/\(deviceA)-00000002.md"])
        XCTAssertTrue(root.files.isEmpty)
        XCTAssertEqual(SyncFormat.placeholderTarget("a/.b/.c.icloud"), "a/.b/c")
        XCTAssertEqual(SyncFormat.placeholderTarget(".a/b.json.icloud"), "a/b.json")
        XCTAssertNil(SyncFormat.placeholderTarget("a/..icloud"))
    }

    func testOneBadEventIsDroppedAlone() throws {
        let file = try log(deviceA, seq: 1, [
            ["t": t0, "op": "course.upsert", "id": course, "fields": ["name": "물리", "sort": 0]],
            ["t": SyncFormat.maxStamp, "op": "course.upsert", "id": course, "fields": ["name": "2100년"]],
            ["t": t0, "op": "course.upsert", "id": course.uppercased(), "fields": ["name": "대문자"]],
            ["t": t0, "op": "course.upsert", "id": course, "fields": ["archived": 1]],
            ["t": t0, "op": "doc.upsert", "id": doc, "fields": ["name": "a/b.pdf"]],
            ["t": t0, "op": "doc.upsert", "id": doc, "fields": ["rel_path": "../밖"]],
            ["t": t0, "op": "course.pin", "id": course],
        ])
        guard case .log(_, _, let kept, let dropped) = file.content else { return XCTFail("not a log") }
        XCTAssertEqual(kept.map(\.index), [0])
        XCTAssertEqual(dropped, 5)
    }

    func testInkGzipReadsLikeNode() throws {
        let tombstone = #"{"id":"e0000000-0000-4000-8000-000000000001","page":1,"t":1793318400000,"del":true}"#
        let whole = try gzip("[\(tombstone)]")
        func count(_ bytes: Data) -> Int? {
            guard case .ink(_, _, _, let objects, _)? = (try? SyncFormat.parse(path: "ink/\(doc)/1/\(deviceA)-00000001.json.gz", bytes: bytes))?.content else { return nil }
            return objects.count
        }
        XCTAssertEqual(count(whole), 1)
        XCTAssertEqual(count(try gzip("[\(tombstone),") + gzip("\(tombstone)]")), 2)
        XCTAssertEqual(count(whole + Data([0, 1, 2])), 1)
        XCTAssertNil(count(whole + Data("xyz".utf8)))
        XCTAssertNil(count(whole.dropLast(4)))
        XCTAssertNil(count(Data()))
    }

    /// Desktop PR #4 item 8 (proposal): a repeated (t, device_id) goes to the later write.
    func testSameStampGoesToTheLaterWrite() throws {
        let older = try log(deviceA, seq: 1, [["t": t0, "op": "course.upsert", "id": course, "fields": ["name": "앞", "sort": 0]]])
        let newer = try log(deviceA, seq: 2, [["t": t0, "op": "course.upsert", "id": course, "fields": ["name": "뒤"]],
                                               ["t": t0, "op": "course.upsert", "id": course, "fields": ["name": "마지막"]]])
        for files in [[try root(), older, newer], [try root(), newer, older]] {
            XCTAssertEqual(SyncMerge.merge(files).courses[course]?.text("name"), "마지막")
        }
    }

    func testPathCollisionAndConflictCopyNames() throws {
        let other = "d0000000-0000-4000-8000-000000000009", h0 = String(repeating: "0", count: 64)
        let h1 = String(repeating: "1", count: 64), h2 = String(repeating: "2", count: 64)
        let place: [String: Any] = ["course_id": course, "type": "md", "rel_path": "노트", "name": "강의.md"]
        let state = SyncMerge.merge([
            try root(),
            try log(deviceA, seq: 1, [["t": t0, "op": "course.upsert", "id": course, "fields": ["name": "물리", "sort": 0]],
                                      ["t": t0 + 1, "op": "doc.upsert", "id": doc, "fields": place.merging(["md_hash": h0, "md_base": NSNull()]) { $1 }],
                                      ["t": t0 + 2, "op": "doc.upsert", "id": other, "fields": place.merging(["md_hash": h0, "md_base": NSNull()]) { $1 }],
                                      ["t": t0 + 3, "op": "doc.upsert", "id": doc, "fields": ["md_hash": h1, "md_base": h0]]]),
            try log(deviceB, seq: 1, [["t": t0 + 4, "op": "doc.upsert", "id": doc, "fields": ["md_hash": h2, "md_base": h0]]]),
        ])
        XCTAssertEqual(state.renames.map(\.id), [other])
        XCTAssertEqual(state.renames.first?.name, "강의 (d000).md")
        XCTAssertEqual(state.notes[doc]?.hash, h2)
        // No devices/ file yet: the copy names the writer by the first 8 characters of its id.
        XCTAssertEqual(state.conflictCopies.map(\.name), ["강의 (충돌 사본 aaaaaaaa).md"])
        XCTAssertEqual(state.conflictCopies.first?.id, SyncMerge.uuidV5("\(doc):\(h1)"))
        XCTAssertEqual(SyncMerge.splitName(".md").stem, ".md")
        XCTAssertEqual(SyncMerge.splitName("a.b.pdf").ext, ".pdf")
    }

    func testWaitingListsWhatHasNotArrived() throws {
        let sha = String(repeating: "b", count: 64), stroke = "e0000000-0000-4000-8000-000000000002"
        let image: [String: Any] = ["id": stroke, "kind": "image", "page": 1, "t": t0, "created": t0,
                                    "data": ["box": ["x": 0, "y": 0, "width": 0.5, "height": 0.5], "image": ["sha256": sha, "ext": "png"]],
                                    "style": ["color": "ink", "width": 0.002, "opacity": 1]]
        let state = SyncMerge.merge([
            try root(),
            try log(deviceA, seq: 1, [["t": t0, "op": "doc.upsert", "id": doc, "fields": ["course_id": course, "type": "pdf", "rel_path": "", "name": "1주차.pdf", "pdf_sha256": sha]]]),
            try XCTUnwrap(SyncFormat.parse(path: "ink/\(doc)/1/\(deviceA)-00000002.json.gz", bytes: gzip(String(decoding: JSONSerialization.data(withJSONObject: [image]), as: UTF8.self)))),
        ])
        XCTAssertEqual(state.waitingDocs, [doc])
        XCTAssertEqual(state.waitingInk, [stroke])
    }

    func testAdapterRoundsMapsAndClamps() throws {
        XCTAssertEqual(SyncAdapter.round(0.000155, digits: 5), 0.00016)
        XCTAssertEqual(SyncAdapter.round(-0.000155, digits: 5), -0.00016)
        XCTAssertEqual(SyncAdapter.round(0.61249, digits: 3), 0.612)
        XCTAssertEqual(SyncAdapter.round(-1e-7, digits: 5).sign, .plus)
        XCTAssertEqual(SyncAdapter.specCourseColor("purple"), "violet")
        XCTAssertEqual(SyncAdapter.specCourseColor("yellow"), "gold")
        XCTAssertEqual(SyncAdapter.specCourseColor("red"), "red")
        XCTAssertEqual(SyncAdapter.localCourseColor("violet"), "purple")
        XCTAssertEqual(SyncAdapter.localCourseColor("gold"), "yellow")
        XCTAssertEqual(SyncAdapter.courseFields(name: "물리", sortOrder: 2, color: "purple", archived: false)["color"] as? String, "violet")
        let location = SyncAdapter.docLocation("1주차/강의.pdf".decomposedStringWithCanonicalMapping)
        XCTAssertEqual(Array(location.relPath.unicodeScalars), Array("1주차".unicodeScalars))
        XCTAssertEqual(location.name, "강의.pdf")
        XCTAssertEqual(SyncAdapter.docLocation("a.pdf").relPath, "")
        XCTAssertEqual(SyncAdapter.iso(t0 + 1), "2026-10-30T00:00:00.001Z")
        XCTAssertEqual(try SyncAdapter.milliseconds("2026-10-30T00:00:00.001Z"), t0 + 1)

        let stroke = "e0000000-0000-4000-8000-000000000001"
        func object(_ kind: String, _ data: [String: Any]) -> SyncFormat.InkObject {
            SyncFormat.InkObject(id: stroke, page: 1, t: t0 + 5, index: 0, value: ["id": stroke, "kind": kind, "page": 1, "t": t0 + 5, "created": t0,
                                                                                  "data": data, "style": ["color": "blue", "width": 0.003, "opacity": 1]])
        }
        let ink = object("ink", ["inkVersion": 5, "points": [["x": 1.02, "y": -0.1, "p": 0.5, "t": 4, "tiltX": 120]]])
        guard case let .upsert(_, _, data, _, createdAt, updatedAt) = try SyncAdapter.importInkObject(ink) else { return XCTFail("not imported") }
        let point = (data["points"] as? [[String: Any]])?.first
        XCTAssertEqual(point?["x"] as? Double, 1)
        XCTAssertEqual(point?["y"] as? Double, 0)
        XCTAssertNil(point?["tiltX"])
        XCTAssertEqual([createdAt, updatedAt], ["2026-10-30T00:00:00.000Z", "2026-10-30T00:00:00.005Z"])
        guard case .hold(.unknownKind) = try SyncAdapter.importInkObject(object("clip", [:])) else { return XCTFail("clip imported") }
        let picture = object("image", ["box": ["x": 0.9, "y": 0, "width": 0.5, "height": 0.1], "image": ["sha256": String(repeating: "c", count: 64), "ext": "png"]])
        guard case .hold(.needsAsset) = try SyncAdapter.importInkObject(picture) else { return XCTFail("image without its file imported") }
        guard case let .upsert(_, _, pictureData, _, _, _) = try SyncAdapter.importInkObject(picture, imagePath: { _ in "assets/x.png" }) else { return XCTFail("image not imported") }
        XCTAssertEqual((pictureData["box"] as? [String: Any])?["width"] as? Double ?? 0, 0.1, accuracy: 1e-12)
        XCTAssertEqual((pictureData["image"] as? [String: Any])?["label"] as? String, "cccccccc.png")
    }

    // MARK: Helpers

    private func root() throws -> SyncFormat.File {
        try XCTUnwrap(SyncFormat.parse(path: "bandal.json", bytes: Data(#"{"format":2}"#.utf8)))
    }

    private func log(_ device: String, seq: Int, _ events: [[String: Any]]) throws -> SyncFormat.File {
        let path = "log/\(device)/" + String(format: "%08d", seq) + ".json"
        return try XCTUnwrap(SyncFormat.parse(path: path, bytes: JSONSerialization.data(withJSONObject: events)))
    }

    private func gzip(_ text: String) throws -> Data {
        var stream = z_stream(), input = Array(text.utf8)
        XCTAssertEqual(deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 32)
        let status = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { target in
                stream.next_in = source.baseAddress; stream.avail_in = uInt(source.count)
                stream.next_out = target.baseAddress; stream.avail_out = uInt(target.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        return Data(output.prefix(output.count - Int(stream.avail_out)))
    }
}
