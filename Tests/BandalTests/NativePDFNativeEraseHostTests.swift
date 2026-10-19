import XCTest
import UIKit
import WebKit
import PDFKit
@testable import Bandal

/// Exercises real Host callbacks, journal and display preparation. It does not
/// synthesize UIKit gesture arbitration or claim a WebKit/backend transaction.
@MainActor
final class NativePDFNativeEraseHostTests: XCTestCase {
    func testNativeEraseFiltersMixedDisplayWithoutMutatingCanonicalOrEditorBases() async throws {
        let f = try await Fixture(); defer { f.close() }
        var ink = Self.ink("saved-ink"); ink["clientMutationId"] = "previous-session-alias"
        let shape: [String: Any] = ["id": "shape", "page": 1, "kind": "rect",
            "data": ["box": ["x": 0.2, "y": 0.2, "width": 0.3, "height": 0.2]],
            "style": ["color": "red", "width": 0.01, "opacity": 1.0]]
        try await f.snapshot([ink, shape], epoch: 1, tool: "eraser")
        try await f.editor([ink, shape], epoch: 1, revision: 1)
        XCTAssertEqual(f.surface.objects.count, 2)
        XCTAssertTrue(f.surface.retainedInkEnabled)
        XCTAssertTrue(f.surface.nativeErasingEnabled)
        f.surface.onEraseBegin?()
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: "saved-ink", mutationID: "previous-session-alias")])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        XCTAssertEqual(erase["operationSequence"] as? Int, 1)
        XCTAssertEqual(erase["originToolEpoch"] as? Int, 1)
        XCTAssertNil((erase["targets"] as? [[String: Any]])?.first?["clientMutationId"], "Prior-session aliases must not block canonical deletion")
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["shape"])
        XCTAssertEqual(f.surface.objectVisualTokens?.count, 1, "Filter rows and tokens together, including CG fallback")
        let result = Self.result(erase, targets: [.init(drawingID: "saved-ink")])
        let ack = try await f.call("pdfNative:eraseResult", result)
        XCTAssertEqual(ack["operationId"] as? String, erase["operationId"] as? String)
        XCTAssertEqual(ack["operationSequence"] as? Int, 1)
        XCTAssertEqual(f.surface.erasedIdentifiers, ["saved-ink"], "ACK alone is not a presentation fence")
        // The old full snapshots remain accepted protocol bases; their deleted
        // row must stay filtered rather than altering the stored request.
        try await f.snapshot([ink, shape], epoch: 1, tool: "eraser")
        try await f.editor([ink, shape], epoch: 1, revision: 2)
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["shape"])
        try await f.snapshot([shape], epoch: 1, tool: "eraser")
        XCTAssertEqual(f.surface.erasedIdentifiers, ["saved-ink"])
        try await f.editor([shape], epoch: 1, revision: 3)
        XCTAssertTrue(f.surface.erasedIdentifiers.isEmpty)
        _ = try await f.call("pdfNative:eraseResult", result) // Lost ACK response.
        let undo = Self.ink("undo-new-id")
        try await f.snapshot([shape, undo], epoch: 1, tool: "eraser")
        try await f.editor([shape, undo], epoch: 1, revision: 4)
        XCTAssertEqual(f.surface.objects.compactMap { $0["id"] as? String }, ["shape", "undo-new-id"])
        XCTAssertEqual(f.events.filter { $0.type == "eraseCommit" }.count, 1)
    }

    func testLiveStrokeEraseOrderKeepsDurableRawBitsAndDoesNotDuplicateRecoveryLane() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let mutation = UUID().uuidString
        let points = [NativePDFPoint(x: 0.2, y: 0.3, p: 1.0 / 12345.0, t: 0, tiltX: -0.0, tiltY: 0.25),
                      NativePDFPoint(x: 0.4, y: 0.35, p: 17.0 / 12345.0, t: 11, tiltX: 0.1, tiltY: 0.2)]
        let stroke = NativePDFCompletedStroke(mutationID: mutation, kind: "ink", points: points,
            style: NativePDFInkStyle(color: "blue", width: 0.01, opacity: 0.45))
        try XCTUnwrap(f.surface.onStroke)(stroke)
        _ = try await f.call("pdfNative:flush", [:]) // Explicit durability barrier, not completion-callback timing.
        let emitted = try XCTUnwrap(f.events.last { $0.type == "stroke" }?.payload)
        XCTAssertEqual(emitted["operationSequence"] as? Int, 1)
        let durable = try NativePDFJournal(root: f.root).pending(courseID: "course", relativePath: "native-erase.pdf")
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(durable[0].input.data.points[0].p.bitPattern, points[0].p.bitPattern)
        XCTAssertEqual(durable[0].input.data.points[0].tiltX?.bitPattern, points[0].tiltX?.bitPattern)
        try await f.snapshot([], epoch: 2, tool: "eraser")
        f.surface.onEraseBegin?()
        // A callback that seals after the next toolbar snapshot keeps the
        // original contact's epoch, not whichever tool happens to be current.
        try await f.snapshot([], epoch: 3, tool: "eraser")
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: mutation, mutationID: mutation)])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        XCTAssertEqual(erase["operationSequence"] as? Int, 2)
        XCTAssertEqual(erase["originToolEpoch"] as? Int, 2)
        let targets = try XCTUnwrap(erase["targets"] as? [[String: Any]])
        XCTAssertNil(targets[0]["drawingId"], "A pending placeholder is not a canonical backend drawing ID")
        XCTAssertEqual(targets[0]["clientMutationId"] as? String, mutation)
        let flush = try await f.call("pdfNative:flush", [:])
        XCTAssertEqual((flush["pending"] as? [[String: Any]])?.count, 0)
        let ordered = try XCTUnwrap(flush["pendingOperations"] as? [[String: Any]])
        XCTAssertEqual(ordered.compactMap { $0["type"] as? String }, ["stroke", "eraseCommit"])
        XCTAssertEqual(ordered.compactMap { $0["operationSequence"] as? Int }, [1, 2])
        XCTAssertEqual(flush["throughOperationSequence"] as? Int, 2)
        _ = try await f.call("pdfNative:ack", ["clientMutationId": mutation, "drawingId": "canonical-new"])
        let resolved = NativePDFEraseTarget(drawingID: "canonical-new", mutationID: mutation)
        _ = try await f.call("pdfNative:eraseResult", Self.result(erase, targets: [resolved]))
        XCTAssertEqual(Set(f.surface.erasedIdentifiers), ["canonical-new", mutation])
        XCTAssertTrue(try NativePDFJournal(root: f.root).pending(courseID: "course", relativePath: "native-erase.pdf").isEmpty)
        var canonical = Self.ink("canonical-new"); canonical["clientMutationId"] = mutation
        try await f.snapshot([canonical], epoch: 3, tool: "eraser")
        XCTAssertTrue(f.surface.objects.isEmpty, "Late create cannot reveal an already erased native contact")
        try await f.snapshot([], epoch: 4, tool: "pen")
        XCTAssertTrue(f.surface.erasedIdentifiers.isEmpty)
        XCTAssertTrue(f.surface.objects.isEmpty)
        let final = try await f.call("pdfNative:flush", [:])
        XCTAssertEqual((final["pendingOperations"] as? [[String: Any]])?.count, 0)
    }


    func testPlaceholderTargetResolvesToAcknowledgedDrawingWhenAckLandsMidContact() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let mutation = UUID().uuidString
        let stroke = NativePDFCompletedStroke(mutationID: mutation, kind: "ink",
            points: [NativePDFPoint(x: 0.2, y: 0.3, p: 0.5, t: 0), NativePDFPoint(x: 0.4, y: 0.35, p: 0.5, t: 11)],
            style: NativePDFInkStyle(color: "blue", width: 0.01, opacity: 0.45))
        try XCTUnwrap(f.surface.onStroke)(stroke)
        _ = try await f.call("pdfNative:flush", [:])
        try await f.snapshot([], epoch: 2, tool: "eraser")
        f.surface.onEraseBegin?()
        // The ACK and the canonical row land while the eraser is still down. The
        // frozen scene still reports the placeholder, which must not be a mismatch.
        _ = try await f.call("pdfNative:ack", ["clientMutationId": mutation, "drawingId": "canonical-new"])
        try await f.snapshot([Self.ink("canonical-new")], epoch: 2, tool: "eraser")
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: mutation, mutationID: mutation)])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        let targets = try XCTUnwrap(erase["targets"] as? [[String: Any]])
        XCTAssertEqual(targets[0]["drawingId"] as? String, "canonical-new")
        XCTAssertEqual(targets[0]["clientMutationId"] as? String, mutation)
    }
    func testErasedPendingStrokeStaysHiddenWhenItsOwnAckAndCanonicalRowLandFirst() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let mutation = UUID().uuidString
        let stroke = NativePDFCompletedStroke(mutationID: mutation, kind: "ink",
            points: [NativePDFPoint(x: 0.2, y: 0.3, p: 0.5, t: 0), NativePDFPoint(x: 0.4, y: 0.35, p: 0.5, t: 11)],
            style: NativePDFInkStyle(color: "blue", width: 0.01, opacity: 0.45))
        try XCTUnwrap(f.surface.onStroke)(stroke)
        _ = try await f.call("pdfNative:flush", [:])
        try await f.snapshot([], epoch: 2, tool: "eraser")
        f.surface.onEraseBegin?()
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: mutation, mutationID: mutation)])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        XCTAssertTrue(f.surface.objects.isEmpty)
        // The ordered drain saves the stroke before the erase: ACK, then the canonical row arrives.
        _ = try await f.call("pdfNative:ack", ["clientMutationId": mutation, "drawingId": "canonical-new"])
        try await f.snapshot([Self.ink("canonical-new")], epoch: 2, tool: "eraser")
        XCTAssertTrue(f.surface.objects.isEmpty, "an erased stroke must not reappear between its ACK and the erase result")
        _ = try await f.call("pdfNative:eraseResult", Self.result(erase, targets: [.init(drawingID: "canonical-new", mutationID: mutation)]))
        try await f.snapshot([], epoch: 2, tool: "eraser")
        XCTAssertTrue(f.surface.objects.isEmpty)
    }

    func testSlowJournalDoesNotBlockAdmissionAndEraseCannotPublishStrokeBeforeDurability() async throws {
        let probe = DiskProbe(); probe.blockFinal = true
        let f = try await Fixture(queueFactory: { root in
            NativePDFJournalQueue(storageFactory: { try ProbedJournal(root: root, probe: probe) })
        })
        defer { probe.release.signal(); f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let stroke = Self.stroke()
        let started = CACurrentMediaTime()
        try XCTUnwrap(f.surface.onStroke)(stroke)
        XCTAssertLessThan(CACurrentMediaTime() - started, 0.2, "Input admission must not wait on a deliberately blocked disk writer")
        try await wait { probe.finalStarted }
        XCTAssertTrue(f.events.filter { $0.type == "stroke" }.isEmpty)
        XCTAssertEqual(f.journalQueue.state.completed.value, 0)
        XCTAssertEqual(f.surface.objects.last?["clientMutationId"] as? String, stroke.mutationID)
        do {
            _ = try await f.call("pdfNative:ack", ["clientMutationId": stroke.mutationID, "drawingId": "too-early"])
            XCTFail("An undurable reserved stroke cannot be acknowledged")
        } catch {}
        try await f.snapshot([], epoch: 2, tool: "eraser")
        f.surface.onEraseBegin?()
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: stroke.mutationID, mutationID: stroke.mutationID)])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        XCTAssertEqual(erase["operationSequence"] as? Int, 2)
        XCTAssertTrue(f.events.filter { $0.type == "stroke" }.isEmpty, "JS may receive erase #2 first and must await durable #1")
        probe.release.signal()
        let flushed = try await f.call("pdfNative:flush", [:])
        XCTAssertEqual(flushed["throughOperationSequence"] as? Int, 2)
        let operations = try XCTUnwrap(flushed["pendingOperations"] as? [[String: Any]])
        XCTAssertEqual(operations.compactMap { $0["type"] as? String }, ["stroke", "eraseCommit"])
        XCTAssertEqual(operations.compactMap { $0["operationSequence"] as? Int }, [1, 2])
        XCTAssertEqual((flushed["pending"] as? [Any])?.count, 0)
        XCTAssertEqual(f.events.filter { $0.type == "stroke" }.count, 1)
        try Self.assertDurable(stroke, root: f.root)
        XCTAssertFalse(probe.sawMainThread)
        XCTAssertFalse(probe.timedOut)
    }

    func testSynchronousRecoveryFenceReconcilesTicketWithoutWaitingForMainCallback() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let stroke = Self.stroke()
        try XCTUnwrap(f.surface.onStroke)(stroke)
        // No await occurs between admission and this fence. The queued main
        // completion cannot run; the explicit fence must reconcile its ticket.
        XCTAssertTrue(f.events.filter { $0.type == "stroke" }.isEmpty)
        try f.host.flushForRecovery()
        XCTAssertEqual(f.events.filter { $0.type == "stroke" }.count, 1)
        XCTAssertEqual(f.journalQueue.state.issued, f.journalQueue.state.completed)
        try Self.assertDurable(stroke, root: f.root)
        let response = try await f.call("pdfNative:flush", [:])
        XCTAssertEqual(response["throughOperationSequence"] as? Int, 1)
        XCTAssertEqual((response["pendingOperations"] as? [Any])?.count, 1)
        await Task.yield()
        XCTAssertEqual(f.events.filter { $0.type == "stroke" }.count, 1, "The delayed notification must not emit the same ticket twice")
    }

    func testFailedCloseKeepsRawInputAndExplicitRetryDrainsSameOperation() async throws {
        let probe = DiskProbe(); probe.failFinal = true
        let f = try await Fixture(queueFactory: { root in
            NativePDFJournalQueue(storageFactory: { try ProbedJournal(root: root, probe: probe) })
        })
        defer { probe.failFinal = false; f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let stroke = Self.stroke()
        try XCTUnwrap(f.surface.onStroke)(stroke)
        try await wait { f.journalQueue.state.failedTicket != nil }
        do { _ = try await f.call("pdfNative:close", [:]); XCTFail("Failed durable close must leave the generation available for retry") } catch {}
        XCTAssertEqual(f.journalQueue.state.queuedJobs, 1)
        XCTAssertEqual(f.surface.objects.last?["clientMutationId"] as? String, stroke.mutationID)
        XCTAssertTrue(f.events.filter { $0.type == "stroke" }.isEmpty)
        _ = try await f.call("pdfNative:diagnostics", [:]) // Still the original live generation.
        probe.failFinal = false
        let response = try await f.call("pdfNative:flush", [:])
        XCTAssertEqual(response["throughOperationSequence"] as? Int, 1)
        XCTAssertEqual((response["pendingOperations"] as? [Any])?.count, 1)
        XCTAssertEqual(f.events.filter { $0.type == "stroke" }.count, 1)
        XCTAssertEqual(f.journalQueue.state.queuedJobs, 0)
        try Self.assertDurable(stroke, root: f.root)
        _ = try await f.call("pdfNative:close", [:])
        try Self.assertDurable(stroke, root: f.root)
    }

    func testRetiredHostReconcilesDiskWithoutDeliveringOldGenerationCallback() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let stroke = Self.stroke()
        try XCTUnwrap(f.surface.onStroke)(stroke)
        // No yield: the completion notification is still enqueued on main.
        f.host.closeAll()
        XCTAssertTrue(f.events.filter { $0.type == "stroke" }.isEmpty)
        try Self.assertDurable(stroke, root: f.root)
        var next = f.identity; next["generation"] = "two"
        let openedValue = try await f.host.handle("pdfNative:open", request: next)
        let opened = try XCTUnwrap(openedValue as? [String: Any])
        let pending = try XCTUnwrap(opened["pending"] as? [[String: Any]])
        XCTAssertEqual(pending.compactMap { $0["clientMutationId"] as? String }, [stroke.mutationID])
        await Task.yield()
        XCTAssertTrue(f.events.filter { $0.type == "stroke" }.isEmpty, "Late notification cannot target either the retired or the replacement renderer")
        let ack = next.merging(["clientMutationId": stroke.mutationID, "drawingId": "recovered-canonical"]) { _, new in new }
        _ = try await f.host.handle("pdfNative:ack", request: ack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.journalURL(stroke, root: f.root).path))
    }

    func testReplacementBindingWaitKeepsOldAckValidAndCapturesLateInput() async throws {
        let binding = BindingGate()
        let f = try await Fixture(binding: binding); defer { binding.release(); f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let acknowledged = Self.stroke(), late = Self.stroke()
        try XCTUnwrap(f.surface.onStroke)(acknowledged)
        _ = try await f.call("pdfNative:flush", [:])
        binding.hold = true
        var next = f.identity; next["generation"] = "two"
        let opening = Task { @MainActor in try await f.host.handle("pdfNative:open", request: next) }
        try await wait { binding.entered }
        // Preparing a replacement is not retirement: old durable ACK remains
        // valid and further measured input still belongs to the visible view.
        _ = try await f.call("pdfNative:ack", ["clientMutationId": acknowledged.mutationID, "drawingId": "already-saved"])
        try XCTUnwrap(f.surface.onStroke)(late)
        _ = try await f.call("pdfNative:flush", [:])
        XCTAssertEqual(f.events.filter { $0.type == "stroke" }.count, 2)
        binding.release()
        let openedValue = try await opening.value
        let opened = try XCTUnwrap(openedValue as? [String: Any])
        let pending = try XCTUnwrap(opened["pending"] as? [[String: Any]])
        XCTAssertEqual(pending.compactMap { $0["clientMutationId"] as? String }, [late.mutationID])
        try Self.assertDurable(late, root: f.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.journalURL(acknowledged, root: f.root).path))
        do { _ = try await f.call("pdfNative:diagnostics", [:]); XCTFail("Only successful replacement retires the old generation") } catch {}
    }

    func testFailedReplacementDoesNotStrandPendingEraseAcknowledgement() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.snapshot([Self.ink("old")], epoch: 1, tool: "eraser")
        f.surface.onEraseBegin?()
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: "old")])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        var next = f.identity; next["generation"] = "two"
        do { _ = try await f.host.handle("pdfNative:open", request: next); XCTFail("Replacement cannot discard an unresolved native erase") } catch {}
        // This request must still be owned by the original renderer after the
        // failed replacement. ACKing it permits a later, explicit close/open.
        _ = try await f.call("pdfNative:eraseResult", Self.result(erase, targets: [.init(drawingID: "old")]))
        _ = try await f.call("pdfNative:diagnostics", [:])
        _ = try await f.host.handle("pdfNative:open", request: next)
    }


    func testFailedReplacementRestoresVisibilityChangedDuringBindingWaitAndOldAck() async throws {
        let binding = BindingGate()
        let f = try await Fixture(binding: binding); defer { binding.release(); f.close() }
        try await f.snapshot([Self.ink("old")], epoch: 1, tool: "eraser")
        let body = try XCTUnwrap(f.controller.view.subviews.compactMap { $0 as? NativePDFApertureView }.first)
        let document = try XCTUnwrap(body.document)
        f.surface.onEraseBegin?()
        try XCTUnwrap(f.surface.onErase)([.init(drawingID: "old")])
        let erase = try XCTUnwrap(f.events.last { $0.type == "eraseCommit" }?.payload)
        let rect: [String: Double] = ["x": 0, "y": 0, "width": 600, "height": 700]
        _ = try await f.call("pdfNative:layout", ["revision": 1, "visible": false, "rect": rect])
        XCTAssertNil(body.document)
        binding.hold = true
        var next = f.identity; next["generation"] = "two"
        let opening = Task { @MainActor in try await f.host.handle("pdfNative:open", request: next) }
        try await wait { binding.entered }
        _ = try await f.call("pdfNative:layout", ["revision": 2, "visible": true, "rect": rect])
        XCTAssertTrue(body.document === document)
        XCTAssertFalse(body.isHidden)
        binding.release()
        do { _ = try await opening.value; XCTFail("Unresolved erase must reject replacement") } catch {}
        let diagnostics = try await f.call("pdfNative:diagnostics", [:])
        XCTAssertEqual(diagnostics["suspended"] as? Bool, false)
        XCTAssertTrue(body.document === document, "Restore the latest visible state, not the hidden state when open began")
        XCTAssertFalse(body.isHidden)
        XCTAssertTrue(body.isUserInteractionEnabled)
        _ = try await f.call("pdfNative:eraseResult", Self.result(erase, targets: [.init(drawingID: "old")]))
    }

    func testReplacementDiskWaitRetainsLatestHiddenLayoutOnFailure() async throws {
        let probe = DiskProbe(); probe.blockFinal = true; probe.failFinal = true
        let f = try await Fixture(queueFactory: { root in
            NativePDFJournalQueue(storageFactory: { try ProbedJournal(root: root, probe: probe) })
        })
        defer { probe.failFinal = false; probe.release.signal(); f.close() }
        try await f.snapshot([], epoch: 1, tool: "pen")
        let body = try XCTUnwrap(f.controller.view.subviews.compactMap { $0 as? NativePDFApertureView }.first)
        let stroke = Self.stroke()
        try XCTUnwrap(f.surface.onStroke)(stroke)
        try await wait { probe.finalStarted }
        var next = f.identity; next["generation"] = "two"
        let opening = Task { @MainActor in try await f.host.handle("pdfNative:open", request: next) }
        try await wait { body.document == nil } // Actual replacement freeze, before its disk fence resolves.
        let reply = try await f.call("pdfNative:layout", ["revision": 7, "visible": false,
            "rect": ["x": 0.0, "y": 0.0, "width": 500.0, "height": 650.0]])
        XCTAssertEqual(reply["revision"] as? Int, 7, "Frozen replacement must retain, not ignore, newer layout authority")
        XCTAssertNil(body.document, "The newer layout cannot resume input during the disk snapshot")
        probe.release.signal()
        do { _ = try await opening.value; XCTFail("Injected final write failure must reject replacement") } catch {}
        let diagnostics = try await f.call("pdfNative:diagnostics", [:])
        XCTAssertEqual(diagnostics["suspended"] as? Bool, true)
        XCTAssertNil(body.document)
        XCTAssertTrue(body.isHidden)
        XCTAssertFalse(body.isUserInteractionEnabled)
        XCTAssertEqual(f.journalQueue.state.queuedJobs, 1)
        probe.failFinal = false
        _ = try await f.call("pdfNative:flush", [:])
        try Self.assertDurable(stroke, root: f.root)
    }

    private func wait(_ predicate: () async throws -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 5
        while !(try await predicate()), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = try await predicate()
        XCTAssertTrue(satisfied, "Expected journal/Host state did not arrive within the functional deadline")
    }
    private static func stroke() -> NativePDFCompletedStroke {
        .init(mutationID: UUID().uuidString, kind: "ink", points: [
            .init(x: 0.2, y: 0.3, p: 1.0 / 12345.0, t: 0, tiltX: -0.0, tiltY: 0.25),
            .init(x: 0.4, y: 0.35, p: 17.0 / 12345.0, t: 11, tiltX: 0.1, tiltY: 0.2)],
            style: .init(color: "blue", width: 0.01, opacity: 0.45))
    }
    private static func journalURL(_ stroke: NativePDFCompletedStroke, root: URL) -> URL {
        root.appendingPathComponent("PendingNativePDFInk").appendingPathComponent(stroke.mutationID + ".json")
    }
    private static func assertDurable(_ stroke: NativePDFCompletedStroke, root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        // Read only after an explicit worker fence; this decoder is an oracle,
        // not a second live NativePDFJournal owner.
        let record = try JSONDecoder().decode(NativePDFPendingStroke.self, from: Data(contentsOf: journalURL(stroke, root: root)))
        XCTAssertNil(record.provisional, file: file, line: line)
        XCTAssertEqual(record.input.clientMutationId, stroke.mutationID, file: file, line: line)
        XCTAssertEqual(record.input.data.points.count, stroke.points.count, file: file, line: line)
        for (actual, expected) in zip(record.input.data.points, stroke.points) {
            XCTAssertEqual(actual.x.bitPattern, expected.x.bitPattern, file: file, line: line)
            XCTAssertEqual(actual.y.bitPattern, expected.y.bitPattern, file: file, line: line)
            XCTAssertEqual(actual.p.bitPattern, expected.p.bitPattern, file: file, line: line)
            XCTAssertEqual(actual.t?.bitPattern, expected.t?.bitPattern, file: file, line: line)
            XCTAssertEqual(actual.tiltX?.bitPattern, expected.tiltX?.bitPattern, file: file, line: line)
            XCTAssertEqual(actual.tiltY?.bitPattern, expected.tiltY?.bitPattern, file: file, line: line)
        }
    }
    @MainActor private final class BindingGate {
        var hold = false, entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func waitIfHeld() async {
            guard hold else { return }
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { hold = false; continuation?.resume(); continuation = nil }
    }
    private final class DiskProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var block = false, fail = false, started = false, main = false, timeout = false
        let release = DispatchSemaphore(value: 0)
        var blockFinal: Bool { get { locked { block } } set { locked { block = newValue } } }
        var failFinal: Bool { get { locked { fail } } set { locked { fail = newValue } } }
        var finalStarted: Bool { locked { started } }
        var sawMainThread: Bool { locked { main } }
        var timedOut: Bool { locked { timeout } }
        func beforeFinal() throws {
            let shouldBlock: Bool = locked {
                main = main || Thread.isMainThread
                let value = block && !started; started = true; return value
            }
            if shouldBlock, release.wait(timeout: .now() + 10) == .timedOut {
                locked { timeout = true }; throw NativePDFError.invalid("Synthetic blocked writer timed out")
            }
            if failFinal { throw NativePDFError.invalid("Synthetic disk failure") }
        }
        private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    }
    private final class ProbedJournal: NativePDFJournalQueueStorage {
        let journal: NativePDFJournal, probe: DiskProbe
        init(root: URL, probe: DiskProbe) throws { journal = try NativePDFJournal(root: root); self.probe = probe }
        func append(_ input: NativePDFStrokeInput, documentRevision: String) throws {
            try probe.beforeFinal(); try journal.append(input, documentRevision: documentRevision)
        }
        func checkpoint(_ input: NativePDFStrokeInput, documentRevision: String) throws { try journal.checkpoint(input, documentRevision: documentRevision) }
        func acknowledge(_ mutationID: String, courseID: String, relativePath: String) throws { try journal.acknowledge(mutationID, courseID: courseID, relativePath: relativePath) }
        func pending(courseID: String, relativePath: String) throws -> [NativePDFPendingStroke] { try journal.pending(courseID: courseID, relativePath: relativePath) }
        var timingStatistics: [String: NativePDFLatencySamples] { journal.timingStatistics }
    }

    private static func result(_ erase: [String: Any], targets: [NativePDFEraseTarget]) -> [String: Any] {
        var result = erase; result.removeValue(forKey: "targets")
        result["outcome"] = "committed"; result["resolvedTargets"] = targets.map(\.json)
        return result
    }
    private static func ink(_ id: String) -> [String: Any] {
        let points: [[String: Double]] = [["x": 0.1, "y": 0.3, "p": 0.4, "t": 0], ["x": 0.8, "y": 0.3, "p": 0.7, "t": 10]]
        return ["id": id, "page": 1, "kind": "ink", "data": ["inkVersion": 4, "points": points],
            "style": ["color": "blue", "width": 0.01, "opacity": 0.45]]
    }
    @MainActor private final class Fixture {
        struct Event { let type: String; let payload: [String: Any] }
        let root: URL, window: UIWindow, controller: UIViewController, host: NativePDFHost
        let journalQueue: NativePDFJournalQueue
        let previous: UIWindow?, oldEnabled: Any?
        let identity: [String: Any] = ["surfaceId": "native-erase", "generation": "one", "courseId": "course", "relPath": "native-erase.pdf"]
        private(set) var surface: NativePDFInkSurface!
        private(set) var events: [Event] = []
        init(queueFactory: ((URL) -> NativePDFJournalQueue)? = nil, binding: BindingGate? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("native-erase-host-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("native-erase.pdf")
            try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { $0.beginPage() }.write(to: url)
            oldEnabled = UserDefaults.standard.object(forKey: "bandal.nativePDF.enabled")
            UserDefaults.standard.set(true, forKey: "bandal.nativePDF.enabled")
            let deadline = CACurrentMediaTime() + 2
            while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
                  CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene); controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible(); window.layoutIfNeeded()
            let shell = WKWebView(frame: controller.view.bounds); controller.view.addSubview(shell)
            journalQueue = queueFactory?(root) ?? NativePDFJournalQueue(root: root)
            let originalsRoot = root
            host = try NativePDFHost(root: root, journalQueue: journalQueue) { channel, request in
                if channel == "nativePDF:binding" {
                    await binding?.waitIfHeld()
                    return try NativePDFTestBinding.respond(root: originalsRoot, file: url, materialID: "native-erase")
                }
                XCTAssertEqual(channel, "nativeMaterial:path"); return url.path
            }
            host.attach(to: controller.view, shell: shell)
            host.emit = { [weak self] channel, raw in
                guard channel == "pdfNative:event", let event = raw as? [String: Any],
                      let type = event["type"] as? String, let payload = event["payload"] as? [String: Any] else { return }
                self?.events.append(.init(type: type, payload: payload))
            }
            let state = try await call("pdfNative:open", [:])
            XCTAssertEqual(state["documentRevision"] as? String, state["revision"] as? String)
            XCTAssertNotNil(state["documentRevision"] as? String)
            _ = try await call("pdfNative:layout", ["visible": true, "rect": ["x": 0.0, "y": 0.0, "width": 600.0, "height": 700.0]])
            try await snapshot([], epoch: 0, tool: "eraser")
            let attachedDeadline = CACurrentMediaTime() + 5
            while CACurrentMediaTime() < attachedDeadline {
                controller.view.layoutIfNeeded(); host.layout()
                if let value = Self.find(controller.view).first, value.mapper != nil { surface = value; break }
                try await Task.sleep(for: .milliseconds(10))
            }
            surface = try XCTUnwrap(surface)
        }
        func call(_ channel: String, _ payload: [String: Any]) async throws -> [String: Any] {
            let result = try await host.handle(channel, request: identity.merging(payload) { _, new in new })
            return try XCTUnwrap(result as? [String: Any])
        }
        func snapshot(_ rows: [[String: Any]], epoch: Int, tool: String) async throws {
            _ = try await call("pdfNative:snapshot", ["nativeInkErase": true, "objectSceneEpoch": epoch,
                "loading": false, "active": true, "drawings": rows, "annotations": [],
                "tool": ["name": tool, "style": ["color": "blue", "width": 0.01, "opacity": 0.45]]])
        }
        func editor(_ rows: [[String: Any]], epoch: Int, revision: Int) async throws {
            _ = try await call("pdfNative:objectScene", ["page": 1, "objects": rows,
                "objectSceneEpoch": epoch, "objectSceneRevision": revision])
        }
        func close() {
            host.closeAll(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            UserDefaults.standard.set(oldEnabled, forKey: "bandal.nativePDF.enabled")
            NativePDFObjectRenderer.releaseInkPaths(); try? FileManager.default.removeItem(at: root)
        }
        private static func find(_ view: UIView) -> [NativePDFInkSurface] {
            if let surface = view as? NativePDFInkSurface { return [surface] }
            return view.subviews.flatMap { find($0) }
        }
    }
}
