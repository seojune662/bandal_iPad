import Foundation
import XCTest
@testable import Bandal

final class NativeLearningRepositoryTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var library: NativeLibraryRepository!
    private var learning: NativeLearningRepository!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-learning-\(UUID().uuidString)")
        try reopen()
    }
    private func reopen() throws {
        context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        library = NativeLibraryRepository(context: context); learning = NativeLearningRepository(context: context)
        context.planMaterialRenameFiles = { [weak learning] course, from, to, directory, operation in
            try learning?.planPathChanges(courseID: course, from: from, to: to, isDirectory: directory, operationID: operation) ?? []
        }
        try library.recoverPathChanges()
    }
    override func tearDownWithError() throws { learning = nil; library = nil; context = nil; try FileManager.default.removeItem(at: root) }
    private func course() throws -> String {
        let result = try XCTUnwrap(library.handle("courses:create", ["name": "학습 자료", "color": "green"]) as? [String: Any]); return try XCTUnwrap(result["id"] as? String)
    }
    private func project(_ course: String, name: String = "Study", linked: String? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["placement": "in-course", "courseId": course, "name": name, "topic": "Vectors"]
        if let linked { request["linkedCourseId"] = linked }
        return try XCTUnwrap(learning.handle("learning:create", request) as? [String: Any])
    }
    private func binding(_ state: [String: Any]) throws -> [String: Any] { try XCTUnwrap(state["binding"] as? [String: Any]) }
    private func read(_ binding: [String: Any]) throws -> [String: Any] { try XCTUnwrap(learning.handle("learning:get", ["binding": binding]) as? [String: Any]) }
    private func source(_ course: String, path: String = "source.md") throws {
        _ = try library.handle("materials:writeFile", ["courseId": course, "dirRelPath": "", "fileName": path, "data": "# Source\n\nVectors belong to a vector space.", "encoding": "utf8"])
    }
    private func save(_ binding: [String: Any], owner: String? = nil, path: String = "source.md", scope: String = "course", revision: Int? = nil) throws -> [String: Any] {
        var source: [String: Any] = ["kind": "material", "pathScope": scope, "relPath": path, "quote": "Vectors belong to a vector space."]
        if let owner { source["sourceCourseId"] = owner }
        var request: [String: Any] = ["binding": binding, "surface": "Vectors", "sentence": "Vectors belong to a vector space.", "meaning": "벡터", "sourceRef": source]
        if let revision { request["expectedRevision"] = revision }
        let result = try learning.handle("learning:saveWord", request)
        return try XCTUnwrap(result as? [String: Any])
    }
    func testSaveWordIsGroundedDeduplicatedAndRejectsStaleRevision() throws {
        let id = try course(); try source(id)
        let binding = try binding(project(id)), saved = try save(binding)
        XCTAssertEqual((saved["words"] as? [Any])?.count, 1); XCTAssertEqual(saved["revision"] as? Int, 1)
        let replay = try save(binding)
        XCTAssertEqual(replay["revision"] as? Int, 1); XCTAssertEqual((replay["occurrences"] as? [Any])?.count, 1)
        XCTAssertThrowsError(try save(binding, revision: 0))
        let bad: [String: Any] = ["binding": binding, "surface": "fabricated", "sentence": "fabricated source", "sourceRef": ["kind": "material", "pathScope": "course", "relPath": "source.md", "quote": "fabricated source"]]
        XCTAssertThrowsError(try learning.handle("learning:saveWord", bad))
        XCTAssertEqual(try read(binding)["revision"] as? Int, 1)
    }
    func testRenameRepointsTwoCoursesAndLinkedCitationsExactlyOnceAcrossRestart() throws {
        let owner = try course(), linked = try course(); try source(owner)
        let a = try binding(project(owner)), b = try binding(project(linked, linked: owner))
        _ = try save(a); _ = try save(b, owner: owner)
        _ = try library.handle("notes:rename", ["courseId": owner, "relPath": "source.md", "newName": "renamed.md"])
        var operations: [String] = []
        for binding in [a, b] {
            let state = try read(binding), refs = try XCTUnwrap(state["occurrences"] as? [[String: Any]]), aliases = try XCTUnwrap(state["pathAliases"] as? [[String: Any]])
            XCTAssertEqual((refs[0]["sourceRef"] as? [String: Any])?["relPath"] as? String, "renamed.md")
            XCTAssertEqual(aliases.count, 1); operations.append(try XCTUnwrap(aliases[0]["operationId"] as? String))
        }
        XCTAssertEqual(operations[0], operations[1])
        try reopen()
        for (index, binding) in [a, b].enumerated() {
            let state = try read(binding), aliases = try XCTUnwrap(state["pathAliases"] as? [[String: Any]])
            XCTAssertEqual(aliases.count, 1); XCTAssertEqual(aliases[0]["operationId"] as? String, operations[index])
        }
        XCTAssertTrue(try context.query("SELECT * FROM material_path_intents").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try context.courseFolder(owner).appendingPathComponent("source.md").path))
    }
    func testProjectDirectoryMoveKeepsLocalCitationsAndUnknownState() throws {
        let owner = try course(), original = try binding(project(owner))
        let folder = try context.courseFolder(owner)
        try Data("Vectors belong to a vector space.".utf8).write(to: folder.appendingPathComponent("Study/local.md"))
        _ = try save(original, path: "local.md", scope: "project")
        let stateURL = folder.appendingPathComponent("Study/.bandal/learning/state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]); state["unknownFuture"] = ["nested": [1, 2, 3]]
        try Data(try NativeRepositoryContext.json(state).utf8).write(to: stateURL)
        _ = try library.handle("materials:rename", ["courseId": owner, "relPath": "Study", "newName": "Moved"])
        let moved = try read(["courseId": owner, "rootRelPath": "Moved"])
        XCTAssertEqual((moved["unknownFuture"] as? [String: Any])?["nested"] as? [Int], [1, 2, 3])
        XCTAssertEqual(((moved["occurrences"] as? [[String: Any]])?.first?["sourceRef"] as? [String: Any])?["relPath"] as? String, "local.md")
    }
    func testRenameWithUnwritableLinkedStatePreservesOriginalPathAndBothCitations() throws {
        let owner = try course(), linked = try course(); try source(owner)
        let a = try binding(project(owner)), b = try binding(project(linked, linked: owner)); _ = try save(a); _ = try save(b, owner: owner)
        let state = try context.courseFolder(linked).appendingPathComponent("Study/.bandal/learning/state.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: state.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path) }
        XCTAssertThrowsError(try library.handle("notes:rename", ["courseId": owner, "relPath": "source.md", "newName": "renamed.md"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try context.courseFolder(owner).appendingPathComponent("source.md").path))
        for binding in [a, b] { XCTAssertEqual(((try read(binding)["occurrences"] as? [[String: Any]])?.first?["sourceRef"] as? [String: Any])?["relPath"] as? String, "source.md") }
    }
    func testCorruptStateReadUsesPreviousWithoutOverwritingCorruptBytes() throws {
        let id = try course(); try source(id)
        let binding = try binding(project(id)); _ = try save(binding)
        let url = try context.courseFolder(id).appendingPathComponent("Study/.bandal/learning/state.json"), damaged = Data("{ damaged original".utf8)
        try damaged.write(to: url)
        XCTAssertEqual(try read(binding)["recovery"] as? String, "previous")
        XCTAssertThrowsError(try save(binding))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }
    func testUnknownVersionAndUnrelatedCourseAreNotSilentlyRewritten() throws {
        let owner = try course(), unrelated = try course(); try source(unrelated)
        let binding = try binding(project(owner))
        XCTAssertThrowsError(try save(binding, owner: unrelated))
        XCTAssertThrowsError(try learning.handle("learning:create", ["placement": "in-course", "courseId": owner, "name": "Nested", "topic": "Vectors", "rootRelPath": "Study/Nested"]))
        let url = try context.courseFolder(owner).appendingPathComponent("Study/.bandal/learning/state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]); state["schemaVersion"] = 99
        let bytes = Data(try NativeRepositoryContext.json(state).utf8); try bytes.write(to: url)
        XCTAssertThrowsError(try learning.handle("learning:rename", ["binding": binding, "name": "Changed"]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
