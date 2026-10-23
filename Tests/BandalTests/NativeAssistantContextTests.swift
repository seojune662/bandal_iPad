import XCTest
@testable import Bandal

final class NativeAssistantContextTests: XCTestCase {
    private var root: URL!
    private var context: NativeRepositoryContext!
    private var library: NativeLibraryRepository!
    private var learning: NativeLearningRepository!
    private var chat: NativeChatRepository!
    private var course: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-context-" + UUID().uuidString)
        context = try NativeRepositoryContext(root:root,legacyRoot:root.appendingPathComponent("Legacy"))
        library = NativeLibraryRepository(context:context); learning = NativeLearningRepository(context:context); chat = NativeChatRepository(context:context)
        course = try XCTUnwrap((library.handle("courses:create",["name":"자료","color":"blue"]) as? [String:Any])?["id"] as? String)
    }
    override func tearDownWithError() throws { chat = nil; learning = nil; library = nil; context = nil; try FileManager.default.removeItem(at:root) }
    private func project(_ name: String) throws -> NativeWorkspaceContext {
        let snapshot = try XCTUnwrap(learning.handle("learning:create",["placement":"in-course","courseId":course!,"name":name]) as? [String:Any])
        return try XCTUnwrap(NativeWorkspaceContext.project(snapshot:snapshot))
    }
    private func identity(_ scope: NativeWorkspaceContext?, session: String = UUID().uuidString) -> [String:Any] {
        var result: [String:Any] = ["courseId":course!,"sessionId":session,"provider":"codex","surface":"app"]
        if let scope { result["workspace"] = scope.request }; return result
    }
    private func send(_ identity: [String:Any], extra: [String:Any] = [:]) throws -> [String:Any] {
        _ = try chat.handle("chat:open",identity)
        return try XCTUnwrap(chat.handle("nativeChat:begin",identity.merging(["content":"질문"]) { _,new in new }.merging(extra) { _,new in new }) as? [String:Any])
    }
    private func finish(_ identity: [String:Any], turn: Int = 1) throws {
        _ = try chat.handle("nativeChat:finish",identity.merging(["turnSeq":turn,"text":"답변"]) { _,new in new })
    }
    func testProjectConversationsRemainIsolatedFromSiblingAndLegacyCourse() throws {
        let first = try project("첫 공간"), second = try project("다른 공간")
        let a = identity(first), b = identity(second), old = identity(nil)
        for value in [a,b,old] { _ = try send(value); try finish(value) }
        for (scope, expected) in [(first,a),(second,b),(NativeWorkspaceContext(kind:.course,courseID:course,title:"자료"),old)] {
            let result = try XCTUnwrap(chat.handle("chat:conversations",identity(scope)) as? [String:Any])
            let rows = try XCTUnwrap(result["conversations"] as? [[String:Any]])
            XCTAssertEqual(rows.count,1); XCTAssertEqual(rows.first?["id"] as? String,expected["sessionId"] as? String)
        }
        var wrong = a; wrong["workspace"] = second.request
        XCTAssertThrowsError(try chat.handle("chat:open",wrong))
        XCTAssertThrowsError(try chat.handle("nativeChat:begin",wrong.merging(["content":"잘못된 공간"]) { _,new in new }))
    }
    func testImmutableCaptureAndModeSurviveSavedHistoryAndSyncEnvelope() throws {
        let scope = try project("캡처"), value = identity(scope)
        let capture = NativeAssistantAttachment(title:"필기",text:"선택한 내용",imageDataURL:"data:image/png;base64,AQID",courseID:course,relativePath:"note.pdf",page:3)
        let result = try send(value,extra:["attachments":[capture.request],"mode":"expected-exam"])
        try finish(value)
        let history = try XCTUnwrap(result["history"] as? [[String:Any]])
        let blocks = try XCTUnwrap(history.first?["blocks"] as? [[String:Any]])
        let saved = try XCTUnwrap(blocks.first(where:{ $0["kind"] as? String == "attachment" })?["payload"] as? [String:Any])
        XCTAssertEqual(saved["imageDataURL"] as? String,capture.imageDataURL)
        XCTAssertEqual(saved["page"] as? Int,3)
        XCTAssertEqual((blocks.first(where:{ $0["kind"] as? String == "request-context" })?["payload"] as? [String:Any])?["mode"] as? String,"expected-exam")
        let replay = NativeAssistantPayload.messages(history)
        XCTAssertEqual((replay.first?["images"] as? [[String:String]])?.first?["dataBase64"],"AQID")
        XCTAssertTrue((replay.first?["text"] as? String ?? "").contains("선택한 내용"))
        let snapshot = try NativeSyncArtifacts(context:context).snapshot()
        let session = try XCTUnwrap(snapshot.records.first { $0["id"] as? String == "chat:" + (value["sessionId"] as! String) }?["payload"] as? [String:Any])
        XCTAssertEqual((session["workspace"] as? [String:Any])?["id"] as? String,scope.id)
        let exported = try XCTUnwrap(snapshot.records.first { ($0["payload"] as? [String:Any])?["recordType"] as? String == "desktop-chat-message" && ($0["payload"] as? [String:Any])?["role"] as? String == "user" }?["payload"] as? [String:Any])
        let exportedCapture = try XCTUnwrap((exported["blocks"] as? [[String:Any]])?.first { $0["kind"] as? String == "attachment" }?["payload"] as? [String:Any])
        XCTAssertNil(exportedCapture["imageDataURL"])
        XCTAssertEqual((exportedCapture["imageAsset"] as? [String:Any])?["sha256"] as? String,NativeSyncFormat.hash(Data([1,2,3])))
        let assets = Dictionary(uniqueKeysWithValues:snapshot.assets.map { ($0["sha256"] as! String,URL(fileURLWithPath:$0["path"] as! String)) })
        let record = try XCTUnwrap(snapshot.records.first { ($0["payload"] as? [String:Any])?["id"] as? String == exported["id"] as? String })
        let plan = try XCTUnwrap(NativeSyncArtifacts(context:context).plan(record,assets:assets))
        for file in plan.files { try file.data?.write(to:file.target,options:.atomic) }; try plan.apply()
        let restored = try XCTUnwrap(chat.handle("chat:open",value) as? [String:Any])
        XCTAssertEqual(NativeChatMessage((restored["history"] as! [[String:Any]])[0])?.attachments.first?.imageDataURL,capture.imageDataURL)
    }
    func testInvalidAttachmentDoesNotAcceptUserTurnOrLeaveSessionRunning() throws {
        let value = identity(try project("검증")); _ = try chat.handle("chat:open",value)
        let invalid = NativeAssistantAttachment(title:"깨진 이미지",imageDataURL:"data:image/png;base64,???")
        XCTAssertThrowsError(try chat.handle("nativeChat:begin",value.merging(["content":"질문","attachments":[invalid.request]]) { _,new in new }))
        let reopened = try XCTUnwrap(chat.handle("chat:open",value) as? [String:Any])
        XCTAssertEqual((reopened["history"] as? [Any])?.count,0)
        XCTAssertEqual((reopened["sessionInfo"] as? [String:Any])?["status"] as? String,"idle")
    }
    func testHistoryReplayKeepsNewestImageBudgetWithoutLosingOlderSourceText() {
        let history: [[String:Any]] = (0..<9).map { index in
            ["role":"user","blocks":[["kind":"text","payload":["text":"질문 \(index)"]],["kind":"attachment","payload":NativeAssistantAttachment(title:"범위 \(index)",text:"원문 \(index)",imageDataURL:"data:image/png;base64,AQID").request]]]
        }
        let replay = NativeAssistantPayload.messages(history)
        XCTAssertEqual(replay.count,9)
        XCTAssertEqual(replay.flatMap { $0["images"] as? [[String:String]] ?? [] }.count,6)
        XCTAssertTrue((replay.first?["text"] as? String ?? "").contains("원문 0"))
        XCTAssertEqual((replay.last?["images"] as? [[String:String]])?.count,1)
    }
    func testPendingCapturesSurviveWorkspaceChangeWithoutChangingEditedDraft() throws {
        let first = try project("지목한 공간"), second = try project("전환한 공간")
        let draftURL = root.appendingPathComponent("NativeAssistantState/edited-conversation.json")
        let draft = Data(#"{"text":"작성하던 질문","mode":"quiz"}"#.utf8)
        try FileManager.default.createDirectory(at:draftURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try draft.write(to:draftURL,options:.atomic)
        let a = NativeAssistantAttachment(id:"capture-a",title:"원래 필기",text:"원본",imageDataURL:"data:image/png;base64,AQID")
        let b = NativeAssistantAttachment(id:"capture-b",title:"두 번째 필기",text:"다음 영역")
        let other = NativeAssistantAttachment(id:"capture-c",title:"다른 프로젝트",text:"별도 내용")
        try NativeAssistantPendingCaptures.enqueue([a],spaceID:first.id,root:root)
        try NativeAssistantPendingCaptures.enqueue([other],spaceID:second.id,root:root)
        // A late duplicate must retain the original captured bytes and text.
        try NativeAssistantPendingCaptures.enqueue([NativeAssistantAttachment(id:a.id,title:"변경된 원본",text:"변경됨"),b],spaceID:first.id,root:root)
        XCTAssertEqual(try NativeAssistantPendingCaptures.load(spaceID:first.id,root:root),[a,b])
        XCTAssertEqual(try NativeAssistantPendingCaptures.load(spaceID:second.id,root:root),[other])
        XCTAssertEqual(try Data(contentsOf:draftURL),draft)
        // Acknowledge only the saved delivery; a newer capture remains durable.
        try NativeAssistantPendingCaptures.acknowledge([a.id],spaceID:first.id,root:root)
        XCTAssertEqual(try NativeAssistantPendingCaptures.load(spaceID:first.id,root:root),[b])
        try NativeAssistantPendingCaptures.acknowledge([b.id],spaceID:first.id,root:root)
        XCTAssertTrue(try NativeAssistantPendingCaptures.load(spaceID:first.id,root:root).isEmpty)
        XCTAssertEqual(try NativeAssistantPendingCaptures.load(spaceID:second.id,root:root),[other])
        XCTAssertEqual(try Data(contentsOf:draftURL),draft)
    }
    func testPinnedArtifactUsesCapturedSourceAndNeverFallsBackToProjectFolder() throws {
        let scope = try project("학습 결과")
        let target = NativeLearningDocumentTarget(projectID:try XCTUnwrap(scope.projectID),binding:try XCTUnwrap(scope.binding),kind:.artifact,entityID:"saved-result")
        let document = target.document(title:"벡터 요약")
        let capture = NativeAssistantAttachment(title:document.title,text:"벡터는 크기와 방향을 가집니다.",courseID:course,url:NativeAssistantPayload.learningSourceURL(target))
        let source = try NativeAssistantPayload.generationSource(document:document,selection:"",attachments:[capture])
        XCTAssertEqual(source["kind"] as? String,"attachment")
        XCTAssertEqual(source["artifactId"] as? String,target.entityID)
        XCTAssertEqual(source["projectId"] as? String,target.projectID)
        XCTAssertEqual(source["attachmentIds"] as? [String],[capture.id])
        XCTAssertNil(source["relPath"])
        XCTAssertThrowsError(try NativeAssistantPayload.generationSource(document:document,selection:"",attachments:[]))
        XCTAssertThrowsError(try NativeAssistantPayload.generationSource(document:document,selection:"",attachments:[NativeAssistantAttachment(title:"다른 자료",text:"별도 내용")]))
    }
    @MainActor func testLargeCaptureUsesBinarySyncAssetBelowEnvelopeLimit() throws {
        let value = identity(try project("큰 캡처"))
        let bytes = Data(repeating:42,count:4_500_000)
        let capture = NativeAssistantAttachment(title:"필기 화면",imageDataURL:"data:image/png;base64," + bytes.base64EncodedString())
        _ = try send(value,extra:["attachments":[capture.request]]); try finish(value)
        let snapshot = try NativeSyncArtifacts(context:context).snapshot()
        let record = try XCTUnwrap(snapshot.records.first { ($0["payload"] as? [String:Any])?["recordType"] as? String == "desktop-chat-message" && ($0["payload"] as? [String:Any])?["role"] as? String == "user" })
        XCTAssertNoThrow(try NativeSyncFormat.validate(record))
        let converted = try DesktopSyncService.record(record)
        let references = try DesktopSyncService.references(converted)
        XCTAssertEqual(references.count,1); XCTAssertEqual(references.first?.byteCount,Int64(bytes.count))
        XCTAssertEqual(references.first?.sha256,NativeSyncFormat.hash(bytes))
    }

}
