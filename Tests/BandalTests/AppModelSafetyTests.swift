import XCTest
import BandalCore
@testable import Bandal

@MainActor
final class AppModelSafetyTests: XCTestCase {
    private func makeModel(_ root: URL) async -> AppModel {
        let model = AppModel(storageRoot: root, seedWelcome: false)
        while model.loading { await Task.yield() }
        model.addCourse("Safety tests")
        await model.flush()
        return model
    }

    func testDecoderAcceptsDesktopFractionalAndNativeWholeSecondDates() throws {
        struct Stamp: Decodable { var date: Date }
        let whole = try AppModel.decoder.decode(Stamp.self, from: Data(#"{"date":"2026-10-13T01:02:03Z"}"#.utf8))
        let fractional = try AppModel.decoder.decode(Stamp.self, from: Data(#"{"date":"2026-10-13T01:02:03.456Z"}"#.utf8))
        XCTAssertEqual(fractional.date.timeIntervalSince(whole.date), 0.456, accuracy: 0.0001)
        XCTAssertThrowsError(try AppModel.decoder.decode(Stamp.self, from: Data(#"{"date":"not-a-date"}"#.utf8)))
    }

    func testInvalidMarkdownFailsBeforeAnyMetadataOrCacheWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await makeModel(root)
        let original = try XCTUnwrap(model.createNote(markdown: "Existing text", open: false))
        await model.flush()
        let recordsBefore = try await model.store!.list()
        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Materials").path)
        let bad = root.appendingPathComponent("invalid.md")
        let invalid = Data([0xFF, 0xFE, 0x81])
        try invalid.write(to: bad)
        model.importURL(bad)
        await model.flush()
        let recordsAfter = try await model.store!.list()
        XCTAssertEqual(Set(recordsAfter.map(\.id)), Set(recordsBefore.map(\.id)))
        XCTAssertEqual(model.materials.map(\.id), [original.id])
        XCTAssertEqual(model.notes[original.id], "Existing text")
        XCTAssertEqual(try Data(contentsOf: model.fileURL(original)), Data("Existing text".utf8))
        XCTAssertEqual(try Data(contentsOf: bad), invalid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Materials").path), filesBefore)
        XCTAssertTrue(model.error?.contains("UTF-8") == true)
    }

    func testOversizeEditsKeepOneLatestRecoveryAndDoNotCommitCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await makeModel(root)
        let item = try XCTUnwrap(model.createNote(markdown: "Saved text", open: false))
        await model.flush()
        let oversized = String(repeating: "a", count: 4 * 1024 * 1024)
        XCTAssertFalse(model.saveNote(item.id, markdown: oversized))
        XCTAssertFalse(model.saveNote(item.id, markdown: oversized + "b"))
        XCTAssertEqual(model.notes[item.id], "Saved text")
        XCTAssertEqual(try Data(contentsOf: model.fileURL(item)), Data("Saved text".utf8))
        let copies = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        let recovered = try AppModel.decoder.decode(NoteContent.self, from: Data(contentsOf: XCTUnwrap(copies.first)))
        XCTAssertEqual(recovered.markdown, oversized + "b")
        let stored = try await model.store!.get(id: "note:\(item.id)")
        XCTAssertEqual(try AppModel.decoder.decode(NoteContent.self, from: XCTUnwrap(stored).payload).markdown, "Saved text")
        XCTAssertNil(model.createNote(markdown: oversized, open: false))
        XCTAssertEqual(model.materials.count, 1)
    }

    func testJournalFailureLeavesNoteStateAndFileUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await makeModel(root)
        let item = try XCTUnwrap(model.createNote(markdown: "Saved text", open: false))
        await model.flush()
        let journal = root.appendingPathComponent("PendingEdits")
        try FileManager.default.removeItem(at: journal)
        try Data("Blocked journal directory".utf8).write(to: journal)
        XCTAssertFalse(model.saveNote(item.id, markdown: "Must not reach cache"))
        XCTAssertNil(model.createNote(markdown: "Must not appear", open: false))
        XCTAssertEqual(model.notes[item.id], "Saved text")
        XCTAssertEqual(try Data(contentsOf: model.fileURL(item)), Data("Saved text".utf8))
        XCTAssertEqual(model.materials.count, 1)
        let stored = try await model.store!.get(id: "note:\(item.id)")
        XCTAssertEqual(try AppModel.decoder.decode(NoteContent.self, from: XCTUnwrap(stored).payload).markdown, "Saved text")
    }

    func testImportLockRejectsEditsDeletionAndAnotherImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await makeModel(root)
        let item = try XCTUnwrap(model.createNote(markdown: "Saved", open: false))
        await model.flush()
        model.isImporting = true
        XCTAssertFalse(model.saveNote(item.id, markdown: "Rejected"))
        XCTAssertFalse(model.persist(NoteContent(materialID: item.id, markdown: "Rejected"), kind: "note", id: "note:\(item.id)"))
        model.deleteRecord("note:\(item.id)")
        model.importURL(model.fileURL(item))
        await model.flush()
        let record = try await model.store!.get(id: "note:\(item.id)")
        XCTAssertNotNil(record)
        XCTAssertEqual(model.materials.count, 1)
        XCTAssertEqual(model.notes[item.id], "Saved")
    }

    func testLegacyMigrationVerifiesRevisionAndPreservesOldBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await makeModel(root)
        let oldBytes = Data("Original PDF bytes".utf8)
        let original = Material(courseID: model.courseID, title: "PDF", fileName: "lecture.pdf", revision: AppModel.hash(oldBytes), kind: .pdf)
        let legacy = root.appendingPathComponent(original.legacyRelativePath)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try oldBytes.write(to: legacy)
        XCTAssertTrue(model.persist(original, kind: "material", id: "material:\(original.id)"))
        await model.reload()
        XCTAssertEqual(try Data(contentsOf: model.fileURL(original)), oldBytes)
        XCTAssertEqual(try Data(contentsOf: legacy), oldBytes)
        var incoming = original
        incoming.revision = AppModel.hash(Data("Replacement PDF".utf8))
        XCTAssertNotEqual(incoming.relativePath, original.relativePath)
        XCTAssertTrue(model.persist(incoming, kind: "material", id: "material:\(incoming.id)"))
        await model.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.fileURL(incoming).path))
        XCTAssertEqual(try Data(contentsOf: model.fileURL(original)), oldBytes)
        XCTAssertEqual(try Data(contentsOf: legacy), oldBytes)
        XCTAssertThrowsError(try model.write(Data("Wrong bytes".utf8), for: original))
        XCTAssertEqual(try Data(contentsOf: model.fileURL(original)), oldBytes)
        let note = Material(courseID: model.courseID, title: "Note", fileName: "note.md", revision: "revision", kind: .note)
        XCTAssertEqual(note.relativePath, note.legacyRelativePath)
    }
}
