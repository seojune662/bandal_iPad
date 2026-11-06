import XCTest
@testable import Bandal

/// The free allowance (design §8.2–8.3): one course and ten documents made on this iPad, 20 AI requests a
/// month. Only making more is refused; what is here stays usable, and what sync brought never counts.
final class FreeTierTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var library: NativeLibraryRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("free-tier-" + UUID().uuidString)
        context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        library = NativeLibraryRepository(context: context)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func refused(_ channel: String, _ request: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) -> String? {
        do { try FreeTier.check(channel, request, library: library); return nil }
        catch let error as DesktopRuntimeError { XCTAssertEqual(error.code, FreeTier.code, file: file, line: line); return error.message }
        catch { XCTFail("\(error)", file: file, line: line); return nil }
    }
    private func course(_ name: String) throws -> String { (try library.handle("courses:create", ["name": name, "color": "blue"]) as! [String: Any])["id"] as! String }
    private func note(_ course: String, _ title: String) throws { _ = try library.handle("notes:create", ["courseId": course, "dirRelPath": "", "title": title]) }
    private func source(_ name: String) throws -> String {
        let url = root.appendingPathComponent("Inbox/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4\n".utf8).write(to: url); return url.path
    }

    func testOneCourseIsFreeAndOnlyLiveOnesCount() throws {
        XCTAssertNil(refused("courses:create"))
        let first = try course("수학")
        XCTAssertEqual(refused("courses:create"), "무료로는 이 iPad에서 과목을 1개까지 만들 수 있어요.")
        XCTAssertNotNil(refused("courses:addFromFolder", ["folderPath": "/tmp", "name": "폴더"]))
        XCTAssertNotNil(refused("learning:create", ["name": "영어", "placement": "standalone"]))
        XCTAssertNotNil(refused("learning:create", ["name": "영어"]))
        XCTAssertNil(refused("learning:create", ["name": "영어", "placement": "in-course", "courseId": first]))
        // Renaming, archiving and reading never count.
        XCTAssertNil(refused("courses:rename", ["courseId": first, "name": "미적분"]))
        _ = try library.handle("courses:archive", ["courseId": first, "archived": true])
        XCTAssertNotNil(refused("courses:create"))
        _ = try library.handle("courses:delete", ["courseId": first])
        XCTAssertNil(refused("courses:create"))
    }

    func testTenDocumentsAreFreeAndImportsAreTakenWholeOrNotAtAll() throws {
        let id = try course("수학")
        for index in 1...8 { try note(id, "노트 \(index)") }
        XCTAssertNil(refused("notes:create", ["courseId": id]))
        // Two more reach ten; three would pass it, so nothing of that import goes in.
        let pdfs = try ["a.pdf", "b.pdf", "b2.pdf"].map(source)
        XCTAssertNil(refused("materials:import", ["courseId": id, "paths": Array(pdfs.prefix(2))]))
        XCTAssertEqual(refused("materials:import", ["courseId": id, "paths": pdfs]), "무료로는 자료를 2개 더 추가할 수 있어요.")
        XCTAssertNil(refused("materials:import", ["courseId": id, "paths": [pdfs[0], try source("c.png"), try source("d.txt")]]))
        XCTAssertEqual(refused("materials:import", ["courseId": id, "paths": try ["e.pdf", "f.md", "g.markdown"].map(source)]), "무료로는 자료를 2개 더 추가할 수 있어요.")
        try note(id, "노트 9"); try note(id, "노트 10")
        XCTAssertEqual(try FreeTier.usage(library: library).documents, 10)
        let full = "무료로는 이 iPad에서 자료를 10개까지 만들 수 있어요."
        for (channel, request) in [("notes:create", ["courseId": id]), ("pdfNotes:create", ["courseId": id]), ("pdf:recoverPagesCopy", ["courseId": id]),
                                   ("materials:importShared", ["courseId": id, "fileName": "공유.pdf"]), ("materials:writeFile", ["courseId": id, "fileName": "새 노트.md"]),
                                   ("materials:duplicate", ["courseId": id, "relPath": "노트 1.md"])] as [(String, [String: Any])] {
            XCTAssertEqual(refused(channel, request), full, channel)
        }
        // Pictures, other files and changes to what is here stay free.
        XCTAssertNil(refused("materials:writeFile", ["courseId": id, "dirRelPath": "assets", "fileName": "그림.png"]))
        XCTAssertNil(refused("materials:import", ["courseId": id, "paths": [try source("h.png")]]))
        XCTAssertNil(refused("notes:write", ["courseId": id, "relPath": "노트 1.md"]))
        XCTAssertNil(refused("materials:rename", ["courseId": id, "relPath": "노트 1.md", "newName": "노트 0.md"]))
        // A folder copies every document in it.
        _ = try library.handle("materials:delete", ["courseId": id, "relPath": "노트 9.md"])
        _ = try library.handle("materials:delete", ["courseId": id, "relPath": "노트 10.md"])
        _ = try library.handle("materials:createFolder", ["courseId": id, "dirRelPath": "", "name": "묶음"])
        for title in ["가", "나", "다"] { _ = try library.handle("notes:create", ["courseId": id, "dirRelPath": "묶음", "title": title]) }
        XCTAssertEqual(try FreeTier.usage(library: library).documents, 11)
        _ = try library.handle("materials:delete", ["courseId": id, "relPath": "묶음/다.md"])
        _ = try library.handle("materials:delete", ["courseId": id, "relPath": "노트 2.md"])
        XCTAssertEqual(try FreeTier.usage(library: library).documents, 9)
        XCTAssertEqual(refused("materials:duplicate", ["courseId": id, "relPath": "묶음"]), "무료로는 자료를 1개 더 추가할 수 있어요.")
        XCTAssertNil(refused("materials:duplicate", ["courseId": id, "relPath": "묶음/가.md"]))
        // An imported folder (a note-app backup) counts the documents inside it.
        _ = try ["백업/a.pdf", "백업/과목/b.pdf", "백업/과목/c.png"].map(source)
        XCTAssertEqual(refused("materials:import", ["courseId": id, "paths": [root.appendingPathComponent("Inbox/백업").path]]), "무료로는 자료를 1개 더 추가할 수 있어요.")
    }

    /// Courses and documents sync made (`origin = 'remote'`) are not made on this iPad; what this iPad
    /// makes inside a received course is.
    func testWhatSyncBroughtDoesNotCount() throws {
        let received = try course("받은 과목"), other = try course("받은 과목 2")
        for index in 1...10 { try note(received, "받은 노트 \(index)") }
        XCTAssertNotNil(refused("courses:create"))
        _ = try SyncStore(context: context, keychain: .init(read: { _ in nil }, write: { _, _ in }))
        for local in [received, other] { try context.run("INSERT INTO cloud_sync_courses(sync_id,local_id,origin,registers) VALUES(?,?,'remote','{}')", [UUID().uuidString.lowercased(), local]) }
        for index in 1...10 {
            try context.run("INSERT INTO cloud_sync_docs(sync_id,course_id,rel_path,origin,registers) VALUES(?,?,?,'remote','{}')", [UUID().uuidString.lowercased(), received, "받은 노트 \(index).md"])
        }
        XCTAssertEqual(try FreeTier.usage(library: library).courses, 0)
        XCTAssertEqual(try FreeTier.usage(library: library).documents, 0)
        XCTAssertNil(refused("courses:create"))
        try note(received, "여기서 쓴 노트")
        XCTAssertEqual(try FreeTier.usage(library: library).documents, 1)
    }

    /// The runtime asks before every channel; a refused channel changes nothing.
    func testTheRuntimeChecksBeforeTheChannelRuns() async throws {
        let runtime = DesktopRuntime(root: root.appendingPathComponent("Runtime"), legacyRoot: root.appendingPathComponent("RuntimeLegacy"))
        runtime.limits = { try FreeTier.check($0, $1, library: $2) }
        try await runtime.start()
        _ = try await runtime.invoke("courses:create", request: ["name": "수학", "color": "blue"])
        do { _ = try await runtime.invoke("courses:create", request: ["name": "과학", "color": "blue"]); XCTFail("A second course was made") }
        catch let error as DesktopRuntimeError { XCTAssertEqual(error.code, FreeTier.code) }
        let courses = try await runtime.invoke("courses:list") as? [[String: Any]]
        XCTAssertEqual(courses?.compactMap { $0["name"] as? String }, ["수학"])
        let usage = try await runtime.invokePrivate("nativeMembership:usage") as? [String: Any]
        XCTAssertEqual(usage?["courses"] as? Int, 1)
        XCTAssertEqual(usage?["documents"] as? Int, 0)
    }
}
