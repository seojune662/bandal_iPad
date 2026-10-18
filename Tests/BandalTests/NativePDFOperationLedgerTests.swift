import XCTest
@testable import Bandal

@MainActor
final class NativePDFOperationLedgerTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)

    func testStrokeEraseStrokeHaveOneGenerationOrderAndCompletionRetriesReuseSequence() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let a = input(), b = input()
        let first = try ledger.recordStroke(a)
        let deletion = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 4, page: 1,
            targets: [.init(drawingID: "old")])
        let last = try ledger.recordStroke(b)
        XCTAssertEqual(first["operationSequence"] as? Int, 1)
        XCTAssertEqual(deletion["operationSequence"] as? Int, 2)
        XCTAssertEqual(last["operationSequence"] as? Int, 3)
        XCTAssertEqual(ledger.pendingOperations.compactMap { $0["type"] as? String }, ["stroke", "eraseCommit", "stroke"])
        XCTAssertEqual(try ledger.recordStroke(a)["operationSequence"] as? Int, 1)
        XCTAssertEqual(ledger.throughOperationSequence, 3)
        var different = a; different.data.points[0].p = 0.75
        XCTAssertThrowsError(try ledger.recordStroke(different))
        try ledger.acknowledgeStroke(mutationID: a.clientMutationId, drawingID: "saved-a")
        XCTAssertEqual(ledger.pendingOperations.compactMap { $0["operationSequence"] as? Int }, [2, 3])
        XCTAssertTrue(ledger.containsLiveStroke(a.clientMutationId), "Flush must not replay a sequenced journal through the recovery lane")
        XCTAssertFalse(ledger.containsLiveStroke(UUID().uuidString))
        XCTAssertThrowsError(try ledger.acknowledgeStroke(mutationID: a.clientMutationId, drawingID: "wrong"))
        XCTAssertEqual(ledger.drawingID(for: a.clientMutationId), "saved-a")
    }

    func testCommittedEraseRetainsTombstoneUntilBothPostAckStreamsExcludeTarget() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let target = NativePDFEraseTarget(drawingID: "D", mutationID: "00000000-0000-4000-8000-000000000001")
        ledger.observeCanonical([row("D", mutation: "00000000-0000-4000-8000-000000000001")])
        ledger.observeEditor(page: 1, objects: [row("D")])
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 2, page: 1, targets: [target])
        // Already-absent states from before the result are insufficient.
        ledger.observeCanonical([]); ledger.observeEditor(page: 1, objects: [])
        let result = response(erase, targets: [target])
        try ledger.acceptEraseResult(result)
        XCTAssertEqual(ledger.pendingEraseCount, 0)
        XCTAssertEqual(Set(ledger.excludedIdentifiers(page: 1)), ["D", "00000000-0000-4000-8000-000000000001"])
        ledger.observeCanonical([])
        XCTAssertEqual(ledger.tombstoneCount, 1)
        ledger.observeEditor(page: 2, objects: [])
        XCTAssertEqual(ledger.tombstoneCount, 1, "Another page cannot satisfy this page's editor fence")
        ledger.observeEditor(page: 1, objects: [row("D")])
        XCTAssertEqual(ledger.tombstoneCount, 1)
        ledger.observeEditor(page: 1, objects: [])
        XCTAssertEqual(ledger.tombstoneCount, 0)
        XCTAssertEqual(ledger.takeRetiredTargets(), [target])
        XCTAssertTrue(ledger.takeRetiredTargets().isEmpty)
        try ledger.acceptEraseResult(result) // Lost result reply after retirement.
        var changed = result; changed["outcome"] = "unknown"
        XCTAssertThrowsError(try ledger.acceptEraseResult(changed))
    }

    func testNeverObservedCanonicalRowStaysHiddenAndUndoNewIdentityIsNotHidden() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let target = NativePDFEraseTarget(drawingID: "deleted")
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 1, page: 1, targets: [target])
        try ledger.acceptEraseResult(response(erase, targets: [target]))
        for _ in 0..<3 { ledger.observeCanonical([]); ledger.retireEditors() }
        XCTAssertEqual(ledger.excludedIdentifiers(page: 1), ["deleted"])
        ledger.observeCanonical([row("undo-new-id")])
        XCTAssertFalse(ledger.excludedIdentifiers(page: 1).contains("undo-new-id"))
        // An old create snapshot arriving late cannot make the deleted row flash.
        ledger.observeCanonical([row("deleted")])
        XCTAssertEqual(ledger.tombstoneCount, 1)
        ledger.observeCanonical([row("undo-new-id")])
        XCTAssertEqual(ledger.tombstoneCount, 0)
    }

    func testUnknownResultIsIdempotentStaysPendingAndDoesNotBlockLaterStrokeOrdering() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let target = NativePDFEraseTarget(drawingID: "D")
        ledger.observeCanonical([row("D")])
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 9, page: 1, targets: [target])
        let unknown = response(erase, targets: [target], outcome: "unknown")
        try ledger.acceptEraseResult(unknown); try ledger.acceptEraseResult(unknown)
        ledger.observeCanonical([]); ledger.retireEditors()
        XCTAssertEqual(ledger.pendingEraseCount, 1)
        XCTAssertEqual(ledger.excludedIdentifiers(page: 1), ["D"])
        XCTAssertEqual(try ledger.recordStroke(input())["operationSequence"] as? Int, 2)
        XCTAssertEqual(ledger.pendingOperations.compactMap { $0["type"] as? String }, ["eraseCommit", "stroke"])
        XCTAssertThrowsError(try ledger.acceptEraseResult(response(erase, targets: [target])),
                             "An unknown operation cannot silently become a second remove attempt")
    }

    func testPendingMutationResolutionRequiresExactNativeStrokeAcknowledgement() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let stroke = input(); _ = try ledger.recordStroke(stroke)
        let original = NativePDFEraseTarget(mutationID: stroke.clientMutationId)
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 4, page: 1, targets: [original])
        let resolved = NativePDFEraseTarget(drawingID: "saved", mutationID: stroke.clientMutationId)
        XCTAssertThrowsError(try ledger.acceptEraseResult(response(erase, targets: [resolved])))
        try ledger.acknowledgeStroke(mutationID: stroke.clientMutationId, drawingID: "saved")
        XCTAssertThrowsError(try ledger.acceptEraseResult(response(erase,
            targets: [.init(drawingID: "foreign", mutationID: stroke.clientMutationId)])))
        try ledger.acceptEraseResult(response(erase, targets: [resolved]))
        XCTAssertEqual(Set(ledger.excludedIdentifiers(page: 1)), ["saved", stroke.clientMutationId])
        XCTAssertTrue(ledger.pendingOperations.isEmpty)
    }

    func testMutationOnlyEraseHidesTheAcknowledgedDrawingBeforeTheEraseResult() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let stroke = input(); _ = try ledger.recordStroke(stroke)
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 4, page: 1,
            targets: [.init(mutationID: stroke.clientMutationId)])
        XCTAssertEqual(ledger.excludedIdentifiers(page: 1), [stroke.clientMutationId])
        // The stroke's own save lands first: its canonical row carries only the drawing id.
        try ledger.acknowledgeStroke(mutationID: stroke.clientMutationId, drawingID: "saved")
        XCTAssertEqual(Set(ledger.excludedIdentifiers(page: 1)), ["saved", stroke.clientMutationId],
            "the erased stroke must not reappear between its ACK and the erase result")
        try ledger.acceptEraseResult(response(erase, targets: [.init(drawingID: "saved", mutationID: stroke.clientMutationId)]))
        XCTAssertEqual(Set(ledger.excludedIdentifiers(page: 1)), ["saved", stroke.clientMutationId])
    }

    func testResultEnvelopeAndOrderedTargetsAreValidatedAtomically() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let targets: [NativePDFEraseTarget] = [.init(drawingID: "a"), .init(drawingID: "b")]
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 7, page: 2, targets: targets)
        let good = response(erase, targets: targets)
        let invalid: [(String, Any)] = [
            ("operationId", UUID().uuidString), ("operationSequence", 2), ("operationSequence", true),
            ("originToolEpoch", 8), ("page", 1), ("documentRevision", String(repeating: "b", count: 64)),
            ("outcome", "failed"), ("resolvedTargets", targets.reversed().map(\.json)),
            ("resolvedTargets", [["drawingId": "a"], ["drawingId": "a"]]),
            ("resolvedTargets", [["drawingId": "a", "clientMutationId": "injected"], ["drawingId": "b"]])
        ]
        for (key, value) in invalid {
            var request = good; request[key] = value
            XCTAssertThrowsError(try ledger.acceptEraseResult(request), key)
            XCTAssertEqual(ledger.pendingEraseCount, 1)
            XCTAssertEqual(ledger.excludedIdentifiers(page: 2), ["a", "b"])
        }
        var withUntrustedExtras = good
        withUntrustedExtras["eraseApproved"] = true
        withUntrustedExtras["nativeTargets"] = ["unrelated"]
        try ledger.acceptEraseResult(withUntrustedExtras)
        XCTAssertEqual(ledger.pendingEraseCount, 0, "Only the explicit envelope/target proof influences acceptance")
    }

    func testEraseRetryKeepsOriginalEpochSequenceAndRejectsChangedInput() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let id = UUID().uuidString, targets: [NativePDFEraseTarget] = [.init(drawingID: "a")]
        let original = try ledger.recordErase(operationID: id, originToolEpoch: 3, page: 1, targets: targets)
        let retried = try ledger.recordErase(operationID: id, originToolEpoch: 3, page: 1, targets: targets)
        XCTAssertEqual(original["operationSequence"] as? Int, retried["operationSequence"] as? Int)
        XCTAssertThrowsError(try ledger.recordErase(operationID: id, originToolEpoch: 4, page: 1, targets: targets))
        XCTAssertThrowsError(try ledger.recordErase(operationID: id, originToolEpoch: 3, page: 2, targets: targets))
        XCTAssertThrowsError(try ledger.recordErase(operationID: id, originToolEpoch: 3, page: 1, targets: [.init(drawingID: "b")]))
        XCTAssertEqual(ledger.throughOperationSequence, 1)
        // Later tool epochs do not invalidate an already issued operation ACK.
        _ = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 8, page: 1,
                                   targets: [.init(drawingID: "different")])
        try ledger.acceptEraseResult(response(original, targets: targets))
        XCTAssertEqual(ledger.pendingEraseCount, 1)
    }

    func testInvalidTargetsDoNotConsumeSequenceAndUTF8IdentitiesStayDistinct() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let invalidTargets: [[NativePDFEraseTarget]] = [[], [.init()], [.init(drawingID: "")],
            [.init(drawingID: "a"), .init(mutationID: "a")], [.init(drawingID: "a", mutationID: "not-a-uuid")]]
        for targets in invalidTargets {
            XCTAssertThrowsError(try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 0, page: 1, targets: targets))
        }
        XCTAssertEqual(ledger.throughOperationSequence, 0)
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        XCTAssertNotEqual(NativePDFEraseTarget(drawingID: composed), NativePDFEraseTarget(drawingID: decomposed))
        _ = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 0, page: 1,
                                  targets: [.init(drawingID: composed), .init(drawingID: decomposed)])
        XCTAssertEqual(ledger.excludedIdentifiers(page: 1).map { Data($0.utf8) }, [Data(composed.utf8), Data(decomposed.utf8)])
    }

    func testFreshInkToolRetirementCanCloseEditorFenceWithoutHidingNewUndoId() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision)
        let target = NativePDFEraseTarget(drawingID: "a")
        ledger.observeCanonical([row("a")]); ledger.observeEditor(page: 1, objects: [row("a")])
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 3, page: 1, targets: [target])
        try ledger.acceptEraseResult(response(erase, targets: [target]))
        ledger.observeCanonical([row("new-undo")])
        XCTAssertEqual(ledger.tombstoneCount, 1)
        ledger.retireEditors()
        XCTAssertEqual(ledger.tombstoneCount, 0)
    }


    func testRejectedDiskAdmissionConsumesNoSequenceAndRetainsNoPhantomStroke() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision), stroke = input()
        XCTAssertThrowsError(try ledger.reserveStroke(stroke) { throw NativePDFJournalQueue.AdmissionError.full })
        XCTAssertEqual(ledger.throughOperationSequence, 0)
        XCTAssertFalse(ledger.containsLiveStroke(stroke.clientMutationId))
        XCTAssertTrue(ledger.pendingOperations.isEmpty)
        let erase = try ledger.recordErase(operationID: UUID().uuidString, originToolEpoch: 1, page: 1, targets: [.init(drawingID: "old")])
        XCTAssertEqual(erase["operationSequence"] as? Int, 1)
        let admitted = try ledger.reserveStroke(stroke, admit: {})
        XCTAssertTrue(admitted.admitted); XCTAssertEqual(admitted.sequence, 2)
        XCTAssertEqual(ledger.throughOperationSequence, 2)
        XCTAssertEqual(ledger.pendingOperations.compactMap { $0["type"] as? String }, ["eraseCommit"])
    }

    func testReservedStrokeWaitsForDurabilityAndExactRetryDoesNotAdmitAgain() throws {
        let ledger = NativePDFOperationLedger(documentRevision: revision), stroke = input()
        var admissions = 0
        _ = try ledger.reserveStroke(stroke) { admissions += 1 }
        let duplicate = try ledger.reserveStroke(stroke) { admissions += 1 }
        XCTAssertFalse(duplicate.admitted); XCTAssertEqual(admissions, 1)
        XCTAssertTrue(ledger.pendingOperations.isEmpty)
        XCTAssertThrowsError(try ledger.acknowledgeStroke(mutationID: stroke.clientMutationId, drawingID: "early"))
        var changed = stroke; changed.data.points[0].tiltX = 0.0 // Original is negative zero.
        XCTAssertThrowsError(try ledger.reserveStroke(changed) { admissions += 1 })
        XCTAssertEqual(admissions, 1)
        let durable = try ledger.recordStroke(stroke)
        XCTAssertEqual(durable["operationSequence"] as? Int, 1)
        XCTAssertEqual(ledger.pendingOperations.count, 1)
        _ = try ledger.recordStroke(stroke)
        XCTAssertEqual(ledger.pendingOperations.count, 1)
        try ledger.acknowledgeStroke(mutationID: stroke.clientMutationId, drawingID: "saved")
        XCTAssertTrue(ledger.pendingOperations.isEmpty)
        XCTAssertEqual(try ledger.reserveStroke(stroke, admit: { admissions += 1 }).sequence, 1)
        XCTAssertEqual(admissions, 1)
    }

    private func input() -> NativePDFStrokeInput {
        .init(courseId: "course", relPath: "paper.pdf", page: 1, kind: "ink",
              data: .init(points: [.init(x: 0.2, y: 0.3, p: 1.0 / 12345, t: 0, tiltX: -0.0, tiltY: 20)]),
              style: .init(color: "blue", width: 0.003, opacity: 0.8),
              clientMutationId: UUID().uuidString, documentRevision: revision)
    }
    private func row(_ id: String, mutation: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["id": id, "page": 1]
        if let mutation { value["clientMutationId"] = mutation }
        return value
    }
    private func response(_ erase: [String: Any], targets: [NativePDFEraseTarget], outcome: String = "committed") -> [String: Any] {
        var value = erase; value.removeValue(forKey: "targets")
        value["resolvedTargets"] = targets.map(\.json); value["outcome"] = outcome
        return value
    }
}
