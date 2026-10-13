import XCTest
import BandalCore
import CryptoKit
@testable import Bandal

@MainActor
final class DesktopSyncTests: XCTestCase {
    func testInterruptedRemoteMaterializationRecoversBeforeExportForEveryFailureBoundary() async throws {
        for boundary in ["afterExchange", "download", "flush", "afterMaterialization", "logout"] {
            let fixture = try await DesktopSyncRecoveryFixture()
            defer { fixture.close() }
            var failing = false
            var environment = fixture.environment
            environment.checkpoint = { stage in
                if failing && boundary == stage { throw DesktopRuntimeError("Injected \(stage) interruption") }
                if failing && boundary == "logout" && stage == "afterExchange" {
                    fixture.service?.accountChanged(["phase": "signed-out"])
                }
            }
            let service = try DesktopSyncService(runtime: fixture.runtime, account: fixture.account, environment: environment)
            fixture.service = service
            service.flushOpenDocuments = {
                if failing && boundary == "flush", await fixture.server.currentText() == "remote B" {
                    let pending = try await fixture.store.projectionRecoveryPending()
                    if pending { throw DesktopRuntimeError("Injected document flush failure") }
                }
            }
            try await service.synchronizeNow()
            await fixture.server.changeNote(to: "remote B")
            if boundary == "download" { await fixture.server.setDownloadFailure(true) }
            failing = true
            do { try await service.synchronizeNow(); XCTFail("Expected interruption at \(boundary)") } catch { }
            let pending = try await fixture.store.projectionRecoveryPending()
            XCTAssertTrue(pending, boundary)
            let cursor = try await fixture.store.syncCursor()
            XCTAssertGreaterThan(cursor, 0)
            let received = await fixture.server.currentText()
            XCTAssertEqual(received, "remote B", boundary)
            // A new service/store instance models process termination. No export
            // is allowed to replace received B with the still-visible A.
            failing = false; await fixture.server.setDownloadFailure(false)
            let restarted = try DesktopSyncService(runtime: fixture.runtime, account: fixture.account, environment: fixture.environment)
            fixture.service = restarted
            try await restarted.synchronizeNow()
            let afterRecovery = await fixture.server.currentText()
            XCTAssertEqual(afterRecovery, "remote B", boundary)
            let bytes = try await fixture.runtime.readMaterial(courseID: fixture.courseID, relativePath: fixture.notePath)
            XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "remote B", boundary)
            let stillPending = try await fixture.store.projectionRecoveryPending(), stalePushes = await fixture.server.staleNotePushes()
            XCTAssertFalse(stillPending, boundary)
            XCTAssertEqual(stalePushes, 0, boundary)
        }
    }

    func testRecoveryPreservesNewLocalEditAndDoesNotUploadItUntilConflictResolution() async throws {
        let fixture = try await DesktopSyncRecoveryFixture(); defer { fixture.close() }
        var fail = false, environment = fixture.environment
        environment.checkpoint = { if fail && $0 == "afterExchange" { throw DesktopRuntimeError("Stopped after cursor commit") } }
        let service = try DesktopSyncService(runtime: fixture.runtime, account: fixture.account, environment: environment)
        try await service.synchronizeNow()
        await fixture.server.changeNote(to: "remote B")
        fail = true
        do { try await service.synchronizeNow(); XCTFail("Expected interruption") } catch { }
        _ = try await fixture.runtime.invoke("notes:write", request: ["courseId": fixture.courseID, "relPath": fixture.notePath, "markdown": "local A prime"])
        let restarted = try DesktopSyncService(runtime: fixture.runtime, account: fixture.account, environment: fixture.environment)
        try await restarted.synchronizeNow()
        try await restarted.synchronizeNow()
        let remote = await fixture.server.currentText()
        XCTAssertEqual(remote, "remote B")
        let conflicts = try await restarted.conflicts()
        XCTAssertTrue(conflicts.contains { (($0["local"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String == "local A prime" })
        let bytes = try await fixture.runtime.readMaterial(courseID: fixture.courseID, relativePath: fixture.notePath)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "local A prime")
        let pending = try await fixture.store.projectionRecoveryPending()
        XCTAssertFalse(pending)
        let choice = try XCTUnwrap(conflicts.first { (($0["local"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String == "local A prime" }?["id"] as? String)
        // While A'/B is on screen, receive C but stop before materializing it.
        // Selecting A' must preserve that unseen accepted C as another conflict.
        var stopAfterPull = true, pendingEnvironment = fixture.environment
        pendingEnvironment.checkpoint = { if stopAfterPull && $0 == "afterExchange" { throw DesktopRuntimeError("Stopped before displaying C") } }
        let pendingService = try DesktopSyncService(runtime: fixture.runtime, account: fixture.account, environment: pendingEnvironment)
        await fixture.server.changeNote(to: "remote C received during review")
        do { try await pendingService.synchronizeNow(); XCTFail("Expected C interruption") } catch { }
        stopAfterPull = false
        _ = try await pendingService.restoreConflict(choice, variant: "local")
        try await pendingService.synchronizeNow()
        let selected = await fixture.server.currentText()
        XCTAssertEqual(selected, "local A prime", "pending replay must preserve the user's explicit local choice")
        let retained = try await pendingService.conflicts()
        XCTAssertTrue(retained.contains { (($0["local"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String == "remote C received during review" })
    }

    func testDurableConflictReviewExportAndRestorePreserveEditsMadeDuringReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await runtime.start()
        let courseValue = try await runtime.invoke("courses:create", request: ["name": "충돌 복구", "color": "#60a5fa"])
        let course = try XCTUnwrap((courseValue as? [String: Any])?["id"] as? String)
        let noteValue = try await runtime.invoke("notes:create", request: ["courseId": course, "dirRelPath": "", "title": "보존할 필기"])
        let path = try XCTUnwrap((noteValue as? [String: Any])?["relPath"] as? String)
        _ = try await runtime.invoke("notes:write", request: ["courseId": course, "relPath": path, "markdown": "첫 번째 필기"])
        let snapshotValue = try await runtime.invokePrivate("nativeSync:export")
        let snapshot = try XCTUnwrap(snapshotValue as? [String: Any])
        var incoming = try XCTUnwrap((snapshot["records"] as? [[String: Any]])?.first { $0["kind"] as? String == "note" })
        var payload = try XCTUnwrap(incoming["payload"] as? [String: Any]); payload["markdown"] = "다른 기기의 필기"; incoming["payload"] = payload
        _ = try await runtime.invoke("notes:write", request: ["courseId": course, "relPath": path, "markdown": "동시에 쓴 필기"])
        _ = try await runtime.invokePrivate("nativeSync:import", request: ["records": [incoming], "assets": []])
        var environment = DesktopAccountEnvironment(); environment.configuration = { ("", "") }; environment.readCredential = { nil }
        let account = DesktopAccountService(root: root, environment: environment)
        let service = try DesktopSyncService(runtime: runtime, account: account)
        let conflicts = try await service.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        let id = try XCTUnwrap(conflicts.first?["id"] as? String)
        let status = try await service.status()
        XCTAssertEqual(status["conflicts"] as? Int, 1)
        let exported = try await service.exportConflict(id)
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(exported["data"] as? String)))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(((json["local"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String, "동시에 쓴 필기")
        XCTAssertEqual(((json["remote"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String, "다른 기기의 필기")
        // The user keeps editing while the conflict preview is open.
        var flushed = false
        service.flushOpenDocuments = {
            _ = try await runtime.invoke("notes:write", request: ["courseId": course, "relPath": path, "markdown": "검토하는 동안 추가한 필기"])
            flushed = true
        }
        let restored = try await service.restoreConflict(id, variant: "remote")
        XCTAssertTrue(flushed); XCTAssertEqual(restored["ok"] as? Bool, true)
        let written = try await runtime.readMaterial(courseID: course, relativePath: path)
        XCTAssertEqual(String(decoding: written, as: UTF8.self), "다른 기기의 필기")
        let retained = try await service.conflicts()
        XCTAssertTrue(retained.contains { (($0["local"] as? [String: Any])?["payload"] as? [String: Any])?["markdown"] as? String == "검토하는 동안 추가한 필기" })
        XCTAssertFalse(retained.contains { $0["id"] as? String == id })
        // A new service instance reads durable projector history, not an array
        // held only by the settings screen or the last import result.
        let reopened = try DesktopSyncService(runtime: runtime, account: account)
        let reread = try await reopened.conflicts()
        XCTAssertEqual(reread.count, retained.count)
    }

    func testLearningManifestReferencesAllAssetsEvenWhenFileRecordsAreOutsidePushBatch() throws {
        let hashA = String(repeating: "a", count: 64), hashB = String(repeating: "b", count: 64)
        let record = try DesktopSyncService.record(["id": "artifact:project", "kind": "artifact", "payload": [
            "recordType": "desktop-learning-project", "files": [
                ["relPath": "state.json", "assetRevision": hashA, "byteCount": 24],
                ["relPath": "articles/article.json", "assetRevision": hashB, "byteCount": 128]
            ]
        ]])
        let references = try DesktopSyncService.references(record)
        XCTAssertEqual(Set(references.map(\.sha256)), [hashA, hashB])
        XCTAssertEqual(references.map(\.originalName), ["state.json", "article.json"])
        let invalid = try DesktopSyncService.record(["id": "artifact:invalid", "kind": "artifact", "payload": ["recordType": "desktop-learning-project", "files": [["relPath": "state.json", "assetRevision": "../escape", "byteCount": 24]]]])
        XCTAssertThrowsError(try DesktopSyncService.references(invalid))
    }
}

private actor DesktopSyncRecoveryServer {
    let userID = "11111111-1111-4111-8111-111111111111"
    private var records: [String: StoredRecord] = [:]
    private var receipts: [String: PushResult] = [:]
    private var changes: [StoredRecord] = []
    private var assets: [String: Data] = [:]
    private var failDownload = false
    private var remoteChanged = false
    private var stalePushes = 0
    func setDownloadFailure(_ value: Bool) { failDownload = value }
    func staleNotePushes() -> Int { stalePushes }
    func currentText() -> String? {
        guard let record = records.values.first(where: { $0.kind == "note" }), let payload = try? JSONSerialization.jsonObject(with: record.payload) as? [String: Any] else { return nil }
        return payload["markdown"] as? String
    }
    func changeNote(to text: String) {
        let note = records.values.first { $0.kind == "note" }!
        var payload = try! JSONSerialization.jsonObject(with: note.payload) as! [String: Any]
        payload["markdown"] = text
        let changed = StoredRecord(id: note.id, kind: note.kind, payload: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), revision: note.revision + 1)
        records[changed.id] = changed; changes.append(changed)
        let bytes = Data(text.utf8), hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        assets[hash] = bytes
        let material = records["material:\(payload["materialID"] as! String)"]!
        var metadata = try! JSONSerialization.jsonObject(with: material.payload) as! [String: Any]
        metadata["revision"] = hash; metadata["byteCount"] = bytes.count
        let file = StoredRecord(id: material.id, kind: material.kind, payload: try! JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), revision: material.revision + 1)
        records[file.id] = file; changes.append(file); remoteChanged = true
    }
    func push(_ operation: SyncOperation) throws -> PushResult {
        if let receipt = receipts[operation.id] { return receipt }
        let result: PushResult
        if let current = records[operation.record.id], current.revision != operation.baseRevision {
            result = PushResult(status: .conflict, record: current)
        } else {
            if remoteChanged && operation.record.kind == "note" {
                let payload = try JSONSerialization.jsonObject(with: operation.record.payload) as! [String: Any]
                if payload["markdown"] as? String == "original A" { stalePushes += 1 }
            }
            records[operation.record.id] = operation.record; changes.append(operation.record)
            result = PushResult(status: .accepted, record: operation.record)
        }
        receipts[operation.id] = result; return result
    }
    func pull(after cursor: Int64, limit: Int) -> PullPage {
        let end = min(changes.count, Int(cursor) + limit)
        return PullPage(records: Array(changes[Int(cursor)..<end]), cursor: Int64(end), hasMore: end < changes.count)
    }
    func upload(_ revision: AssetRevision, file: URL) throws { assets[revision.sha256] = try Data(contentsOf: file) }
    func download(_ revision: AssetRevision, destination: URL) throws {
        if failDownload { throw URLError(.networkConnectionLost) }
        guard let data = assets[revision.sha256] else { throw URLError(.fileDoesNotExist) }
        try data.write(to: destination)
    }
}

private struct DesktopSyncRecoveryTransport: DesktopSyncTransport {
    let userID: String
    let server: DesktopSyncRecoveryServer
    let token: @Sendable () async throws -> String
    func push(_ operation: SyncOperation) async throws -> PushResult { _ = try await token(); return try await server.push(operation) }
    func pull(after cursor: Int64, limit: Int) async throws -> PullPage { _ = try await token(); return await server.pull(after: cursor, limit: limit) }
    func uploadAsset(_ revision: AssetRevision, from file: URL) async throws { _ = try await token(); try await server.upload(revision, file: file) }
    func downloadAsset(_ revision: AssetRevision, to destination: URL) async throws { _ = try await token(); try await server.download(revision, destination: destination) }
}

@MainActor
private final class DesktopSyncRecoveryFixture {
    let root: URL
    let runtime: DesktopRuntime
    let account: DesktopAccountService
    let server = DesktopSyncRecoveryServer()
    let store: RecordStore
    let courseID: String
    let notePath: String
    weak var service: DesktopSyncService?
    var environment: DesktopSyncEnvironment {
        var value = DesktopSyncEnvironment()
        value.transport = { identity, token in DesktopSyncRecoveryTransport(userID: identity.userID, server: self.server, token: token) }
        return value
    }
    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-recovery-\(UUID().uuidString)")
        runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await runtime.start()
        let created = try await runtime.invoke("courses:create", request: ["name": "복구 검증", "color": "#60a5fa"])
        courseID = try XCTUnwrap((created as? [String: Any])?["id"] as? String)
        let note = try await runtime.invoke("notes:create", request: ["courseId": courseID, "dirRelPath": "", "title": "보존할 필기"])
        notePath = try XCTUnwrap((note as? [String: Any])?["relPath"] as? String)
        _ = try await runtime.invoke("notes:write", request: ["courseId": courseID, "relPath": notePath, "markdown": "original A"])
        let user = "11111111-1111-4111-8111-111111111111", url = "https://sync-fixture.invalid"
        let claims = try JSONSerialization.data(withJSONObject: ["sub": user, "iss": url + "/auth/v1", "exp": Date().timeIntervalSince1970 + 3600])
        let token = "fixture." + claims.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
        let credential = String(decoding: try JSONSerialization.data(withJSONObject: ["access_token": token, "refresh_token": "fixture-refresh", "expires_at": Date().timeIntervalSince1970 + 3600, "user": ["id": user]]), as: UTF8.self)
        var environment = DesktopAccountEnvironment()
        environment.configuration = { (url, "fixture-key") }; environment.readCredential = { credential }; environment.writeCredential = { _ in }
        environment.request = { request in (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        account = DesktopAccountService(root: root, environment: environment)
        store = try RecordStore(url: root.appendingPathComponent("CommonSync/bandal.sqlite"))
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}

final class DesktopLogTests: XCTestCase {
    func testBoundedOperationalLogSurvivesRotationWithoutRequestContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DesktopLog(root: root, limit: 240)
        for _ in 0..<15 { log.record("ipc.failed", channel: "notes:write", code: "ENOSPC") }
        log.record("runtime.recovered")
        await log.flush()
        let directory = root.appendingPathComponent("Logs")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 240) }
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("bandal.log"), encoding: .utf8).contains("runtime.recovered"))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("bandal.previous.log"), encoding: .utf8).contains("channel=notes:write code=ENOSPC"))
    }
}
