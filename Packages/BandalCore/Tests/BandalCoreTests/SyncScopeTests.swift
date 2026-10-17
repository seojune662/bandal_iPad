import Foundation
import Testing
@testable import BandalCore

private actor ScopeServer: SyncTransport {
    let userID = "11111111-1111-4111-8111-111111111111"
    var pushed: [String] = []
    func push(_ operation: SyncOperation) async throws -> PushResult { pushed.append(operation.record.id); return PushResult(status: .accepted, record: operation.record) }
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage {
        PullPage(records: [StoredRecord(id: "remote-chat", kind: "chat", payload: Data("{}".utf8), revision: 1)], cursor: max(cursor, 1), hasMore: false)
    }
}

@Test func narrowedScopeRetainsLegacyQueueWithoutStarvingNotes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try RecordStore(url: folder.appendingPathComponent("store.sqlite"))
    for index in 0..<1001 { _ = try await store.upsert(id: "chat-\(index)", kind: "chat", payload: Data("{}".utf8)) }
    _ = try await store.upsert(id: "note", kind: "note", payload: Data("{}".utf8))
    let server = ScopeServer(), engine = SyncEngine(store: store, transport: server)
    let paused = try await engine.synchronize(pushAllowed: false, scope: .personalContentV1)
    #expect(paused.pushed == 0)
    #expect(try await store.get(id: "remote-chat") != nil)
    #expect(try await store.syncCursor() == 1)
    let active = try await engine.synchronize(scope: .personalContentV1)
    #expect(active.pushed == 1)
    #expect(await server.pushed == ["note"])
    #expect(try await store.pendingOperations(limit: 1000).count == 1000)
    #expect(try await store.pendingOperations(scope: .personalContentV1).isEmpty)
}

@Test func uploadedAssetReceiptsAndOptInSurviveReopen() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("store.sqlite"), store = try RecordStore(url: url)
    let revision = AssetRevision(sha256: String(repeating: "a", count: 64), byteCount: 123, originalName: "note.pdf", contentType: "application/pdf")
    #expect(try await store.preference("syncEnabled") == nil)
    #expect(try await store.assetWasUploaded(revision) == false)
    try await store.recordUploadedAsset(revision)
    try await store.setPreference("syncEnabled", value: "true")
    let reopened = try RecordStore(url: url)
    #expect(try await reopened.assetWasUploaded(revision))
    #expect(try await reopened.preference("syncEnabled") == "true")
    let changedSize = AssetRevision(sha256: revision.sha256, byteCount: 124, originalName: "note.pdf", contentType: "application/pdf")
    #expect(try await reopened.assetWasUploaded(changedSize) == false)
}

@Test func multiRecordConflictChoiceRollsBackEveryPageIfAnyChoiceIsInvalid() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try RecordStore(url: folder.appendingPathComponent("store.sqlite"))
    let original = try await store.upsert(id: "material", kind: "material", payload: Data(#"{"revision":1}"#.utf8))
    let selected = StoredRecord(id: "material", kind: "material", payload: Data(#"{"revision":2}"#.utf8), revision: 2)
    let invalid = StoredRecord(id: "page", kind: "not-supported", payload: Data("{}".utf8), revision: 1)
    do {
        _ = try await store.queueConflictResolutions([(selected, [original]), (invalid, [invalid])])
        Issue.record("Invalid page choice should roll back all prior work")
    } catch { }
    #expect(try await store.get(id: "material") == original)
    #expect(try await store.pendingOperations().count == 1)
    #expect(try await store.projectionRecoveryPending() == false)
}
