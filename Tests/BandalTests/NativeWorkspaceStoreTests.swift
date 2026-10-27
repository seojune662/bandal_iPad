import Combine
import PDFKit
import XCTest
@testable import Bandal

@MainActor
final class NativeWorkspaceStoreTests: XCTestCase {
    private var directory: URL!
    private var stores: [NativeWorkspaceStore] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        stores.removeAll()
        try FileManager.default.removeItem(at: directory)
    }

    private func started() async throws -> NativeWorkspaceStore {
        let store = NativeWorkspaceStore(storageRoot: directory)
        stores.append(store)
        await store.start()
        XCTAssertTrue(store.isReady, store.errorMessage ?? "Native workspace did not start")
        return store
    }
    func testMaterialShareAndExportWaitForPendingDocumentEdits() async throws {
        let store = try await started()
        var events: [String] = []
        let token = store.registerDocumentFlush(id: "pending") { events.append("saved") }
        defer { store.unregisterDocumentFlush(token) }
        store.nativeChannelHandler = { channel, _ in events.append(channel); return [:] }
        for channel in ["materials:share", "materials:export"] {
            store.markDocumentChanged()
            _ = try await store.invoke(channel, ["courseId": "course", "relPath": "paper.pdf"])
        }
        XCTAssertEqual(events, ["saved", "materials:share", "saved", "materials:export"])
    }
    func testFailedPendingSavePreventsLibraryShare() async throws {
        let store = try await started()
        let token = store.registerDocumentFlush(id: "pending") { throw DesktopRuntimeError("Unsettled ink") }
        defer { store.unregisterDocumentFlush(token) }
        var presented = false
        store.nativeChannelHandler = { _, _ in presented = true; return [:] }
        do { _ = try await store.invoke("materials:share", ["courseId": "course", "relPath": "paper.pdf"]); XCTFail("Sharing must not bypass an unfinished save") }
        catch {}
        XCTAssertFalse(presented)
    }

    func testNativeFacadeReusesExistingDesktopDatabaseAndPreservesPDFAndInk() async throws {
        let existing = DesktopRuntime(root: directory, legacyRoot: directory.appendingPathComponent("Legacy"))
        try await existing.start()
        let courseValue = try await existing.invoke("courses:create", request: ["name": "기존 과목", "color": "green"])
        let course = try XCTUnwrap(courseValue as? [String: Any])
        let courseID = try XCTUnwrap(course["id"] as? String)
        let noteValue = try await existing.invoke("notes:create", request: ["courseId": courseID, "dirRelPath": "", "title": "보존할 노트"])
        let note = try XCTUnwrap(noteValue as? [String: Any])
        let notePath = try XCTUnwrap(note["relPath"] as? String)
        let originalText = "# 기존 필기\n\n이 내용과 링크 [[보존할 노트]]를 그대로 유지합니다.\n"
        _ = try await existing.invoke("notes:write", request: ["courseId": courseID, "relPath": notePath, "markdown": originalText])
        let pdfValue = try await existing.invoke("pdfNotes:create", request: ["courseId": courseID, "title": "기존 PDF", "paper": "lines", "orientation": "portrait"])
        let pdfPath = try XCTUnwrap((pdfValue as? [String: Any])?["relPath"] as? String)
        let sourcePathValue = try await existing.invokePrivate("nativeMaterial:path", request: ["courseId": courseID, "relPath": pdfPath])
        let sourceURL = URL(fileURLWithPath: try XCTUnwrap(sourcePathValue as? String))
        let originalPDF = try Data(contentsOf: sourceURL)
        let drawingValue = try await existing.invoke("drawings:create", request: ["courseId": courseID, "relPath": pdfPath, "page": 1, "kind": "ink",
            "data": ["points": [["x": 0.1, "y": 0.2, "p": 0.5], ["x": 0.3, "y": 0.4, "p": 0.8]]],
            "style": ["width": 0.004, "color": "ink", "opacity": 1]])
        let drawingID = try XCTUnwrap((drawingValue as? [String: Any])?["id"] as? String)

        let store = try await started()
        XCTAssertEqual(store.courses.map(\.id), [courseID])
        XCTAssertEqual(store.selectedCourseID, courseID)
        XCTAssertTrue(store.materials.contains(where: { $0.relPath == notePath }))
        let read = try await store.invoke("notes:read", ["courseId": courseID, "relPath": notePath])
        XCTAssertEqual((read as? [String: Any])?["markdown"] as? String, originalText)
        let drawings = try await store.invoke("drawings:listForFile", ["courseId": courseID, "relPath": pdfPath])
        XCTAssertEqual((drawings as? [[String: Any]])?.first?["id"] as? String, drawingID)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalPDF)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bandal.db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bandal.sqlite").path), "The Swift UI must not create the abandoned AppModel store")
    }

    func testMarkdownRenameAndSelectionPersistAcrossNativeWorkspaceRestart() async throws {
        let store = try await started()
        try await store.createCourse(name: "과목 A")
        let firstCourse = try XCTUnwrap(store.selectedCourseID)
        try await store.createCourse(name: "과목 B")
        let secondCourse = try XCTUnwrap(store.selectedCourseID)
        XCTAssertNotEqual(firstCourse, secondCourse)
        let note = try await store.createMarkdown(title: "Original")
        _ = try await store.invoke("notes:write", ["courseId": secondCourse, "relPath": note.relativePath, "markdown": "# Original\n\n지속되는 내용 [[Original]]\n"])
        await store.refreshMaterials()
        let material = try XCTUnwrap(store.materials.first(where: { $0.relPath == note.relativePath }))
        try await store.rename(material, to: "Renamed")
        XCTAssertTrue(store.materials.contains(where: { $0.relPath == "Renamed.md" }))
        let reopened = try await started()
        XCTAssertEqual(reopened.selectedCourseID, secondCourse)
        let read = try await reopened.invoke("notes:read", ["courseId": secondCourse, "relPath": "Renamed.md"])
        let markdown = try XCTUnwrap((read as? [String: Any])?["markdown"] as? String)
        XCTAssertTrue(markdown.contains("지속되는 내용"))
        XCTAssertTrue(markdown.contains("[[Renamed]]"))
        XCTAssertTrue(markdown.hasPrefix("# Renamed"))
    }

    func testImportCopiesExternalBytesAndReportsMaterialTreeWithoutDeletingSource() async throws {
        let store = try await started()
        try await store.createCourse(name: "자료 가져오기")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("native-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let source = outside.appendingPathComponent("원본.md")
        let bytes = Data("# 외부 원본\n\n복사 이후에도 원래 파일은 유지합니다.\n".utf8)
        try bytes.write(to: source, options: .atomic)
        try await store.importFiles([source])
        let imported = try XCTUnwrap(store.materials.first(where: { $0.name == "원본.md" }))
        let courseID = try XCTUnwrap(store.selectedCourseID)
        let pathValue = try await store.invokePrivate("nativeMaterial:path", ["courseId": courseID, "relPath": imported.relPath])
        let path = try XCTUnwrap(pathValue as? String)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
        XCTAssertNotEqual(path, source.path)
        let staging = directory.appendingPathComponent("Temporary/NativeImports")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testPaperCreationAndDeleteRetainRecoverableOriginal() async throws {
        let store = try await started()
        try await store.createCourse(name: "필기 노트")
        try await store.createFolder(name:"수학",parentPath:"")
        let note = try await store.createNote(title: "가로 격자", paper: "grid", orientation: "landscape",parentPath:"수학")
        XCTAssertTrue(note.relativePath.hasPrefix("수학/"))
        let pathValue = try await store.invokePrivate("nativeMaterial:path", ["courseId": note.courseID, "relPath": note.relativePath])
        let url = URL(fileURLWithPath: try XCTUnwrap(pathValue as? String))
        let bytes = try Data(contentsOf: url)
        let pdf = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertEqual(pdf.pageCount, 1)
        let page = try XCTUnwrap(pdf.page(at: 0))
        XCTAssertGreaterThan(page.bounds(for: .mediaBox).width, page.bounds(for: .mediaBox).height)
        let material = try XCTUnwrap(NativeLibraryIndex.flatten(store.materials).first(where: { $0.relPath == note.relativePath }))
        try await store.delete(material)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory.appendingPathComponent("Trash"), includingPropertiesForKeys: [.isRegularFileKey]))
        let retained = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "pdf" }
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retained.first)), bytes)
    }

    func testCapturedCreationAndImportOwnerSurvivesCourseSelectionChange() async throws {
        let store = try await started()
        try await store.createCourse(name: "Original destination")
        let destination = try XCTUnwrap(store.selectedCourseID)
        try await store.createCourse(name: "Currently selected")
        let selected = try XCTUnwrap(store.selectedCourseID)
        XCTAssertNotEqual(destination, selected)

        try await store.createFolder(name: "Captured folder", courseID: destination, parentPath: "")
        let note = try await store.createNote(title: "Captured note", paper: "blank", orientation: "portrait", courseID: destination, parentPath: "Captured folder")
        XCTAssertEqual(note.courseID, destination)
        XCTAssertTrue(note.relativePath.hasPrefix("Captured folder/"))
        let source = directory.appendingPathComponent("picked.md")
        let original = Data("# Preserved import destination\n".utf8)
        try original.write(to: source)
        try await store.importFiles([source], courseID: destination, parentPath: "Captured folder")
        let pathValue = try await store.invokePrivate("nativeMaterial:path", ["courseId": destination, "relPath": "Captured folder/picked.md"])
        let imported = URL(fileURLWithPath: try XCTUnwrap(pathValue as? String))
        XCTAssertEqual(try Data(contentsOf: imported), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(store.selectedCourseID, selected, "Background creation must not change the selected course")
        XCTAssertFalse(NativeLibraryIndex.flatten(store.materials).contains { $0.relPath.hasPrefix("Captured folder") })

        do {
            try await store.createFolder(name: "Wrong fallback", courseID: "removed-course", parentPath: "")
            XCTFail("A missing explicit owner must fail rather than write into the selected course")
        } catch {}
        XCTAssertFalse(store.materials.contains { $0.name == "Wrong fallback" })
    }

    func testDocumentScopedMutationRetiresOnlyTheChangedTabAndResumesTheInitiator() async throws {
        let store = NativeWorkspaceStore(storageRoot: directory)
        let edited = NativeDocumentReference(courseID: "a", relativePath: "notes/x.pdf", title: "x", kind: "pdf")
        let duplicate = edited.duplicated() // a second pane of the same file has its own tab id
        let other = NativeDocumentReference(courseID: "a", relativePath: "notes/y.pdf", title: "y", kind: "pdf")
        let browser = NativeDocumentReference(courseID: "a", relativePath: "", title: "web", kind: "browser")
        var retired: [String] = [], resumed: [String] = []
        func register(_ document: NativeDocumentReference, _ name: String) -> UUID {
            store.registerDocumentFlush(id: document.id, document: document, resume: { resumed.append(name) }, retire: { retired.append(name) }) {}
        }
        let initiator = register(edited, "initiator"), twin = register(duplicate, "twin"), bystander = register(other, "bystander")
        defer { [initiator, twin, bystander].forEach(store.unregisterDocumentFlush) }
        let identities = [edited, duplicate, other, browser].map(store.reloadIdentity)
        _ = try await store.withExternalMutation({ ["changedCourseIDs": ["a"], "changedDocuments": [["courseId": "a", "relPath": "notes/x.pdf"]]] }, reopening: initiator)
        XCTAssertEqual(Set(retired), ["twin"], "only another editor of the changed file is retired")
        XCTAssertEqual(Set(resumed), ["initiator", "bystander"])
        XCTAssertEqual(store.reloadIdentity(for: edited), identities[0], "the initiator reopens in place")
        XCTAssertNotEqual(store.reloadIdentity(for: duplicate), identities[1], "a duplicate pane rebuilds")
        XCTAssertEqual(store.reloadIdentity(for: other), identities[2], "an untouched file in the same course keeps its editor")
        XCTAssertEqual(store.reloadIdentity(for: browser), identities[3])
        // A directory scope matches contained paths; the old course scope still matches by course.
        XCTAssertTrue(NativeWorkspaceStore.affects(changedDocuments: [["courseId": "a", "relPath": "notes", "isDirectory": true]], changedCourseIDs: nil, ["courseId": "a", "relPath": "notes/y.pdf"]))
        XCTAssertFalse(NativeWorkspaceStore.affects(changedDocuments: [["courseId": "a", "relPath": "notes/x.pdf"]], changedCourseIDs: ["a"], ["courseId": "a", "relPath": "notes/y.pdf"]))
        XCTAssertTrue(NativeWorkspaceStore.affects(changedDocuments: nil, changedCourseIDs: ["a"], ["courseId": "a", "relPath": "notes/y.pdf"]))
        XCTAssertTrue(NativeWorkspaceStore.affects(changedDocuments: nil, changedCourseIDs: nil, ["courseId": "b", "relPath": "z.pdf"]))
        // A universal mutation still never rebuilds a tool tab.
        _ = try await store.withExternalMutation { [:] as [String: Any] }
        XCTAssertEqual(store.reloadIdentity(for: browser), identities[3])
        XCTAssertNotEqual(store.reloadIdentity(for: other), identities[2])
    }

    func testFlushBarrierJoinsConcurrentCallsAndStillFlushesAfterOneFailure() async throws {
        let store = NativeWorkspaceStore(storageRoot: directory)
        var firstCalls = 0, secondCalls = 0
        var shouldFail = true
        let first = store.registerDocumentFlush(id: "a") {
            firstCalls += 1
            try await Task.sleep(nanoseconds: 10_000_000)
            if shouldFail { throw DesktopRuntimeError("fixture save failure") }
        }
        let second = store.registerDocumentFlush(id: "b") { secondCalls += 1 }
        let a = Task { try await store.flushDocuments() }
        let b = Task { try await store.flushDocuments() }
        for pending in [a, b] {
            do { try await pending.value; XCTFail("Both callers should observe the save failure") }
            catch { XCTAssertEqual(error.localizedDescription, "fixture save failure") }
        }
        XCTAssertGreaterThanOrEqual(firstCalls, 1)
        XCTAssertEqual(secondCalls, firstCalls, "A failing document must not prevent other documents from saving")
        let previousCalls = firstCalls
        shouldFail = false
        try await store.flushDocuments()
        XCTAssertEqual(firstCalls, previousCalls + 1)
        XCTAssertEqual(secondCalls, previousCalls + 1)
        store.unregisterDocumentFlush(first)
        store.unregisterDocumentFlush(second)
        try await store.flushDocuments()
        XCTAssertEqual(firstCalls, previousCalls + 1)
    }

    func testFlushBarrierIncludesEditsToAnEarlierDocumentWhileAnotherSaveIsAwaiting() async throws {
        let store = NativeWorkspaceStore(storageRoot: directory)
        var editedText = "original", savedText = "", saveCalls = 0
        var pending: CheckedContinuation<Void, Never>?
        let first = store.registerDocumentFlush(id: "a") { savedText = editedText; saveCalls += 1 }
        let second = store.registerDocumentFlush(id: "b") {
            if saveCalls == 1 { await withCheckedContinuation { pending = $0 } }
        }
        let saving = Task { try await store.flushDocuments() }
        while pending == nil { await Task.yield() }
        editedText = "new edit while another document saves"
        store.markDocumentChanged()
        pending?.resume()
        try await saving.value
        XCTAssertEqual(savedText, editedText)
        XCTAssertEqual(saveCalls, 2)
        store.unregisterDocumentFlush(first)
        store.unregisterDocumentFlush(second)
    }

    func testPDFRewriteReachesValidatedNativeRepository() async throws {
        let store = try await started()
        do {
            _ = try await store.invoke("pdf:restructure", [:])
            XCTFail("Page rewrites must reject missing document identity")
        } catch { XCTAssertNotEqual((error as? DesktopRuntimeError)?.code, "UNSUPPORTED_CHANNEL") }
    }

    private func markdownSession(_ document: NativeDocumentReference, store: NativeWorkspaceStore,
                                 debounceNanoseconds: UInt64 = 60_000_000_000,
                                 rejectWrite: @escaping () -> Bool = { false }) -> NativeMarkdownSession {
        let session = NativeMarkdownSession(courseID: document.courseID, relativePath: document.relativePath,
            draftFile: draftFile(document), debounceNanoseconds: debounceNanoseconds,
            invoke: { [weak store] channel, request in
                if channel == "notes:write", rejectWrite() { throw DesktopRuntimeError("fixture disk failure") }
                guard let store else { throw CancellationError() }
                return try await store.invoke(channel, request)
            })
        session.onContentChanged = { [weak store] in store?.markDocumentChanged() }
        return session
    }

    private func draftFile(_ document: NativeDocumentReference) -> NativeMarkdownDraftFile {
        NativeMarkdownDraftFile(documentID: document.id, directory: directory.appendingPathComponent("Drafts"))
    }

    private func register(_ session: NativeMarkdownSession, document: NativeDocumentReference, store: NativeWorkspaceStore) -> UUID {
        store.registerDocumentFlush(id: document.id,
            freeze: { session.freezeForMaterialMutation() },
            suspendWrites: { session.suspendWritesForMaterialMutation() },
            resume: { session.cancelMaterialMutation() },
            retire: { session.retireAfterMaterialMutation() },
            flush: { try await session.flush() })
    }

    private func read(_ document: NativeDocumentReference, store: NativeWorkspaceStore) async throws -> [String: Any] {
        let value = try await store.invoke("notes:read", ["courseId": document.courseID, "relPath": document.relativePath])
        return try XCTUnwrap(value as? [String: Any])
    }

    private func replace(_ document: NativeDocumentReference, text: String, store: NativeWorkspaceStore) async throws {
        let value = try await read(document, store: store)
        _ = try await store.invoke("notes:write", ["courseId": document.courseID, "relPath": document.relativePath,
            "markdown": text, "expectedMtime": try XCTUnwrap(value["mtime"])])
    }

    func testExternalMutationCommitsCompositionBeforeOverwriteAndRetiresOldMarkdownOwner() async throws {
        let store = try await started()
        try await store.createCourse(name: "동기화")
        let document = try await store.createMarkdown(title: "동기화 노트")
        let session = markdownSession(document, store: store)
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        session.update("아", isComposing: true)
        session.prepareForFlush = { session.update("# 완성된 입력\n", isComposing: false) }
        var editing: [Bool] = [], events: [String] = []
        session.setEditingEnabled = { editing.append($0) }
        let subscription = store.events.sink { events.append($0.channel) }
        defer { subscription.cancel() }
        let epoch = store.documentReloadEpoch

        _ = try await store.withExternalMutation {
            XCTAssertTrue(store.isApplyingExternalChanges)
            XCTAssertTrue(session.frozen)
            XCTAssertFalse(session.dirty)
            let local = try await self.read(document, store: store)
            XCTAssertEqual(local["markdown"] as? String, "# 완성된 입력\n")
            try await self.replace(document, text: "# 다른 기기의 내용\n", store: store)
            return ["changedCourseIDs": [document.courseID]]
        }

        XCTAssertTrue(session.retired)
        XCTAssertTrue(session.frozen)
        XCTAssertFalse(store.isApplyingExternalChanges)
        XCTAssertEqual(store.documentReloadEpoch, epoch + 1)
        XCTAssertEqual(editing, [false, false])
        XCTAssertTrue(events.contains("nativeWorkspace:materialWillMutate"))
        XCTAssertTrue(events.contains("nativeWorkspace:materialReplaced"))
        XCTAssertTrue(events.contains("nativeWorkspace:externalMutationFinished"))
        session.update("늦게 도착한 이전 화면 입력", isComposing: false)
        try await session.flush()
        let final = try await read(document, store: store)
        XCTAssertEqual(final["markdown"] as? String, "# 다른 기기의 내용\n")
        XCTAssertNil(try draftFile(document).read())
        let reopened = markdownSession(document, store: store)
        await reopened.load()
        XCTAssertEqual(reopened.text, "# 다른 기기의 내용\n")
    }

    func testPDFRenameFlushesAndReloadsOpenConnectedPageNote() async throws {
        try await assertLinkedPageNoteSurvivesPathChange("renamePDF")
    }

    func testPDFMoveFlushesAndReloadsOpenConnectedPageNote() async throws {
        try await assertLinkedPageNoteSurvivesPathChange("movePDF")
    }

    func testFolderRenameFlushesAndReloadsContainedPDFPageNote() async throws {
        try await assertLinkedPageNoteSurvivesPathChange("renameFolder")
    }

    private func assertLinkedPageNoteSurvivesPathChange(_ operation: String) async throws {
        let store = try await started()
        try await store.createCourse(name: "연결된 페이지 노트")
        try await store.createFolder(name: "Original", parentPath: "")
        try await store.createFolder(name: "Destination", parentPath: "")
        let pdf = try await store.createNote(title: "Source", paper: "blank", orientation: "portrait", parentPath: "Original")
        let note = try await store.openPDFPageNote(courseID: pdf.courseID, relativePath: pdf.relativePath)
        let session = markdownSession(note, store: store)
        let token = register(session, document: note, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        var body = try XCTUnwrap(NativePDFPageNoteDocument(session.text))
        body.pages[0] = "    unsaved code before path change"
        session.update(try body.markdown(), isComposing: false)
        XCTAssertTrue(session.dirty)
        let identity = store.reloadIdentity(for: note)
        var channels: [String] = []
        let subscription = store.events.sink { channels.append($0.channel) }
        defer { subscription.cancel() }
        await store.refreshMaterials()
        let target = operation == "renameFolder" ? "Original" : pdf.relativePath
        let material = try XCTUnwrap(NativeLibraryIndex.flatten(store.materials).first { $0.relPath == target })
        let newPDFPath: String
        var reopenedNote = note
        switch operation {
        case "movePDF":
            try await store.move(material, to: "Destination")
            newPDFPath = "Destination/" + (pdf.relativePath as NSString).lastPathComponent
        case "renameFolder":
            try await store.rename(material, to: "Renamed")
            newPDFPath = "Renamed/" + (pdf.relativePath as NSString).lastPathComponent
            reopenedNote.relativePath = "Renamed/" + (note.relativePath as NSString).lastPathComponent
        default:
            try await store.rename(material, to: "Renamed")
            newPDFPath = "Original/Renamed.pdf"
        }
        XCTAssertTrue(session.retired)
        XCTAssertFalse(session.dirty)
        XCTAssertNotEqual(store.reloadIdentity(for: note), identity)
        let renamedEvent = try XCTUnwrap(channels.firstIndex(of: "nativeWorkspace:materialRenamed"))
        let replacedEvent = try XCTUnwrap(channels.firstIndex(of: "nativeWorkspace:externalMutationFinished"))
        XCTAssertLessThan(renamedEvent, replacedEvent, "Tabs must adopt the new path before editors reopen")
        session.update("stale editor must not overwrite the rewritten manifest", isComposing: false)
        try await session.flush()
        let saved = try await read(reopenedNote, store: store)
        let savedBody = try XCTUnwrap(NativePDFPageNoteDocument(try XCTUnwrap(saved["markdown"] as? String)))
        XCTAssertEqual(savedBody.source, newPDFPath)
        XCTAssertEqual(savedBody.pages[0], "    unsaved code before path change")
        let reopened = markdownSession(reopenedNote, store: store)
        await reopened.load()
        var next = try XCTUnwrap(NativePDFPageNoteDocument(reopened.text))
        next.pages[0] += "\ncontinued after path change"
        reopened.update(try next.markdown(), isComposing: false)
        try await reopened.flush()
        let final = try await read(reopenedNote, store: store)
        XCTAssertTrue((final["markdown"] as? String)?.contains("continued after path change") == true)
        XCTAssertFalse(reopened.dirty, "A fresh owner must use the new on-disk version")
    }

    func testFailedExternalMutationResumesSameMarkdownSessionAndItsExpectedVersion() async throws {
        let store = try await started()
        try await store.createCourse(name: "동기화 실패")
        let document = try await store.createMarkdown(title: "노트")
        let session = markdownSession(document, store: store)
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        session.update("# 내 편집\n", isComposing: false)
        var editing: [Bool] = [], events: [String] = []
        session.setEditingEnabled = { editing.append($0) }
        let subscription = store.events.sink { events.append($0.channel) }
        defer { subscription.cancel() }
        let epoch = store.documentReloadEpoch
        do {
            _ = try await store.withExternalMutation {
                XCTAssertTrue(session.frozen)
                XCTAssertFalse(session.dirty)
                throw DesktopRuntimeError("fixture download failed")
            }
            XCTFail("The external error must reach the caller")
        } catch { XCTAssertEqual(error.localizedDescription, "fixture download failed") }
        XCTAssertFalse(session.frozen)
        XCTAssertFalse(session.retired)
        XCTAssertFalse(store.isApplyingExternalChanges)
        XCTAssertEqual(store.documentReloadEpoch, epoch)
        XCTAssertEqual(editing, [false, true])
        XCTAssertTrue(events.contains("nativeWorkspace:materialMutationCancelled"))
        XCTAssertFalse(events.contains("nativeWorkspace:externalMutationFinished"))
        session.update("# 실패 후 계속 작성\n", isComposing: false)
        try await session.flush()
        let saved = try await read(document, store: store)
        XCTAssertEqual(saved["markdown"] as? String, "# 실패 후 계속 작성\n")
    }

    func testExternalMutationFlushFailureKeepsDraftAndNeverRunsReplacement() async throws {
        let store = try await started()
        try await store.createCourse(name: "저장 실패")
        let document = try await store.createMarkdown(title: "노트")
        var rejectWrite = true
        let session = markdownSession(document, store: store, rejectWrite: { rejectWrite })
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        let original = session.text
        session.update("# 보존할 임시 내용\n", isComposing: false)
        var replacementRan = false, otherFlushes = 0
        let other = store.registerDocumentFlush(id: "z:other") { otherFlushes += 1 }
        defer { store.unregisterDocumentFlush(other) }
        do {
            _ = try await store.withExternalMutation { replacementRan = true; return [:] as [String: Any] }
            XCTFail("A failed local save must stop the import")
        } catch { XCTAssertEqual(error.localizedDescription, "fixture disk failure") }
        XCTAssertFalse(replacementRan)
        XCTAssertGreaterThan(otherFlushes, 0)
        XCTAssertTrue(session.dirty)
        XCTAssertFalse(session.frozen)
        XCTAssertFalse(session.retired)
        XCTAssertFalse(store.isApplyingExternalChanges)
        XCTAssertEqual(store.documentReloadEpoch, 0)
        XCTAssertEqual(try draftFile(document).read()?.markdown, "# 보존할 임시 내용\n")
        let unchanged = try await read(document, store: store)
        XCTAssertEqual(unchanged["markdown"] as? String, original)
        rejectWrite = false
        try await session.flush()
        let saved = try await read(document, store: store)
        XCTAssertEqual(saved["markdown"] as? String, "# 보존할 임시 내용\n")
    }

    func testNoOpAndUnrelatedCourseImportPreserveTheLoadedMarkdownSession() async throws {
        let store = try await started()
        try await store.createCourse(name: "열린 과목")
        let document = try await store.createMarkdown(title: "노트")
        let session = markdownSession(document, store: store)
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        var editing: [Bool] = [], replaced = 0
        session.setEditingEnabled = { editing.append($0) }
        let subscription = store.events.sink { if $0.channel == "nativeWorkspace:materialReplaced" { replaced += 1 } }
        defer { subscription.cancel() }
        for changed in [[], ["unrelated-course"]] as [[String]] {
            session.update("# 편집 \(changed.count)\n", isComposing: false)
            _ = try await store.withExternalMutation { ["changedCourseIDs": changed] }
            XCTAssertFalse(session.frozen)
            XCTAssertFalse(session.retired)
            XCTAssertEqual(store.documentReloadEpoch, 0)
            XCTAssertFalse(session.dirty)
        }
        XCTAssertEqual(editing, [false, true, false, true])
        XCTAssertEqual(replaced, 0, "No reload event means the existing UIKit text view and undo manager survive")
    }

    func testLateRegisteredMarkdownWaitsForReplacementAndCannotAutosaveItsRecoveredDraft() async throws {
        let store = try await started()
        try await store.createCourse(name: "열리는 중 동기화")
        let document = try await store.createMarkdown(title: "늦게 연 노트")
        let before = try await read(document, store: store)
        try draftFile(document).write(.init(markdown: "# 아직 저장되지 않은 복구본\n", expectedMtime: try XCTUnwrap((before["mtime"] as? NSNumber)?.doubleValue)))
        var finishReplacement: CheckedContinuation<Void, Never>?
        let replacement = Task {
            try await store.withExternalMutation {
                await withCheckedContinuation { finishReplacement = $0 }
                try await self.replace(document, text: "# 원격 노트\n", store: store)
                return ["changedCourseIDs": [document.courseID]]
            }
        }
        while finishReplacement == nil { await Task.yield() }
        let session = markdownSession(document, store: store, debounceNanoseconds: 1_000_000)
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        XCTAssertTrue(session.frozen, "Registration synchronously freezes a newly mounted editor")
        var didPassGate = false
        let opening = Task {
            await store.waitForExternalMutation()
            didPassGate = true
            guard !session.retired else { return }
            await session.load()
        }
        // Even a caller that had already begun loading must retain its draft,
        // with both debounce writes and explicit background flush suspended.
        await session.load()
        XCTAssertTrue(session.dirty)
        try await session.flush()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(didPassGate)
        let untouched = try await read(document, store: store)
        XCTAssertEqual(untouched["markdown"] as? String, before["markdown"] as? String)
        store.unregisterDocumentFlush(token)
        finishReplacement?.resume()
        _ = try await replacement.value
        await opening.value
        XCTAssertTrue(didPassGate)
        XCTAssertTrue(session.retired, "An owner unregistered during the import must still be retired")
        XCTAssertEqual(store.documentReloadEpoch, 1)
        XCTAssertEqual(try draftFile(document).read()?.markdown, "# 아직 저장되지 않은 복구본\n")
        let reopened = markdownSession(document, store: store)
        await reopened.load()
        XCTAssertTrue(reopened.dirty)
        XCTAssertNotNil(reopened.errorMessage, "The old draft must become an explicit conflict, never overwrite the imported version")
        let remote = try await read(document, store: store)
        XCTAssertEqual(remote["markdown"] as? String, "# 원격 노트\n")
    }

    func testOneCourseReplacementPreservesCompanionViewIdentityAndUndoOwner() async throws {
        let store = try await started()
        try await store.createCourse(name:"변경할 과목")
        let changed = try await store.createMarkdown(title:"원격 변경")
        let changedSession = markdownSession(changed,store:store)
        let changedToken = register(changedSession,document:changed,store:store)
        try await store.createCourse(name:"함께 읽는 과목")
        let companion = try await store.createMarkdown(title:"계속 편집")
        let companionSession = markdownSession(companion,store:store)
        let companionToken = register(companionSession,document:companion,store:store)
        defer { store.unregisterDocumentFlush(changedToken); store.unregisterDocumentFlush(companionToken) }
        await changedSession.load(); await companionSession.load()
        let changedIdentity = store.reloadIdentity(for:changed)
        let companionIdentity = store.reloadIdentity(for:companion)
        _ = try await store.withExternalMutation {
            try await self.replace(changed,text:"# 원격 내용\n",store:store)
            return ["changedCourseIDs":[changed.courseID]]
        }
        XCTAssertNotEqual(store.reloadIdentity(for:changed),changedIdentity)
        XCTAssertEqual(store.reloadIdentity(for:companion),companionIdentity)
        XCTAssertTrue(changedSession.retired)
        XCTAssertFalse(companionSession.retired)
        XCTAssertFalse(companionSession.frozen)
        companionSession.update("# 이어서 작성\n",isComposing:false)
        try await companionSession.flush()
        let saved = try await read(companion,store:store)
        XCTAssertEqual(saved["markdown"] as? String,"# 이어서 작성\n")
    }

    func testPartiallyCommittedImportRetiresChangedEditorWhileReportingFailure() async throws {
        let store = try await started()
        try await store.createCourse(name:"부분 적용")
        let document = try await store.createMarkdown(title:"노트")
        let session = markdownSession(document,store:store)
        let token = register(session,document:document,store:store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        session.update("# 저장할 내 내용\n",isComposing:false)
        let oldIdentity = store.reloadIdentity(for:document)
        do {
            _ = try await store.withExternalMutation {
                try await self.replace(document,text:"# 이미 적용된 원격 내용\n",store:store)
                throw NativeSyncImportFailure(underlyingError:DesktopRuntimeError("다음 파일 복구 필요",code:"RECOVERY_REQUIRED"),changedCourseIDs:[document.courseID])
            }
            XCTFail("The partial failure must reach the sync UI")
        } catch { XCTAssertTrue(error is NativeSyncImportFailure) }
        XCTAssertTrue(session.retired)
        XCTAssertNotEqual(store.reloadIdentity(for:document),oldIdentity)
        XCTAssertFalse(store.isApplyingExternalChanges)
        session.update("오래된 편집기 내용",isComposing:false)
        try await session.flush()
        let saved = try await read(document,store:store)
        XCTAssertEqual(saved["markdown"] as? String,"# 이미 적용된 원격 내용\n")
        let reopened = markdownSession(document,store:store)
        await reopened.load()
        XCTAssertEqual(reopened.text,"# 이미 적용된 원격 내용\n")
    }

    func testRegistrationDuringInitialFlushParticipatesWithoutDeadlockingTheOpenGate() async throws {
        let store = try await started()
        try await store.createCourse(name: "저장 중 열기")
        let document = try await store.createMarkdown(title: "새로 연 노트")
        var finishFlush: CheckedContinuation<Void, Never>?, didWait = false
        let blocker = store.registerDocumentFlush(id: "a:blocker") {
            if !didWait { didWait = true; await withCheckedContinuation { finishFlush = $0 } }
        }
        defer { store.unregisterDocumentFlush(blocker) }
        let mutation = Task {
            try await store.withExternalMutation {
                let read = try await self.read(document, store: store)
                XCTAssertEqual(read["markdown"] as? String, "# 초기 flush 중 복구된 노트\n")
                return ["changedCourseIDs": [] as [String]]
            }
        }
        while finishFlush == nil { await Task.yield() }
        let original = try await read(document, store: store)
        try draftFile(document).write(.init(markdown: "# 초기 flush 중 복구된 노트\n", expectedMtime: try XCTUnwrap((original["mtime"] as? NSNumber)?.doubleValue)))
        let session = markdownSession(document, store: store)
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await store.waitForExternalMutation()
        await session.load()
        XCTAssertTrue(session.frozen)
        XCTAssertTrue(session.dirty)
        finishFlush?.resume()
        _ = try await mutation.value
        XCTAssertFalse(session.frozen)
        XCTAssertFalse(session.dirty)
        XCTAssertFalse(session.retired)
    }

    func testRenameAwaitingLocalFlushFinishesBeforeAnExternalReplacementCanStart() async throws {
        let store = try await started()
        try await store.createCourse(name: "이름 변경 중 동기화")
        let document = try await store.createMarkdown(title: "Original")
        let material = try XCTUnwrap(store.materials.first { $0.relPath == document.relativePath })
        let session = markdownSession(document, store: store)
        let token = register(session, document: document, store: store)
        defer { store.unregisterDocumentFlush(token) }
        await session.load()
        session.update("# Original\n\n내 편집\n", isComposing: false)
        // Mirror the workspace's local-path event handling. Global replacement
        // uses the lifecycle callbacks registered above.
        let subscription = store.events.sink { event in
            guard let value = event.payload as? [String: Any],
                  value["courseId"] as? String == document.courseID,
                  (value["fromRelPath"] ?? value["relPath"]) as? String == document.relativePath else { return }
            switch event.channel {
            case "nativeWorkspace:materialWillMutate": session.freezeForMaterialMutation()
            case "nativeWorkspace:materialMutationCancelled": session.cancelMaterialMutation()
            case "nativeWorkspace:materialRenamed": session.retireAfterMaterialMutation()
            default: break
            }
        }
        defer { subscription.cancel() }
        var finishSave: CheckedContinuation<Void, Never>?, blockedOnce = false
        let blocker = store.registerDocumentFlush(id: "0:save") {
            if !blockedOnce { blockedOnce = true; await withCheckedContinuation { finishSave = $0 } }
        }
        defer { store.unregisterDocumentFlush(blocker) }
        let rename = Task { try await store.rename(material, to: "Renamed") }
        while finishSave == nil { await Task.yield() }
        var replacementStarted = false
        let replacement = Task {
            try await store.withExternalMutation {
                replacementStarted = true
                let renamed = NativeDocumentReference(courseID: document.courseID, relativePath: "Renamed.md", title: "Renamed.md", kind: "note")
                let local = try await self.read(renamed, store: store)
                XCTAssertEqual(local["markdown"] as? String, "# Renamed\n\n내 편집\n")
                try await self.replace(renamed, text: "# 동기화된 이름 변경 노트\n", store: store)
                return ["changedCourseIDs": [document.courseID]]
            }
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(replacementStarted)
        XCTAssertFalse(store.isApplyingExternalChanges, "An import waiting for a local mutation must not freeze that mutation halfway through")
        finishSave?.resume()
        try await rename.value
        _ = try await replacement.value
        XCTAssertTrue(session.retired)
        session.update("늦은 원본 편집", isComposing: false)
        try await session.flush()
        let renamed = NativeDocumentReference(courseID: document.courseID, relativePath: "Renamed.md", title: "Renamed.md", kind: "note")
        let saved = try await read(renamed, store: store)
        XCTAssertEqual(saved["markdown"] as? String, "# 동기화된 이름 변경 노트\n")
        XCTAssertFalse(store.materials.contains { $0.relPath == document.relativePath })
    }

    func testMutationLeaseRejectsNestedCallsAndReleasesCancelledQueuedTurns() async throws {
        let store = try await started()
        var finishFirst: CheckedContinuation<Void, Never>?
        let first = Task {
            try await store.withExternalMutation {
                do {
                    _ = try await store.withExternalMutation { XCTFail("Nested replacement must not run"); return [:] as [String: Any] }
                    XCTFail("Nested acquisition must fail instead of waiting on its own lease")
                } catch { XCTAssertTrue(error.localizedDescription.contains("자료 변경 작업")) }
                await withCheckedContinuation { finishFirst = $0 }
                return ["changedCourseIDs": [] as [String]]
            }
        }
        while finishFirst == nil { await Task.yield() }
        let cancelled = Task { try await store.withExternalMutation { XCTFail("Cancelled replacement must not run"); return [:] as [String: Any] } }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        var lastRan = false
        let last = Task { try await store.withExternalMutation { lastRan = true; return ["changedCourseIDs": [] as [String]] } }
        finishFirst?.resume()
        _ = try await first.value
        do { _ = try await cancelled.value; XCTFail("Cancellation must be propagated") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await last.value
        XCTAssertTrue(lastRan)
        XCTAssertFalse(store.isApplyingExternalChanges)
    }

    func testEditorRegisteredByCompletionNotificationStartsUnfrozen() async throws {
        let store = try await started()
        try await store.createCourse(name: "완료 직후 열기")
        let document = try await store.createMarkdown(title: "노트")
        let session = markdownSession(document, store: store)
        var token: UUID?
        let subscription = store.events.sink { event in
            if event.channel == "nativeWorkspace:externalMutationFinished" {
                token = self.register(session, document: document, store: store)
            }
        }
        defer { subscription.cancel(); if let token { store.unregisterDocumentFlush(token) } }
        _ = try await store.withExternalMutation { ["status": "ok"] }
        XCTAssertNotNil(token)
        XCTAssertFalse(session.frozen)
        await store.waitForExternalMutation()
        await session.load()
        session.update("# 완료 후 작성\n", isComposing: false)
        try await session.flush()
        let saved = try await read(document, store: store)
        XCTAssertEqual(saved["markdown"] as? String, "# 완료 후 작성\n")
    }
}
