import Foundation
import XCTest
@testable import Bandal

final class NativeLibraryRepositoryTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var repository: NativeLibraryRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-library-\(UUID().uuidString)")
        context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        repository = NativeLibraryRepository(context: context)
    }
    override func tearDownWithError() throws { repository = nil; context = nil; try FileManager.default.removeItem(at: root) }
    private func call(_ channel: String, _ request: [String: Any] = [:]) throws -> Any { try { let result = try repository.handle(channel, request); return try XCTUnwrap(result) }() }
    private func course() throws -> String { let result = try XCTUnwrap(call("courses:create", ["name": "보존할 과목", "color": "blue"]) as? [String: Any]); return try XCTUnwrap(result["id"] as? String) }
    private func note(_ course: String, title: String = "기존 제목") throws -> String { let result = try XCTUnwrap(call("notes:create", ["courseId": course, "dirRelPath": "", "title": title]) as? [String: Any]); return try XCTUnwrap(result["relPath"] as? String) }

    func testAllMigrationsAndReopenPreserveExistingRows() throws {
        let id = try course(), relative = try note(id)
        let original = try Data(contentsOf: context.materialURL(courseID: id, relativePath: relative))
        let before = try context.query("SELECT * FROM courses WHERE id=?", [id]).first!
        let reopened = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        XCTAssertEqual((try reopened.query("SELECT COUNT(*) AS n FROM migrations").first?["n"] as? NSNumber)?.intValue, 37)
        XCTAssertEqual(try reopened.query("SELECT id FROM courses WHERE id=?", [id]).first?["id"] as? String, id)
        XCTAssertEqual(try reopened.query("SELECT created_at FROM courses WHERE id=?", [id]).first?["created_at"] as? String, before["created_at"] as? String)
        XCTAssertEqual(try Data(contentsOf: reopened.materialURL(courseID: id, relativePath: relative)), original)
        XCTAssertTrue(try reopened.query("PRAGMA foreign_key_check").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("bandal.sqlite").path))
    }
    func testExpectedMtimeRejectsConcurrentWriteAndDeletedFile() throws {
        let id = try course(), relative = try note(id)
        let read = try XCTUnwrap(call("notes:read", ["courseId": id, "relPath": relative]) as? [String: Any])
        _ = try call("notes:write", ["courseId": id, "relPath": relative, "markdown": "external newest", "expectedMtime": read["mtime"]!])
        XCTAssertThrowsError(try call("notes:write", ["courseId": id, "relPath": relative, "markdown": "stale", "expectedMtime": read["mtime"]!]))
        let url = try context.materialURL(courseID: id, relativePath: relative)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external newest")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try call("notes:write", ["courseId": id, "relPath": relative, "markdown": "recreated stale", "expectedMtime": read["mtime"]!]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testLinkedFolderAndSymlinkContainment() throws {
        let external = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: external.appendingPathComponent("source.md"))
        let linked = try XCTUnwrap(call("courses:addFromFolder", ["folderPath": external.path, "name": "연결된 과목", "color": "green"]) as? [String: Any])
        let linkedID = try XCTUnwrap((linked["course"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: linkedID, relativePath: "source.md"), encoding: .utf8), "outside")
        let id = try course(), folder = try context.courseFolder(id)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: external)
        for path in ["../External/source.md", "/tmp/source.md", "escape/source.md", "escape/new.md", "a//b.md"] {
            XCTAssertThrowsError(try context.materialURL(courseID: id, relativePath: path, allowMissing: true), path)
        }
        _ = try call("courses:delete", ["courseId": linkedID])
        XCTAssertEqual(try String(contentsOf: external.appendingPathComponent("source.md"), encoding: .utf8), "outside")
    }
    func testImportAndTrashKeepOriginalBytes() throws {
        let id = try course(), input = root.appendingPathComponent("original.pdf"), bytes = Data([0, 1, 2, 255])
        try bytes.write(to: input)
        let imported = try XCTUnwrap(call("materials:import", ["courseId": id, "paths": [input.path]]) as? [String: Any])
        let path = try XCTUnwrap((imported["imported"] as? [String])?.first)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        _ = try call("materials:delete", ["courseId": id, "relPath": path])
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("Trash"), includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "pdf" }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), bytes)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }
    func testRenameRepointsNotesAndRowsAndPreservesReceipt() throws {
        let id = try course(), old = try note(id), backlink = try note(id, title: "연결 노트")
        _ = try call("notes:write", ["courseId": id, "relPath": old, "markdown": "# 기존 제목\n[[기존 제목]]"])
        _ = try call("notes:write", ["courseId": id, "relPath": backlink, "markdown": "[[기존 제목|별칭]] [보기](bandal://material?path=%EA%B8%B0%EC%A1%B4%20%EC%A0%9C%EB%AA%A9.md)"])
        _ = try call("materials:tree", ["courseId": id])
        let identity = try context.query("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [id, old]).first?["id"] as? String
        let renamed = try XCTUnwrap(call("notes:rename", ["courseId": id, "relPath": old, "newName": "새 제목"]) as? [String: Any])
        let next = try XCTUnwrap(renamed["relPath"] as? String)
        XCTAssertEqual(renamed["markdown"] as? String, "# 새 제목\n[[새 제목]]")
        let body = try String(contentsOf: context.materialURL(courseID: id, relativePath: backlink), encoding: .utf8)
        XCTAssertTrue(body.contains("[[새 제목|별칭]]"))
        XCTAssertEqual(try context.query("SELECT id FROM materials_index WHERE course_id=? AND rel_path=?", [id, next]).first?["id"] as? String, identity)
        XCTAssertTrue(try context.query("SELECT * FROM material_path_intents").isEmpty)
    }
    func testRenameSQLFailureRollsBackFileHeadingAndBacklinks() throws {
        let id = try course(), old = try note(id), backlink = try note(id, title: "링크")
        _ = try call("notes:write", ["courseId": id, "relPath": backlink, "markdown": "[[기존 제목]]"])
        _ = try call("materials:tree", ["courseId": id])
        try context.db.exec("CREATE TRIGGER native_fixture_rename_failure BEFORE UPDATE OF rel_path ON materials_index BEGIN SELECT RAISE(ABORT,'fixture rename failure'); END")
        XCTAssertThrowsError(try call("notes:rename", ["courseId": id, "relPath": old, "newName": "변경 제목"]))
        XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: id, relativePath: old), encoding: .utf8), "# 기존 제목\n")
        XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: id, relativePath: backlink), encoding: .utf8), "[[기존 제목]]")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try context.courseFolder(id).appendingPathComponent("변경 제목.md").path))
        XCTAssertTrue(try context.query("SELECT * FROM material_path_intents").isEmpty)
    }
    func testInterruptedRenameRestoresCapturedOriginalOnReopen() throws {
        let id = try course(), old = try note(id), folder = try context.courseFolder(id), source = try context.materialURL(courseID: id, relativePath: old), next = "중단된 이름.md"
        let original = try NativeRepositoryContext.identity(source), folderIdentity = try NativeRepositoryContext.identity(folder)
        let before = try String(contentsOf: source, encoding: .utf8), after = "# 중단된 이름\n"
        try context.run("INSERT INTO material_path_intents(id,course_id,folder_path,folder_identity,from_rel_path,to_rel_path,original_identity,created_at,note_writes) VALUES(?,?,?,?,?,?,?,?,?)", [UUID().uuidString, id, folder.path, NativeRepositoryContext.json(folderIdentity), old, next, NativeRepositoryContext.json(original), NativeRepositoryContext.nowISO, NativeRepositoryContext.json([["relPath": next, "before": before, "after": after]])])
        let target = folder.appendingPathComponent(next)
        try FileManager.default.moveItem(at: source, to: target)
        try context.atomicWrite(Data(after.utf8), to: target)
        let reopened = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try NativeLibraryRepository(context: reopened).recoverPathChanges()
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try reopened.query("SELECT * FROM material_path_intents").isEmpty)
    }
    func testGroupRemovalNeverDeletesCourseAndCourseRenameKeepsFolder() throws {
        let id = try course(), originalFolder = try context.courseFolder(id)
        let group = try XCTUnwrap(call("courseGroups:create", ["name": "가을 학기"]) as? [String: Any]), groupID = try XCTUnwrap(group["id"] as? String)
        _ = try call("courses:organize", ["courseId": id, "groupId": groupID, "beforeCourseId": NSNull()])
        _ = try call("courseGroups:delete", ["groupId": groupID])
        _ = try call("courses:rename", ["courseId": id, "name": "이름만 변경"])
        XCTAssertEqual(try context.courseFolder(id), originalFolder)
        let list = try XCTUnwrap(call("courses:list") as? [[String: Any]])
        XCTAssertEqual(list.first?["name"] as? String, "이름만 변경")
        XCTAssertTrue(list.first?["groupId"] is NSNull)
    }
    func testUnicodeEquivalentPathsAndNestedDuplicateNamesDoNotCrash() throws {
        let id = try course(), nfc = "보존할 노트.md", nfd = nfc.decomposedStringWithCanonicalMapping
        _ = try call("notes:create", ["courseId": id, "dirRelPath": "", "title": "보존할 노트"])
        _ = try call("materials:createFolder", ["courseId": id, "dirRelPath": "", "name": "Nested"])
        _ = try call("notes:create", ["courseId": id, "dirRelPath": "Nested", "title": "보존할 노트"])
        _ = try call("materials:tree", ["courseId": id])
        try context.run("INSERT OR REPLACE INTO material_added_state(course_id,rel_path,added_at) VALUES(?,?,?)", [id, nfc, 1])
        try context.run("INSERT OR REPLACE INTO material_added_state(course_id,rel_path,added_at) VALUES(?,?,?)", [id, nfd, 2])
        let tree = try XCTUnwrap(call("materials:tree", ["courseId": id]) as? [[String: Any]])
        XCTAssertEqual(tree.count, 2)
        let nested = try XCTUnwrap(tree.first { $0["kind"] as? String == "dir" }?["children"] as? [[String: Any]])
        XCTAssertEqual(nested.first?["relPath"] as? String, "Nested/" + nfc)
    }

    func testUnchangedMaterialPollDoesNotRewriteIndexAndExternalChangesStillRefresh() throws {
        let id = try course(), folder = try context.courseFolder(id)
        for number in 0..<40 { try Data("# Note \(number)".utf8).write(to: folder.appendingPathComponent("\(number).md")) }
        let initial = try NativeRepositoryContext.json(call("materials:tree", ["courseId": id]))
        func changes() throws -> Int64 { try XCTUnwrap(context.query("SELECT total_changes() AS n").first?["n"] as? NSNumber).int64Value }
        let writes = try changes()
        for _ in 0..<3 { XCTAssertEqual(try NativeRepositoryContext.json(call("materials:tree", ["courseId": id])), initial) }
        XCTAssertEqual(try changes(), writes, "The 5 s watcher and share refresh must not rewrite unchanged material rows")

        let externalEdit = Data("# Externally changed note with different length".utf8)
        try externalEdit.write(to: folder.appendingPathComponent("0.md"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("1.md"))
        try Data("# Added externally".utf8).write(to: folder.appendingPathComponent("new.md"))
        let changed = try XCTUnwrap(call("materials:tree", ["courseId": id]) as? [[String: Any]])
        XCTAssertTrue(changed.contains { $0["relPath"] as? String == "new.md" })
        XCTAssertFalse(changed.contains { $0["relPath"] as? String == "1.md" })
        XCTAssertEqual((try context.query("SELECT size FROM materials_index WHERE course_id=? AND rel_path='0.md'", [id]).first?["size"] as? NSNumber)?.intValue, externalEdit.count)
        XCTAssertNotNil(try context.query("SELECT deleted_at FROM materials_index WHERE course_id=? AND rel_path='1.md'", [id]).first?["deleted_at"] as? String)
        let refreshedWrites = try changes()
        XCTAssertGreaterThan(refreshedWrites, writes)
        _ = try call("materials:tree", ["courseId": id])
        XCTAssertEqual(try changes(), refreshedWrites)
    }

    func testMatchingSnapshotDoesNotSkipIncompleteMaterialBaseline() throws {
        let id = try course()
        _ = try note(id)
        _ = try call("materials:tree", ["courseId": id])
        try context.run("UPDATE material_added_baselines SET completed=0 WHERE course_id=?", [id])
        _ = try call("materials:tree", ["courseId": id])
        XCTAssertEqual((try context.query("SELECT completed FROM material_added_baselines WHERE course_id=?", [id]).first?["completed"] as? NSNumber)?.intValue, 1)
    }

    func testShareFoldersReadDoesNotBuildIndexAndReflectsDirectoryChanges() throws {
        let id = try course(), folder = try context.courseFolder(id)
        for relative in ["자료/시험", "다른 폴더", ".hidden/secret"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        try Data("# Note".utf8).write(to: folder.appendingPathComponent("자료/note.md"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("shortcut"), withDestinationURL: root)
        let changes = context.db.totalChanges
        let folders = try XCTUnwrap(call("nativeMaterial:folders", ["courseId": id]) as? [String])
        XCTAssertEqual(Set(folders), ["자료", "자료/시험", "다른 폴더"])
        XCTAssertEqual(context.db.totalChanges, changes, "Publishing share destinations must not rewrite the material/sync index")
        XCTAssertTrue(try context.query("SELECT * FROM materials_index WHERE course_id=?", [id]).isEmpty)
        XCTAssertTrue(try context.query("SELECT * FROM material_added_baselines WHERE course_id=?", [id]).isEmpty)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("자료/시험"), to: folder.appendingPathComponent("자료/새 시험"))
        XCTAssertEqual(Set(try XCTUnwrap(call("nativeMaterial:folders", ["courseId": id]) as? [String])), ["자료", "자료/새 시험", "다른 폴더"])
        XCTAssertEqual(context.db.totalChanges, changes)
    }

    func testContainerRelocationRebasesOnlyLocalMetadataAndKeepsCanonicalPayload() throws {
        let old = root.appendingPathComponent("OldContainer"), new = root.appendingPathComponent("NewContainer")
        var source: NativeRepositoryContext? = try NativeRepositoryContext(root: old, legacyRoot: root.appendingPathComponent("Legacy"))
        var library: NativeLibraryRepository? = NativeLibraryRepository(context: source!)
        let created = try library!.handle("courses:create", ["name": "Relocated", "color": "green"]) as! [String: Any], id = created["id"] as! String
        let folder = try source!.courseFolder(id), canonical = "{\"keepAbsoluteUserText\":\"" + folder.path + "\"}"
        let note = folder.appendingPathComponent("note.md"); try Data("original".utf8).write(to: note)
        try source!.db.exec("CREATE TABLE ipad_sync_projection(id TEXT PRIMARY KEY,kind TEXT,payload_json TEXT,deleted INTEGER,source_json TEXT,baseline_json TEXT)")
        try source!.run("INSERT INTO ipad_sync_projection VALUES(?,?,?,?,?,?)", ["material:fixture", "material", canonical, 0, NativeRepositoryContext.json(["courseID": id, "path": note.path]), canonical])
        try Data(NativeRepositoryContext.json(["dataRoot": old.appendingPathComponent("Courses").path, "userText": folder.path]).utf8).write(to: old.appendingPathComponent("settings.json"))
        library = nil; source = nil
        try FileManager.default.moveItem(at: old, to: new)
        let reopened = try NativeRepositoryContext(root: new, legacyRoot: root.appendingPathComponent("Legacy")), relocated = try reopened.courseFolder(id)
        XCTAssertTrue(relocated.path.hasPrefix(new.path + "/Courses/")); XCTAssertEqual(try String(contentsOf: relocated.appendingPathComponent("note.md"), encoding: .utf8), "original")
        let row = try XCTUnwrap(reopened.query("SELECT * FROM ipad_sync_projection").first)
        XCTAssertEqual(row["payload_json"] as? String, canonical); XCTAssertEqual(row["baseline_json"] as? String, canonical)
        let mapped = try NativeRepositoryContext.jsonObject(row["source_json"] as! String) as! [String: Any]
        XCTAssertEqual(mapped["path"] as? String, relocated.appendingPathComponent("note.md").path)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: new.appendingPathComponent("settings.json"))) as! [String: Any]
        XCTAssertEqual(settings["dataRoot"] as? String, new.appendingPathComponent("Courses").path); XCTAssertEqual(settings["userText"] as? String, folder.path)
    }

    func testCrossCourseRenamePlanCommitsAndRollsBackLinkedLearningFiles() throws {
        let first = try course(), old = try note(first), second = try course(), linked = try note(second, title: "Linked")
        let url = try context.materialURL(courseID: second, relativePath: linked)
        try Data("before reference".utf8).write(to: url)
        context.planMaterialRenameFiles = { course, from, to, directory, operation in
            XCTAssertEqual(course, first); XCTAssertEqual(from, old); XCTAssertFalse(directory); XCTAssertNotNil(UUID(uuidString: operation))
            return [["courseId": second, "relPath": linked, "before": "before reference", "after": "after reference"]]
        }
        _ = try call("materials:tree", ["courseId": first])
        try context.db.exec("CREATE TRIGGER native_cross_course_rollback BEFORE UPDATE OF rel_path ON materials_index BEGIN SELECT RAISE(ABORT,'fixture rollback'); END")
        XCTAssertThrowsError(try call("notes:rename", ["courseId": first, "relPath": old, "newName": "Changed"]))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before reference")
        XCTAssertTrue(try context.query("SELECT * FROM material_path_intents").isEmpty)
        try context.db.exec("DROP TRIGGER native_cross_course_rollback")
        _ = try call("notes:rename", ["courseId": first, "relPath": old, "newName": "Changed"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after reference")
    }

    func testDirectoryRenameRollbackAcceptsMtimeChangesFromItsOwnChildNotePublication() throws {
        let id = try course()
        _ = try call("materials:createFolder", ["courseId": id, "dirRelPath": "", "name": "Old"])
        _ = try call("notes:create", ["courseId": id, "dirRelPath": "Old", "title": "Inside"])
        _ = try call("notes:write", ["courseId": id, "relPath": "Old/Inside.md", "markdown": "[[Old/Inside]]"])
        _ = try call("materials:tree", ["courseId": id])
        try context.db.exec("CREATE TRIGGER native_folder_failure BEFORE UPDATE OF rel_path ON materials_index BEGIN SELECT RAISE(ABORT,'fixture folder failure'); END")
        XCTAssertThrowsError(try call("materials:rename", ["courseId": id, "relPath": "Old", "newName": "New"]))
        XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: id, relativePath: "Old/Inside.md"), encoding: .utf8), "[[Old/Inside]]")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try context.materialURL(courseID: id, relativePath: "New", allowMissing: true).path))
        XCTAssertTrue(try context.query("SELECT * FROM material_path_intents").isEmpty)
    }

}
