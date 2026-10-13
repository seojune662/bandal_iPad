import Foundation
import Testing
@testable import BandalCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("BandalCore-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let user = "e7a33e3b-991d-45d0-8710-8939591a3c8a"
private func json(_ value: String) -> Data { Data("{\"text\":\"\(value)\",\"version\":1}".utf8) }

private actor TestServer: SyncTransport {
    nonisolated let userID = user
    var records: [String: StoredRecord] = [:]
    var receipts: [String: PushResult] = [:]
    var changes: [StoredRecord] = []
    var dropAcknowledgement = false
    var pushCalls = 0
    func failNextAcknowledgement() { dropAcknowledgement = true }
    func count() -> Int { receipts.count }
    func push(_ operation: SyncOperation) async throws -> PushResult {
        pushCalls += 1
        if let receipt = receipts[operation.id] { return receipt }
        let result: PushResult
        if let current = records[operation.record.id], current.revision != operation.baseRevision {
            result = PushResult(status: .conflict, record: current)
        } else {
            records[operation.record.id] = operation.record
            changes.append(operation.record)
            result = PushResult(status: .accepted, record: operation.record)
        }
        receipts[operation.id] = result
        if dropAcknowledgement {
            dropAcknowledgement = false
            throw CoreError.transport(503, "Lost acknowledgement")
        }
        return result
    }
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage {
        let end = min(Int(cursor) + limit, changes.count)
        return PullPage(records: Array(changes[Int(cursor)..<end]), cursor: Int64(end), hasMore: end < changes.count)
    }
}

@Test func durableRecordsAndAtomicOutbox() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let first = try RecordStore(url: url)
    let created = try await first.upsert(id: "note-1", kind: "note", payload: json("hello"))
    let operation = try #require(await first.pendingOperations().first)
    #expect(created.revision == 1)
    #expect(operation.baseRevision == 0)
    let reopened = try RecordStore(url: url)
    #expect(try await reopened.get(id: "note-1") == created)
    #expect(try await reopened.pendingOperations().first?.id == operation.id)
    await #expect(throws: CoreError.self) { try await reopened.upsert(id: "bad", kind: "note", payload: Data("not-json".utf8)) }
    #expect(try await reopened.get(id: "bad") == nil)
    #expect(try await reopened.pendingOperations().count == 1)
}

@Test func multiplePendingRevisionsAndTombstones() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    try await store.upsert(id: "n", kind: "note", payload: json("first"))
    try await store.upsert(id: "n", kind: "note", payload: json("second"))
    try await store.delete(id: "n")
    try await store.delete(id: "n")
    #expect(try await store.list().isEmpty)
    #expect(try await store.list(includeDeleted: true).first?.revision == 3)
    #expect(try await store.pendingOperations().map(\.baseRevision) == [0, 1, 2])
    let server = TestServer()
    let result = try await SyncEngine(store: store, transport: server).synchronize()
    #expect(result.pushed == 3)
    #expect(try await store.pendingOperations().isEmpty)
    #expect(try await store.get(id: "n")?.deleted == true)
}

@Test func journalReplayAfterReopenPreservesLaterEditAndDeletion() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let store = try RecordStore(url: url)
    let original = try await store.applyLocalJournalEntry(mutationID: "journal-1", id: "n", kind: "note", payload: json("first"))
    #expect(original.revision == 1)
    try await store.upsert(id: "n", kind: "note", payload: json("later"))
    let reopened = try RecordStore(url: url)
    let replay = try await reopened.applyLocalJournalEntry(mutationID: "journal-1", id: "n", kind: "note", payload: json("first"))
    #expect(replay.payload == json("later"))
    #expect(replay.revision == 2)
    #expect(try await reopened.pendingOperations().count == 2)
    await #expect(throws: CoreError.self) {
        try await reopened.applyLocalJournalEntry(mutationID: "journal-1", id: "n", kind: "note", payload: json("different"))
    }
    try await reopened.delete(id: "n")
    let tombstone = try await reopened.applyLocalJournalEntry(mutationID: "journal-1", id: "n", kind: "note", payload: json("first"))
    #expect(tombstone.deleted)
    #expect(try await reopened.pendingOperations().count == 3)
}

@Test func journalReceiptFailureRollsBackRecordAndOutbox() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let store = try RecordStore(url: url)
    let fault = try SQLiteConnection(url: url)
    try fault.exec("CREATE TRIGGER reject_receipt BEFORE INSERT ON local_mutation_receipts BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;")
    await #expect(throws: CoreError.self) {
        try await store.applyLocalJournalEntry(mutationID: "journal-1", id: "n", kind: "note", payload: json("first"))
    }
    #expect(try await store.get(id: "n") == nil)
    #expect(try await store.pendingOperations().isEmpty)
    try fault.exec("DROP TRIGGER reject_receipt")
    #expect(try await store.applyLocalJournalEntry(mutationID: "journal-1", id: "n", kind: "note", payload: json("first")).revision == 1)
    #expect(try await store.pendingOperations().count == 1)
}

@Test func localImportAssignsLocalRevisionsAndIncludesTombstones() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    try await store.upsert(id: "existing", kind: "note", payload: json("before"))
    let result = try await store.importLocalRecords([
        StoredRecord(id: "existing", kind: "note", payload: json("removed"), revision: -100, deleted: true),
        StoredRecord(id: "new", kind: "note", payload: json("imported"), revision: Int.max)
    ])
    #expect(result.map(\.revision) == [2, 1])
    #expect(result.first?.deleted == true)
    #expect(try await store.list().map(\.id) == ["new"])
    #expect(try await store.pendingOperations().map(\.baseRevision) == [0, 1, 0])
}

@Test func localImportValidatesEntireBatchBeforeWriting() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    let existing = try await store.upsert(id: "existing", kind: "note", payload: json("before"))
    let valid = StoredRecord(id: "new", kind: "note", payload: json("valid"), revision: 1)
    let invalidInputs = [
        StoredRecord(id: "existing", kind: "drawing", payload: json("kind mismatch"), revision: 1),
        StoredRecord(id: "future", kind: "note", payload: json("future"), revision: 1, formatVersion: 2),
        StoredRecord(id: "workspace", kind: "workspace", payload: json("local only"), revision: 1),
        StoredRecord(id: "bad-json", kind: "note", payload: Data("invalid".utf8), revision: 1),
        StoredRecord(id: "large", kind: "note", payload: Data(repeating: 32, count: 4 * 1024 * 1024 + 1), revision: 1),
        valid
    ]
    for invalid in invalidInputs {
        await #expect(throws: CoreError.self) { try await store.importLocalRecords([valid, invalid]) }
        #expect(try await store.get(id: "new") == nil)
        #expect(try await store.get(id: "existing") == existing)
        #expect(try await store.pendingOperations().count == 1)
    }
}

@Test func localImportRollsBackEarlierWritesOnOutboxFailure() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let store = try RecordStore(url: url)
    let existing = try await store.upsert(id: "first", kind: "note", payload: json("before"))
    let fault = try SQLiteConnection(url: url)
    try fault.exec("CREATE TRIGGER reject_second_outbox BEFORE INSERT ON outbox WHEN NEW.record_id='second' BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;")
    await #expect(throws: CoreError.self) {
        try await store.importLocalRecords([
            StoredRecord(id: "first", kind: "note", payload: json("overwrite"), revision: 1),
            StoredRecord(id: "second", kind: "note", payload: json("fail"), revision: 1)
        ])
    }
    #expect(try await store.get(id: "first") == existing)
    #expect(try await store.get(id: "second") == nil)
    #expect(try await store.pendingOperations().count == 1)
}

@Test func credentialsAndDeviceLayoutNeverEnterOutbox() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    for kind in ["workspace", "cookie", "apiKey", "session", "account"] {
        try await store.upsert(id: kind, kind: kind, payload: json("local"))
    }
    #expect(try await store.list().count == 5)
    #expect(try await store.pendingOperations().isEmpty)
}

@Test func retryReusesOperationIDAfterServerCommitted() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    try await store.upsert(id: "n", kind: "note", payload: json("persist me"))
    let server = TestServer()
    let retryEngine = SyncEngine(store: store, transport: server)
    await server.failNextAcknowledgement()
    await #expect(throws: CoreError.self) { try await retryEngine.synchronize() }
    #expect(try await store.pendingOperations().count == 1)
    let report = try await retryEngine.synchronize()
    #expect(report.pushed == 1)
    #expect(await server.count() == 1)
    #expect(try await store.pendingOperations().isEmpty)
}

@Test func failedOutboxInsertRollsBackRecordWrite() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("records.sqlite")
    let store = try RecordStore(url: url)
    let fault = try SQLiteConnection(url: url)
    try fault.exec("CREATE TRIGGER reject_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;")
    await #expect(throws: CoreError.self) { try await store.upsert(id: "n", kind: "note", payload: json("cannot commit")) }
    #expect(try await store.get(id: "n") == nil)
    #expect(try await store.pendingOperations().isEmpty)
}

@Test func bidirectionalMergeAndConflictRecovery() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = try RecordStore(url: root.appendingPathComponent("a.sqlite"))
    let b = try RecordStore(url: root.appendingPathComponent("b.sqlite"))
    let server = TestServer()
    let sa = SyncEngine(store: a, transport: server), sb = SyncEngine(store: b, transport: server)
    try await a.upsert(id: "n", kind: "note", payload: json("original"))
    _ = try await sa.synchronize(); _ = try await sb.synchronize()
    try await a.upsert(id: "n", kind: "note", payload: json("from a"))
    try await b.upsert(id: "n", kind: "note", payload: json("from b"))
    // Include a later queued local edit: the latest intent must survive conflict.
    try await b.upsert(id: "n", kind: "note", payload: json("latest b"))
    try await b.upsert(id: "separate-stroke", kind: "drawing", payload: json("stroke"))
    _ = try await sa.synchronize()
    let report = try await sb.synchronize()
    #expect(report.conflicts == 1)
    #expect(try await b.get(id: "n")?.payload == json("from a"))
    let conflict = try #require(await b.conflicts().first)
    #expect(conflict.local.payload == json("latest b"))
    #expect(try await b.pendingOperations().isEmpty)
    let restored = try await b.restoreConflict(id: conflict.id, newRecordID: "recovered")
    #expect(restored.payload == json("latest b"))
    _ = try await sb.synchronize(); _ = try await sa.synchronize()
    #expect(try await a.get(id: "recovered")?.payload == restored.payload)
    #expect(try await a.get(id: "separate-stroke") != nil)
}

@Test func deletionConflictDoesNotResurrect() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = try RecordStore(url: root.appendingPathComponent("a.sqlite"))
    let b = try RecordStore(url: root.appendingPathComponent("b.sqlite"))
    let server = TestServer()
    let sa = SyncEngine(store: a, transport: server), sb = SyncEngine(store: b, transport: server)
    try await a.upsert(id: "n", kind: "note", payload: json("original"))
    _ = try await sa.synchronize(); _ = try await sb.synchronize()
    try await a.delete(id: "n"); _ = try await sa.synchronize()
    try await b.upsert(id: "n", kind: "note", payload: json("offline edit"))
    _ = try await sb.synchronize()
    #expect(try await b.get(id: "n")?.deleted == true)
    #expect(try await b.conflicts().first?.local.payload == json("offline edit"))
}

@Test func remotePullAndCursorAreAtomic() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    let valid = StoredRecord(id: "n", kind: "note", payload: json("valid"), revision: 1)
    let invalid = StoredRecord(id: "bad", kind: "note", payload: json("bad"), revision: 1, formatVersion: 99)
    await #expect(throws: CoreError.self) {
        try await store.apply(PullPage(records: [valid, invalid], cursor: 2, hasMore: false))
    }
    #expect(try await store.get(id: "n") == nil)
    #expect(try await store.syncCursor() == 0)
}

@Test func accountSwitchIsRejectedBeforeNetworkAccess() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    try await store.bindSyncAccount(userID: "account-a")
    let server = TestServer()
    await #expect(throws: CoreError.self) { try await SyncEngine(store: store, transport: server).synchronize() }
    #expect(await server.pushCalls == 0)
}

@Test func assetSnapshotIntegrityAndPathValidation() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("lecture.pdf")
    try Data("abc".utf8).write(to: source)
    let assets = try AssetStore(directory: root.appendingPathComponent("assets"))
    let revision = try await assets.importFile(at: source, contentType: "application/pdf")
    #expect(revision.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(revision.byteCount == 3)
    try Data("changed".utf8).write(to: source)
    try AssetHasher.verify(revision, file: await assets.url(for: revision))
    #expect(throws: CoreError.self) { try AssetHasher.verify(revision, file: source) }
    let traversal = AssetRevision(sha256: "../../private", byteCount: 0, originalName: "", contentType: "")
    await #expect(throws: CoreError.self) { try await assets.url(for: traversal) }
}

private func inkPayload(_ objects: [String: Double], deleted: [String] = []) throws -> Data {
    let shapes: [[String: Any]] = objects.sorted { $0.key < $1.key }.map { id, x in
        ["id": id, "kind": "ink", "data": ["points": [["x": x, "y": 0.4, "p": 0.7]]],
         "style": ["color": "ink", "width": 0.003, "opacity": 1], "createdAt": "2026-10-13T00:00:00Z", "updatedAt": "2026-10-13T00:00:00Z"]
    }
    let page: [String: Any] = ["schemaVersion": 1, "materialID": "pdf", "documentRevision": "hash", "page": 1,
        "coordinateSpace": "unrotated-crop-box-top-left-normalized",
        "geometry": ["cropX": 0, "cropY": 0, "width": 600, "height": 800, "rotation": 0],
        "objects": shapes, "highlights": [], "deletedObjectIDs": deleted, "deletedHighlightIDs": []]
    let data = try JSONSerialization.data(withJSONObject: page, options: [.sortedKeys])
    return try JSONSerialization.data(withJSONObject: ["materialID": "pdf", "documentRevision": "hash", "page": 1,
                                                        "data": data.base64EncodedString()], options: [.sortedKeys])
}

@Test func independentOfflineStrokesMergeAndUploadInOneRun() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = try RecordStore(url: root.appendingPathComponent("a.sqlite"))
    let b = try RecordStore(url: root.appendingPathComponent("b.sqlite"))
    let server = TestServer()
    let sa = SyncEngine(store: a, transport: server), sb = SyncEngine(store: b, transport: server)
    try await a.upsert(id: "drawing:pdf:hash:1", kind: "drawing", payload: inkPayload(["original": 0.1]))
    _ = try await sa.synchronize(); _ = try await sb.synchronize()
    try await a.upsert(id: "drawing:pdf:hash:1", kind: "drawing", payload: inkPayload(["original": 0.1, "a": 0.2]))
    try await b.upsert(id: "drawing:pdf:hash:1", kind: "drawing", payload: inkPayload(["original": 0.1, "b": 0.3]))
    _ = try await sa.synchronize()
    let report = try await sb.synchronize()
    #expect(report.merged == 1)
    #expect(report.conflicts == 0)
    #expect(try await b.pendingOperations().isEmpty)
    #expect(try await b.conflicts().isEmpty)
    _ = try await sa.synchronize()
    #expect(try await a.get(id: "drawing:pdf:hash:1") == b.get(id: "drawing:pdf:hash:1"))
    let record = try #require(await b.get(id: "drawing:pdf:hash:1"))
    let wrapper = try #require(JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
    let portableData = try #require(Data(base64Encoded: wrapper["data"] as! String))
    let portable = try #require(JSONSerialization.jsonObject(with: portableData) as? [String: Any])
    #expect((portable["objects"] as? [[String: Any]])?.count == 3)
    #expect(record.revision == 3)
}

@Test func sameStrokeEditAndDeleteRaceRemainRecoverableConflicts() throws {
    let local = StoredRecord(id: "d", kind: "drawing", payload: try inkPayload(["same": 0.2]), revision: 2)
    let remote = StoredRecord(id: "d", kind: "drawing", payload: try inkPayload(["same": 0.8]), revision: 2)
    #expect(try DrawingMerge.merge(local: local, remote: remote) == nil)
    let deleted = StoredRecord(id: "d", kind: "drawing", payload: try inkPayload([:], deleted: ["same"]), revision: 2)
    #expect(try DrawingMerge.merge(local: deleted, remote: remote) == nil)
}

@Test func syncAccountReadDoesNotBindTheStore() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
    #expect(try await store.syncAccount() == nil)
    #expect(try await store.syncAccount() == nil)
    try await store.bindSyncAccount(userID: user)
    #expect(try await store.syncAccount() == user)
    #expect(try await store.pendingOperations().isEmpty)
}

@Test func oversizedMergedPageFallsBackToRecoverableConflict() throws {
    func largePayload(_ id: String) throws -> Data {
        var wrapper = try #require(JSONSerialization.jsonObject(with: inkPayload([id: 0.5])) as? [String: Any])
        let original = try #require(Data(base64Encoded: wrapper["data"] as! String))
        var page = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var objects = page["objects"] as! [[String: Any]]
        objects[0]["largeObjectData"] = String(repeating: "a", count: 1_600_000)
        page["objects"] = objects
        wrapper["data"] = try JSONSerialization.data(withJSONObject: page).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: wrapper)
    }
    let a = StoredRecord(id: "d", kind: "drawing", payload: try largePayload("a"), revision: 2)
    let b = StoredRecord(id: "d", kind: "drawing", payload: try largePayload("b"), revision: 2)
    try validate(a); try validate(b)
    #expect(try DrawingMerge.merge(local: a, remote: b) == nil)
}
