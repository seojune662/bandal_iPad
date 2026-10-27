import XCTest
@testable import Bandal

@MainActor
final class NativeWhiteboardTests: XCTestCase {
    func testCanonicalWhiteboardShapesRestartAndTombstonesDoNotResurrect() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let input = f.put("stroke")
        _ = try f.repo.handle("canvas:putShape", input)
        let restarted = NativeWhiteboardRepository(context: f.context)
        let opened = try restarted.handle("canvas:open", f.identity) as! [String: Any]
        let shape = (opened["shapes"] as! [[String: Any]])[0], point = ((shape["data"] as! [String: Any])["points"] as! [[String: Any]])[0]
        XCTAssertEqual((point["p"] as! NSNumber).doubleValue.bitPattern, 0.00016200891049007697.bitPattern)
        _ = try f.repo.handle("canvas:removeShapes", f.identity.merging(["ids": ["stroke"]]) { _, n in n })
        _ = try f.repo.handle("canvas:putShape", input)
        XCTAssertTrue(try f.shapes().isEmpty, "A late pressure correction cannot revive an erased object")
        _ = try f.repo.handle("canvas:putShape", input.merging(["restore": true]) { _, n in n })
        XCTAssertEqual(try f.shapes().count, 1)
    }
    func testPageTruncationAndCrossBoardDeleteValidateBeforeMutation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try f.repo.handle("canvas:setPageCount", f.identity.merging(["pageCount": 2]) { _, n in n })
        _ = try f.repo.handle("canvas:putShape", f.put("page-two", page: 2))
        XCTAssertThrowsError(try f.repo.handle("canvas:setPageCount", f.identity.merging(["pageCount": 1]) { _, n in n }))
        let other = try f.repo.handle("canvas:create", ["courseId": f.course, "title": "Other"]) as! [String: Any]
        _ = try f.repo.handle("canvas:putShape", f.put("foreign").merging(["boardId": other["id"]!]) { _, n in n })
        XCTAssertThrowsError(try f.repo.handle("canvas:removeShapes", f.identity.merging(["ids": ["page-two", "foreign"]]) { _, n in n }))
        XCTAssertEqual(try f.shapes().count, 1)
    }
    func testLateEstimatedCorrectionCannotBeRemovedByEarlierAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = HoldingBackend(), id = UUID().uuidString
        let writer = try NativeWhiteboardPersistence(root: root, courseID: "course", boardID: "board", invoke: backend.invoke)
        try writer.enqueue(id: id, commands: [command(pressure: 0.3)])
        let draining = Task { @MainActor in try await writer.drain() }
        while backend.waiting == nil { await Task.yield() }
        try writer.enqueue(id: id, commands: [command(pressure: 0.9)])
        backend.waiting?.resume(returning: [:]); backend.waiting = nil
        try await draining.value
        XCTAssertEqual(backend.inputs.count, 2)
        XCTAssertEqual(backend.inputs.last?["pressure"] as? Double, 0.9)
        XCTAssertEqual(writer.pendingCount, 0)
        let restarted = try NativeWhiteboardPersistence(root: root, courseID: "course", boardID: "board", invoke: backend.invoke)
        XCTAssertEqual(restarted.pendingCount, 0)
    }
    func testInterruptedQueuedEraseReplaysAfterRestartWithStableShapeIdentity() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        var fail = true
        let writer = try NativeWhiteboardPersistence(root: f.root, courseID: f.course, boardID: f.board) { channel, input in
            if channel == "canvas:removeShapes", fail { fail = false; throw NativePDFError.invalid("simulated save failure") }
            return try f.repo.handle(channel, input)!
        }
        let command: [String: Any] = ["channel": "canvas:putShape", "request": f.put("durable")]
        try writer.enqueue(commands: [command, ["channel": "canvas:removeShapes", "request": ["ids": ["durable"]]]])
        do { try await writer.drain(); XCTFail("Expected simulated interruption") } catch {}
        XCTAssertEqual(try f.shapes().count, 1); XCTAssertEqual(writer.pendingCount, 1)
        let resumed = try NativeWhiteboardPersistence(root: f.root, courseID: f.course, boardID: f.board) { try f.repo.handle($0, $1)! }
        try await resumed.drain()
        XCTAssertEqual(resumed.pendingCount, 0); XCTAssertTrue(try f.shapes().isEmpty)
        XCTAssertEqual(try f.context.query("SELECT id FROM whiteboard_local_shapes").count, 1)
    }
    private func command(pressure: Double) -> [String: Any] { ["channel": "canvas:putShape", "request": ["pressure": pressure]] }
    private final class HoldingBackend {
        var inputs: [[String: Any]] = []
        var waiting: CheckedContinuation<Any, Error>?
        func invoke(_ channel: String, _ input: [String: Any]) async throws -> Any {
            inputs.append(input)
            if inputs.count == 1 { return try await withCheckedThrowingContinuation { waiting = $0 } }
            return [:]
        }
    }
    private final class Fixture {
        let root: URL, context: NativeRepositoryContext, repo: NativeWhiteboardRepository, course: String, board: String
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-repo-" + UUID().uuidString)
            context = try NativeRepositoryContext(root: root, legacyRoot: root.appendingPathComponent("Legacy")); repo = NativeWhiteboardRepository(context: context)
            let created = try NativeLibraryRepository(context: context).handle("courses:create", ["name": "Board", "color": "blue"]) as! [String: Any]; course = created["id"] as! String
            board = (try repo.handle("canvas:create", ["courseId": course, "title": "Board"]) as! [String: Any])["id"] as! String
        }
        var identity: [String: Any] { ["courseId": course, "boardId": board] }
        func put(_ id: String, page: Int = 1) -> [String: Any] { identity.merging(["id": id, "page": page, "shape": ["kind": "ink", "data": ["inkVersion": 5, "points": [["x": 0.2, "y": 0.3, "p": 0.00016200891049007697, "t": 12.3, "tiltX": -25, "tiltY": 12]]], "style": ["color": "blue", "width": 0.003, "opacity": 1]]]) { _, n in n } }
        func shapes() throws -> [[String: Any]] { (try repo.handle("canvas:open", identity) as! [String: Any])["shapes"] as! [[String: Any]] }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

extension NativeWhiteboardTests {
    func testDuplicateBoardInstancesShareOneRecoveryQueueAndPublishPendingPeers() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let registry = NativeWhiteboardSessionRegistry()
        let original = NativeDocumentReference(courseID: f.course, relativePath: f.board, title: "Board", kind: "whiteboard")
        let first = try registry.session(root: f.root, document: original) { try f.repo.handle($0, $1)! }
        let second = try registry.session(root: f.root, document: original.duplicated()) { try f.repo.handle($0, $1)! }
        XCTAssertTrue(first === second)
        try await first.open()
        try first.enqueue(id: UUID().uuidString, commands: [["channel": "canvas:putShape", "request": f.put("first")]])
        XCTAssertEqual(second.visibleRows.first?["id"] as? String, "first", "A peer renders a journaled edit before acknowledgement")
        try second.enqueue(id: UUID().uuidString, commands: [["channel": "canvas:putShape", "request": f.put("second")]])
        async let firstFlush: Void = first.drain()
        async let secondFlush: Void = second.drain()
        _ = try await (firstFlush, secondFlush)
        XCTAssertEqual(Set(try f.shapes().compactMap { $0["id"] as? String }), ["first", "second"])
        XCTAssertEqual(first.writer.pendingCount, 0)
        async let firstPage: Void = first.addPage()
        async let secondPage: Void = second.addPage()
        _ = try await (firstPage, secondPage)
        XCTAssertEqual(first.board["pageCount"] as? Int, 3, "Two panes adding pages must serialize against the shared count")
    }

    func testPaneHistoryRejectsPeerChangedObjectsAndDoesNotRejectUnrelatedEdits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        _ = try f.repo.handle("canvas:putShape", f.put("mine"))
        let rows = try f.shapes()
        let undo = NativeWhiteboardHistoryEntry(commands: [["channel": "canvas:removeShapes", "request": ["ids": ["mine"]]]], rows: rows)
        _ = try f.repo.handle("canvas:putShape", f.put("peer"))
        XCTAssertTrue(undo.matches(try f.shapes()))
        var edited = rows[0]; var style = edited["style"] as! [String: Any]; style["color"] = "red"; edited["style"] = style
        XCTAssertFalse(undo.matches([edited]), "Local undo cannot erase a shape that a peer restyled")
        XCTAssertFalse(undo.matches([]), "Local undo cannot treat a peer deletion as its own operation")
        let restore = NativeWhiteboardHistoryEntry(commands: [["channel": "canvas:putShape", "request": ["id": "mine", "shape": edited]]], rows: [])
        XCTAssertTrue(restore.matches([])); XCTAssertFalse(restore.matches(rows), "Local erase undo cannot overwrite a peer-restored object")
    }

    func testRetainedBoardSessionReloadsAfterAllPanesWereClosed() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let session = try NativeWhiteboardSession(root: f.root, courseID: f.course, boardID: f.board) { try f.repo.handle($0, $1)! }
        try await session.open(); XCTAssertTrue(session.rows.isEmpty)
        _ = try f.repo.handle("canvas:putShape", f.put("external"))
        try await session.open()
        XCTAssertEqual(session.rows.first?["id"] as? String, "external")
    }

    func testHiddenPanelKeepsToolsUndoAndPeerContentOnReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whiteboard-panel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root); await store.start()
        try await store.createCourse(name: "Boards")
        let course = try XCTUnwrap(store.selectedCourseID)
        let board = try await store.invoke("canvas:create", ["courseId": course, "title": "Board"]) as! [String: Any]
        let boardID = try XCTUnwrap(board["id"] as? String)
        let document = NativeDocumentReference(courseID: course, relativePath: boardID, title: "Board", kind: "whiteboard")
        let first = NativeWhiteboardModel(document: document, store: store)
        let peer = NativeWhiteboardModel(document: document.duplicated(), store: store)
        first.start(); peer.start()
        do {
            try await first.flush(); try await peer.flush()
            first.chooseTool("highlighter"); first.chooseColor("violet"); first.setWidth(0.008)
            let mine = NativePDFCompletedStroke(mutationID: UUID().uuidString, kind: "ink",
                points: [.init(x: 0.2, y: 0.3, p: 0.5, t: 12)], style: .init(color: "violet", width: 0.008, opacity: 1))
            try first.stroke(mine, provisional: false); try await first.flush()
            XCTAssertTrue(first.canUndo)
            first.setVisible(false)
            XCTAssertFalse(first.editorVisible)
            first.undo(); try await first.flush()
            XCTAssertEqual(first.count, 1, "Hidden panels cannot execute keyboard undo")
            var theirs = mine; theirs.mutationID = UUID().uuidString
            try peer.stroke(theirs, provisional: false); try await peer.flush()
            XCTAssertEqual(first.count, 2, "Hidden panes continue receiving shared content")
            first.setVisible(true)
            XCTAssertEqual(first.tool, "highlighter"); XCTAssertEqual(first.color, "violet")
            XCTAssertTrue(first.canUndo)
            first.undo(); try await first.flush()
            let opened = try await store.invoke("canvas:open", ["courseId": course, "boardId": boardID]) as! [String: Any]
            XCTAssertEqual((opened["shapes"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [theirs.mutationID], "The returned panel's undo removes only its own stroke")
            XCTAssertTrue(first.canRedo)
            await first.close(); await peer.close()
        } catch {
            await first.close(); await peer.close(); throw error
        }
    }
}
