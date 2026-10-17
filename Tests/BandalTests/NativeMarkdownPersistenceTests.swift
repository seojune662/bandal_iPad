import XCTest
@testable import Bandal

@MainActor
final class NativeMarkdownPersistenceTests: XCTestCase {
    func testUndoRebasesSeparateMarkupEditsAcrossPeerChangesAndKeepsEmojiWhole() throws {
        let before = "Start\n**한국 👩🏽‍💻**\nEnd"
        let desired = "Start\n한국 👩🏽‍💻\nEnd"
        let current = "Peer start\n**한국 👩🏽‍💻 edited**\nPeer end"
        XCTAssertEqual(try NativeMarkdownTextChange.rebase(from: before, to: desired, onto: current), "Peer start\n한국 👩🏽‍💻 edited\nPeer end")
        XCTAssertEqual(try NativeMarkdownTextChange.rebase(from: "😀a", to: "😎a", onto: "😀a!"), "😎a!")
        XCTAssertEqual(NativeMarkdownTextChange(from: "a b c", to: "Xa b cY").translate(NSRange(location: 2, length: 1)), NSRange(location: 3, length: 1))
    }
    private func temporaryDraft() throws -> (URL, NativeMarkdownDraftFile) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-markdown-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, NativeMarkdownDraftFile(documentID: "course:notes/test.md", directory: directory))
    }

    func testDuplicatePanesShareOneReadDraftAndSerializedWriteRevision() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var stored = "원본", mtime = 1.0, reads = 0
        var written: [String] = [], release: CheckedContinuation<Void, Never>?
        let invoke: NativeMarkdownSession.Invoke = { channel, request in
            if channel == "notes:read" { reads += 1; return ["markdown": stored, "mtime": mtime] }
            XCTAssertEqual((request["expectedMtime"] as? NSNumber)?.doubleValue, mtime)
            written.append(request["markdown"] as! String)
            if written.count == 1 { await withCheckedContinuation { release = $0 } }
            stored = request["markdown"] as! String; mtime += 1; return ["mtime": mtime]
        }
        let key = UUID().uuidString
        var first: NativeMarkdownSession? = .init(courseID: "course", relativePath: "note.md", draftFile: file, sharedKey: key, paneID: "first", debounceNanoseconds: 60_000_000_000, invoke: invoke)
        let second = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, sharedKey: key, paneID: "second", debounceNanoseconds: 60_000_000_000, invoke: invoke)
        await first!.load(); await second.load(); XCTAssertEqual(reads, 1)
        first!.update("왼쪽 편집", isComposing: false)
        XCTAssertEqual(second.text, "왼쪽 편집")
        let writing = Task { try await second.flush() }
        for _ in 0..<100 { if release != nil { break }; await Task.yield() }
        second.update("왼쪽 편집 + 오른쪽 편집", isComposing: false)
        XCTAssertEqual(first!.text, second.text)
        XCTAssertEqual(try file.read()?.markdown, second.text)
        first = nil
        release?.resume(); release = nil
        try await writing.value
        XCTAssertEqual(written, ["왼쪽 편집", "왼쪽 편집 + 오른쪽 편집"])
        XCTAssertEqual(stored, second.text); XCTAssertFalse(second.dirty); XCTAssertNil(try file.read())
    }

    func testSharedMutationCommitsEveryPaneCompositionBeforeFreezingAndRetiresAll() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var stored = "", mtime = 1.0
        let invoke: NativeMarkdownSession.Invoke = { channel, request in
            if channel == "notes:read" { return ["markdown": stored, "mtime": mtime] }
            stored = request["markdown"] as! String; mtime += 1; return ["mtime": mtime]
        }
        let key = UUID().uuidString
        let first = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, sharedKey: key, invoke: invoke)
        let second = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, sharedKey: key, invoke: invoke)
        await first.load(); await second.load()
        var firstCommitted = false, secondCommitted = false
        first.prepareForFlush = { if !firstCommitted { firstCommitted = true; first.update(first.text + "가", isComposing: false) } }
        second.prepareForFlush = { if !secondCommitted { secondCommitted = true; second.update(second.text + "나", isComposing: false) } }
        first.freezeForMaterialMutation()
        XCTAssertTrue(firstCommitted && secondCommitted); XCTAssertTrue(first.frozen && second.frozen)
        try await second.flush()
        XCTAssertEqual(Set(stored), Set("가나"))
        first.retireAfterMaterialMutation()
        XCTAssertTrue(second.retired)
        second.update("늦은 pane callback", isComposing: false)
        XCTAssertEqual(second.text, stored)
        first.prepareForFlush = nil; second.prepareForFlush = nil
    }

    func testPeerDisjointEditRebasesAndOverlappingCompositionKeepsRecoveryCopy() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = UUID().uuidString
        let invoke: NativeMarkdownSession.Invoke = { channel, _ in
            if channel == "notes:read" { return ["markdown": "Left\nRight", "mtime": 1] }
            return ["mtime": 2]
        }
        let first = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, sharedKey: key, paneID: "first", invoke: invoke)
        let second = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, sharedKey: key, paneID: "second", invoke: invoke)
        await first.load(); await second.load()
        first.update("Left!\nRight", isComposing: false)
        XCTAssertTrue(second.update("Left\nRight?", isComposing: false, base: "Left\nRight"))
        XCTAssertEqual(first.text, "Left!\nRight?")
        first.update("Peer\nRight?", isComposing: false)
        XCTAssertFalse(second.update("Mine\nRight?", isComposing: false, base: "Left!\nRight?"))
        XCTAssertEqual(first.text, "Peer\nRight?")
        XCTAssertNotNil(second.errorMessage)
        do { try await second.flush(); XCTFail("An unresolved pane recovery must prevent silent close") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("pane-") })
    }

    func testParentSeesChildConflictAndRestartRecoversItBeforeChildPageMounts() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var copyWritten: String?
        let invoke: NativeMarkdownSession.Invoke = { channel, request in
            if channel == "notes:read" { return ["markdown": "canonical", "mtime": 1] }
            if request["relPath"] as? String == "copy.md" { copyWritten = request["markdown"] as? String }
            return ["mtime": 2]
        }
        let parent = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, invoke: invoke)
        let child = NativeMarkdownSession(sharing: parent, paneID: "page-80")
        await parent.load(); await child.load()
        child.preserveUnmergedText("한글 조합 복구 원문")
        XCTAssertNotNil(parent.errorMessage)
        do { try await parent.flush(); XCTFail("Parent must see the page's unresolved composition") } catch {}
        let restarted = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file, invoke: invoke)
        await restarted.load()
        XCTAssertNotNil(restarted.errorMessage, "An offscreen child page need not be mounted to recover its unsaved conflict")
        do { try await restarted.flush(); XCTFail("Recovered child drafts must block silent close") } catch {}
        try await restarted.keepCopy { .init(courseID: "course", relativePath: "copy.md", title: "copy", kind: "note") }
        XCTAssertEqual(copyWritten, "한글 조합 복구 원문")
        XCTAssertNil(restarted.errorMessage)
        try await restarted.flush()
    }

    func testUnresolvedPaneFreezesAndLateFlushCannotOverwriteItsFirstRecovery() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: file) { channel, _ in
            channel == "notes:read" ? ["markdown": "canonical", "mtime": 1] : ["mtime": 2]
        }
        let child = NativeMarkdownSession(sharing: parent, paneID: "page")
        await parent.load(); await child.load()
        var enabled = true
        child.setEditingEnabled = { enabled = $0 }
        child.preserveUnmergedText("첫 번째 미해결 조합")
        XCTAssertTrue(child.frozen); XCTAssertFalse(enabled); XCTAssertFalse(parent.frozen)
        XCTAssertFalse(child.update("new edit must not replace the recovery", isComposing: false))
        child.prepareForFlush = { child.preserveUnmergedText("늦게 끝난 다른 조합") }
        for _ in 0..<2 { do { try await parent.flush(); XCTFail("Recovery still needs resolution") } catch {} }
        let recovered = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("pane-") }
            .compactMap { try NativeMarkdownDraftFile(url: $0).read()?.markdown }
        XCTAssertEqual(Set(recovered), Set(["첫 번째 미해결 조합", "늦게 끝난 다른 조합"]))
        XCTAssertEqual(recovered.count, 2, "Repeated lifecycle flushes must be idempotent")
        child.prepareForFlush = nil
        try await parent.reloadDiscardingDraft()
        XCTAssertFalse(child.frozen); XCTAssertTrue(enabled); XCTAssertNil(parent.errorMessage)
        XCTAssertTrue(child.update("editing resumed", isComposing: false))
        try await parent.flush()
    }

    func testEditsDuringSaveSerializeWithFreshRevisionAndConcurrentFlushWaits() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var mtime = 1.0
        var stored = "원본"
        var requests: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let session = NativeMarkdownSession(courseID: "course", relativePath: "notes/test.md", draftFile: file, debounceNanoseconds: 60_000_000_000) { channel, request in
            if channel == "notes:read" { return ["markdown": stored, "mtime": mtime] }
            XCTAssertEqual(channel, "notes:write")
            XCTAssertEqual((request["expectedMtime"] as? NSNumber)?.doubleValue, mtime)
            let text = try XCTUnwrap(request["markdown"] as? String)
            requests.append(text)
            if requests.count == 1 { await withCheckedContinuation { release = $0 } }
            stored = text; mtime += 1
            return ["mtime": mtime]
        }
        await session.load()
        session.update("첫 번째 😀", isComposing: false)
        let first = Task { try await session.flush() }
        for _ in 0..<100 { if release != nil { break }; await Task.yield() }
        XCTAssertNotNil(release)
        session.update("두 번째 한글 👨‍👩‍👧‍👦", isComposing: false)
        var joinedFinished = false
        let joined = Task { try await session.flush(); joinedFinished = true }
        await Task.yield()
        XCTAssertFalse(joinedFinished)
        release?.resume(); release = nil
        try await first.value; try await joined.value
        XCTAssertEqual(requests, ["첫 번째 😀", "두 번째 한글 👨‍👩‍👧‍👦"])
        XCTAssertEqual(stored, session.text)
        XCTAssertFalse(session.dirty)
        XCTAssertNil(try file.read())
    }

    func testFailedSaveRetainsDraftAndRestartRecoversExactUnicodeContent() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = "# 한국어\n\n가나다 👩🏽‍💻\n끝\n"
        let session = NativeMarkdownSession(courseID: "course", relativePath: "notes/test.md", draftFile: file, debounceNanoseconds: 60_000_000_000) { channel, _ in
            if channel == "notes:read" { return ["markdown": "원본", "mtime": 4] }
            throw DesktopRuntimeError("저장 공간 부족")
        }
        await session.load()
        session.update(text, isComposing: false)
        do { try await session.flush(); XCTFail("Failed save must reach the lifecycle barrier") } catch {}
        XCTAssertTrue(session.dirty)
        XCTAssertEqual(try file.read(), NativeMarkdownDraft(markdown: text, expectedMtime: 4))
        var saved: String?
        let recovered = NativeMarkdownSession(courseID: "course", relativePath: "notes/test.md", draftFile: file, debounceNanoseconds: 60_000_000_000) { channel, request in
            if channel == "notes:read" { return ["markdown": "원본", "mtime": 4] }
            saved = request["markdown"] as? String
            return ["mtime": 5]
        }
        await recovered.load()
        XCTAssertEqual(recovered.text, text)
        XCTAssertTrue(recovered.recoveredDraft)
        try await recovered.flush()
        XCTAssertEqual(saved, text)
        XCTAssertNil(try file.read())
    }

    func testUndoDuringInflightWriteRetainsTheLatestIntentInTheDraft() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var stored = "원본", mtime = 1.0
        var release: CheckedContinuation<Void, Never>?
        var writes = 0
        let session = NativeMarkdownSession(courseID: "course", relativePath: "notes/test.md", draftFile: file, debounceNanoseconds: 60_000_000_000) { channel, request in
            if channel == "notes:read" { return ["markdown": stored, "mtime": mtime] }
            writes += 1
            if writes == 1 { await withCheckedContinuation { release = $0 } }
            stored = try XCTUnwrap(request["markdown"] as? String); mtime += 1
            return ["mtime": mtime]
        }
        await session.load()
        session.update("작성 중", isComposing: false)
        let writing = Task { try await session.flush() }
        for _ in 0..<100 { if release != nil { break }; await Task.yield() }
        XCTAssertNotNil(release)
        session.update("원본", isComposing: false)
        XCTAssertEqual(try file.read()?.markdown, "원본", "A completed in-flight write must not erase the user's later Undo intent after a crash")
        release?.resume(); release = nil
        try await writing.value
        XCTAssertEqual(stored, "원본")
        XCTAssertEqual(writes, 2)
        XCTAssertNil(try file.read())
    }

    func testRecoveredConflictNeverOverwritesNewerFile() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        try file.write(.init(markdown: "내 미저장 내용", expectedMtime: 1))
        var writes = 0
        let session = NativeMarkdownSession(courseID: "course", relativePath: "notes/test.md", draftFile: file) { channel, _ in
            if channel == "notes:read" { return ["markdown": "다른 기기에서 쓴 내용", "mtime": 2] }
            writes += 1
            return ["mtime": 3]
        }
        await session.load()
        XCTAssertEqual(session.text, "내 미저장 내용")
        XCTAssertNotNil(session.errorMessage)
        do { try await session.flush(); XCTFail("Conflict must block the save") } catch {}
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try file.read()?.markdown, "내 미저장 내용")
        try await session.reloadDiscardingDraft()
        XCTAssertEqual(session.text, "다른 기기에서 쓴 내용")
        XCTAssertNil(try file.read())
    }

    func testCompositionIsJournaledAndExplicitFlushCommitsLatestText() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved: String?
        let session = NativeMarkdownSession(courseID: "course", relativePath: "notes/test.md", draftFile: file, debounceNanoseconds: 0) { channel, request in
            if channel == "notes:read" { return ["markdown": "", "mtime": 1] }
            saved = request["markdown"] as? String
            return ["mtime": 2]
        }
        await session.load()
        session.update("ㅎ", isComposing: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(saved, "Debounce must not commit an active Korean composition")
        XCTAssertEqual(try file.read()?.markdown, "ㅎ")
        session.prepareForFlush = { session.update("한", isComposing: false) }
        try await session.flush()
        session.prepareForFlush = nil
        XCTAssertEqual(saved, "한")
        XCTAssertFalse(session.dirty)
    }

    func testFailedReadDoesNotAllowTypingOrBlockLeavingTheDocument() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = NativeMarkdownSession(courseID: "course", relativePath: "missing.md", draftFile: file) { _, _ in throw DesktopRuntimeError("자료 없음") }
        await session.load()
        XCTAssertFalse(session.canEdit)
        session.update("must not save an unloaded document", isComposing: false)
        XCTAssertFalse(session.dirty)
        try await session.flush()
        XCTAssertNil(try file.read())
    }

    func testRenameFreezeFlushAndRetirementCannotResurrectTheOldPath() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var written: [String] = []
        let session = NativeMarkdownSession(courseID: "course", relativePath: "old.md", draftFile: file, debounceNanoseconds: 60_000_000_000) { channel, request in
            if channel == "notes:read" { return ["markdown": "원본", "mtime": 1] }
            written.append(try XCTUnwrap(request["markdown"] as? String))
            return ["mtime": written.count + 1]
        }
        await session.load()
        session.prepareForFlush = { session.update("마지막 조합 한글", isComposing: false) }
        session.freezeForMaterialMutation()
        session.update("너무 늦은 이벤트", isComposing: false)
        try await session.flush()
        XCTAssertEqual(written, ["마지막 조합 한글"])
        session.retireAfterMaterialMutation()
        session.update("dismantle must not recreate old.md", isComposing: false)
        try await session.flush()
        XCTAssertEqual(written.count, 1)
        XCTAssertNil(try file.read())
    }

    func testFailedMaterialMutationResumesTheSameEditor() async throws {
        let (directory, file) = try temporaryDraft()
        defer { try? FileManager.default.removeItem(at: directory) }
        var saved = ""
        let session = NativeMarkdownSession(courseID: "course", relativePath: "old.md", draftFile: file, debounceNanoseconds: 60_000_000_000) { channel, request in
            if channel == "notes:read" { return ["markdown": "원본", "mtime": 1] }
            saved = request["markdown"] as? String ?? ""
            return ["mtime": 2]
        }
        await session.load()
        session.freezeForMaterialMutation()
        session.cancelMaterialMutation()
        session.update("다시 편집", isComposing: false)
        try await session.flush()
        XCTAssertEqual(saved, "다시 편집")
        XCTAssertFalse(session.frozen)
    }
}
