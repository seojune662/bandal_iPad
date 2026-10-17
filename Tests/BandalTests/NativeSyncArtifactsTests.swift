import Foundation
import XCTest
@testable import Bandal

final class NativeSyncArtifactsTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var artifacts: NativeSyncArtifacts!
    private var courseID: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-sync-artifacts-\(UUID().uuidString)")
        context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        artifacts = NativeSyncArtifacts(context: context); courseID = try createCourse()
    }
    override func tearDownWithError() throws {
        artifacts = nil; context = nil; try FileManager.default.removeItem(at: root)
    }
    private func createCourse() throws -> String {
        let id = UUID().uuidString, folder = root.appendingPathComponent("Courses/" + id), now = NativeRepositoryContext.nowISO
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try context.run("INSERT INTO courses(id,name,slug,color,folder_path,source,created_at,updated_at) VALUES(?,?,?,?,?,'managed',?,?)", [id, "원본 과목", id, "blue", folder.path, now, now]); return id
    }
    private func record(_ id: String, kind: String, _ payload: [String: Any], deleted: Bool = false) -> [String: Any] {
        NativeSyncFormat.record(id: id, kind: kind, payload: payload, deleted: deleted)
    }
    private func commit(_ record: [String: Any], assets: [String: URL] = [:]) throws {
        let plan = try XCTUnwrap(artifacts.plan(record, assets: assets))
        // Test helper stands in for the separately tested production journal.
        for file in plan.files {
            try FileManager.default.createDirectory(at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = file.data { try data.write(to: file.target, options: .atomic) }
            else if FileManager.default.fileExists(atPath: file.target.path) { try FileManager.default.removeItem(at: file.target) }
        }
        try context.transaction { try plan.apply() }
    }
    private func payload(_ id: String) throws -> [String: Any] {
        let snapshot = try artifacts.snapshot()
        return try XCTUnwrap(snapshot.records.first { $0["id"] as? String == id }?["payload"] as? [String: Any])
    }
    func testTaskPlanIsReadOnlyAndRoundTripsGlobalAllDayFieldsAndTombstone() throws {
        let id = UUID().uuidString
        let value = record("task:" + id, kind: "task", ["id": id, "courseID": NSNull(), "title": "시험 준비", "completed": false, "due": "2026-10-22", "desktop": ["notes": "교재 3장", "status": "in-progress", "kind": "exam", "startAt": "2026-10-20", "allDay": true, "color": "violet", "sortOrder": 9]])
        let plan = try XCTUnwrap(artifacts.plan(value, assets: [:]))
        XCTAssertTrue(try context.query("SELECT * FROM board_tasks").isEmpty)
        try context.transaction { try plan.apply() }
        let exported = try payload("task:" + id), desktop = try XCTUnwrap(exported["desktop"] as? [String: Any])
        XCTAssertTrue(exported["courseID"] is NSNull); XCTAssertEqual(exported["due"] as? String, "2026-10-22")
        XCTAssertEqual(desktop["startAt"] as? String, "2026-10-20"); XCTAssertEqual(desktop["notes"] as? String, "교재 3장")
        XCTAssertEqual(desktop["status"] as? String, "in-progress"); XCTAssertEqual(desktop["allDay"] as? Bool, true)
        var deleted = value; deleted["deleted"] = true; try commit(deleted)
        XCTAssertEqual(try artifacts.snapshot().records.first { $0["id"] as? String == "task:" + id }?["deleted"] as? Bool, true)
    }
    func testChatRoundTripPreservesBlocksEffortButNeverImportsDevicePrivileges() throws {
        let id = UUID().uuidString, messageID = UUID().uuidString, blockID = UUID().uuidString
        let value = record("chat:" + id, kind: "chat", ["recordType": "desktop-chat-session", "id": id, "courseID": courseID!, "title": "질문", "provider": "codex", "surface": "app", "reasoningEffort": "high", "accessPolicy": ["mode": "full"], "cliSessionId": "do-not-import", "launchConfig": ["path": "/unsafe"]])
        try commit(value)
        let row = try XCTUnwrap(context.query("SELECT * FROM agent_sessions WHERE id=?", [id]).first)
        XCTAssertEqual(row["effort"] as? String, "high"); XCTAssertTrue(row["cli_session_id"] is NSNull)
        XCTAssertTrue(row["launch_config_json"] is NSNull); XCTAssertTrue(row["access_policy"] is NSNull)
        let message = record("chat:message:" + messageID, kind: "chat", ["recordType": "desktop-chat-message", "id": messageID, "courseID": courseID!, "sessionID": id, "role": "assistant", "turnSequence": 1, "blocks": [["id": blockID, "order": 0, "kind": "text", "payload": ["text": "중단 전에 저장한 응답", "interrupted": true, "futureField": [1, 2, 3]]]]])
        try commit(message)
        let exported = try payload("chat:message:" + messageID), blocks = try XCTUnwrap(exported["blocks"] as? [[String: Any]])
        XCTAssertEqual((blocks.first?["payload"] as? [String: Any])?["futureField"] as? [Int], [1, 2, 3])
        XCTAssertEqual(try payload("chat:" + id)["reasoningEffort"] as? String, "high")
        try context.run("UPDATE agent_sessions SET status='running' WHERE id=?", [id])
        XCTAssertThrowsError(try artifacts.plan(message, assets: [:]))
        XCTAssertThrowsError(try artifacts.plan(value, assets: [:]))
        XCTAssertEqual((try context.query("SELECT COUNT(*) AS n FROM messages").first?["n"] as? NSNumber)?.intValue, 1)
    }
    func testChatRejectsCrossCourseIdentityAndDuplicateBlocksBeforeMutation() throws {
        let id = UUID().uuidString, messageID = UUID().uuidString, block = UUID().uuidString, other = try createCourse()
        var sessionPayload: [String: Any] = ["recordType": "desktop-chat-session", "id": id, "courseID": courseID!, "provider": "codex", "surface": "app"]
        try commit(record("chat:" + id, kind: "chat", sessionPayload))
        sessionPayload["courseID"] = other
        XCTAssertThrowsError(try artifacts.plan(record("chat:" + id, kind: "chat", sessionPayload), assets: [:]))
        let bad = record("chat:message:" + messageID, kind: "chat", ["recordType": "desktop-chat-message", "id": messageID, "courseID": courseID!, "sessionID": id, "role": "user", "turnSequence": 1, "blocks": [["id": block, "order": 0, "kind": "text"], ["id": block, "order": 1, "kind": "text"]]])
        XCTAssertThrowsError(try artifacts.plan(bad, assets: [:])); XCTAssertTrue(try context.query("SELECT * FROM messages").isEmpty)
    }
    func testRecordingImportsFloatAudioPreservesTranscriptAndAnchorsAndRejectsDeletion() throws {
        let id = UUID().uuidString, anchor = UUID().uuidString, url = root.appendingPathComponent("incoming.wav")
        let floatAudio = wav(float: true, values: [-1, -0.5, 0, 0.5, 1])
        try floatAudio.write(to: url)
        let hash = NativeSyncFormat.hash(floatAudio)
        let value = record("recording:" + id, kind: "recording", ["id": id, "courseID": courseID!, "title": "강의 원음", "fileName": "Recordings/\(id).wav", "assetRevision": hash, "byteCount": floatAudio.count, "state": "completed", "segments": [["id": "remote-segment", "time": 0, "text": "처음 자막", "endSample": 5]], "anchors": [["id": anchor, "time": 0.000125, "desktop": ["label": "중요"]]]])
        let planned = try XCTUnwrap(artifacts.plan(value, assets: [hash: url]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: planned.files[0].target.path))
        XCTAssertTrue(try context.query("SELECT * FROM recording_sessions").isEmpty)
        try commit(value, assets: [hash: url])
        let actual = try Data(contentsOf: planned.files[0].target)
        XCTAssertEqual(actual.count, 54); XCTAssertEqual(Array(actual[44...]), [0, 128, 0, 192, 0, 0, 0, 64, 255, 127])
        let exported = try payload("recording:" + id), segments = try XCTUnwrap(exported["segments"] as? [[String: Any]])
        XCTAssertEqual(segments[0]["text"] as? String, "처음 자막"); XCTAssertEqual(segments[0]["endSample"] as? Int, 5)
        let anchors = try XCTUnwrap(exported["anchors"] as? [[String: Any]])
        XCTAssertEqual((anchors[0]["time"] as? Double), 0.000125)
        let firstID = segments[0]["id"] as? String
        XCTAssertEqual((try payload("recording:" + id)["segments"] as? [[String: Any]])?.first?["id"] as? String, firstID)
        var deleted = value; deleted["deleted"] = true
        XCTAssertThrowsError(try artifacts.plan(deleted, assets: [hash: url]))
        XCTAssertEqual(try Data(contentsOf: planned.files[0].target), actual)
        try context.run("UPDATE recording_sessions SET payload=json_set(payload,'$.status','recording') WHERE id=?", [id])
        XCTAssertThrowsError(try artifacts.plan(value, assets: [hash: url]))
        XCTAssertFalse(try artifacts.snapshot().records.contains { $0["id"] as? String == "recording:" + id })
    }
    func testRecordingRejectsCorruptAssetsAndTraversalWithoutPublishingFiles() throws {
        let id = UUID().uuidString, url = root.appendingPathComponent("audio.wav"), bytes = wav(float: false, values: [0, 0])
        try bytes.write(to: url); let hash = NativeSyncFormat.hash(bytes)
        var p: [String: Any] = ["id": id, "courseID": courseID!, "title": "녹음", "fileName": "Recordings/\(id).wav", "assetRevision": hash, "byteCount": bytes.count, "desktop": ["session": ["audioRelPath": "../outside.wav"]]]
        XCTAssertThrowsError(try artifacts.plan(record("recording:" + id, kind: "recording", p), assets: [hash: url]))
        p["desktop"] = [:]; try Data("changed after download".utf8).write(to: url)
        XCTAssertThrowsError(try artifacts.plan(record("recording:" + id, kind: "recording", p), assets: [hash: url]))
        XCTAssertTrue(try context.query("SELECT * FROM recording_sessions").isEmpty)
    }
    func testAudioRejectsInvalidFloatAndTruncatedHeaderLength() throws {
        let url = root.appendingPathComponent("bad.wav")
        try wav(float: true, values: [.nan]).write(to: url)
        XCTAssertThrowsError(try NativeSyncRecordingAudio.read(url))
        var truncated = wav(float: false, values: [0, 0]); truncated.removeLast(); try truncated.write(to: url)
        XCTAssertThrowsError(try NativeSyncRecordingAudio.read(url))
    }
    func testLearningBundlePreservesExactArtifactsAndPublishesStateLast() throws {
        let project = "learning-project", directory = try context.courseFolder(courseID).appendingPathComponent("학습/.bandal/learning")
        let manifest: [String: Any] = ["format": "bandal-learning", "formatVersion": 1, "projectId": project]
        let state: [String: Any] = ["schemaVersion": 1, "projectId": project, "revision": 4, "futureField": ["keep": true]]
        let content: [String: Data] = ["manifest.json": Data(try NativeSyncFormat.canonical(manifest).utf8), "state.json": Data(try NativeSyncFormat.canonical(state).utf8), "artifacts/quiz.json": Data("{\"original\":\"  preserved spacing  \"}".utf8)]
        var files: [[String: Any]] = [], assets: [String: URL] = [:]
        for (path, bytes) in content.sorted(by: { $0.key < $1.key }) {
            let hash = NativeSyncFormat.hash(bytes), source = root.appendingPathComponent(hash)
            try bytes.write(to: source); assets[hash] = source
            files.append(["recordID": "artifact:learning-file:\(project):\(try NativeSyncFormat.digest(path))", "relPath": path, "assetRevision": hash, "byteCount": bytes.count])
        }
        let value = record("artifact:learning-project:" + project, kind: "artifact", ["recordType": "desktop-learning-project", "id": project, "courseID": courseID!, "rootRelPath": "학습", "stateRevision": 4, "files": files])
        let plan = try XCTUnwrap(artifacts.plan(value, assets: assets))
        XCTAssertEqual(plan.files.last?.target.lastPathComponent, "state.json"); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try commit(value, assets: assets)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("artifacts/quiz.json")), content["artifacts/quiz.json"])
        let snapshot = try artifacts.snapshot(), exported = try payload("artifact:learning-project:" + project)
        XCTAssertEqual(exported["stateRevision"] as? Int, 4); XCTAssertEqual((exported["files"] as? [Any])?.count, 3)
        XCTAssertEqual(snapshot.assets.filter { $0["contentType"] as? String == "application/json" }.count, 3)
        let replay = try XCTUnwrap(artifacts.plan(value, assets: assets)); XCTAssertTrue(replay.files.isEmpty)
        try Data("{\"locallyEdited\":true}".utf8).write(to: directory.appendingPathComponent("artifacts/quiz.json"))
        XCTAssertThrowsError(try artifacts.plan(value, assets: assets))
    }
    func testUnknownArtifactRemainsOpaqueAndFavoriteDescriptorRoundTrips() throws {
        XCTAssertNil(try artifacts.plan(record("artifact:newer", kind: "artifact", ["recordType": "future-kind", "unknown": ["kept": true]]), assets: [:]))
        let id = UUID().uuidString, descriptor: [String: Any] = ["kind": "browser", "payload": ["initialUrl": "https://example.org", "futureField": 7]]
        try commit(record("favorite:" + id, kind: "favorite", ["id": id, "courseID": courseID!, "label": "원본 링크", "descriptor": descriptor]))
        XCTAssertEqual(try NativeSyncFormat.canonical(payload("favorite:" + id)["descriptor"]!), try NativeSyncFormat.canonical(descriptor))
    }
    private func wav(float: Bool, values: [Float]) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let bytes = values.count * (float ? 4 : 2)
        text("RIFF"); u32(UInt32(36 + bytes)); text("WAVEfmt "); u32(16); u16(float ? 3 : 1); u16(1); u32(16000); u32(float ? 64000 : 32000); u16(float ? 4 : 2); u16(float ? 32 : 16); text("data"); u32(UInt32(bytes))
        for value in values { if float { u32(value.bitPattern) } else { u16(UInt16(bitPattern: Int16(value * 32767))) } }
        return data
    }
}
