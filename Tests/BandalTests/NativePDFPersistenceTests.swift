import XCTest
@testable import Bandal

@MainActor
final class NativePDFPersistenceTests: XCTestCase {
    private let course = "11111111-1111-4111-8111-111111111111"
    private let revision = String(repeating: "a", count: 64)

    func testLostStrokeAcknowledgementRetriesWithoutDuplicateDrawingOrUndoEntry() async throws {
        let backend = Repository(), bridge = Bridge()
        bridge.failAcknowledgement = true
        let writer = makeWriter(backend, bridge)
        let input = stroke(sequence: 1)
        try writer.accept(input, type: "stroke")
        do { try await writer.drain(); XCTFail("ACK failure must remain retryable") } catch {}
        XCTAssertEqual(backend.rows.count, 1)
        XCTAssertEqual(writer.completedSequence, 0)
        try await writer.drain(through: 1)
        XCTAssertEqual(backend.createCalls, 1)
        XCTAssertEqual(bridge.acknowledgements, 2)
        XCTAssertEqual(writer.completedSequence, 1)
        try await writer.undo()
        XCTAssertTrue(backend.rows.isEmpty)
        XCTAssertFalse(writer.canUndo, "An ACK retry must not append a second undo item")
        try await writer.redo()
        XCTAssertEqual(backend.rows.count, 1)
        XCTAssertEqual((backend.rows.first?["data"] as? [String: Any])?["inkVersion"] as? Int, 5)
    }

    func testLostStrokeCreateReplyPreservesExactlyOneUndoStep() async throws {
        let backend = Repository(), bridge = Bridge()
        backend.failAfterNextCreate = true
        let writer = makeWriter(backend, bridge)
        try writer.accept(stroke(sequence: 1), type: "stroke")
        do { try await writer.drain(); XCTFail("An uncertain create must await a receipt retry") } catch {}
        XCTAssertEqual(backend.rows.count, 1)
        XCTAssertEqual(bridge.acknowledgements, 0)
        try await writer.drain(through: 1)
        XCTAssertEqual(backend.createCalls, 1)
        XCTAssertTrue(writer.canUndo)
        try await writer.undo()
        XCTAssertTrue(backend.rows.isEmpty)
        XCTAssertFalse(writer.canUndo)
    }

    func testEraseArrivingBeforeDurableStrokeWaitsAndUndoRestoresBothHistorySteps() async throws {
        let backend = Repository(), bridge = Bridge(), writer = makeWriter(backend, Bridge())
        // Use one writer/bridge pair so the fake also verifies mutation aliases.
        let owner = makeWriter(backend, bridge)
        let input = stroke(sequence: 1), mutation = input["clientMutationId"] as! String
        let erase = erase(sequence: 2, mutation: mutation)
        try owner.accept(erase, type: "eraseCommit")
        try await owner.drain()
        XCTAssertEqual(backend.deleteCalls, 0)
        try owner.accept(input, type: "stroke")
        try await owner.drain(through: 2)
        XCTAssertTrue(backend.rows.isEmpty)
        XCTAssertEqual(bridge.eraseResults, 1)
        try await owner.undo()
        XCTAssertEqual(backend.rows.count, 1)
        try await owner.undo()
        XCTAssertTrue(backend.rows.isEmpty, "Undo of the original stroke must resolve the restored row's new ID")
        XCTAssertFalse(owner.canUndo)
        XCTAssertFalse(writer.canUndo, "A different document owner cannot inherit undo state")
    }

    func testLostRestoreReplyReusesReceiptAcrossRetryAndProcessRecovery() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Repository(), bridge = Bridge()
        let recovery = try NativePDFEditRecovery(root: root, courseID: course, relativePath: "notes/a.pdf")
        let owner = makeWriter(backend, bridge, recovery: recovery)
        try owner.accept(stroke(sequence: 1), type: "stroke"); try await owner.drain()
        try await owner.undo()
        backend.failAfterNextCreate = true
        do { try await owner.redo(); XCTFail("Lost restore reply must retain the recovery operation") } catch {}
        XCTAssertEqual(backend.rows.count, 1)
        XCTAssertEqual(try recovery.records().count, 1)
        // Recreate the Swift persistence owner, retaining only disk and DB.
        let restarted = makeWriter(backend, Bridge(), recovery: recovery)
        try await restarted.recoverEdits()
        XCTAssertEqual(backend.rows.count, 1, "A replayed create uses the original operation UUID")
        XCTAssertTrue(try recovery.records().isEmpty)
        XCTAssertEqual(backend.createCalls, 3, "Original create, lost restore reply, same-receipt replay")
    }

    func testFailedEraseIsPreservedOnDiskAndRecoversWithoutReplayingSuccessfulDelete() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Repository(), bridge = Bridge()
        let recovery = try NativePDFEditRecovery(root: root, courseID: course, relativePath: "notes/a.pdf")
        let owner = makeWriter(backend, bridge, recovery: recovery)
        let input = stroke(sequence: 1)
        try owner.accept(input, type: "stroke"); try await owner.drain()
        backend.failDelete = true
        try owner.accept(erase(sequence: 2, mutation: input["clientMutationId"] as! String), type: "eraseCommit")
        do { try await owner.drain(); XCTFail("The failed erase must not ACK") } catch {}
        XCTAssertEqual(bridge.eraseResults, 0)
        XCTAssertEqual(try recovery.records().count, 1)
        XCTAssertEqual(backend.rows.count, 1)
        backend.failDelete = false
        let restarted = makeWriter(backend, Bridge(), recovery: recovery)
        try await restarted.recoverEdits()
        XCTAssertTrue(backend.rows.isEmpty)
        XCTAssertTrue(try recovery.records().isEmpty)
    }

    func testMismatchedDocumentCannotConsumeRecoveryOrOverwriteInk() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let recovery = try NativePDFEditRecovery(root: root, courseID: course, relativePath: "notes/a.pdf")
        try recovery.save(["version": 1, "recoveryId": UUID().uuidString, "courseId": course, "relPath": "notes/a.pdf",
                           "documentRevision": revision, "kind": "delete", "rows": []])
        let backend = Repository()
        let replacement = NativePDFPersistence(courseID: course, relativePath: "notes/a.pdf", documentRevision: String(repeating: "b", count: 64),
            recovery: recovery, backend: backend.invoke, host: { _, _ in [:] })
        do { try await replacement.recoverEdits(); XCTFail("Replacing a PDF cannot consume the old edit log") } catch {}
        XCTAssertEqual(try recovery.records().count, 1)
        XCTAssertEqual(backend.deleteCalls, 0)
        XCTAssertEqual(backend.createCalls, 0)
    }

    func testNativeObjectCreationMoveAndHistoryKeepOriginalMeasuredData() async throws {
        let backend = Repository(), bridge = Bridge(), owner = makeWriter(backend, Bridge())
        bridge.repository = backend
        let original: [String: Any] = ["page": 1, "kind": "rect", "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2]], "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]
        try await owner.createObjects([original])
        var moved = try XCTUnwrap(backend.rows.first)
        moved["data"] = ["box": ["x": 0.4, "y": 0.5, "width": 0.3, "height": 0.2]]
        try await owner.updateObjects([moved])
        XCTAssertEqual(backend.rows.first?["data"] as? NSDictionary, moved["data"] as? NSDictionary)
        try await owner.undo()
        XCTAssertEqual(backend.rows.first?["data"] as? NSDictionary, original["data"] as? NSDictionary)
        try await owner.undo()
        XCTAssertTrue(backend.rows.isEmpty)
        try await owner.redo(); try await owner.redo()
        XCTAssertEqual(backend.rows.first?["data"] as? NSDictionary, moved["data"] as? NSDictionary)
    }

    func testCrossPageMovePreservesIdentityAndUndoRedoRestoresPageAndGeometry() async throws {
        let backend = Repository(), bridge = Bridge()
        let writer = makeWriter(backend, bridge)
        let source: [String: Any] = ["page": 1, "kind": "rect", "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2]], "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]
        try await writer.createObjects([source])
        let original = try XCTUnwrap(backend.rows.first), id = original["id"] as? String
        var moved = original; moved["page"] = 3
        moved["data"] = ["box": ["x": 0.4, "y": 0.5, "width": 0.3, "height": 0.2]]
        try await writer.updateObjects([moved], expected: [original])
        XCTAssertEqual(backend.rows.first?["page"] as? Int, 3)
        XCTAssertEqual(backend.rows.first?["id"] as? String, id)
        try await writer.undo()
        XCTAssertEqual(backend.rows.first?["page"] as? Int, 1)
        XCTAssertEqual(backend.rows.first?["data"] as? NSDictionary, original["data"] as? NSDictionary)
        try await writer.redo()
        XCTAssertEqual(backend.rows.first?["page"] as? Int, 3)
        XCTAssertEqual(backend.rows.first?["data"] as? NSDictionary, moved["data"] as? NSDictionary)
        XCTAssertEqual(backend.rows.first?["id"] as? String, id)
    }
    func testDelayedImageCutDoesNotDeleteObjectsChangedWhileClipboardLoads() async throws {
        let backend = Repository()
        let owner = makeWriter(backend, Bridge())
        try await owner.createObjects([["page": 1, "kind": "rect", "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.2, "height": 0.2]],
            "style": ["color": "blue", "width": 0.003, "opacity": 1]]])
        let original = try XCTUnwrap(owner.rows.first), id = try XCTUnwrap(original["id"] as? String)
        _ = try await backend.invoke("drawings:update", ["id": id, "data": original["data"]!, "style": ["color": "red", "width": 0.003, "opacity": 1]])
        do { try await owner.deleteObjects(ids: [id], expected: [original]); XCTFail("A delayed cut cannot erase a peer's updated object") } catch {}
        XCTAssertEqual(backend.rows.count, 1)
        XCTAssertEqual((backend.rows.first?["style"] as? [String: Any])?["color"] as? String, "red")
    }

    func testInterruptedMultiObjectMoveReplaysWholeDurableActionAfterRestart() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Repository(), bridge = Bridge()
        let recovery = try NativePDFEditRecovery(root: root, courseID: course, relativePath: "notes/a.pdf")
        let owner = makeWriter(backend, bridge, recovery: recovery)
        let original: [String: Any] = ["page": 1, "kind": "rect", "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2]], "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]
        try await owner.createObjects([original, original])
        let changed = backend.rows.map { row -> [String: Any] in var row = row; row["page"] = 2; row["data"] = ["box": ["x": 0.5, "y": 0.6, "width": 0.3, "height": 0.2]]; return row }
        backend.failUpdateNumber = 2
        do { try await owner.updateObjects(changed); XCTFail("Partial update must remain recoverable") } catch {}
        XCTAssertEqual(try recovery.records().count, 1)
        backend.failUpdateNumber = nil
        let restarted = makeWriter(backend, Bridge(), recovery: recovery)
        try await restarted.recoverEdits()
        for row in backend.rows { XCTAssertEqual(row["data"] as? NSDictionary, changed[0]["data"] as? NSDictionary); XCTAssertEqual(row["page"] as? Int, 2) }
        XCTAssertTrue(try recovery.records().isEmpty)
    }

    func testCommittedHistorySurvivesTabRecreationIncludingRestoredDrawingAliases() async throws {
        let root = temporaryRoot(), backend = Repository(), bridge = Bridge()
        let first = makeWriter(backend, bridge)
        let input = stroke(sequence: 1)
        try first.accept(input, type: "stroke"); try await first.drain()
        try first.accept(erase(sequence: 2, mutation: input["clientMutationId"] as! String), type: "eraseCommit")
        try await first.drain(); try await first.undo()
        XCTAssertEqual(backend.rows.count, 1)
        first.checkpointHistory(root: root)
        let reopened = makeWriter(backend, Bridge())
        try await reopened.reload(); reopened.restoreHistory(root: root)
        XCTAssertTrue(reopened.canUndo); XCTAssertTrue(reopened.canRedo)
        try await reopened.undo()
        XCTAssertTrue(backend.rows.isEmpty, "Restored alias maps the original stroke to the recreated drawing")
        try await reopened.redo(); XCTAssertEqual(backend.rows.count, 1)
        reopened.checkpointHistory(root: root)
        let again = makeWriter(backend, Bridge())
        try await again.reload(); again.restoreHistory(root: root)
        XCTAssertTrue(again.canUndo); XCTAssertTrue(again.canRedo)
    }
    func testHistoryCheckpointRejectsExternalDrawingEditsAndWorkspaceMismatch() async throws {
        let root = temporaryRoot(), backend = Repository(), first = makeWriter(backend, Bridge())
        try first.accept(stroke(sequence: 1), type: "stroke"); try await first.drain()
        first.checkpointHistory(root: root)
        let otherWorkspace = makeWriter(backend, Bridge())
        try await otherWorkspace.reload(); otherWorkspace.restoreHistory(root: root.appendingPathComponent("other"))
        XCTAssertFalse(otherWorkspace.canUndo)
        backend.rows[0]["style"] = ["color": "red", "width": 0.02, "opacity": 0.7]
        let changed = makeWriter(backend, Bridge())
        try await changed.reload(); changed.restoreHistory(root: root)
        XCTAssertFalse(changed.canUndo, "Undo must never overwrite an external change on the same PDF revision")
        XCTAssertEqual((backend.rows[0]["style"] as? [String: Any])?["color"] as? String, "red")
    }

    func testDuplicatePanesShareCanonicalInkButUndoOnlyTheirOwnStrokes() async throws {
        let root = temporaryRoot(), backend = Repository()
        let file = NativePDFFileCoordinator.shared(root: root, courseID: course, relativePath: "notes/a.pdf")
        let a = makeWriter(backend, Bridge(), coordinator: file, instanceID: "A")
        let b = makeWriter(backend, Bridge(), coordinator: file, instanceID: "B")
        var peerUpdates = 0; b.onPeerChanged = { _ in peerUpdates += 1 }
        try a.accept(stroke(sequence: 1), type: "stroke"); try await a.drain()
        let aID = try XCTUnwrap(a.rows.first?["id"] as? String)
        try b.accept(stroke(sequence: 1), type: "stroke"); try await b.drain()
        XCTAssertEqual(a.rows.count, 2); XCTAssertEqual(b.rows.count, 2); XCTAssertGreaterThan(peerUpdates, 0)
        try await a.undo()
        XCTAssertEqual(b.rows.count, 1); XCTAssertNotEqual(b.rows.first?["id"] as? String, aID)
        XCTAssertTrue(b.canUndo, "An unrelated peer undo must preserve this pane's own history")
        try await b.undo(); XCTAssertTrue(a.rows.isEmpty)
        try await a.redo(); XCTAssertEqual(b.rows.count, 1)
        XCTAssertFalse(b.canUndo, "Mirroring a peer's redo cannot become a local undo action")
    }

    func testPeerObjectChangeInvalidatesOnlyOverlappingHistoryAndRejectsStaleEdit() async throws {
        let backend = Repository(), file = NativePDFFileCoordinator()
        let a = makeWriter(backend, Bridge(), coordinator: file, instanceID: "A")
        let b = makeWriter(backend, Bridge(), coordinator: file, instanceID: "B")
        try a.accept(stroke(sequence: 1), type: "stroke"); try await a.drain()
        let first = try XCTUnwrap(a.rows.first)
        try a.accept(stroke(sequence: 2), type: "stroke"); try await a.drain()
        let old = try XCTUnwrap(a.rows.last)
        var changed = old; changed["style"] = ["color": "red", "width": 0.01, "opacity": 1.0]
        try await b.updateObjects([changed])
        var stale = old; stale["style"] = ["color": "blue", "width": 0.005, "opacity": 1.0]
        do { try await a.updateObjects([stale], expected: [old]); XCTFail("A stale pane must not overwrite a peer's edit") } catch {}
        XCTAssertTrue(a.canUndo)
        try await a.undo()
        XCTAssertFalse(backend.rows.contains { $0["id"] as? String == first["id"] as? String })
        XCTAssertEqual(backend.rows.first?["style"] as? NSDictionary, changed["style"] as? NSDictionary)
        XCTAssertFalse(a.canUndo, "History for the peer-modified second stroke was removed")
    }

    func testAnnotationsMirrorAcrossPanesWithoutSharingUndoOwnership() async throws {
        let backend = Repository(), file = NativePDFFileCoordinator()
        let a = makeWriter(backend, Bridge(), coordinator: file), b = makeWriter(backend, Bridge(), coordinator: file)
        try await a.createAnnotation(["page": 1, "color": "yellow", "rects": [], "anchor": ["quote": "text"], "comment": "First note"])
        XCTAssertEqual(b.annotations.count, 1); XCTAssertFalse(b.canUndo)
        var edited = try XCTUnwrap(b.annotations.first); edited["comment"] = "Second pane note"
        try await b.updateAnnotation(edited)
        XCTAssertEqual(a.annotations.first?["comment"] as? String, "Second pane note")
        XCTAssertFalse(a.canUndo, "The original pane cannot delete a note subsequently edited by its peer")
        try await b.undo()
        XCTAssertEqual(a.annotations.first?["comment"] as? String, "First note")
    }

    func testUncertainEditRemainsWithItsLiveOwnerUntilRetry() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let backend = Repository(), file = NativePDFFileCoordinator()
        let recovery = try NativePDFEditRecovery(root: root, courseID: course, relativePath: "notes/a.pdf")
        let a = makeWriter(backend, Bridge(), recovery: recovery, coordinator: file, instanceID: "A")
        let b = makeWriter(backend, Bridge(), recovery: recovery, coordinator: file, instanceID: "B")
        try a.accept(stroke(sequence: 1), type: "stroke"); try await a.drain(); try await a.undo()
        backend.failAfterNextCreate = true
        do { try await a.redo(); XCTFail("Lost result must retain durable intent") } catch {}
        XCTAssertEqual(try recovery.records().count, 1)
        do { try await b.recoverEdits(); XCTFail("A second live pane cannot steal uncertain recovery") } catch {}
        XCTAssertEqual(try recovery.records().count, 1); XCTAssertEqual(backend.rows.count, 1)
        try await a.redo()
        try await b.recoverEdits()
        XCTAssertTrue(try recovery.records().isEmpty); XCTAssertEqual(b.rows.count, 1)
    }

    func testDuplicateHistoryCheckpointsRemainScopedToTheirPane() async throws {
        let root = temporaryRoot(), backend = Repository()
        let a = makeWriter(backend, Bridge(), instanceID: "A")
        try a.accept(stroke(sequence: 1), type: "stroke"); try await a.drain(); a.checkpointHistory(root: root)
        let b = makeWriter(backend, Bridge(), instanceID: "B")
        try await b.reload(); b.restoreHistory(root: root); XCTAssertFalse(b.canUndo)
        try b.accept(stroke(sequence: 1), type: "stroke"); try await b.drain()
        let reopened = makeWriter(backend, Bridge(), instanceID: "A")
        try await reopened.reload(); reopened.restoreHistory(root: root); XCTAssertTrue(reopened.canUndo)
        try await reopened.undo(); XCTAssertEqual(backend.rows.count, 1, "An unrelated peer stroke preserves this pane's checkpoint and survives its undo")
    }

    func testCommittedStrokesSpliceIntoRowsInListingOrderWithoutRereadingTheDocument() async throws {
        let backend = Repository(), bridge = Bridge()
        let writer = makeWriter(backend, bridge)
        try await writer.recoverEdits()
        let listsBefore = backend.listCalls
        for (index, page) in [2, 1, 3, 1, 2].enumerated() {
            var input = stroke(sequence: index + 1); input["page"] = page
            try writer.accept(input, type: "stroke")
            try await writer.drain()
            let listedRaw = try await backend.invoke("drawings:listForFile", [:])
            let listed = try XCTUnwrap(listedRaw as? [[String: Any]])
            XCTAssertEqual(writer.rows.map { $0["id"] as? String }, listed.map { $0["id"] as? String }, "rows must mirror listDrawings order after each stroke")
            XCTAssertEqual(writer.rows.map { ($0["page"] as? NSNumber)?.intValue }, listed.map { ($0["page"] as? NSNumber)?.intValue })
        }
        XCTAssertEqual(backend.listCalls, listsBefore + 5, "the equality probes above are the only listings; the commits must not re-read the document")
        XCTAssertEqual(writer.rows.count, 5); XCTAssertTrue(writer.canUndo)
        try await writer.undo()
        XCTAssertEqual(writer.rows.count, 4, "undo refreshes its affected canonical ID")
        XCTAssertEqual(backend.fullListCalls, listsBefore + 5)
    }

    func testFreshOwnerLoadsExistingRowsOnceBeforeStrokeOrObjectCreation() async throws {
        for useStroke in [true, false] {
            let backend = Repository(), file = NativePDFFileCoordinator()
            backend.rows = fixtureRows(count: 2)
            let existing = backend.rows
            let writer = makeWriter(backend, Bridge(), coordinator: file)
            let peer = makeWriter(backend, Bridge(), coordinator: file)
            peer.receivePeerSnapshot(drawings: existing, annotations: nil)
            // Deliberately do not recoverEdits/reload the fresh writer. Its
            // first delta must not replace the peer's complete document.
            if useStroke {
                try writer.accept(stroke(sequence: 1), type: "stroke")
                try await writer.drain()
            } else {
                try await writer.createObjects([["page": 1, "kind": "rect",
                    "data": ["box": ["x": 0.1, "y": 0.2, "width": 0.3, "height": 0.2]],
                    "style": ["color": "blue", "width": 0.003, "opacity": 1.0]]])
            }
            XCTAssertEqual(writer.rows.count, 3)
            XCTAssertEqual(peer.rows as NSArray, writer.rows as NSArray)
            try await writer.undo()
            XCTAssertEqual(writer.rows as NSArray, existing as NSArray)
            XCTAssertEqual(peer.rows as NSArray, existing as NSArray)
            try await writer.redo()
            XCTAssertEqual(writer.rows.count, 3)
            XCTAssertEqual(peer.rows as NSArray, writer.rows as NSArray)
            XCTAssertEqual(backend.fullListCalls, 1, "Only the unknown initial baseline needs a full listing")
        }
    }

    func testFreshAnnotationOwnerPreservesExistingAnnotationsThroughCreateUndoAndRedo() async throws {
        let backend = Repository(), file = NativePDFFileCoordinator()
        let annotation: [String: Any] = ["page": 1, "color": "yellow", "rects": [], "anchor": [:], "comment": "new"]
        backend.annotationRows = fixtureRows(count: 2).map { row in row.merging(annotation) { _, new in new } }
        let existing = backend.annotationRows
        let writer = makeWriter(backend, Bridge(), coordinator: file)
        let peer = makeWriter(backend, Bridge(), coordinator: file)
        peer.receivePeerSnapshot(drawings: nil, annotations: existing)
        try await writer.createAnnotation(annotation)
        XCTAssertEqual(writer.annotations.count, 3)
        XCTAssertEqual(peer.annotations as NSArray, writer.annotations as NSArray)
        try await writer.undo()
        XCTAssertEqual(writer.annotations as NSArray, existing as NSArray)
        XCTAssertEqual(peer.annotations as NSArray, existing as NSArray)
        try await writer.redo()
        XCTAssertEqual(writer.annotations.count, 3)
        XCTAssertEqual(peer.annotations as NSArray, writer.annotations as NSArray)
        XCTAssertEqual(backend.fullListCalls, 1)
    }

    func testCompletePeerSnapshotEstablishesEvenAnEmptyCanonicalBaseline() async throws {
        for existingCount in [0, 2] {
            let backend = Repository(), writer = makeWriter(backend, Bridge())
            backend.rows = fixtureRows(count: existingCount)
            backend.annotationRows = fixtureRows(count: existingCount).map { row in
                row.merging(["color": "yellow", "rects": [], "anchor": [:], "comment": "peer"]) { _, new in new }
            }
            writer.receivePeerSnapshot(drawings: backend.rows, annotations: backend.annotationRows)
            try writer.accept(stroke(sequence: 1), type: "stroke")
            try await writer.drain()
            try await writer.createAnnotation(["page": 1, "color": "yellow", "rects": [], "anchor": [:], "comment": "new"])
            XCTAssertEqual(writer.rows.count, existingCount + 1)
            XCTAssertEqual(writer.annotations.count, existingCount + 1)
            XCTAssertEqual(backend.fullListCalls, 0, "A complete peer snapshot already supplied the baseline")
        }
    }

    func testObjectEditsEraseAndRetryHistoryFetchOnlyAffectedCanonicalRows() async throws {
        let backend = Repository(), bridge = Bridge(), writer = makeWriter(backend, bridge)
        backend.rows = fixtureRows(count: 300)
        try await writer.recoverEdits()
        let original = try XCTUnwrap(writer.rows.first), id = try XCTUnwrap(original["id"] as? String)
        let untouched = writer.rows.filter { $0["id"] as? String != id }
        let fullLists = backend.fullListCalls
        backend.maximumScopedRows = 0
        var moved = original; moved["page"] = 4; moved["style"] = ["color": "red", "width": 0.005, "opacity": 1]
        try await writer.updateObjects([moved], expected: [original])
        try await writer.undo(); try await writer.redo()
        XCTAssertEqual(writer.rows.first { $0["id"] as? String == id }?["page"] as? Int, 4)

        // An ACK may be lost after a new stroke is already committed.
        bridge.failAcknowledgement = true
        let input = stroke(sequence: 1)
        try writer.accept(input, type: "stroke")
        do { try await writer.drain(); XCTFail("Lost ACK must remain retryable") } catch {}
        try await writer.drain()
        try writer.accept(erase(sequence: 2, mutation: input["clientMutationId"] as! String), type: "eraseCommit")
        try await writer.drain(); try await writer.undo(); try await writer.redo()
        XCTAssertEqual(writer.rows.count, 300)
        XCTAssertEqual(backend.fullListCalls, fullLists, "No edit, ACK retry, erase, undo, or redo may reload unrelated drawing JSON")
        XCTAssertGreaterThan(backend.scopedListCalls, 0)
        XCTAssertLessThanOrEqual(backend.maximumScopedRows, 1)
        XCTAssertEqual(writer.rows.filter { $0["id"] as? String != id } as NSArray, untouched as NSArray)
    }

    func testEqualCreationTimesPreserveCanonicalStackingAcrossPageMoves() async throws {
        let backend = Repository(), writer = makeWriter(backend, Bridge())
        backend.rows = fixtureRows(count: 3)
        let stamp = backend.rows[0]["createdAt"]!
        for index in backend.rows.indices { backend.rows[index]["createdAt"] = stamp }
        backend.rows[0]["page"] = 2; backend.rows[1]["page"] = 1; backend.rows[2]["page"] = 2
        try await writer.recoverEdits()
        let old = backend.rows[0]
        var moved = old; moved["page"] = 1
        let fullLists = backend.fullListCalls
        try await writer.updateObjects([moved], expected: [old])
        XCTAssertEqual(writer.rows.map { $0["id"] as? String }, backend.rows.map { $0["id"] as? String })
        try await writer.undo()
        XCTAssertEqual(writer.rows.map { $0["id"] as? String }, [backend.rows[1], backend.rows[0], backend.rows[2]].map { $0["id"] as? String })
        try await writer.redo()
        XCTAssertEqual(writer.rows.map { $0["id"] as? String }, backend.rows.map { $0["id"] as? String })
        XCTAssertEqual(backend.fullListCalls, fullLists)
        XCTAssertGreaterThan(backend.pageListCalls, 0, "Only an ambiguous timestamp tie needs a canonical page-order query")
    }

    func testTargetedReplyCannotOverwriteNewerPeerSnapshot() async throws {
        let backend = Repository(), writer = makeWriter(backend, Bridge())
        backend.rows = fixtureRows(count: 2)
        try await writer.recoverEdits()
        let original = backend.rows[0]
        var changed = original; changed["style"] = ["color": "red", "width": 0.008, "opacity": 1]
        let peerRows = [changed, backend.rows[1]]
        backend.beforeScopedReply = { writer.receivePeerSnapshot(drawings: peerRows, annotations: nil) }
        var attempted = original; attempted["page"] = 3
        do { try await writer.updateObjects([attempted], expected: [original]); XCTFail("A stale edit must not overwrite the peer") } catch {}
        XCTAssertEqual(writer.rows as NSArray, peerRows as NSArray)
        XCTAssertEqual(backend.updateCalls, 0)
    }

    func testAnnotationEditsUseOnlyAffectedIDs() async throws {
        let backend = Repository(), writer = makeWriter(backend, Bridge())
        backend.annotationRows = fixtureRows(count: 40).map { row in
            var value = row; value["color"] = "yellow"; value["rects"] = []; value["anchor"] = [:]; value["comment"] = "original"
            return value
        }
        try await writer.reloadAnnotations()
        let original = backend.annotationRows[0], id = try XCTUnwrap(backend.annotationRows[0]["id"] as? String)
        let fullLists = backend.fullListCalls
        var changed = original; changed["comment"] = "edited"
        try await writer.updateAnnotation(changed, expected: original)
        try await writer.undo(); try await writer.redo()
        try await writer.deleteAnnotation(id: id)
        XCTAssertEqual(writer.annotations.count, 39)
        XCTAssertEqual(backend.fullListCalls, fullLists)
        XCTAssertLessThanOrEqual(backend.maximumScopedRows, 1)
    }

    func testCoordinatedHintAvoidsComparingUnrelatedPayloadAndPublicRefreshKeepsFallback() throws {
        let writer = makeWriter(Repository(), Bridge()), ids = (0..<50).map { _ in UUID().uuidString }
        let comparisons = ComparisonCounter()
        func snapshot(changed: Int?) -> [[String: Any]] {
            ids.enumerated().map { index, id in ["id": id, "page": 1, "createdAt": "same",
                "data": ComparisonProbe(value: changed == index ? 2 : 1, counter: comparisons)] }
        }
        writer.receiveCoordinatedSnapshot(drawings: snapshot(changed: nil), annotations: nil, drawingIDs: nil, annotationIDs: nil)
        comparisons.count = 0
        var observed = Set<String>(); writer.onPeerChanged = { observed = $0 }
        writer.receiveCoordinatedSnapshot(drawings: snapshot(changed: 0), annotations: nil, drawingIDs: [ids[0]], annotationIDs: nil)
        XCTAssertEqual(observed, [ids[0]])
        XCTAssertLessThanOrEqual(comparisons.count, 2, "A one-object edit must not deep-compare every other drawing payload")
        comparisons.count = 0
        writer.receivePeerSnapshot(drawings: snapshot(changed: 1), annotations: nil)
        XCTAssertEqual(observed, [ids[0], ids[1]])
        XCTAssertGreaterThan(comparisons.count, 2, "Uncoordinated snapshots still require the full comparison")
    }

    func testNewPeerIgnoresPartialHintUntilItHasCanonicalBaseline() {
        let backend = Repository(), writer = makeWriter(backend, Bridge()), rows = fixtureRows(count: 3)
        var observed = Set<String>(); writer.onPeerChanged = { observed = $0 }
        let first = rows[0]["id"] as! String
        writer.receiveCoordinatedSnapshot(drawings: rows, annotations: nil, drawingIDs: [first], annotationIDs: nil)
        XCTAssertEqual(observed, Set(rows.compactMap { $0["id"] as? String }))
        XCTAssertEqual(writer.rows.count, 3)
    }

    func testIndependentReloadInvalidatesPeerHintBaseline() async throws {
        let backend = Repository(), writer = makeWriter(backend, Bridge())
        backend.rows = fixtureRows(count: 2)
        let original = backend.rows
        writer.receiveCoordinatedSnapshot(drawings: original, annotations: nil, drawingIDs: nil, annotationIDs: nil)
        backend.rows[1]["style"] = ["color": "red"]
        try await writer.reload()
        var observed = Set<String>(); writer.onPeerChanged = { observed = $0 }
        var next = original; next[0]["style"] = ["color": "green"]
        writer.receiveCoordinatedSnapshot(drawings: next, annotations: nil,
                                         drawingIDs: [original[0]["id"] as! String], annotationIDs: nil)
        XCTAssertEqual(observed, Set(original.compactMap { $0["id"] as? String }),
                       "The previous broadcast's delta is unsafe after an independent reload changes this pane's baseline")
    }

    func testPageTieRefreshPublishesEveryRefreshedIDAndInvalidatesAffectedPeerHistory() async throws {
        let backend = Repository(), file = NativePDFFileCoordinator()
        backend.rows = fixtureRows(count: 3)
        let stamp = backend.rows[0]["createdAt"]!
        for index in backend.rows.indices { backend.rows[index]["createdAt"] = stamp }
        let a = makeWriter(backend, Bridge(), coordinator: file), b = makeWriter(backend, Bridge(), coordinator: file)
        try await a.recoverEdits(); try await b.recoverEdits()
        var peerEdit = backend.rows[1]; peerEdit["style"] = ["color": "blue"]
        try await b.updateObjects([peerEdit])
        XCTAssertTrue(b.canUndo)
        let changedElsewhere = backend.rows[1]["id"] as! String
        backend.rows[1]["style"] = ["color": "red"]
        var observed = Set<String>(); b.onPeerChanged = { observed.formUnion($0) }
        var localEdit = backend.rows[0]; localEdit["style"] = ["color": "green"]
        try await a.updateObjects([localEdit])
        XCTAssertTrue(observed.contains(changedElsewhere), "A page tie refresh can discover changes beyond the requested ID")
        XCTAssertFalse(b.canUndo, "The peer must not undo over an externally changed object discovered on the same page")
        XCTAssertEqual(b.rows[1]["style"] as? NSDictionary, ["color": "red"] as NSDictionary)
    }

    private final class ComparisonCounter { var count = 0 }
    private final class ComparisonProbe: NSObject {
        let value: Int, counter: ComparisonCounter
        init(value: Int, counter: ComparisonCounter) { self.value = value; self.counter = counter }
        override func isEqual(_ object: Any?) -> Bool { counter.count += 1; return (object as? ComparisonProbe)?.value == value }
        override var hash: Int { value }
    }

    private func fixtureRows(count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            var row = stroke(sequence: index + 1)
            row.removeValue(forKey: "operationSequence"); row.removeValue(forKey: "clientMutationId"); row.removeValue(forKey: "documentRevision")
            row["id"] = UUID().uuidString
            row["createdAt"] = String(format: "2026-10-20T00:00:%02d.%03dZ", index / 1000, index % 1000)
            row["updatedAt"] = row["createdAt"]
            row["data"] = ["points": [["x": 0.2, "y": 0.3]], "fixturePayload": String(repeating: "x", count: 8192)]
            return row
        }
    }

    private func makeWriter(_ backend: Repository, _ bridge: Bridge, recovery: NativePDFEditRecovery? = nil,
                            coordinator: NativePDFFileCoordinator? = nil, instanceID: String = "") -> NativePDFPersistence {
        bridge.repository = backend
        return NativePDFPersistence(courseID: course, relativePath: "notes/a.pdf", documentRevision: revision,
            recovery: recovery, coordinator: coordinator, instanceID: instanceID, backend: backend.invoke, host: bridge.invoke)
    }
    private func stroke(sequence: Int) -> [String: Any] {
        ["operationSequence": sequence, "courseId": course, "relPath": "notes/a.pdf", "page": 1, "kind": "ink",
         "clientMutationId": UUID().uuidString, "documentRevision": revision,
         "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.5], ["x": 0.4, "y": 0.5, "p": 0.7]]],
         "style": ["color": "ink", "width": 0.003, "opacity": 1.0]]
    }
    private func erase(sequence: Int, mutation: String) -> [String: Any] {
        ["operationId": UUID().uuidString, "operationSequence": sequence, "originToolEpoch": 0,
         "documentRevision": revision, "page": 1, "targets": [["clientMutationId": mutation]]]
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("native-pdf-persistence-" + UUID().uuidString) }

    @MainActor private final class Repository {
        var annotationRows: [[String: Any]] = []
        var rows: [[String: Any]] = [], receipts: [String: [String: Any]] = [:]
        var createCalls = 0, deleteCalls = 0, updateCalls = 0, listCalls = 0, clock = 0
        var fullListCalls = 0, scopedListCalls = 0, pageListCalls = 0, maximumScopedRows = 0
        var beforeScopedReply: (() -> Void)?
        private func list(_ source: [[String: Any]], _ input: [String: Any]) -> [[String: Any]] {
            var selected = source
            if let ids = input["ids"] as? [String] {
                scopedListCalls += 1
                let wanted = Set(ids); selected = selected.filter { wanted.contains($0["id"] as? String ?? "") }
                maximumScopedRows = max(maximumScopedRows, selected.count)
            } else if let page = input["page"] as? Int {
                pageListCalls += 1; selected = selected.filter { $0["page"] as? Int == page }
            } else { fullListCalls += 1 }
            let result = selected.sorted { a, b in
                let pa = (a["page"] as? NSNumber)?.intValue ?? 0, pb = (b["page"] as? NSNumber)?.intValue ?? 0
                return pa != pb ? pa < pb : (a["createdAt"] as? String ?? "") < (b["createdAt"] as? String ?? "")
            }
            if input["ids"] != nil, let hook = beforeScopedReply { beforeScopedReply = nil; hook() }
            return result
        }
        /// Real rows carry ISO8601 stamps; strictly increasing so listing order is deterministic.
        private func stamp() -> String {
            clock += 1
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000 + Double(clock) * 0.001))
        }
        var failUpdateNumber: Int?
        var failAfterNextCreate = false, failDelete = false
        func invoke(_ channel: String, _ input: [String: Any]) async throws -> Any {
            await Task.yield()
            switch channel {
            case "annotations:listForFile": return list(annotationRows, input)
            case "annotations:create":
                var row = input; row["id"] = UUID().uuidString
                let created = stamp(); row["createdAt"] = created; row["updatedAt"] = created
                annotationRows.append(row); return row
            case "annotations:update":
                guard let index = annotationRows.firstIndex(where: { $0["id"] as? String == input["id"] as? String }) else { throw NativePDFError.invalid("Missing annotation") }
                annotationRows[index]["color"] = input["color"]; annotationRows[index]["comment"] = input["comment"]; return annotationRows[index]
            case "annotations:delete":
                annotationRows.removeAll { $0["id"] as? String == input["id"] as? String }; return [:]
            case "drawings:listForFile":
                listCalls += 1
                return list(rows, input)
            case "drawings:create":
                createCalls += 1
                let mutation = input["clientMutationId"] as? String
                if let mutation, let receipt = receipts[mutation] { return receipt }
                var row = input; row["id"] = UUID().uuidString
                row.removeValue(forKey: "clientMutationId"); row.removeValue(forKey: "documentRevision")
                let created = stamp(); row["createdAt"] = created; row["updatedAt"] = created
                rows.append(row)
                if let mutation { receipts[mutation] = row }
                if failAfterNextCreate { failAfterNextCreate = false; throw NativePDFError.invalid("Lost reply") }
                return row
            case "drawings:delete":
                deleteCalls += 1
                if failDelete { throw NativePDFError.invalid("Disk full") }
                let ids = Set(input["ids"] as? [String] ?? [])
                rows.removeAll { ($0["id"] as? String).map(ids.contains) == true }
                return ["ok": true]
            case "drawings:update":
                updateCalls += 1
                if failUpdateNumber == updateCalls { throw NativePDFError.invalid("Interrupted update") }
                guard let index = rows.firstIndex(where: { $0["id"] as? String == input["id"] as? String }) else { throw NativePDFError.invalid("Missing drawing") }
                rows[index]["data"] = input["data"]; rows[index]["style"] = input["style"]
                if let page = input["page"] { rows[index]["page"] = page }
                return rows[index]
            default: throw NativePDFError.invalid("Unexpected backend command: " + channel)
            }
        }
    }
    @MainActor private final class Bridge {
        weak var repository: Repository?
        var failAcknowledgement = false, acknowledgements = 0, eraseResults = 0
        func invoke(_ command: String, _ input: [String: Any]) async throws -> Any {
            await Task.yield()
            switch command {
            case "mutationStatus":
                let payload = input["input"] as? [String: Any] ?? [:]
                if let mutation = payload["clientMutationId"] as? String, let row = repository?.receipts[mutation], let id = row["id"] as? String {
                    let live = repository?.rows.contains { $0["id"] as? String == id } == true
                    return ["status": live ? "live" : "deleted", "drawingId": id]
                }
                return ["status": "missing"]
            case "ack":
                acknowledgements += 1
                if failAcknowledgement { failAcknowledgement = false; throw NativePDFError.invalid("Lost ACK") }
                return [:]
            case "eraseResult":
                eraseResults += 1
                return ["operationId": input["operationId"]!, "outcome": input["outcome"]!]
            default: throw NativePDFError.invalid("Unexpected host command: " + command)
            }
        }
    }
}
