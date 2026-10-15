import XCTest
import Foundation
@testable import Bandal

@MainActor
final class NativePDFJournalQueueTests: XCTestCase {
    func testAdmissionDoesNotWaitForDiskAndOwnsExactValueUntilDurable() async throws {
        let writer = Writer(); writer.blockFirst = true
        let queue = NativePDFJournalQueue(storageFactory: { writer })
        var input = Self.input(); let original = input
        let start = Date()
        let ticket = try queue.enqueueStroke(input, documentRevision: Self.revision)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "Admission must not wait for the blocked writer")
        defer { writer.release.signal() }
        try await wait { writer.hasStarted }
        XCTAssertEqual(queue.state.queuedJobs, 1)
        XCTAssertEqual(queue.state.completed.value, 0)
        input.data.points[0].p = 0.9; input.data.points.append(.init(x: 0.9, y: 0.9, p: 0.9))
        writer.release.signal()
        try await queue.barrier(through: ticket)
        let saved = try XCTUnwrap(writer.inputs.first)
        XCTAssertEqual(saved.data.points.count, original.data.points.count)
        XCTAssertEqual(saved.data.points[0].p.bitPattern, original.data.points[0].p.bitPattern)
        XCTAssertEqual(saved.data.points[0].tiltX?.bitPattern, original.data.points[0].tiltX?.bitPattern)
        XCTAssertEqual(queue.state.completed, ticket)
        XCTAssertEqual(queue.state.queuedBytes, 0)
        XCTAssertFalse(writer.sawMainThread)
    }

    func testFailedHeadRetainsFollowingDocumentsAndOnlyExplicitRetryAdvances() async throws {
        let writer = Writer(); writer.failWrites = true
        let queue = NativePDFJournalQueue(storageFactory: { writer })
        let a = Self.input(), b = Self.input(course: "other"), c = Self.input()
        let first = try queue.enqueueStroke(a, documentRevision: Self.revision)
        _ = try queue.enqueueStroke(b, documentRevision: Self.revision)
        do { try await queue.barrier(); XCTFail("Failed disk write must fail a close/save barrier") } catch {}
        XCTAssertEqual(queue.state.failedTicket, first)
        XCTAssertEqual(queue.state.queuedJobs, 2)
        XCTAssertEqual(writer.attempts, [a.clientMutationId])
        _ = try queue.enqueueStroke(c, documentRevision: Self.revision)
        do { try queue.barrierSynchronously(); XCTFail("A synchronous close cannot discard failed work") } catch {}
        XCTAssertEqual(writer.attempts, [a.clientMutationId], "New input and ordinary fences cannot spin a failed write")
        XCTAssertEqual(queue.state.queuedJobs, 3)
        writer.failWrites = false
        // Retry only the failed prefix; the already-admitted later work must
        // automatically resume even if no new input arrives after this call.
        try await queue.barrier(through: first, retryFailed: true)
        try await wait { queue.state.queuedJobs == 0 }
        XCTAssertEqual(writer.attempts, [a.clientMutationId, a.clientMutationId, b.clientMutationId, c.clientMutationId])
        XCTAssertEqual(writer.inputs.map(\.clientMutationId), [a.clientMutationId, b.clientMutationId, c.clientMutationId])
        XCTAssertNil(queue.state.failedTicket)
        XCTAssertFalse(writer.sawMainThread)
    }

    func testQueueBudgetRejectsWithoutConsumingTicketOrLosingAcceptedRawInput() async throws {
        let writer = Writer(); writer.blockFirst = true
        let queue = NativePDFJournalQueue(maximumQueuedBytes: 4096, maximumQueuedJobs: 1, storageFactory: { writer })
        let a = Self.input(), b = Self.input()
        let first = try queue.enqueueStroke(a, documentRevision: Self.revision)
        defer { writer.release.signal() }
        try await wait { writer.hasStarted }
        let state = queue.state
        XCTAssertThrowsError(try queue.enqueueStroke(b, documentRevision: Self.revision))
        XCTAssertEqual(queue.state.issued, first)
        XCTAssertEqual(queue.state.queuedBytes, state.queuedBytes)
        XCTAssertEqual(queue.state.queuedJobs, 1)
        writer.release.signal(); try await queue.barrier()
        let second = try queue.enqueueStroke(b, documentRevision: Self.revision)
        XCTAssertEqual(second.value, first.value + 1)
        try await queue.barrier()
        XCTAssertEqual(writer.inputs.map(\.clientMutationId), [a.clientMutationId, b.clientMutationId])
        let noBytes = NativePDFJournalQueue(maximumQueuedBytes: 0, storageFactory: { writer })
        XCTAssertThrowsError(try noBytes.enqueueCheckpoint(a, documentRevision: Self.revision))
        XCTAssertEqual(noBytes.state.issued.value, 0)
    }

    func testDiskBarrierDoesNotWaitForItsMainQueueCompletion() async throws {
        let writer = Writer(), observed = Observation()
        let queue = NativePDFJournalQueue(storageFactory: { writer })
        let ticket = try queue.enqueueStroke(Self.input(), documentRevision: Self.revision) { result in
            observed.record(main: Thread.isMainThread, success: (try? result.get()) != nil)
        }
        // This test remains on MainActor, deliberately preventing queued main
        // callbacks from executing until the disk-only synchronous fence returns.
        try queue.barrierSynchronously(through: ticket)
        XCTAssertEqual(queue.state.completed, ticket)
        XCTAssertEqual(observed.count, 0)
        try await wait { observed.count == 1 }
        XCTAssertTrue(observed.allMain)
        XCTAssertTrue(observed.allSuccess)
    }

    func testCheckpointFinalAndAcknowledgementUseSingleWorkerWithRealJournal() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let creation = Observation()
        let queue = NativePDFJournalQueue(storageFactory: {
            creation.record(main: Thread.isMainThread, success: true)
            return try NativePDFJournal(root: root)
        })
        let a = Self.input(), other = Self.input(course: "other")
        var corrected = a; corrected.data.points[0].p = 17.0 / 12345.0
        try queue.enqueueCheckpoint(a, documentRevision: Self.revision)
        try queue.enqueueCheckpoint(corrected, documentRevision: Self.revision)
        try queue.enqueueStroke(corrected, documentRevision: Self.revision)
        try queue.enqueueStroke(other, documentRevision: Self.revision)
        let saved = try await queue.pending(courseID: a.courseId, relativePath: a.relPath)
        XCTAssertEqual(saved.count, 1); XCTAssertNil(saved[0].provisional)
        XCTAssertEqual(saved[0].input.data.points[0].p.bitPattern, corrected.data.points[0].p.bitPattern)
        XCTAssertEqual(saved[0].input.data.points[0].t?.bitPattern, corrected.data.points[0].t?.bitPattern)
        XCTAssertEqual(saved[0].input.data.points[0].tiltX?.bitPattern, corrected.data.points[0].tiltX?.bitPattern)
        try await queue.acknowledge(a.clientMutationId, courseID: a.courseId, relativePath: a.relPath)
        let empty = try await queue.pending(courseID: a.courseId, relativePath: a.relPath)
        let untouched = try await queue.pending(courseID: other.courseId, relativePath: other.relPath)
        XCTAssertTrue(empty.isEmpty); XCTAssertEqual(untouched.map(\.input.clientMutationId), [other.clientMutationId])
        XCTAssertEqual(creation.count, 1); XCTAssertFalse(creation.allMain)
        let timings = try await queue.timings()
        XCTAssertEqual(timings["commit"]?.count, 2)
        XCTAssertEqual(timings["ack"]?.count, 1)
    }

    func testProvisionalAfterFinalIsRejectedAndRetainedInsteadOfOverwritingDurableStroke() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = NativePDFJournalQueue(root: root), input = Self.input()
        try queue.enqueueStroke(input, documentRevision: Self.revision)
        try await queue.barrier()
        let invalid = try queue.enqueueCheckpoint(input, documentRevision: Self.revision)
        do { try await queue.barrier(); XCTFail("A final receipt cannot become provisional again") } catch {}
        XCTAssertEqual(queue.state.failedTicket, invalid)
        XCTAssertEqual(queue.state.queuedJobs, 1)
        // Read the persisted bytes only after the worker has failed and stopped;
        // this independent decoder is an oracle, not a second journal owner.
        let url = root.appendingPathComponent("PendingNativePDFInk").appendingPathComponent(input.clientMutationId + ".json")
        let record = try JSONDecoder().decode(NativePDFPendingStroke.self, from: Data(contentsOf: url))
        XCTAssertNil(record.provisional)
        XCTAssertEqual(record.input.data.points[0].p.bitPattern, input.data.points[0].p.bitPattern)
    }

    func testRealJournalUnlinkFailureRequiresSameOwnerDirectoryBarrierOnRetry() throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        var armed = false, failures = 0, calls = 0
        let journal = try NativePDFJournal(root: root, beforeDirectorySynchronization: {
            calls += 1
            if armed { failures += 1; throw Failure.disk }
        })
        let input = Self.input()
        try journal.append(input, documentRevision: Self.revision)
        let before = journal.synchronizationCount
        armed = true
        XCTAssertThrowsError(try journal.acknowledge(input.clientMutationId, courseID: input.courseId, relativePath: input.relPath))
        let path = root.appendingPathComponent("PendingNativePDFInk").appendingPathComponent(input.clientMutationId + ".json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "The first unlink already happened")
        let afterFailureCalls = calls
        XCTAssertThrowsError(try journal.acknowledge(input.clientMutationId, courseID: "other", relativePath: input.relPath))
        XCTAssertEqual(calls, afterFailureCalls, "Wrong owner cannot finish the pending barrier")
        XCTAssertThrowsError(try journal.acknowledge(input.clientMutationId, courseID: input.courseId, relativePath: input.relPath))
        XCTAssertEqual(failures, 2)
        XCTAssertEqual(journal.synchronizationCount, before)
        armed = false
        try journal.acknowledge(input.clientMutationId, courseID: input.courseId, relativePath: input.relPath)
        XCTAssertEqual(journal.synchronizationCount, before + 1)
        let afterSuccessCalls = calls
        try journal.acknowledge(input.clientMutationId, courseID: input.courseId, relativePath: input.relPath)
        XCTAssertEqual(calls, afterSuccessCalls, "An ordinary already-absent ACK stays a no-op")
    }

    func testQueueRetainsFailedAcknowledgementUntilMissingFileBarrierIsDurable() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let failure = FailureSwitch()
        let queue = NativePDFJournalQueue(storageFactory: {
            try NativePDFJournal(root: root, beforeDirectorySynchronization: { if failure.enabled { throw Failure.disk } })
        })
        let input = Self.input()
        try queue.enqueueStroke(input, documentRevision: Self.revision); try await queue.barrier()
        failure.enabled = true
        do { try await queue.acknowledge(input.clientMutationId, courseID: input.courseId, relativePath: input.relPath); XCTFail("ACK must not pass a failed directory fsync") } catch {}
        XCTAssertEqual(queue.state.queuedJobs, 1)
        XCTAssertNotNil(queue.state.failedTicket)
        do { try await queue.barrier(retryFailed: true); XCTFail("Missing file is not proof of durable unlink") } catch {}
        XCTAssertEqual(queue.state.queuedJobs, 1)
        failure.enabled = false
        try await queue.barrier(retryFailed: true)
        XCTAssertEqual(queue.state.queuedJobs, 0); XCTAssertNil(queue.state.failedTicket)
        let pending = try await queue.pending(courseID: input.courseId, relativePath: input.relPath)
        XCTAssertTrue(pending.isEmpty)
    }


    func testWorkerPreparedTransportMatchesDurableRawBitsBeforeCompletedWatermark() async throws {
        let root = try Self.root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = NativePDFJournalQueue(root: root), input = Self.input()
        let prepared = NativePDFJournalQueue.PreparedStroke()
        let ticket = try queue.enqueueStroke(input, documentRevision: Self.revision, preparedTransport: prepared)
        try await queue.barrier(through: ticket)
        XCTAssertEqual(queue.state.completed, ticket)
        let transport = try XCTUnwrap(prepared.value)
        let decoded = try JSONDecoder().decode(NativePDFStrokeInput.self,
            from: JSONSerialization.data(withJSONObject: transport.payload, options: [.sortedKeys]))
        XCTAssertEqual(decoded, input)
        XCTAssertEqual(decoded.data.points[0].p.bitPattern, input.data.points[0].p.bitPattern)
        // JSONSerialization may canonicalize the spelling of signed zero; the
        // worker payload itself keeps the original Double bits before JS wire.
        let data = try XCTUnwrap(transport.payload["data"] as? [String: Any])
        let points = try XCTUnwrap(data["points"] as? [[String: Any]])
        XCTAssertEqual((points[0]["tiltX"] as? Double)?.bitPattern, input.data.points[0].tiltX?.bitPattern)
        XCTAssertEqual(transport.fingerprint.count, 32)
        let saved = try await queue.pending(courseID: input.courseId, relativePath: input.relPath)
        XCTAssertEqual(saved[0].input.data.points[0].tiltX?.bitPattern, input.data.points[0].tiltX?.bitPattern)
        prepared.release(); XCTAssertNil(prepared.value)
    }

    private static let revision = String(repeating: "a", count: 64)
    private static func input(course: String = "course") -> NativePDFStrokeInput {
        .init(courseId: course, relPath: "public.pdf", page: 1, kind: "ink",
            data: .init(points: [.init(x: 0.2, y: 0.3, p: 1.0 / 12345.0, t: 0, tiltX: -0.0, tiltY: 0.25)]),
            style: .init(color: "blue", width: 0.01, opacity: 0.45),
            clientMutationId: UUID().uuidString, documentRevision: revision)
    }
    private static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-queue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Bounded queue progress condition was not reached")
    }
    private enum Failure: Error { case disk }
    private final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        var enabled: Bool { get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() } }
    }
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock(); private var values: [(Bool, Bool)] = []
        func record(main: Bool, success: Bool) { lock.lock(); values.append((main, success)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
        var allMain: Bool { lock.lock(); defer { lock.unlock() }; return values.allSatisfy(\.0) }
        var allSuccess: Bool { lock.lock(); defer { lock.unlock() }; return values.allSatisfy(\.1) }
    }
    private final class Writer: NativePDFJournalQueueStorage, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var firstBlocked = false, started = false, fail = false, main = false
        private var saved: [NativePDFStrokeInput] = [], tried: [String] = []
        var blockFirst = false // Configured before the queue is created.
        var failWrites: Bool { get { lock.lock(); defer { lock.unlock() }; return fail }
            set { lock.lock(); fail = newValue; lock.unlock() } }
        var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
        var sawMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
        var inputs: [NativePDFStrokeInput] { lock.lock(); defer { lock.unlock() }; return saved }
        var attempts: [String] { lock.lock(); defer { lock.unlock() }; return tried }
        var timingStatistics: [String: NativePDFLatencySamples] { [:] }
        func append(_ input: NativePDFStrokeInput, documentRevision: String) throws {
            lock.lock(); started = true; main = main || Thread.isMainThread; tried.append(input.clientMutationId)
            let shouldBlock = blockFirst && !firstBlocked; firstBlocked = true
            lock.unlock()
            if shouldBlock, release.wait(timeout: .now() + 3) != .success { throw Failure.disk }
            lock.lock(); let shouldFail = fail
            if !shouldFail { saved.append(input) }
            lock.unlock()
            if shouldFail { throw Failure.disk }
        }
        func checkpoint(_ input: NativePDFStrokeInput, documentRevision: String) throws { try append(input, documentRevision: documentRevision) }
        func acknowledge(_ mutationID: String, courseID: String, relativePath: String) throws {
            lock.lock(); defer { lock.unlock() }; main = main || Thread.isMainThread
            saved.removeAll { $0.clientMutationId == mutationID && $0.courseId == courseID && $0.relPath == relativePath }
        }
        func pending(courseID: String, relativePath: String) throws -> [NativePDFPendingStroke] {
            lock.lock(); defer { lock.unlock() }; main = main || Thread.isMainThread
            return saved.filter { $0.courseId == courseID && $0.relPath == relativePath }.map {
                .init(createdAt: Date(), documentRevision: $0.documentRevision!, input: $0)
            }
        }
    }
}
