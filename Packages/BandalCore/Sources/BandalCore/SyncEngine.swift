import Foundation

public protocol SyncTransport: Sendable {
    var userID: String { get }
    func push(_ operation: SyncOperation) async throws -> PushResult
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage
}

public struct SyncReport: Sendable, Equatable {
    public var pushed: Int = 0
    public var pulled: Int = 0
    public var conflicts: Int = 0
    public var merged: Int = 0
    public var cursor: Int64 = 0
    public init() {}
}

public actor SyncEngine {
    private let store: RecordStore
    private let transport: any SyncTransport
    private var active: Task<SyncReport, Error>?

    public init(store: RecordStore, transport: any SyncTransport) {
        self.store = store; self.transport = transport
    }

    /// Concurrent triggers join the same run. Failed pushes leave their durable
    /// operation ID intact for retry; errors never discard pending local work.
    public func synchronize() async throws -> SyncReport {
        if let active { return try await active.value }
        let store = self.store, transport = self.transport
        let task = Task { try await Self.run(store: store, transport: transport) }
        active = task
        defer { active = nil }
        return try await task.value
    }

    public func cancel() { active?.cancel() }

    private static func run(store: RecordStore, transport: any SyncTransport) async throws -> SyncReport {
        try await store.bindSyncAccount(userID: transport.userID)
        var report = SyncReport()
        // Bound each run so continuous editing cannot starve pulling or cancellation.
        var pending = try await store.pendingOperations(limit: 1000)
        var visited = Set(pending.map(\.id))
        var index = 0
        while index < pending.count && index < 1000 {
            let operation = pending[index]; index += 1
            try Task.checkCancellation()
            if try await !store.isPending(operation.id) { continue }
            let result = try await transport.push(operation)
            switch try await store.acknowledge(operation, result: result) {
            case .conflict:
                report.conflicts += 1
            case .merged:
                report.merged += 1
                for next in try await store.pendingOperations(limit: 1000)
                    where next.record.id == operation.record.id && !visited.contains(next.id) {
                    pending.append(next); visited.insert(next.id)
                }
            case .accepted: report.pushed += 1
            }
        }
        var cursor = try await store.syncCursor()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let page = try await transport.pull(after: cursor, limit: 200)
            guard !page.hasMore || page.cursor > cursor else { throw CoreError.invalidResponse("Non-advancing cursor") }
            try await store.apply(page)
            report.pulled += page.records.count; cursor = page.cursor
            if !page.hasMore { break }
        }
        report.cursor = cursor
        return report
    }
}
