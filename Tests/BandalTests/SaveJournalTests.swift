import XCTest
import BandalCore
@testable import Bandal

@MainActor
final class SaveJournalTests: XCTestCase {
    func testCallbackJournalRecoversWhenSQLiteCommitNeverRan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try LocalSaveJournal(directory: root.appendingPathComponent("pending"))
        let payload = Data("{\"markdown\":\"completed edit\"}".utf8)
        _ = try journal.append(id: "note:test", kind: "note", payload: payload)
        // Simulate termination between the synchronous callback and async DB work.
        let reopened = try LocalSaveJournal(directory: root.appendingPathComponent("pending"))
        let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
        try await reopened.recover(into: store)
        let record = try await store.get(id: "note:test")
        XCTAssertEqual(record?.payload, payload)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: reopened.directory.path).isEmpty)
    }
    func testCrashAfterCommitCannotReplayOlderContentOverNewEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try LocalSaveJournal(directory: root.appendingPathComponent("pending"))
        let (entry, _) = try journal.append(id: "note:test", kind: "note", payload: Data("{\"value\":1}".utf8))
        let store = try RecordStore(url: root.appendingPathComponent("records.sqlite"))
        _ = try await store.applyLocalJournalEntry(mutationID: entry.mutationID, id: entry.id, kind: entry.kind, payload: entry.payload)
        let newer = Data("{\"value\":2}".utf8)
        _ = try await store.upsert(id: entry.id, kind: entry.kind, payload: newer)
        try await journal.recover(into: store)
        let record = try await store.get(id: entry.id)
        XCTAssertEqual(record?.payload, newer)
    }
}
