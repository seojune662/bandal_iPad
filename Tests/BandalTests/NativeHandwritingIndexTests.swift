import XCTest
import PDFKit
@testable import Bandal

final class NativeHandwritingIndexTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var courseID = ""
    private var path = ""
    private var events: [[String: Any]] = []
    private let lock = NSLock()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("handwriting-\(UUID().uuidString)")
        runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        runtime.handwritingTiming = (debounce: 0.2, launch: 0.2, idle: 0.2)
        runtime.onEmit = { [weak self] channel, payload in
            guard channel == "handwriting:progress", let self, let value = payload as? [String: Any] else { return }
            self.lock.lock(); self.events.append(value); self.lock.unlock()
        }
        try await runtime.start()
        let course = try await runtime.invoke("courses:create", request: ["name": "손글씨", "color": "blue"]) as! [String: Any]
        courseID = course["id"] as! String
        let note = try await runtime.invoke("pdfNotes:create", request: ["courseId": courseID, "title": "필기", "paper": "blank", "orientation": "portrait"]) as! [String: Any]
        path = note["relPath"] as! String
    }
    override func tearDown() async throws { runtime = nil; try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, page: Int = 1, y: CGFloat = 200, color: String = "ink") async throws {
        let size = CGSize(width: 595, height: 842)
        for stroke in NativeHandwritingFixture.strokes(text, at: CGPoint(x: 60, y: y), fontSize: 44, pageSize: size, color: color) {
            _ = try await runtime.invoke("drawings:create", request: stroke.merging(["courseId": courseID, "relPath": path, "page": page, "kind": "ink"]) { _, new in new })
        }
    }
    private func status() async throws -> [String: Any] { try await runtime.invoke("handwriting:status") as! [String: Any] }
    /// Recognition has caught up with every written page. The first Vision request after an install loads its models, which can take a minute on a simulator.
    private func settle(timeout: TimeInterval = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await Task.sleep(for: .milliseconds(400))
        while Date() < deadline {
            let value = try await status()
            if value["active"] as? Bool == false, value["done"] as? Int == value["total"] as? Int { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("handwriting index did not settle")
    }
    private func lines(_ match: String? = nil) async throws -> [[String: Any]] {
        try await runtime.withSyncStorage { context, _ in
            if let match { return try context.query("SELECT * FROM handwriting_text WHERE handwriting_text MATCH ? ORDER BY page_index,line_index", ["\"" + match + "\""]) }
            return try context.query("SELECT * FROM handwriting_text ORDER BY page_index,line_index")
        }
    }

    func testInkIsRenderedDarkOnWhiteAtTwiceThePageSize() throws {
        let size = CGSize(width: 595, height: 842)
        let rows = NativeHandwritingFixture.strokes("가", at: CGPoint(x: 100, y: 300), fontSize: 120, pageSize: size, color: "yellow").map { $0.merging(["kind": "ink", "id": UUID().uuidString]) { _, new in new } }
        let image = try XCTUnwrap(NativeHandwritingRecognizer.image(rows: rows, pageSize: size).cgImage)
        XCTAssertEqual(image.width, 1190); XCTAssertEqual(image.height, 1684)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height)
        XCTAssertEqual(pixels[0], 255, "paper is white")
        // A yellow pen still reads as dark ink.
        XCTAssertLessThan(pixels.min() ?? 255, 60)
    }

    func testKoreanAndEnglishInkLinesAreReadSeparately() throws {
        let size = CGSize(width: 595, height: 842)
        let rows = (NativeHandwritingFixture.strokes("엔트로피 증가 법칙", at: CGPoint(x: 70, y: 150), fontSize: 46, pageSize: size)
            + NativeHandwritingFixture.strokes("Carnot cycle", at: CGPoint(x: 70, y: 250), fontSize: 46, pageSize: size, color: "blue"))
            .map { $0.merging(["kind": "ink", "id": UUID().uuidString]) { _, new in new } }
        let lines = try NativeHandwritingRecognizer.lines(rows: rows, pageSize: size)
        XCTAssertEqual(lines.count, 2, "\(lines)")
        XCTAssertTrue(lines.first?.text.contains("엔트로피") == true, "\(lines)")
        XCTAssertTrue(lines.last?.text.localizedCaseInsensitiveContains("carnot") == true, "\(lines)")
        XCTAssertLessThan(lines.first?.box.minY ?? 1, lines.last?.box.minY ?? 0)
    }

    func testRecognisedLinesAreNormalisedFromTheTopLeft() throws {
        let size = CGSize(width: 1190, height: 1684)
        let image = UIGraphicsImageRenderer(size: size, format: { let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format }()).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ("Lecture notes 2026" as NSString).draw(at: CGPoint(x: 120, y: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }
        let lines = try NativeHandwritingRecognizer.recognize(try XCTUnwrap(image.cgImage))
        let line = try XCTUnwrap(lines.first)
        XCTAssertTrue(line.text.localizedCaseInsensitiveContains("lecture"), line.text)
        XCTAssertGreaterThanOrEqual(line.confidence, NativeHandwritingRecognizer.minimumConfidence)
        XCTAssertEqual(line.box.minX, 120 / 1190, accuracy: 0.03)
        XCTAssertEqual(line.box.minY, 150 / 1684, accuracy: 0.03)
    }

    func testWrittenPagesAreIndexedAfterThePenLiftsAndOnlyChangedPagesAgain() async throws {
        try await write("Thermodynamics")
        try await settle()
        let first = try await lines()
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue((first[0]["text"] as? String ?? "").localizedCaseInsensitiveContains("thermo"), "\(first)")
        XCTAssertEqual(first[0]["page_index"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(first[0]["confidence"] as? Double ?? 0, 0.3)
        let box = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((first[0]["bbox"] as! String).utf8)) as? [Double])
        XCTAssertEqual(box.count, 4); XCTAssertEqual(box[1], 200 / 842, accuracy: 0.08)
        let stamp = first[0]["updated_at"] as? String
        // The trigram index answers a substring of three or more characters.
        let matched = try await lines("ermodyn")
        XCTAssertEqual(matched.count, 1)

        // A highlight on the page changes its drawings but not its ink: nothing is recognised again.
        _ = try await runtime.invoke("drawings:create", request: ["courseId": courseID, "relPath": path, "page": 1, "kind": "highlighter",
            "data": ["inkVersion": 5, "points": [["x": 0.1, "y": 0.5, "p": 0.5], ["x": 0.6, "y": 0.5, "p": 0.5]]], "style": ["color": "yellow", "width": 0.02, "opacity": 0.4]])
        try await settle()
        let afterHighlight = try await lines()
        XCTAssertEqual(afterHighlight.first?["updated_at"] as? String, stamp)
        let total = try await status()["total"] as? Int
        XCTAssertEqual(total, 1)
    }

    func testTrashingTheDocumentAndTurningTheSettingOffRemoveItsText() async throws {
        try await write("Entropy")
        try await settle()
        let indexed = try await lines()
        XCTAssertFalse(indexed.isEmpty)
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": false])
        let cleared = try await lines()
        XCTAssertTrue(cleared.isEmpty)
        let off = try await status()
        XCTAssertEqual(off["enabled"] as? Bool, false)
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": true])
        try await settle()
        let again = try await lines()
        XCTAssertFalse(again.isEmpty)
        _ = try await runtime.invoke("materials:delete", request: ["courseId": courseID, "relPath": path])
        let gone = try await lines()
        XCTAssertTrue(gone.isEmpty)
        // The trashed note keeps its ink rows, but it is no longer a page to index.
        try await Task.sleep(for: .milliseconds(300))
        try await settle()
        let total = try await status()["total"] as? Int
        XCTAssertEqual(total, 0)
    }

    func testProgressCountsPagesWhileExistingNotesAreRead() async throws {
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": false])
        try await write("Alpha")
        let revision = try await runtime.invokePrivate("nativePDF:binding", request: ["courseId": courseID, "relPath": path]) as! [String: Any]
        _ = try await runtime.invoke("pdf:restructure", request: ["courseId": courseID, "relPath": path, "expectedRevision": revision["documentRevision"]!, "operationId": UUID().uuidString, "pages": [["source": 1], ["source": NSNull()]]])
        try await write("Gamma", page: 2)
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": true])
        try await settle()
        lock.lock(); let seen = events; lock.unlock()
        XCTAssertTrue(seen.contains { $0["active"] as? Bool == true && $0["total"] as? Int == 2 }, "\(seen)")
        XCTAssertEqual(seen.last?["done"] as? Int, 2)
        XCTAssertEqual(seen.last?["active"] as? Bool, false)
        let pages = try await lines().compactMap { $0["page_index"] as? Int }
        XCTAssertEqual(Set(pages), [0, 1])
    }
}
