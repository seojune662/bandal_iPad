import Foundation
import XCTest
@testable import Bandal

final class NativeShareInboxTests: XCTestCase {
    private var root: URL!
    private var inbox: BandalShareInbox!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-share-" + UUID().uuidString)
        inbox = BandalShareInbox(root: root.appendingPathComponent("Group"))
    }
    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
    private func batch(id: String, items: [BandalShareBatch.Item], folder: String = "") -> BandalShareBatch {
        .init(id: id, workspaceID: UUID().uuidString, courseID: UUID().uuidString, folderPath: folder, createdAt: Date(), items: items)
    }

    func testOnlyCommittedBatchesAreVisibleAndPayloadSurvivesSourceDeletion() throws {
        let id = UUID().uuidString, staging = try inbox.beginBatch(id: id)
        let source = root.appendingPathComponent("원본.pdf"), bytes = Data([0, 3, 255, 25])
        try bytes.write(to: source)
        let item = try inbox.stageFile(source, name: source.lastPathComponent, in: staging)
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(try inbox.batches().isEmpty)
        try inbox.commit(batch(id: id, items: [item]), staging: staging)
        let queued = try XCTUnwrap(inbox.batches().first)
        XCTAssertEqual(try Data(contentsOf: inbox.payloadURL(item, batchID: queued.id)), bytes)
        XCTAssertEqual(queued.items.first?.fileName, "원본.pdf")
        try inbox.removeCompleted(queued)
        XCTAssertTrue(try inbox.batches().isEmpty)
    }

    func testRejectsTraversalAndTamperedPayloadWithoutPublishing() throws {
        for path in ["../course", "/root", "a//b", "a/./b", "a/../b", ".private", "a\\b"] {
            XCTAssertFalse(BandalShareInbox.validRelativeFolder(path), path)
        }
        XCTAssertTrue(BandalShareInbox.validRelativeFolder("자료/시험"))
        let id = UUID().uuidString, staging = try inbox.beginBatch(id: id)
        let item = try inbox.stageText("untouched", name: "노트.md", in: staging)
        XCTAssertThrowsError(try inbox.commit(batch(id: id, items: [item], folder: "../escape"), staging: staging))
        try Data("changed size".utf8).write(to: staging.appendingPathComponent(item.storedName))
        XCTAssertThrowsError(try inbox.commit(batch(id: id, items: [item]), staging: staging))
        XCTAssertTrue(try inbox.batches().isEmpty)
    }

    func testRejectsSymlinkPayloadAndOversizedManifest() throws {
        let id = UUID().uuidString, staging = try inbox.beginBatch(id: id)
        let item = try inbox.stageText("hello", name: "shared.md", in: staging)
        let payload = staging.appendingPathComponent(item.storedName)
        let external = root.appendingPathComponent("external.md")
        try Data("hello".utf8).write(to: external)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)
        XCTAssertThrowsError(try inbox.commit(batch(id: id, items: [item]), staging: staging))
        let tooLarge = BandalShareBatch.Item(id: item.id, storedName: item.id, fileName: "large.pdf", byteCount: BandalShareInbox.maximumFileBytes + 1)
        XCTAssertThrowsError(try inbox.commit(batch(id: id, items: [tooLarge]), staging: staging))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "hello")
    }

    func testCatalogKeepsDestinationRelativeAndSanitizesFileNames() throws {
        let value = BandalShareCatalog(workspaceID: UUID().uuidString,
            courses: [.init(id: UUID().uuidString, name: "운동체역학", folders: ["과제", "과제/10월"])], updatedAt: Date())
        try inbox.publishCatalog(value)
        let restored = try inbox.readCatalog()
        XCTAssertEqual(restored.courses.first?.folders, ["과제", "과제/10월"])
        XCTAssertEqual(restored.workspaceID, value.workspaceID)
        XCTAssertEqual(BandalShareInbox.safeFileName("../photo.png"), "-photo.png")
        XCTAssertEqual(BandalShareInbox.safeFileName(""), "공유 자료.md")
    }

    func testUnchangedCatalogIsNotRewrittenButAnotherWorkspaceAndFolderChangesArePublished() throws {
        let workspace = UUID().uuidString, course = UUID().uuidString
        let courses: [BandalShareCatalog.Course] = [.init(id: course, name: "Course", folders: ["Folder"])]
        let first = BandalShareCatalog(workspaceID: workspace, courses: courses, updatedAt: Date(timeIntervalSince1970: 100))
        try inbox.publishCatalog(first)
        let file = inbox.root.appendingPathComponent("destinations.json"), bytes = try Data(contentsOf: file)
        try inbox.publishCatalog(.init(workspaceID: workspace, courses: courses, updatedAt: Date(timeIntervalSince1970: 200)))
        XCTAssertEqual(try Data(contentsOf: file), bytes, "A changed note mtime does not change share destinations")
        let alternate = UUID().uuidString
        try inbox.publishCatalog(.init(workspaceID: alternate, courses: courses, updatedAt: Date(timeIntervalSince1970: 300)))
        XCTAssertEqual(try inbox.readCatalog().workspaceID, alternate)
        try inbox.publishCatalog(first)
        XCTAssertEqual(try inbox.readCatalog().workspaceID, workspace, "Returning scenes must compare the shared file, not an old in-memory cache")
        try inbox.publishCatalog(.init(workspaceID: workspace, courses: [.init(id: course, name: "Renamed", folders: ["New Folder"])], updatedAt: Date(timeIntervalSince1970: 400)))
        XCTAssertEqual(try inbox.readCatalog().courses.first?.folders, ["New Folder"])
        XCTAssertEqual(try inbox.readCatalog().courses.first?.name, "Renamed")
    }

    func testInterruptedCompletedCleanupCannotPoisonReadyBatches() throws {
        let firstID = UUID().uuidString, firstDirectory = try inbox.beginBatch(id: firstID)
        let first = batch(id: firstID, items: [try inbox.stageText("first", name: "first.md", in: firstDirectory)])
        try inbox.commit(first, staging: firstDirectory)
        let secondID = UUID().uuidString, secondDirectory = try inbox.beginBatch(id: secondID)
        let second = batch(id: secondID, items: [try inbox.stageText("second", name: "second.md", in: secondDirectory)])
        try inbox.commit(second, staging: secondDirectory)
        try inbox.retireCompleted(first)
        let tombstone = inbox.root.appendingPathComponent(".completed-" + first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.root.appendingPathComponent(first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))
        // Simulate termination halfway through cleanup, after the manifest was
        // removed. Recovery must not parse this directory as a pending share.
        try FileManager.default.removeItem(at: tombstone.appendingPathComponent("manifest.json"))
        let restarted = BandalShareInbox(root: inbox.root)
        XCTAssertEqual(try restarted.batches().map(\.id), [secondID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        let thirdID = UUID().uuidString, thirdDirectory = try restarted.beginBatch(id: thirdID)
        let third = batch(id: thirdID, items: [try restarted.stageText("third", name: "third.md", in: thirdDirectory)])
        XCTAssertNoThrow(try restarted.commit(third, staging: thirdDirectory))
        XCTAssertEqual(try restarted.batches().count, 2)
    }

    func testOnlyExpiredOwnedStagingIsRemoved() throws {
        let oldID = UUID().uuidString, old = try inbox.beginBatch(id: oldID)
        _ = try inbox.stageText("abandoned", name: "old.md", in: old)
        let active = try inbox.beginBatch(id: UUID().uuidString)
        _ = try inbox.stageText("active", name: "active.md", in: active)
        let foreign = inbox.root.appendingPathComponent(".staging-user-folder")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let date = Date().addingTimeInterval(-25 * 60 * 60)
        for directory in [old, foreign] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path) }
        XCTAssertTrue(try inbox.batches().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testTemporaryCopyExpiryUsesLocalChangeTimeAndNeverFollowsSymlinks() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let copy = root.appendingPathComponent(".bandal-share-" + UUID().uuidString)
        let foreign = root.appendingPathComponent(".bandal-share-user-document")
        let original = root.appendingPathComponent("original.md")
        for file in [copy, foreign, original] { try Data("preserve".utf8).write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: copy.path)
        let symlink = root.appendingPathComponent(".bandal-share-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
        NativeLibraryRepository.removeStaleShareCopies(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "An active copy may inherit an old source modification time")
        NativeLibraryRepository.removeStaleShareCopies(in: root, now: Date().addingTimeInterval(25 * 60 * 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: symlink.path))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "preserve")
    }

    func testRepositoryRetriesExactlyOnceAndDoesNotRecreateDeletedImport() throws {
        let context = try NativeRepositoryContext(root: root.appendingPathComponent("Library"), legacyRoot: root.appendingPathComponent("Legacy"))
        let repository = NativeLibraryRepository(context: context)
        let course = try XCTUnwrap(repository.handle("courses:create", ["name": "과목", "color": "blue"]) as? [String: Any])
        let courseID = try XCTUnwrap(course["id"] as? String)
        let source = root.appendingPathComponent("input.pdf"), bytes = Data("PDF fixture".utf8)
        try bytes.write(to: source)
        let request: [String: Any] = ["courseId": courseID, "dirRelPath": "", "fileName": "자료.pdf", "sourcePath": source.path, "shareID": UUID().uuidString]
        let first = try XCTUnwrap(repository.handle("materials:importShared", request) as? [String: Any])
        let relative = try XCTUnwrap(first["relPath"] as? String)
        let second = try XCTUnwrap(repository.handle("materials:importShared", request) as? [String: Any])
        XCTAssertEqual(first["alreadyImported"] as? Bool, false)
        XCTAssertEqual(second["alreadyImported"] as? Bool, true)
        XCTAssertEqual(second["relPath"] as? String, relative)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.courseFolder(courseID).path), ["자료.pdf"])
        let destination = try context.materialURL(courseID: courseID, relativePath: relative)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        try FileManager.default.removeItem(at: destination)
        _ = try repository.handle("materials:importShared", request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInterruptedImportResumesSameFileAndRejectsChangedSource() throws {
        let libraryRoot = root.appendingPathComponent("Library")
        let context = try NativeRepositoryContext(root: libraryRoot, legacyRoot: root.appendingPathComponent("Legacy"))
        let repository = NativeLibraryRepository(context: context)
        let course = try XCTUnwrap(repository.handle("courses:create", ["name": "과목", "color": "blue"]) as? [String: Any])
        let courseID = try XCTUnwrap(course["id"] as? String), shareID = UUID().uuidString
        let source = root.appendingPathComponent("source.md")
        try Data("# preserved".utf8).write(to: source)
        let request: [String: Any] = ["courseId": courseID, "dirRelPath": "", "fileName": "노트.md", "sourcePath": source.path, "shareID": shareID]
        _ = try repository.handle("materials:importShared", request)
        let receiptURL = libraryRoot.appendingPathComponent("ShareReceipts/" + shareID + ".json")
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        receipt["complete"] = false // interrupted after durable publication
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL, options: .atomic)
        _ = try NativeLibraryRepository(context: context).handle("materials:importShared", request)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.courseFolder(courseID).path), ["노트.md"])
        try Data("different source".utf8).write(to: source)
        XCTAssertThrowsError(try repository.handle("materials:importShared", request))
        XCTAssertEqual(try String(contentsOf: context.materialURL(courseID: courseID, relativePath: "노트.md"), encoding: .utf8), "# preserved")
    }
}
