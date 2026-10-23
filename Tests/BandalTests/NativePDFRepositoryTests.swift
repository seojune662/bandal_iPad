import XCTest
import PDFKit
import UIKit
import CryptoKit
@testable import Bandal

@MainActor
final class NativePDFRepositoryTests: XCTestCase {
    func testReopenDecodeCacheSeesExternalSQLChangeWithUnchangedTimestampAndDeletion() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), identity = fixture.identity(path)
        let binding = try fixture.call("nativePDF:binding", identity) as! [String: Any]
        let original = try fixture.call("drawings:create", fixture.stroke(path, revision: binding["documentRevision"] as! String)) as! [String: Any]
        _ = try fixture.call("drawings:listForFile", identity)
        var data = try XCTUnwrap(original["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Any]])
        points[0]["x"] = 0.77; data["points"] = points
        let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        _ = try fixture.context.db.run("UPDATE pdf_drawings SET data_json=? WHERE id=?", params: [json, original["id"]!])
        let reread = try XCTUnwrap((try fixture.call("drawings:listForFile", identity) as? [[String: Any]])?.first)
        XCTAssertEqual(reread["updatedAt"] as? String, original["updatedAt"] as? String)
        XCTAssertEqual(((reread["data"] as? [String: Any])?["points"] as? [[String: Any]])?.first?["x"] as? Double, 0.77)
        _ = try fixture.context.db.run("UPDATE pdf_drawings SET deleted_at='external' WHERE id=?", params: [original["id"]!])
        XCTAssertTrue((try fixture.call("drawings:listForFile", identity) as! [[String: Any]]).isEmpty)
    }
    func testMovingDrawingToAnotherPagePersistsInSQLiteAndRestoresWithUndo() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), url = try fixture.context.materialURL(courseID: fixture.course, relativePath: path)
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.insert(try XCTUnwrap(document.page(at: 0)?.copy() as? PDFPage), at: 1)
        XCTAssertTrue(document.write(to: url))
        let binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let owner = NativePDFPersistence(courseID: fixture.course, relativePath: path,
            documentRevision: binding["documentRevision"] as! String,
            backend: { try fixture.call($0, $1) }, host: { _, _ in [:] })
        try await owner.createObjects([["page": 1, "kind": "rect",
            "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.2, "height": 0.2]],
            "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]])
        let original = try XCTUnwrap(owner.rows.first)
        var moved = original; moved["page"] = 2
        try await owner.updateObjects([moved], expected: [original])
        let reopened = try NativePDFRepository(context: fixture.context)
        let saved = try XCTUnwrap(try reopened.handle("drawings:listForFile", fixture.identity(path)) as? [[String: Any]])
        XCTAssertEqual((saved.first?["page"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(saved.first?["id"] as? String, original["id"] as? String)
        try await owner.undo(); XCTAssertEqual((owner.rows.first?["page"] as? NSNumber)?.intValue, 1)
        try await owner.redo(); XCTAssertEqual((owner.rows.first?["page"] as? NSNumber)?.intValue, 2)
    }
    func testSwiftPaperAndMeasuredReceiptRoundTripAcrossRestartAndUndoTombstone() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let paper = try fixture.call("pdfNotes:create", ["courseId": fixture.course, "title": "원본 노트", "paper": "grid", "orientation": "landscape"]) as! [String: Any]
        let path = paper["relPath"] as! String
        let source = try fixture.context.materialURL(courseID: fixture.course, relativePath: path)
        let document = try XCTUnwrap(PDFDocument(url: source)), page = try XCTUnwrap(document.page(at: 0))
        XCTAssertGreaterThan(page.bounds(for: .mediaBox).width, page.bounds(for: .mediaBox).height)
        let binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let digest = binding["documentRevision"] as! String
        let original = fixture.root.appendingPathComponent("PDFOriginals/\(digest).pdf")
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: original))
        let input = fixture.stroke(path, revision: digest)
        let first = try fixture.call("drawings:create", input) as! [String: Any]
        let replay = try fixture.call("drawings:create", input) as! [String: Any]
        XCTAssertEqual(first["id"] as? String, replay["id"] as? String)
        XCTAssertEqual((first["data"] as? NSDictionary), input["data"] as? NSDictionary)
        let restarted = try NativePDFRepository(context: fixture.context)
        XCTAssertEqual((try restarted.handle("drawings:create", input) as? [String: Any])?["id"] as? String, first["id"] as? String)
        _ = try fixture.call("drawings:delete", ["ids": [first["id"]!]])
        let status = try fixture.call("nativePDF:mutationStatus", input) as! [String: Any]
        XCTAssertEqual(status["status"] as? String, "deleted")
        XCTAssertThrowsError(try fixture.call("drawings:create", input), "An idempotent retry cannot resurrect an undone drawing")
        var altered = input; altered["page"] = 2
        XCTAssertThrowsError(try fixture.call("nativePDF:mutationStatus", altered))
    }

    func testHistoricalJSReceiptUsesStructuralNumberEqualityWithoutLosingIdentity() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let input = fixture.stroke(path, revision: binding["documentRevision"] as! String)
        let drawing = try fixture.call("drawings:create", input) as! [String: Any]
        var fingerprint = input; fingerprint.removeValue(forKey: "clientMutationId")
        let unordered = try JSONSerialization.data(withJSONObject: fingerprint, options: [.prettyPrinted, .withoutEscapingSlashes])
        _ = try fixture.context.db.run("UPDATE drawing_create_receipts SET request_json=? WHERE operation_id=?", params: [String(decoding: unordered, as: UTF8.self), input["clientMutationId"]!])
        let status = try fixture.call("nativePDF:mutationStatus", input) as! [String: Any]
        XCTAssertEqual(status["status"] as? String, "live")
        XCTAssertEqual(status["drawingId"] as? String, drawing["id"] as? String)
        var changed = input; changed["style"] = ["color": "red", "width": 0.004, "opacity": 1]
        XCTAssertThrowsError(try fixture.call("drawings:create", changed))
    }

    func testReplacementPDFNeverRebindsHistoricalInkAndKeepsRecoveryOriginal() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), inputIdentity = fixture.identity(path)
        let binding = try fixture.call("nativePDF:binding", inputIdentity) as! [String: Any]
        let oldDigest = binding["documentRevision"] as! String
        _ = try fixture.call("drawings:create", fixture.stroke(path, revision: oldDigest))
        let source = try fixture.context.materialURL(courseID: fixture.course, relativePath: path)
        let original = try Data(contentsOf: source)
        try NativePDFRepository.paperData(title: "Replacement", paper: "dots", orientation: "portrait").write(to: source, options: .atomic)
        XCTAssertThrowsError(try fixture.call("drawings:listForFile", inputIdentity))
        let restarted = try NativePDFRepository(context: fixture.context)
        XCTAssertThrowsError(try restarted.handle("nativePDF:binding", inputIdentity))
        XCTAssertEqual(try fixture.context.db.query("SELECT bound_sha FROM pdf_document_bindings", params: []).first?["bound_sha"] as? String, oldDigest)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("PDFOriginals/\(oldDigest).pdf")), original)
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM pdf_drawings WHERE deleted_at IS NULL", params: []).count, 1)
    }

    func testBatchDeleteValidationAndAnnotationsPreserveCanonicalRows() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let drawing = try fixture.call("drawings:create", fixture.stroke(path, revision: binding["documentRevision"] as! String)) as! [String: Any]
        XCTAssertThrowsError(try fixture.call("drawings:delete", ["ids": [drawing["id"]!, UUID().uuidString]]))
        XCTAssertEqual((try fixture.call("drawings:listForFile", fixture.identity(path)) as? [[String: Any]])?.count, 1)
        var input = fixture.identity(path)
        input.merge(["page": 1, "color": "yellow", "rects": [["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.04]],
                     "anchor": ["quote": "원문", "prefix": "앞", "suffix": "뒤"], "comment": "메모"]) { _, new in new }
        let annotation = try fixture.call("annotations:create", input) as! [String: Any]
        let changed = try fixture.call("annotations:update", ["id": annotation["id"]!, "color": "blue", "comment": NSNull()]) as! [String: Any]
        XCTAssertTrue(changed["comment"] is NSNull)
        XCTAssertEqual(changed["anchor"] as? NSDictionary, annotation["anchor"] as? NSDictionary)
        _ = try fixture.call("annotations:delete", ["id": annotation["id"]!])
        XCTAssertTrue((try fixture.call("annotations:listForFile", fixture.identity(path)) as! [[String: Any]]).isEmpty)
    }

    func testExportPreservesSourceTextAndPlacesInkInRotatedCropBox() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { value in value.beginPage(); ("Source text" as NSString).draw(at: CGPoint(x: 40, y: 70), withAttributes: [.font: UIFont.systemFont(ofSize: 14)]) }
        let pdf = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(pdf.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 250, height: 330), for: .cropBox); page.rotation = 90
        let source = try XCTUnwrap(pdf.dataRepresentation())
        let row: [String: Any] = ["id": "ink", "page": 1, "kind": "ink", "data": ["inkVersion": 5, "points": [["x": 0.25, "y": 0.3, "p": 0.7]]], "style": ["color": "red", "width": 0.025, "opacity": 1.0]]
        let exported = try NativePDFExport.render(source: source, drawings: [row], annotations: [], images: [])
        let result = try XCTUnwrap(PDFDocument(data: exported)), resultPage = try XCTUnwrap(result.page(at: 0))
        XCTAssertTrue(result.string?.contains("Source text") == true)
        XCTAssertEqual(resultPage.bounds(for: .mediaBox).width, 330, accuracy: 0.01)
        XCTAssertEqual(resultPage.bounds(for: .mediaBox).height, 250, accuracy: 0.01)
        let image = try XCTUnwrap(resultPage.thumbnail(of: CGSize(width: 660, height: 500), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // PDFKit thumbnails use top-left image storage. Ink must remain at the
        // same normalized displayed location after the rotated original is copied.
        let x = Int(Double(image.width) * 0.25), y = Int(Double(image.height) * 0.3), offset = (y * image.width + x) * 4
        XCTAssertGreaterThan(Int(pixels[offset]), Int(pixels[offset + 1]) + 20)
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 20, y: 30, width: 250, height: 330))
    }

    func testAnnotationReceiptReplaysOnceAndRefusesChangedPayloadOrDeletedRevival() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        var input = fixture.annotation(path)
        input["clientMutationId"] = UUID().uuidString; input["documentRevision"] = binding["documentRevision"]!
        let first = try fixture.call("annotations:create", input) as! [String: Any]
        let restarted = try NativePDFRepository(context: fixture.context)
        let replay = try restarted.handle("annotations:create", input) as! [String: Any]
        XCTAssertEqual(first["id"] as? String, replay["id"] as? String)
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM annotations", params: []).count, 1)
        var changed = input; changed["comment"] = "Different"
        XCTAssertThrowsError(try fixture.call("annotations:create", changed))
        _ = try fixture.call("annotations:delete", ["id": first["id"]!])
        XCTAssertThrowsError(try fixture.call("annotations:create", input))
        XCTAssertTrue((try fixture.call("annotations:listForFile", fixture.identity(path)) as! [[String: Any]]).isEmpty)
    }

    func testAnnotationLostCreateReplyRecoversFromDiskWithoutDuplicate() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let revision = binding["documentRevision"] as! String
        let recovery = try NativePDFEditRecovery(root: fixture.root, courseID: fixture.course, relativePath: path)
        var loseReply = true
        let owner = NativePDFPersistence(courseID: fixture.course, relativePath: path, documentRevision: revision, recovery: recovery,
            backend: { channel, input in
                let result = try fixture.call(channel, input)
                if channel == "annotations:create", loseReply { loseReply = false; throw NativePDFError.invalid("Lost response") }
                return result
            }, host: { _, _ in [:] })
        do { try await owner.createAnnotation(fixture.annotation(path)); XCTFail("Keep the uncertain operation on disk") } catch {}
        XCTAssertEqual(try recovery.records().count, 1)
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM annotations", params: []).count, 1)
        let reopened = NativePDFPersistence(courseID: fixture.course, relativePath: path, documentRevision: revision, recovery: recovery,
            backend: { try fixture.call($0, $1) }, host: { _, _ in [:] })
        try await reopened.recoverEdits(); try await reopened.reloadAnnotations()
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertEqual(reopened.annotations.first?["comment"] as? String, "Original comment")
        XCTAssertTrue(try recovery.records().isEmpty)
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM annotations", params: []).count, 1)
    }

    func testAnnotationHistoryResolvesRestoredIdentityAndKeepsExactAnchor() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let recovery = try NativePDFEditRecovery(root: fixture.root, courseID: fixture.course, relativePath: path)
        let owner = NativePDFPersistence(courseID: fixture.course, relativePath: path, documentRevision: binding["documentRevision"] as! String, recovery: recovery,
            backend: { try fixture.call($0, $1) }, host: { _, _ in [:] })
        let original = fixture.annotation(path)
        try await owner.createAnnotation(original)
        let firstID = try XCTUnwrap(owner.annotations.first?["id"] as? String)
        var update = try XCTUnwrap(owner.annotations.first); update["color"] = "blue"; update["comment"] = "Edited comment"
        try await owner.updateAnnotation(update)
        try await owner.undo()
        XCTAssertEqual(owner.annotations.first?["comment"] as? String, "Original comment")
        try await owner.undo(); XCTAssertTrue(owner.annotations.isEmpty)
        try await owner.redo(); XCTAssertEqual(owner.annotations.count, 1)
        XCTAssertNotEqual(owner.annotations.first?["id"] as? String, firstID)
        try await owner.redo()
        XCTAssertEqual(owner.annotations.first?["comment"] as? String, "Edited comment")
        XCTAssertEqual(owner.annotations.first?["color"] as? String, "blue")
        XCTAssertEqual(owner.annotations.first?["anchor"] as? NSDictionary, original["anchor"] as? NSDictionary)
        let id = try XCTUnwrap(owner.annotations.first?["id"] as? String)
        try await owner.deleteAnnotation(id: id); XCTAssertTrue(owner.annotations.isEmpty)
        try await owner.undo(); XCTAssertEqual(owner.annotations.count, 1)
        XCTAssertTrue(try recovery.records().isEmpty)
    }

    func testShapeCorrectionJournalSurvivesLostReplyThenUndoRawRemoveRedoAndOldIDAliases() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let revision = binding["documentRevision"] as! String, raw = fixture.stroke(path, revision: revision)
        var input = try JSONDecoder().decode(NativePDFStrokeInput.self, from: JSONSerialization.data(withJSONObject: raw))
        input.heldShape = NativePDFHeldShape(kind: "line", points: [.init(x: 0.2, y: 0.3, p: 0.5), .init(x: 0.6, y: 0.5, p: 0.5)], box: [0.2, 0.3, 0.4, 0.2])
        let journal = try NativePDFJournal(root: fixture.root)
        try journal.append(input, documentRevision: revision)
        let recovery = try NativePDFEditRecovery(root: fixture.root, courseID: fixture.course, relativePath: path)
        var loseReply = true
        let backend: NativePDFPersistence.Invoke = { channel, request in
            let result = try fixture.call(channel, request)
            if channel == "drawings:replace", loseReply { loseReply = false; throw NativePDFError.invalid("Lost committed correction reply") }
            return result
        }
        let host: NativePDFPersistence.Invoke = { command, request in
            if command == "mutationStatus" { return try fixture.call("nativePDF:mutationStatus", request["input"] as! [String: Any]) }
            if command == "ack" { try journal.acknowledge(request["clientMutationId"] as! String, courseID: fixture.course, relativePath: path); return [:] }
            if command == "eraseResult" { return ["operationId": request["operationId"]!, "outcome": "committed"] }
            throw NativePDFError.invalid("Unexpected command")
        }
        func owner() -> NativePDFPersistence { NativePDFPersistence(courseID: fixture.course, relativePath: path, documentRevision: revision,
            recovery: recovery, backend: backend, host: host) }
        let first = owner()
        do { try await first.recoverStrokes([try NativePDFHost.json(input)]); XCTFail("Committed correction remains retryable until ACK") } catch {}
        XCTAssertEqual(try journal.pending(courseID: fixture.course, relativePath: path).count, 1)
        let corrected = try fixture.call("drawings:listForFile", fixture.identity(path)) as! [[String: Any]]
        let originalID = try XCTUnwrap(corrected.first?["id"] as? String)
        XCTAssertEqual(corrected.count, 1); XCTAssertEqual(corrected.first?["kind"] as? String, "line")
        let restarted = owner(), recovered = try NativePDFJournal(root: fixture.root).pending(courseID: fixture.course, relativePath: path)
        XCTAssertEqual(recovered.first?.input.heldShape, input.heldShape)
        try await restarted.recoverStrokes(recovered.map { try NativePDFHost.json($0.input) })
        XCTAssertTrue(try journal.pending(courseID: fixture.course, relativePath: path).isEmpty)
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM drawing_create_receipts", params: []).count, 1)
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM drawing_replace_receipts", params: []).count, 1)
        try await restarted.undo()
        XCTAssertEqual(restarted.rows.first?["id"] as? String, originalID)
        XCTAssertEqual(restarted.rows.first?["kind"] as? String, "ink")
        XCTAssertEqual(restarted.rows.first?["data"] as? NSDictionary, raw["data"] as? NSDictionary, "Measured pressure/time/tilt survive correction")
        try await restarted.undo(); XCTAssertTrue(restarted.rows.isEmpty)
        try await restarted.redo(); XCTAssertEqual(restarted.rows.first?["kind"] as? String, "ink")
        try await restarted.redo(); XCTAssertEqual(restarted.rows.first?["kind"] as? String, "line")
        XCTAssertNotEqual(restarted.rows.first?["id"] as? String, originalID)
        try restarted.accept(["operationId": UUID().uuidString, "operationSequence": 1, "originToolEpoch": 0,
            "documentRevision": revision, "page": 1, "targets": [["drawingId": originalID]]], type: "eraseCommit")
        try await restarted.drain(through: 1); XCTAssertTrue(restarted.rows.isEmpty, "Queued erasers resolve a restored row's new identity")
        try await restarted.undo(); XCTAssertEqual(restarted.rows.first?["kind"] as? String, "line")
        XCTAssertTrue(try recovery.records().isEmpty)
    }

    func testCorrectionReceiptRecoveryDoesNotUndoNewerCanonicalEditAfterLostACK() async throws {
        for restart in [false, true] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
            let revision = binding["documentRevision"] as! String, raw = fixture.stroke(path, revision: revision)
            var input = try JSONDecoder().decode(NativePDFStrokeInput.self, from: JSONSerialization.data(withJSONObject: raw))
            input.heldShape = NativePDFHeldShape(kind: "line", points: [.init(x: 0.2, y: 0.3, p: 0.5), .init(x: 0.6, y: 0.5, p: 0.5)], box: [0.2, 0.3, 0.4, 0.2])
            let journal = try NativePDFJournal(root: fixture.root); try journal.append(input, documentRevision: revision)
            var loseACK = true
            let host: NativePDFPersistence.Invoke = { command, request in
                if command == "mutationStatus" { return try fixture.call("nativePDF:mutationStatus", request["input"] as! [String: Any]) }
                if command == "ack" {
                    if loseACK { loseACK = false; throw NativePDFError.invalid("Lost ACK") }
                    try journal.acknowledge(request["clientMutationId"] as! String, courseID: fixture.course, relativePath: path); return [:]
                }
                throw NativePDFError.invalid("Unexpected command")
            }
            func owner() -> NativePDFPersistence { NativePDFPersistence(courseID: fixture.course, relativePath: path, documentRevision: revision,
                backend: { try fixture.call($0, $1) }, host: host) }
            let original = owner(), payload = try NativePDFHost.json(input)
            do { try await original.recoverStrokes([payload]); XCTFail("An ACK loss leaves a recoverable journal") } catch {}
            XCTAssertTrue(original.canUndo)
            let rows = try fixture.call("drawings:listForFile", fixture.identity(path)) as! [[String: Any]], id = try XCTUnwrap(rows.first?["id"] as? String)
            // A sync import preserves this ID and replaces its canonical values.
            let newer = try fixture.call("drawings:update", ["id": id,
                "data": ["points": [["x": 0.3, "y": 0.4, "p": 0.5], ["x": 0.7, "y": 0.6, "p": 0.5]]],
                "style": ["color": "red", "width": 0.01, "opacity": 0.8]]) as! [String: Any]
            let recovered = restart ? owner() : original
            try await recovered.recoverStrokes([payload])
            XCTAssertFalse(recovered.canUndo, "The historical receipt cannot authorize undo of newer remote content; restart=\(restart)")
            try await recovered.undo()
            XCTAssertEqual(recovered.rows.first as NSDictionary?, newer as NSDictionary)
            XCTAssertTrue(try journal.pending(courseID: fixture.course, relativePath: path).isEmpty)
            XCTAssertEqual(try fixture.context.db.query("SELECT * FROM drawing_replace_receipts", params: []).count, 1)
        }
    }

    func testStableTextboxCreationTokenSurvivesFailureAndDoesNotAdoptIdenticalPeerObject() async throws {
        for failure in ["beforeCommit", "lostReply", "presentation"] {
            let fixture = try Fixture(); defer { fixture.cleanup() }
            let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
            let revision = binding["documentRevision"] as! String
            let text: [String: Any] = ["page": 1, "kind": "textbox",
                "data": ["text": "동일한 한국어 메모", "box": ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.15]],
                "style": ["color": "ink", "width": 0.003, "fontSizePt": 18.0, "opacity": 1.0]]
            var peerInput = fixture.identity(path); peerInput.merge(text) { _, next in next }
            peerInput["documentRevision"] = revision; peerInput["clientMutationId"] = UUID().uuidString
            let peer = try fixture.call("drawings:create", peerInput) as! [String: Any]
            let recovery = try NativePDFEditRecovery(root: fixture.root, courseID: fixture.course, relativePath: path)
            var injected = false
            let owner = NativePDFPersistence(courseID: fixture.course, relativePath: path, documentRevision: revision, recovery: recovery,
                backend: { channel, request in
                    if channel == "drawings:create", !injected, failure == "beforeCommit" { injected = true; throw NativePDFError.invalid("Disk full") }
                    let result = try fixture.call(channel, request)
                    if channel == "drawings:create", !injected, failure == "lostReply" { injected = true; throw NativePDFError.invalid("Lost reply") }
                    return result
                }, host: { _, _ in [:] })
            owner.onRowsChanged = { if !injected, failure == "presentation" { injected = true; throw NativePDFError.invalid("Lost presentation") } }
            let token = UUID().uuidString
            do { _ = try await owner.createObject(text, mutationID: token); XCTFail("The injected failure must leave the same creation retryable") } catch {}
            XCTAssertEqual(try recovery.records().count, 1)
            let created = try await owner.createObject(text, mutationID: token)
            XCTAssertNotEqual(created["id"] as? String, peer["id"] as? String)
            XCTAssertEqual(owner.rows.count, 2, "Identical objects from distinct pane creation tokens both survive")
            let repeated = try await owner.createObject(text, mutationID: token)
            XCTAssertEqual(repeated["id"] as? String, created["id"] as? String)
            XCTAssertEqual(try fixture.context.db.query("SELECT * FROM drawing_create_receipts", params: []).count, 2)
            var changed = text; changed["data"] = ["text": "다른 내용", "box": ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.15]]
            do { _ = try await owner.createObject(changed, mutationID: token); XCTFail("A token cannot be reused for different content") } catch {}
            try await owner.undo()
            XCTAssertEqual(owner.rows.count, 1); XCTAssertEqual(owner.rows.first?["id"] as? String, peer["id"] as? String)
            XCTAssertFalse(owner.canUndo, "Retrying a receipt must not append duplicate history")
            do { _ = try await owner.createObject(text, mutationID: token); XCTFail("An undone creation must not resurrect") } catch {}
            XCTAssertEqual(owner.rows.count, 1)
            try await owner.redo(); XCTAssertEqual(owner.rows.count, 2)
            XCTAssertEqual(try fixture.context.db.query("SELECT * FROM drawing_create_receipts", params: []).count, 3, "Undo restoration owns a new token")
            XCTAssertTrue(try recovery.records().isEmpty)
        }
    }

    func testAtomicCorrectionRollbackReceiptImmutabilityAndStaleInputRejection() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let path = try fixture.paper(), binding = try fixture.call("nativePDF:binding", fixture.identity(path)) as! [String: Any]
        let revision = binding["documentRevision"] as! String, raw = fixture.stroke(path, revision: revision)
        let row = try fixture.call("drawings:create", raw) as! [String: Any]
        let originalReceipts = try fixture.context.db.query("SELECT * FROM drawing_create_receipts", params: [])
        var replacement = fixture.identity(path)
        replacement.merge(["id": row["id"]!, "operationId": UUID().uuidString, "documentRevision": revision, "expected": row,
            "kind": "rect", "data": ["box": ["x": 0.2, "y": 0.3, "width": 0.4, "height": 0.2]], "style": raw["style"]!]) { _, new in new }
        try fixture.context.db.exec("CREATE TRIGGER fail_correction BEFORE INSERT ON drawing_replace_receipts BEGIN SELECT RAISE(ABORT, 'test full disk'); END;")
        XCTAssertThrowsError(try fixture.repo.handle("drawings:replace", replacement))
        XCTAssertEqual((try fixture.call("drawings:listForFile", fixture.identity(path)) as! [[String: Any]]).first as NSDictionary?, row as NSDictionary)
        XCTAssertTrue(try fixture.context.db.query("SELECT * FROM drawing_replace_receipts", params: []).isEmpty)
        try fixture.context.db.exec("DROP TRIGGER fail_correction;")
        let result = try fixture.call("drawings:replace", replacement) as! [String: Any]
        XCTAssertEqual((result["after"] as? [String: Any])?["id"] as? String, row["id"] as? String)
        let repo = try NativePDFRepository(context: fixture.context)
        XCTAssertEqual(try repo.handle("drawings:replace", replacement) as? NSDictionary, result as NSDictionary)
        var changed = replacement; changed["kind"] = "ellipse"
        XCTAssertThrowsError(try repo.handle("drawings:replace", changed))
        changed["operationId"] = UUID().uuidString
        XCTAssertThrowsError(try repo.handle("drawings:replace", changed), "An unrelated later correction cannot overwrite a changed row")
        XCTAssertEqual(try fixture.context.db.query("SELECT * FROM drawing_create_receipts", params: []) as NSArray, originalReceipts as NSArray)
        let status = try fixture.call("nativePDF:mutationStatus", raw) as! [String: Any]
        XCTAssertEqual(status["drawingId"] as? String, row["id"] as? String); XCTAssertEqual(status["status"] as? String, "live")
    }

    private final class Fixture {
        let root: URL, context: NativeRepositoryContext, repo: NativePDFRepository, course: String
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-repo-" + UUID().uuidString)
            context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
            let library = NativeLibraryRepository(context: context)
            let created = try library.handle("courses:create", ["name": "PDF test", "color": "blue"]) as! [String: Any]
            course = created["id"] as! String; repo = try NativePDFRepository(context: context)
        }
        func identity(_ path: String) -> [String: Any] { ["courseId": course, "relPath": path] }
        func call(_ channel: String, _ request: [String: Any]) throws -> Any {
            let value = try repo.handle(channel, request)
            return try XCTUnwrap(value)
        }
        func paper() throws -> String { (try call("pdfNotes:create", ["courseId": course, "title": "Paper", "paper": "blank"]) as! [String: Any])["relPath"] as! String }
        func stroke(_ path: String, revision: String) -> [String: Any] {
            ["courseId": course, "relPath": path, "page": 1, "kind": "ink", "documentRevision": revision, "clientMutationId": UUID().uuidString,
             "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.37, "t": 0.0, "tiltX": -30.0, "tiltY": 14.0], ["x": 0.6, "y": 0.5, "p": 0.83, "t": 24.3, "tiltX": -25.0, "tiltY": 18.0]]],
             "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]
        }
        func annotation(_ path: String) -> [String: Any] {
            identity(path).merging(["page": 1, "color": "yellow", "rects": [["x": 0.123, "y": 0.25, "width": 0.34, "height": 0.025]],
                                   "anchor": ["quote": "A selected source sentence", "prefix": "before ", "suffix": " after"], "comment": "Original comment"]) { _, new in new }
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
