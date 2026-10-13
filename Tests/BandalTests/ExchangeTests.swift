import XCTest
import BandalCore
@testable import Bandal

@MainActor
final class ExchangeTests: XCTestCase {
    private func record<T: Encodable>(_ value: T, kind: String, id: String) throws -> StoredRecord {
        StoredRecord(id: id, kind: kind, payload: try AppModel.encoder.encode(value))
    }
    func testPreflightRejectsOversizeAndDuplicateAssets() throws {
        let bytes = Data("pdf fixture".utf8)
        let item = Material(courseID: "course", title: "PDF", fileName: "test.pdf", revision: AppModel.hash(bytes), kind: .pdf)
        let material = try record(item, kind: "material", id: "material:\(item.id)")
        let asset = ExchangeAsset(materialID: item.id, sha256: item.revision, byteCount: Int64(bytes.count), fileName: item.fileName, data: bytes)
        XCTAssertThrowsError(try AppModel.validateExchange(ExchangePackage(records: [material], assets: [asset, asset])))
        let oversized = StoredRecord(id: "note:large", kind: "note", payload: Data(repeating: 32, count: 4 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try AppModel.validateExchange(ExchangePackage(records: [oversized], assets: [])))
    }
    func testReplacementCommitsAsBatchAndKeepsOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, seedWelcome: false)
        while model.loading { await Task.yield() }
        let old = Data("old document".utf8), new = Data("replacement".utf8)
        var item = Material(courseID: "course", title: "PDF", fileName: "test.pdf", revision: AppModel.hash(old), kind: .pdf)
        try model.write(old, for: item)
        let oldURL = model.fileURL(item)
        XCTAssertTrue(model.persist(item, kind: "material", id: "material:\(item.id)"))
        try await model.flushChecked()
        item.revision = AppModel.hash(new)
        let package = ExchangePackage(records: [try record(item, kind: "material", id: "material:\(item.id)")], assets: [ExchangeAsset(materialID: item.id, sha256: item.revision, byteCount: Int64(new.count), fileName: item.fileName, data: new)])
        model.isImporting = true
        try await model.importValidatedExchange(package, original: JSONEncoder().encode(package))
        model.isImporting = false
        XCTAssertNotEqual(oldURL, model.fileURL(item))
        XCTAssertEqual(try Data(contentsOf: oldURL), old)
        XCTAssertEqual(try Data(contentsOf: model.fileURL(item)), new)
        XCTAssertEqual(model.material(item.id)?.revision, item.revision)
    }
    func testKindConflictRejectsBeforeInstallingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, seedWelcome: false)
        while model.loading { await Task.yield() }
        let data = Data("new document".utf8)
        let item = Material(courseID: "course", title: "PDF", fileName: "test.pdf", revision: AppModel.hash(data), kind: .pdf)
        _ = try await model.store?.upsert(id: "material:\(item.id)", kind: "artifact", payload: Data("{}".utf8))
        let package = ExchangePackage(records: [try record(item, kind: "material", id: "material:\(item.id)")], assets: [ExchangeAsset(materialID: item.id, sha256: item.revision, byteCount: Int64(data.count), fileName: item.fileName, data: data)])
        do { try await model.importValidatedExchange(package, original: JSONEncoder().encode(package)); XCTFail("Import should reject kind changes") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.fileURL(item).path))
        let preserved = try await model.store?.get(id: "material:\(item.id)")
        XCTAssertEqual(preserved?.kind, "artifact")
    }
    func testNoteExportHasOneAuthoritativeCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(storageRoot: root, seedWelcome: false)
        while model.loading { await Task.yield() }
        model.addCourse("Course")
        let item = try XCTUnwrap(model.createNote(markdown: "A note"))
        let file = try await model.exportExchange()
        defer { try? FileManager.default.removeItem(at: file) }
        let package = try JSONDecoder().decode(ExchangePackage.self, from: Data(contentsOf: file))
        XCTAssertFalse(package.assets.contains { $0.materialID == item.id })
        XCTAssertTrue(package.records.contains { $0.id == "note:\(item.id)" })
        try AppModel.validateExchange(package)
    }
}
