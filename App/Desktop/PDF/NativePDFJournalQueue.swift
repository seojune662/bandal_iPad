import Foundation
import CryptoKit

/// The journal implementation is created and accessed only on the queue's
/// serial worker. Tests may supply a slow/failing implementation of this seam.
protocol NativePDFJournalQueueStorage: AnyObject {
    func append(_ input: NativePDFStrokeInput, documentRevision: String) throws
    func checkpoint(_ input: NativePDFStrokeInput, documentRevision: String) throws
    func acknowledge(_ mutationID: String, courseID: String, relativePath: String) throws
    func pending(courseID: String, relativePath: String) throws -> [NativePDFPendingStroke]
    var timingStatistics: [String: NativePDFLatencySamples] { get }
}
extension NativePDFJournal: NativePDFJournalQueueStorage {}

/// One Host-wide disk owner. Admission holds a short metadata lock, never a
/// disk lock. Each accepted job strongly owns its immutable value-type input
/// until its write succeeds; a failed head and every later job remain queued.
/// @unchecked Sendable: admission state is lock-protected; storage is accessed
/// only on `worker`; callbacks are dispatched asynchronously to the main queue.
final class NativePDFJournalQueue: @unchecked Sendable {
    struct Ticket: Equatable, Sendable { let value: UInt64 }
    struct State: Sendable {
        let issued: Ticket, completed: Ticket
        let queuedJobs: Int, queuedBytes: Int
        let failedTicket: Ticket?
    }
    typealias Completion = @MainActor @Sendable (Result<Ticket, Error>) -> Void
    /// Worker-prepared immutable transport; no UIKit or renderer state is read.
    struct StrokeTransport {
        let payload: [String: Any]
        let fingerprint: Data
    }
    final class PreparedStroke: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: StrokeTransport?
        fileprivate func prepare(_ input: NativePDFStrokeInput) throws {
            let payload = try NativePDFHost.json(input)
            let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .fragmentsAllowed])
            let value = StrokeTransport(payload: payload, fingerprint: Data(SHA256.hash(data: bytes)))
            lock.lock(); transport = value; lock.unlock()
        }
        var value: StrokeTransport? { lock.lock(); defer { lock.unlock() }; return transport }
        func release() { lock.lock(); transport = nil; lock.unlock() }
    }
    private enum Mutation {
        case checkpoint(NativePDFStrokeInput, String)
        case final(NativePDFStrokeInput, String, PreparedStroke?)
        case acknowledgement(String, String, String)
    }
    private struct Job {
        let ticket: Ticket, mutation: Mutation, charge: Int, completion: Completion?
    }
    private struct Failure { let ticket: Ticket; let error: Error }
    enum AdmissionError: Error, LocalizedError {
        case full, exhausted
        var errorDescription: String? {
            switch self {
            case .full: return "아직 저장하지 못한 필기가 많습니다. 저장을 다시 시도해 주세요."
            case .exhausted: return "필기 저장 작업 순서를 더 만들 수 없습니다."
            }
        }
    }
    let maximumQueuedBytes: Int
    let maximumQueuedJobs: Int
    private let worker = DispatchQueue(label: "app.bandal.native-pdf-journal", qos: .userInitiated)
    private let workerKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()
    private let factory: () throws -> NativePDFJournalQueueStorage
    // Worker-confined; construction (including directory creation) is off-main.
    private var storage: NativePDFJournalQueueStorage?
    // All following state is lock-protected, including while on the worker.
    private var jobs: [Job] = []
    private var bytes = 0
    private var issued: UInt64 = 0, completed: UInt64 = 0
    private var automaticDrainScheduled = false
    private var failure: Failure?
    private var cachedTimings: [String: NativePDFLatencySamples] = [:]
    var timingStatistics: [String: NativePDFLatencySamples] { locked { cachedTimings } }

    convenience init(root: URL, maximumQueuedBytes: Int = 64 * 1024 * 1024, maximumQueuedJobs: Int = 4096) {
        self.init(maximumQueuedBytes: maximumQueuedBytes, maximumQueuedJobs: maximumQueuedJobs,
                  storageFactory: { try NativePDFJournal(root: root) })
    }
    init(maximumQueuedBytes: Int = 64 * 1024 * 1024, maximumQueuedJobs: Int = 4096,
         storageFactory: @escaping () throws -> NativePDFJournalQueueStorage) {
        self.maximumQueuedBytes = max(0, maximumQueuedBytes)
        self.maximumQueuedJobs = max(0, maximumQueuedJobs)
        factory = storageFactory
        worker.setSpecific(key: workerKey, value: 1)
    }
    var state: State {
        locked { State(issued: Ticket(value: issued), completed: Ticket(value: completed),
            queuedJobs: jobs.count, queuedBytes: bytes, failedTicket: failure?.ticket) }
    }
    /// Deliberately does no JSON encoding, validation walk, path work or fsync.
    /// The caller validates measured data before admission; the existing journal
    /// validates it again on the worker. Rejected admission transfers no ownership.
    @discardableResult
    func enqueueCheckpoint(_ input: NativePDFStrokeInput, documentRevision: String,
                           completion: Completion? = nil) throws -> Ticket {
        try enqueue(.checkpoint(input, documentRevision), charge: Self.charge(input, documentRevision), completion: completion)
    }
    @discardableResult
    func enqueueStroke(_ input: NativePDFStrokeInput, documentRevision: String,
                       preparedTransport: PreparedStroke? = nil, completion: Completion? = nil) throws -> Ticket {
        try enqueue(.final(input, documentRevision, preparedTransport), charge: Self.charge(input, documentRevision), completion: completion)
    }
    /// ACK itself is an ordered write and cannot pass an earlier failed final.
    /// On failure its job remains at the head; an explicit retry barrier retries
    /// that same job. Calling ACK again is harmless but can add another no-op job.
    func acknowledge(_ mutationID: String, courseID: String, relativePath: String) async throws {
        let ticket = try enqueue(.acknowledgement(mutationID, courseID, relativePath),
            charge: 1024 + mutationID.utf8.count + courseID.utf8.count + relativePath.utf8.count, completion: nil)
        try await barrier(through: ticket)
    }
    /// Captures an admission watermark. Later inputs are not part of this
    /// barrier. It never waits for main-queue notifications to execute.
    func barrier(through ticket: Ticket? = nil, retryFailed: Bool = false) async throws {
        let target = ticket ?? state.issued
        try await onWorker {
            try self.drain(through: target, retryFailed: retryFailed)
            self.resumeAutomaticDrainIfNeeded()
        }
    }
    /// Only explicit synchronous lifecycle callers may use this disk barrier.
    /// It must not run inside an input/frame callback. Main callback delivery is
    /// not part of the barrier, avoiding a main->worker->main deadlock.
    func barrierSynchronously(through ticket: Ticket? = nil, retryFailed: Bool = false) throws {
        let target = ticket ?? state.issued
        if DispatchQueue.getSpecific(key: workerKey) != nil {
            try drain(through: target, retryFailed: retryFailed)
            resumeAutomaticDrainIfNeeded()
        } else {
            try worker.sync {
                try self.drain(through: target, retryFailed: retryFailed)
                self.resumeAutomaticDrainIfNeeded()
            }
        }
    }
    func pending(courseID: String, relativePath: String, retryFailed: Bool = false) async throws -> [NativePDFPendingStroke] {
        let target = state.issued
        return try await onWorker {
            try self.drain(through: target, retryFailed: retryFailed)
            self.resumeAutomaticDrainIfNeeded()
            return try self.journal().pending(courseID: courseID, relativePath: relativePath)
        }
    }
    func timings() async throws -> [String: NativePDFLatencySamples] {
        try await onWorker { try self.journal().timingStatistics }
    }
    private func enqueue(_ mutation: Mutation, charge: Int, completion: Completion?) throws -> Ticket {
        lock.lock()
        guard charge >= 0, charge <= maximumQueuedBytes - bytes, jobs.count < maximumQueuedJobs else {
            lock.unlock(); throw AdmissionError.full
        }
        guard issued < UInt64.max else { lock.unlock(); throw AdmissionError.exhausted }
        issued += 1
        let ticket = Ticket(value: issued)
        jobs.append(Job(ticket: ticket, mutation: mutation, charge: charge, completion: completion)); bytes += charge
        let schedule = !automaticDrainScheduled && failure == nil
        if schedule { automaticDrainScheduled = true }
        lock.unlock()
        if schedule { scheduleAutomaticDrain(through: ticket) }
        return ticket
    }
    private func scheduleAutomaticDrain(through target: Ticket) {
        worker.async {
            do { try self.drain(through: target, retryFailed: false) } catch { /* Head and error remain owned. */ }
            self.lock.lock()
            self.automaticDrainScheduled = false
            let next = self.failure == nil ? self.jobs.last?.ticket : nil
            if next != nil { self.automaticDrainScheduled = true }
            self.lock.unlock()
            if let next { self.scheduleAutomaticDrain(through: next) }
        }
    }
    private func resumeAutomaticDrainIfNeeded() {
        let next: Ticket? = locked {
            guard !automaticDrainScheduled, failure == nil, let next = jobs.last?.ticket else { return nil }
            automaticDrainScheduled = true; return next
        }
        if let next { scheduleAutomaticDrain(through: next) }
    }
    private func drain(through target: Ticket, retryFailed: Bool) throws {
        dispatchPrecondition(condition: .onQueue(worker))
        lock.lock()
        if target.value > issued { lock.unlock(); throw AdmissionError.exhausted }
        if let failure, failure.ticket.value <= target.value {
            if retryFailed { self.failure = nil }
            else { lock.unlock(); throw failure.error }
        }
        lock.unlock()
        while true {
            let job: Job? = locked { jobs.first.flatMap { $0.ticket.value <= target.value ? $0 : nil } }
            guard let job else { return }
            do {
                let storage = try journal()
                switch job.mutation {
                case let .checkpoint(input, revision): try storage.checkpoint(input, documentRevision: revision)
                case let .final(input, revision, prepared):
                    try storage.append(input, documentRevision: revision)
                    try prepared?.prepare(input)
                case let .acknowledgement(mutation, course, path): try storage.acknowledge(mutation, courseID: course, relativePath: path)
                }
            } catch {
                if let storage { locked { cachedTimings = storage.timingStatistics } }
                locked { failure = Failure(ticket: job.ticket, error: error) }
                notify(job, .failure(error))
                throw error
            }
            if let storage { locked { cachedTimings = storage.timingStatistics } }
            locked {
                precondition(jobs.first?.ticket == job.ticket)
                jobs.removeFirst(); bytes -= job.charge; completed = job.ticket.value
            }
            notify(job, .success(job.ticket))
        }
    }
    private func journal() throws -> NativePDFJournalQueueStorage {
        dispatchPrecondition(condition: .onQueue(worker))
        if let storage { return storage }
        let value = try factory(); storage = value; return value
    }
    private func notify(_ job: Job, _ result: Result<Ticket, Error>) {
        guard let completion = job.completion else { return }
        DispatchQueue.main.async { completion(result) }
    }
    private func onWorker<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    /// Bounds queued value storage conservatively, not exact allocator RSS.
    /// Array/String COW keeps the accepted input stable if the caller mutates it.
    private static func charge(_ input: NativePDFStrokeInput, _ revision: String) -> Int {
        let points = (input.data.points.count + (input.heldShape?.points.count ?? 0)).multipliedReportingOverflow(by: MemoryLayout<NativePDFPoint>.stride * 2)
        let strings = [input.courseId, input.relPath, input.kind, input.style.color, input.clientMutationId,
                       input.documentRevision ?? "", revision].reduce(0) { $0 + $1.utf8.count * 2 }
        let total = points.partialValue.addingReportingOverflow(strings + 2048)
        return points.overflow || total.overflow ? Int.max : total.partialValue
    }
}
