import XCTest
import UIKit
import Darwin
import CryptoKit
@testable import Bandal

final class DesktopRuntimeTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testRepositoriesNativeDatabasePreservesValuesAndRollsBackTransactions() throws {
        let native = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try native.database.exec("CREATE TABLE sample(id TEXT PRIMARY KEY, number REAL, missing TEXT, bytes BLOB)")
        _ = try native.database.run("INSERT INTO sample VALUES(@id,@number,@missing,@bytes)", params: ["id": "자료 🌙", "number": 1.25, "missing": NSNull(), "bytes": ["__buffer": "AAH/"]])
        try native.database.exec("SAVEPOINT outer_tx; UPDATE sample SET id='changed'; SAVEPOINT inner_tx; DELETE FROM sample; ROLLBACK TO outer_tx; RELEASE outer_tx;")
        let value = try XCTUnwrap(native.database.query("SELECT * FROM sample", params: []).first)
        XCTAssertEqual(value["id"] as? String, "자료 🌙")
        XCTAssertEqual(value["number"] as? Double, 1.25)
        XCTAssertTrue(value["missing"] is NSNull)
        XCTAssertEqual((value["bytes"] as? [String: String])?["__buffer"], "AAH/")
        XCTAssertThrowsError(try native.database.run("INSERT INTO sample(id) VALUES (?)", params: ["자료 🌙"])) { error in
            XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SQLITE_CONSTRAINT_PRIMARYKEY")
        }
    }

    func testNamedSQLBindingsMatchRepositoryObjectsAndRejectMissingValues() throws {
        let database = try DesktopSQLite(url: directory.appendingPathComponent("named-bindings.db"))
        try database.exec("CREATE TABLE bindings(id TEXT PRIMARY KEY, value TEXT)")
        _ = try database.run("INSERT INTO bindings VALUES (@id, :value)", params: ["id": "kept", "value": NSNull(), "unused": ["nested": [1, 2, 3]]])
        let rows = try database.query("SELECT id, value, @id AS repeated, $id AS alternate FROM bindings WHERE id=@id", params: ["id": "kept", "readingMinutes": 5])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["repeated"] as? String, "kept")
        XCTAssertEqual(rows.first?["alternate"] as? String, "kept")
        XCTAssertTrue(rows.first?["value"] is NSNull)
        XCTAssertThrowsError(try database.run("INSERT INTO bindings VALUES (@id, @value)", params: ["id": "missing", "unused": "present"])) { error in
            XCTAssertEqual((error as? DesktopRuntimeError)?.code, "SQLITE_RANGE")
        }
        XCTAssertEqual(try database.query("SELECT id FROM bindings", params: [:]).count, 1, "A missing named value must not insert an accidental SQL NULL")
    }

    func testSQLiteIntegersBridgeDirectlyToSwiftAndRetainFullWidth() throws {
        let database = try DesktopSQLite(url:directory.appendingPathComponent("native-integers.db"))
        try database.exec("CREATE TABLE integers(id INTEGER PRIMARY KEY, value INTEGER)")
        let result = try database.run("INSERT INTO integers(value) VALUES(?)",params:[Int.max])
        XCTAssertEqual(result["lastInsertRowid"] as? Int,1)
        let row = try XCTUnwrap(database.query("SELECT id,value,1 AS page FROM integers",params:[]).first)
        XCTAssertEqual(row["id"] as? Int,1)
        XCTAssertEqual(row["page"] as? Int,1)
        XCTAssertEqual(row["value"] as? Int,Int.max)
        XCTAssertEqual((row["value"] as? NSNumber)?.int64Value,Int64.max)
    }

    func testFilesystemBlocksEscapesAndKeepsOriginalOnExclusiveWriteFailure() throws {
        let native = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        let path = directory.appendingPathComponent("필기.md").path
        _ = try native.perform("fs.writeFile", args: ["path": path, "data": "원본", "encoding": "utf8"])
        XCTAssertThrowsError(try native.perform("fs.writeFile", args: ["path": path, "data": "덮어쓰기", "encoding": "utf8", "flag": "wx"]))
        XCTAssertEqual(try native.perform("fs.readFile", args: ["path": path, "encoding": "utf8"]) as? String, "원본")
        XCTAssertThrowsError(try native.perform("fs.readFile", args: ["path": "/etc/passwd"]))
        let link = directory.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        XCTAssertThrowsError(try native.perform("fs.readFile", args: ["path": link.appendingPathComponent("passwd").path]))
        XCTAssertThrowsError(try native.perform("fs.remove", args: ["path": directory.path, "recursive": true]))
    }

    func testMissingPathsResolveTheirRealParentWithoutAllowingSymlinkEscapes() throws {
        let native = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        let missing = directory.appendingPathComponent("새 폴더/하위/필기.md")
        XCTAssertEqual(try DesktopStoragePath.canonical(missing).path, native.root.appendingPathComponent("새 폴더/하위/필기.md").path)
        XCTAssertNoThrow(try native.checkedPath(missing.path, writing: true))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = directory.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try native.checkedPath(link.appendingPathComponent("missing.md").path, writing: true))
        let dangling = directory.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing"))
        XCTAssertThrowsError(try native.checkedPath(dangling.path, writing: true))
        XCTAssertThrowsError(try native.checkedPath(dangling.appendingPathComponent("note.md").path, writing: true))
        let regular = directory.appendingPathComponent("regular")
        try Data([1]).write(to: regular)
        XCTAssertThrowsError(try native.checkedPath(regular.appendingPathComponent("child").path, writing: true))
        let internalLink = directory.appendingPathComponent("internal-link")
        try FileManager.default.createSymbolicLink(at: internalLink, withDestinationURL: regular)
        XCTAssertThrowsError(try native.perform("fs.writeFile", args: ["path": internalLink.path, "data": "keep", "encoding": "utf8"]))
        XCTAssertEqual(try Data(contentsOf: regular), Data([1]))
    }

    func testFileDescriptorStatsAndStreamingHashUseTheOpenedBytes() throws {
        let native = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        let source = directory.appendingPathComponent("source.bin"), moved = directory.appendingPathComponent("original.bin")
        let data = Data(repeating: 41, count: 1_000_000)
        try data.write(to: source)
        let fd = try XCTUnwrap(native.perform("fs.open", args: ["path": source.path, "flags": Int(O_RDONLY | O_NOFOLLOW)]) as? Int)
        defer { _ = try? native.perform("fs.close", args: ["fd": fd]) }
        try FileManager.default.moveItem(at: source, to: moved)
        try Data([1, 2]).write(to: source)
        let status = try XCTUnwrap(native.perform("fs.fstat", args: ["fd": fd]) as? [String: Any])
        XCTAssertEqual((status["size"] as? NSNumber)?.intValue, data.count)
        let movedStatus = try XCTUnwrap(native.perform("fs.stat", args: ["path": moved.path, "followSymlinks": false]) as? [String: Any])
        let replacedStatus = try XCTUnwrap(native.perform("fs.stat", args: ["path": source.path, "followSymlinks": false]) as? [String: Any])
        var exact = Darwin.stat()
        XCTAssertEqual(Darwin.fstat(Int32(fd), &exact), 0)
        XCTAssertEqual(status["dev"] as? String, String(exact.st_dev))
        XCTAssertEqual(status["ino"] as? String, String(exact.st_ino))
        XCTAssertEqual(status["ctimeNs"] as? String, String(Int64(exact.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(exact.st_ctimespec.tv_nsec)))
        XCTAssertEqual(status["ino"] as? String, movedStatus["ino"] as? String, "A rename must retain the exact identity used by pending move recovery")
        XCTAssertNotEqual(status["ino"] as? String, replacedStatus["ino"] as? String, "A replacement at the old path must never be mistaken for the moved original")
        let id = try XCTUnwrap(native.perform("crypto.hashCreate", args: ["algorithm": "sha256"]) as? String)
        var readCount = 0
        while true {
            let chunk = try XCTUnwrap(native.perform("fs.read", args: ["fd": fd, "length": 65_536]) as? String)
            if chunk.isEmpty { break }
            readCount += try XCTUnwrap(Data(base64Encoded: chunk)).count
            _ = try native.perform("crypto.hashUpdate", args: ["id": id, "data": chunk])
        }
        XCTAssertEqual(readCount, data.count)
        XCTAssertEqual(try native.perform("crypto.hashDigest", args: ["id": id]) as? String, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        XCTAssertThrowsError(try native.perform("crypto.hashDigest", args: ["id": id]))
        let link = directory.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: moved)
        XCTAssertThrowsError(try native.perform("fs.open", args: ["path": link.path, "flags": Int(O_RDONLY | O_NOFOLLOW)]))
    }

    func testSwiftStorageBoundaryPreservesErrorCode() throws {
        let native = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        let raw = native.perform("{\"op\":\"fs.readFile\",\"args\":{\"path\":\"/etc/passwd\"}}")
        let result = try DesktopJSON.decode(Data(raw.utf8)) as? [String:Any]
        XCTAssertEqual((result?["error"] as? [String:Any])?["code"] as? String,"EACCES")
    }

    func testMoveRecoveryLockExcludesAnotherRuntimeAndReleasesWithItsOwner() throws {
        var owner: DesktopNativePrimitives? = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        let contender = try DesktopNativePrimitives(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        let path = directory.appendingPathComponent("material-path-lock.db").path
        let token = try XCTUnwrap(owner?.perform("fs.lockAcquire", args: ["path": path]) as? Int)
        XCTAssertTrue(try contender.perform("fs.lockAcquire", args: ["path": path]) is NSNull)
        XCTAssertThrowsError(try contender.perform("fs.lockRelease", args: ["token": token]))
        owner = nil
        let next = try XCTUnwrap(contender.perform("fs.lockAcquire", args: ["path": path]) as? Int)
        _ = try contender.perform("fs.lockRelease", args: ["token": next])
        let again = try XCTUnwrap(contender.perform("fs.lockAcquire", args: ["path": path]) as? Int)
        _ = try contender.perform("fs.lockRelease", args: ["token": again])
        XCTAssertThrowsError(try contender.perform("fs.lockAcquire", args: ["path": "/private/bandal-path-lock"]))
    }

    @MainActor
    func testNoteRenameKeepsHeadingAndSelfLinksAcrossNativeRuntimeRestart() async throws {
        let runtime = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await runtime.start()
        let courseValue = try await runtime.invoke("courses:create", request: ["name": "노트 이동 복구", "color": "blue"])
        let course = try XCTUnwrap(courseValue as? [String: Any])
        let courseId = try XCTUnwrap(course["id"] as? String)
        let noteValue = try await runtime.invoke("notes:create", request: ["courseId": courseId, "dirRelPath": "", "title": "Original"])
        let note = try XCTUnwrap(noteValue as? [String: Any])
        let oldPath = try XCTUnwrap(note["relPath"] as? String)
        _ = try await runtime.invoke("notes:write", request: ["courseId": courseId, "relPath": oldPath, "markdown": "# Original\n\n보존할 본문 [[Original]]\n"])
        let movedValue = try await runtime.invoke("notes:rename", request: ["courseId": courseId, "relPath": oldPath, "newName": "Renamed"])
        let moved = try XCTUnwrap(movedValue as? [String: Any])
        let newPath = try XCTUnwrap(moved["relPath"] as? String)
        XCTAssertEqual(newPath, "Renamed.md")
        XCTAssertTrue((moved["markdown"] as? String ?? "").contains("# Renamed"))
        XCTAssertTrue((moved["markdown"] as? String ?? "").contains("[[Renamed]]"))
        let reopened = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await reopened.start()
        let savedValue = try await reopened.invoke("notes:read", request: ["courseId": courseId, "relPath": newPath])
        let saved = try XCTUnwrap(savedValue as? [String: Any])
        XCTAssertEqual(saved["markdown"] as? String, moved["markdown"] as? String)
        do {
            _ = try await reopened.invoke("notes:read", request: ["courseId": courseId, "relPath": oldPath])
            XCTFail("The old note must not reappear after recovery")
        } catch {}
    }

    @MainActor
    func testLearningSourcesFollowRenamesAcrossTwoCoursesAndNativeRestart() async throws {
        let runtime = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await runtime.start()
        var projects: [(courseID: String, binding: [String: Any], wordID: String)] = []
        for name in ["학습 연결 A", "학습 연결 B"] {
            let courseValue = try await runtime.invoke("courses:create", request: ["name": name, "color": "green"])
            let course = try XCTUnwrap(courseValue as? [String: Any])
            let courseID = try XCTUnwrap(course["id"] as? String)
            _ = try await runtime.invoke("materials:writeFile", request: ["courseId": courseID, "dirRelPath": "", "fileName": "source.md", "data": "# Source\n\nVectors belong to a vector space.", "encoding": "utf8"])
            let createdValue = try await runtime.invoke("learning:create", request: ["placement": "in-course", "courseId": courseID, "name": "Study", "topic": "Vectors"])
            let created = try XCTUnwrap(createdValue as? [String: Any])
            let binding = try XCTUnwrap(created["binding"] as? [String: Any])
            let savedValue = try await runtime.invoke("learning:saveWord", request: ["binding": binding, "surface": "Vectors", "sentence": "Vectors belong to a vector space.", "sourceRef": ["kind": "material", "pathScope": "course", "relPath": "source.md", "quote": "Vectors belong to a vector space."]])
            let saved = try XCTUnwrap(savedValue as? [String: Any])
            let words = try XCTUnwrap(saved["words"] as? [[String: Any]])
            projects.append((courseID, binding, try XCTUnwrap(words.first?["id"] as? String)))
        }
        // These enter one JSCore runtime together. Their shared OS-backed path
        // lock must serialize our own readers, rather than reject one course.
        async let firstList = runtime.invoke("learning:list", request: ["courseId": projects[0].courseID])
        async let secondList = runtime.invoke("learning:list", request: ["courseId": projects[1].courseID])
        _ = try await (firstList, secondList)
        var receipts: [String] = []
        for project in projects {
            _ = try await runtime.invoke("notes:rename", request: ["courseId": project.courseID, "relPath": "source.md", "newName": "renamed.md"])
            let stateValue = try await runtime.invoke("learning:get", request: ["binding": project.binding])
            let state = try XCTUnwrap(stateValue as? [String: Any])
            let occurrences = try XCTUnwrap(state["occurrences"] as? [[String: Any]])
            let source = try XCTUnwrap(occurrences.first?["sourceRef"] as? [String: Any])
            XCTAssertEqual(source["relPath"] as? String, "renamed.md")
            XCTAssertEqual(occurrences.first?["wordId"] as? String, project.wordID)
            let aliases = try XCTUnwrap(state["pathAliases"] as? [[String: Any]])
            XCTAssertEqual(aliases.count, 1)
            receipts.append(try XCTUnwrap(aliases.first?["operationId"] as? String))
        }
        let reopened = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await reopened.start()
        for (index, project) in projects.enumerated() {
            let stateValue = try await reopened.invoke("learning:get", request: ["binding": project.binding])
            let state = try XCTUnwrap(stateValue as? [String: Any])
            let aliases = try XCTUnwrap(state["pathAliases"] as? [[String: Any]])
            XCTAssertEqual(aliases.count, 1, "Restart must not apply an acknowledged rename twice")
            XCTAssertEqual(aliases.first?["operationId"] as? String, receipts[index])
            let occurrences = try XCTUnwrap(state["occurrences"] as? [[String: Any]])
            XCTAssertEqual((occurrences.first?["sourceRef"] as? [String: Any])?["relPath"] as? String, "renamed.md")
            let sourceValue = try await reopened.invoke("notes:read", request: ["courseId": project.courseID, "relPath": "renamed.md"])
            XCTAssertTrue(((sourceValue as? [String: Any])?["markdown"] as? String ?? "").contains("Vectors belong to a vector space."))
        }
    }

    @MainActor
    func testActualDesktopBackendCreatesCoursesNotesAndReloadsSavedLayout() async throws {
        let runtime = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await runtime.start()
        let settingsValue = try await runtime.invoke("settings:get")
        let settings = try XCTUnwrap(settingsValue as? [String: Any])
        XCTAssertNotNil(settings["browser"])
        XCTAssertNotNil(settings["tabs"])
        let createdValue = try await runtime.invoke("courses:create", request: ["name": "실제 저장 검증", "color": "#60a5fa"])
        let created = try XCTUnwrap(createdValue as? [String: Any])
        let identifier = try XCTUnwrap(created["id"] as? String)
        let noteValue = try await runtime.invoke("notes:create", request: ["courseId": identifier, "dirRelPath": "", "title": "검색 검증"])
        let note = try XCTUnwrap(noteValue as? [String: Any])
        let path = try XCTUnwrap(note["relPath"] as? String)
        _ = try await runtime.invoke("notes:write", request: ["courseId": identifier, "relPath": path, "markdown": "# 검색 검증\n아이패드에서 필기하고 항공역학을 공부합니다."])
        let foundValue = try await runtime.invoke("search:query", request: ["courseId": identifier, "query": "아이패드"])
        let found = try XCTUnwrap(foundValue as? [String: Any])
        XCTAssertTrue((found["hits"] as? [[String: Any]] ?? []).contains { $0["relPath"] as? String == path }, String(describing: found))
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { $0.beginPage() }
        _ = try await runtime.invoke("materials:writeFile", request: ["courseId": identifier, "dirRelPath": "", "fileName": "학습.pdf", "data": pdf.base64EncodedString(), "encoding": "base64"])
        _ = try await runtime.invoke("search:indexPdfPages", request: ["courseId": identifier, "relPath": "학습.pdf", "pages": [["page": 1, "text": "힘과 모멘트"]]])
        let shortValue = try await runtime.invoke("search:query", request: ["courseId": identifier, "query": "힘"])
        let short = try XCTUnwrap(shortValue as? [String: Any])
        XCTAssertTrue((short["hits"] as? [[String: Any]] ?? []).contains { $0["relPath"] as? String == "학습.pdf" && ($0["page"] as? NSNumber)?.intValue == 1 }, String(describing: short))
        let layout: [String: Any] = ["panels": ["note": ["id": "note", "component": "note"]], "activePanel": "note"]
        _ = try await runtime.invoke("layout:save", request: ["courseId": identifier, "layout": layout])
        let reopened = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await reopened.start()
        let coursesValue = try await reopened.invoke("courses:list", request: [:])
        let courses = try XCTUnwrap(coursesValue as? [[String: Any]])
        XCTAssertEqual(courses.map { $0["id"] as? String }, [identifier])
        let saved = try await reopened.invoke("layout:get", request: ["courseId": identifier])
        XCTAssertTrue(String(describing: saved).contains("note"))
    }
}
