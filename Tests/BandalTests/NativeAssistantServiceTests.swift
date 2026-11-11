import XCTest
@testable import Bandal

private final class NativeAssistantProtocol: URLProtocol {
    static var body = ""
    static var hold = false
    static var began: (() -> Void)?
    static var replies: [(Int,String)] = []
    static var requests: [[String:Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // The ai-proxy's config: Auto is an OpenAI model, so the fixtures below stream OpenAI events.
        if request.url?.path.hasSuffix("/config") == true {
            let config: [String: Any] = ["models": [["id": "gpt-6-luna", "provider": "openai", "label": "GPT-6 Luna", "contextCap": 100000, "badge": 1]],
                                         "auto": ["id": "gpt-6-luna", "provider": "openai", "contextCap": 30000], "consentVersion": 1, "usage": ["consents": ["openai": 1, "anthropic": 1]]]
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:config)); client?.urlProtocolDidFinishLoading(self)
            return
        }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; bytes.append(contentsOf:buffer.prefix(count)) }
        }
        if let object = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] { Self.requests.append(object) }
        Self.began?()
        guard !Self.hold else { return }
        let reply = Self.replies.isEmpty ? (200,Self.body) : Self.replies.removeFirst()
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:reply.0,httpVersion:nil,headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(reply.1.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class NativeAssistantServiceTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var service: NativeAssistantService!
    private var identity: [String:Any] = [:]
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-assistant-\(UUID().uuidString)")
        runtime = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy")); try await runtime.start()
        let course = try await runtime.invoke("courses:create",request:["name":"AI test","color":"blue"]) as! [String:Any]
        identity = ["courseId":course["id"]!,"sessionId":UUID().uuidString,"provider":"codex"]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NativeAssistantProtocol.self]
        var environment = DesktopAIEnvironment(); environment.session = URLSession(configuration:config); environment.endpoint = { AIEndpoint(userID: "user-a", projectURL: URL(string: "https://project.test")!, publishableKey: "pk", token: { "jwt" }) }; environment.hasConsent = { _, _, _ in true }
        NativeAssistantProtocol.hold = false; NativeAssistantProtocol.began = nil; NativeAssistantProtocol.requests = []; NativeAssistantProtocol.replies = []
        service = NativeAssistantService(runtime:runtime,ai:DesktopAIService(environment:environment))
        runtime.onNativeCall = { [weak service] channel,request in guard let service else { throw CancellationError() }; return try await service.handle(channel,request) }
        _ = try await runtime.invoke("chat:open",request:identity)
    }
    override func tearDown() async throws {
        runtime.onNativeCall = nil; runtime.onEmit = nil; service = nil; runtime = nil; NativeAssistantProtocol.began = nil
        try? FileManager.default.removeItem(at:root)
    }
    func testTwoStreamedTurnsPersistAndSequenceNeverRestarts() async throws {
        NativeAssistantProtocol.body = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"보존된 응답\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[],\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}}\n\n"
        var sequences: [Int] = []
        for index in 1...2 {
            let completed = expectation(description:"turn \(index)")
            runtime.onEmit = { channel,value in
                guard channel == "chat:event-batch", let batch = value as? [String:Any] else { return }
                if let seq = batch["seq"] as? Int { sequences.append(seq) }
                if (batch["events"] as? [[String:Any]])?.contains(where: { $0["type"] as? String == "turn-complete" }) == true { completed.fulfill() }
            }
            let accepted = try await runtime.invoke("chat:send",request:identity.merging(["content":"질문 \(index)"]) { _,new in new }) as! [String:Any]
            XCTAssertEqual(accepted["turnSeq"] as? Int,index)
            await fulfillment(of:[completed],timeout:8)
        }
        XCTAssertEqual(sequences,Array(1...sequences.count))
        let reopened = try await runtime.invoke("chat:open",request:identity) as! [String:Any]
        XCTAssertEqual((reopened["history"] as? [Any])?.count,4)
        XCTAssertEqual(reopened["eventSeq"] as? Int,sequences.last)
        let last = (reopened["history"] as? [[String:Any]])?.last
        let block = (last?["blocks"] as? [[String:Any]])?.first?["payload"] as? [String:Any]
        XCTAssertEqual(block?["text"] as? String,"보존된 응답")
    }
    func testCancelSettlesTransportAndPersistsInterruptedTurn() async throws {
        NativeAssistantProtocol.hold = true
        let began = expectation(description:"request began"); NativeAssistantProtocol.began = { began.fulfill() }
        _ = try await runtime.invoke("chat:send",request:identity.merging(["content":"중단할 질문"]) { _,new in new })
        await fulfillment(of:[began],timeout:5)
        _ = try await runtime.invoke("chat:cancel",request:identity)
        let opened = try await runtime.invoke("chat:open",request:identity) as! [String:Any]
        XCTAssertEqual((opened["sessionInfo"] as? [String:Any])?["status"] as? String,"idle")
        let history = opened["history"] as! [[String:Any]]; XCTAssertEqual(history.count,2)
        let payload = (history.last?["blocks"] as? [[String:Any]])?.first?["payload"] as? [String:Any]
        XCTAssertEqual(payload?["interrupted"] as? Bool,true)
    }
    private func streamed(_ text: String) throws -> String {
        let delta = try JSONSerialization.data(withJSONObject:["type":"response.output_text.delta","delta":text])
        return "data: " + String(decoding:delta,as:UTF8.self) + "\n\ndata: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"
    }
    private func complete(_ request: [String:Any]) async throws {
        let completed = expectation(description:"response complete")
        runtime.onEmit = { channel,value in
            guard channel == "chat:event-batch", let batch = value as? [String:Any],
                  batch["sessionId"] as? String == request["sessionId"] as? String else { return }
            if (batch["events"] as? [[String:Any]])?.contains(where:{ $0["type"] as? String == "turn-complete" }) == true { completed.fulfill() }
        }
        _ = try await runtime.invoke("chat:send",request:request)
        await fulfillment(of:[completed],timeout:8)
    }
    func testCapturedImageIsSentAndReplayedFromDurableHistory() async throws {
        NativeAssistantProtocol.body = try streamed("이미지 답변")
        let capture = NativeAssistantAttachment(title:"손글씨",text:"질문한 영역",imageDataURL:"data:image/png;base64,AQID",page:2)
        try await complete(identity.merging(["content":"설명해 줘","attachments":[capture.request]]) { _,new in new })
        try await complete(identity.merging(["content":"앞의 답변을 요약해 줘"]) { _,new in new })
        XCTAssertEqual(NativeAssistantProtocol.requests.count,2)
        for request in NativeAssistantProtocol.requests {
            let inputs = try XCTUnwrap(request["input"] as? [[String:Any]])
            let content = try XCTUnwrap(inputs.first?["content"] as? [[String:Any]])
            XCTAssertEqual(content.first(where:{ $0["type"] as? String == "input_image" })?["image_url"] as? String,capture.imageDataURL)
            XCTAssertTrue((content.first?["text"] as? String ?? "").contains("질문한 영역"))
        }
    }
    func testProjectReadToolCannotReadSiblingFolder() async throws {
        let course = identity["courseId"] as! String
        let project = try await runtime.invoke("learning:create",request:["placement":"in-course","courseId":course,"name":"Private workspace"]) as! [String:Any]
        let scope = try XCTUnwrap(NativeWorkspaceContext.project(snapshot:project))
        var scoped = identity; scoped["sessionId"] = UUID().uuidString; scoped["workspace"] = scope.request
        _ = try await runtime.invoke("chat:open",request:scoped)
        _ = try await runtime.invoke("materials:writeFile",request:["courseId":course,"dirRelPath":"","fileName":"outside.md","data":"SIBLING_PRIVATE_TEXT","encoding":"utf8"])
        let tool = try JSONSerialization.data(withJSONObject:["type":"response.completed","response":["output":[["type":"function_call","call_id":"read-1","name":"read_material","arguments":"{\"relPath\":\"outside.md\"}"]]]])
        NativeAssistantProtocol.replies = [(200,"data: " + String(decoding:tool,as:UTF8.self) + "\n\n"),(200,try streamed("범위를 확인해 주세요"))]
        try await complete(scoped.merging(["content":"자료 확인"]) { _,new in new })
        XCTAssertEqual(NativeAssistantProtocol.requests.count,2)
        let input = try XCTUnwrap(NativeAssistantProtocol.requests.last?["input"] as? [[String:Any]])
        let result = try XCTUnwrap(input.first { $0["type"] as? String == "function_call_output" }?["output"] as? String)
        XCTAssertTrue(result.contains("현재 작업 공간"),result); XCTAssertFalse(result.contains("SIBLING_PRIVATE_TEXT"))
    }
    func testProviderErrorPreservesCaptureAndSettlesForRetry() async throws {
        NativeAssistantProtocol.replies = [(429,"{\"error\":{\"message\":\"fixture rate limit\"}}")]
        let capture = NativeAssistantAttachment(title:"선택",text:"보존할 원문")
        try await complete(identity.merging(["content":"질문","attachments":[capture.request]]) { _,new in new })
        let opened = try await runtime.invoke("chat:open",request:identity) as! [String:Any]
        XCTAssertEqual((opened["sessionInfo"] as? [String:Any])?["status"] as? String,"idle")
        let history = try XCTUnwrap(opened["history"] as? [[String:Any]])
        XCTAssertEqual(NativeChatMessage(history.first!)?.attachments.first?.text,"보존할 원문")
        XCTAssertEqual(NativeChatMessage(history.last!)?.interrupted,true)
        NativeAssistantProtocol.body = try streamed("재시도 완료")
        try await complete(identity.merging(["content":"다시 시도"]) { _,new in new })
        let retried = try await runtime.invoke("chat:open",request:identity) as! [String:Any]
        XCTAssertEqual((retried["history"] as? [Any])?.count,4)
    }

    func testProjectReadToolDecodesProviderArgumentsAndReadsAllowedMaterial() async throws {
        let course = identity["courseId"] as! String
        let project = try await runtime.invoke("learning:create",request:["placement":"in-course","courseId":course,"name":"Workspace"]) as! [String:Any]
        let scope = try XCTUnwrap(NativeWorkspaceContext.project(snapshot:project))
        var scoped = identity; scoped["sessionId"] = UUID().uuidString; scoped["workspace"] = scope.request
        _ = try await runtime.invoke("chat:open",request:scoped)
        _ = try await runtime.invoke("materials:writeFile",request:["courseId":course,"dirRelPath":scope.rootRelPath,"fileName":"source.md","data":"ALLOWED_PROJECT_SOURCE","encoding":"utf8"])
        let arguments = String(decoding:try JSONSerialization.data(withJSONObject:["relPath":scope.rootRelPath + "/source.md"]),as:UTF8.self)
        let tool = try JSONSerialization.data(withJSONObject:["type":"response.completed","response":["output":[["type":"function_call","call_id":"read-allowed","name":"read_material","arguments":arguments]]]])
        NativeAssistantProtocol.replies = [(200,"data: " + String(decoding:tool,as:UTF8.self) + "\n\n"),(200,try streamed("읽었습니다"))]
        try await complete(scoped.merging(["content":"자료 읽기"]) { _,new in new })
        let input = try XCTUnwrap(NativeAssistantProtocol.requests.last?["input"] as? [[String:Any]])
        XCTAssertEqual(input.first { $0["type"] as? String == "function_call_output" }?["output"] as? String,"ALLOWED_PROJECT_SOURCE")
    }

    private func readCall(_ id: String, _ arguments: [String:Any]) throws -> (Int,String) {
        let call: [String:Any] = ["type":"function_call","call_id":id,"name":"read_material","arguments":String(decoding:try JSONSerialization.data(withJSONObject:arguments),as:UTF8.self)]
        return (200,"data: " + String(decoding:try JSONSerialization.data(withJSONObject:["type":"response.completed","response":["output":[call]]]),as:UTF8.self) + "\n\n")
    }
    private func write(_ name: String, _ text: String) async throws {
        _ = try await runtime.invoke("materials:writeFile",request:["courseId":identity["courseId"]!,"dirRelPath":"","fileName":name,"data":text,"encoding":"utf8"])
    }
    private func lastAnswer() async throws -> NativeChatMessage {
        let opened = try await runtime.invoke("chat:open",request:identity) as! [String:Any]
        return try XCTUnwrap((opened["history"] as? [[String:Any]])?.last.flatMap(NativeChatMessage.init))
    }
    private func outputs() throws -> [String] {
        try XCTUnwrap(NativeAssistantProtocol.requests.last?["input"] as? [[String:Any]]).filter { $0["type"] as? String == "function_call_output" }.compactMap { $0["output"] as? String }
    }
    func testMaterialsTheAnswerReadBecomeItsSourcesOnceEach() async throws {
        try await write("3주차 노트.md","NOTE_TEXT"); try await write("강의자료.txt","SLIDE_TEXT")
        NativeAssistantProtocol.replies = [try readCall("r1",["relPath":"3주차 노트.md"]),try readCall("r2",["relPath":"강의자료.txt"]),try readCall("r3",["relPath":"3주차 노트.md"]),
                                           try readCall("r4",["relPath":"없는 자료.md"]),(200,try streamed("정리했어요"))]
        try await complete(identity.merging(["content":"요약해 줘"]) { _,new in new })
        let answer = try await lastAnswer()
        XCTAssertEqual(answer.text,"정리했어요")
        // A failed read is no source; the same material is one chip.
        XCTAssertEqual(answer.sources.map(\.title),["3주차 노트","강의자료"])
        XCTAssertEqual(answer.sources.first?.request as? [String:String],["courseId":identity["courseId"] as! String,"relPath":"3주차 노트.md","kind":"note"])
        // The next turn sends the answer back to the model as text only.
        NativeAssistantProtocol.replies = [(200,try streamed("네"))]
        try await complete(identity.merging(["content":"고마워"]) { _,new in new })
        let replayed = String(decoding:try JSONSerialization.data(withJSONObject:try XCTUnwrap(NativeAssistantProtocol.requests.last?["input"])),as:UTF8.self)
        XCTAssertTrue(replayed.contains("정리했어요")); XCTAssertFalse(replayed.contains("relPath"))
        let untouched = try await lastAnswer()
        XCTAssertTrue(untouched.sources.isEmpty)
    }
    func testSourceNamesThePageOnlyWhenTheModelAskedForOne() {
        let paged = NativeChatSource(["courseId":"c","relPath":"자료/강의자료.pdf","page":12]), whole = NativeChatSource(["courseId":"c","relPath":"자료/강의자료.pdf"])
        XCTAssertEqual(paged?.title,"강의자료 p.12"); XCTAssertEqual(whole?.title,"강의자료")
        XCTAssertEqual(paged?.request["kind"] as? String,"pdf"); XCTAssertEqual(paged?.request["page"] as? Int,12); XCTAssertNil(whole?.request["page"])
        XCTAssertNotEqual(paged?.id,whole?.id)
        XCTAssertNil(NativeChatSource(["courseId":"c","relPath":""])); XCTAssertNil(NativeChatSource(["relPath":"a.md"]))
    }
    func testNoteScopeLeavesOnlyTheOpenNoteToRead() async throws {
        try await write("지금 노트.md","NOTE_TEXT"); try await write("다른 자료.md","OTHER_TEXT")
        let course = identity["courseId"] as! String
        NativeAssistantProtocol.replies = [try readCall("r1",["relPath":"다른 자료.md"]),try readCall("r2",["relPath":"지금 노트.md"]),(200,try streamed("끝"))]
        try await complete(identity.merging(["content":"정리","referenceScope":"note","documentContext":["courseId":course,"relPath":"지금 노트.md","title":"지금 노트.md","kind":"note","selection":""]]) { _,new in new })
        XCTAssertEqual((NativeAssistantProtocol.requests.first?["tools"] as? [[String:Any]])?.compactMap { $0["name"] as? String },["read_material"])
        let results = try outputs()
        XCTAssertEqual(results.count,2)
        XCTAssertTrue(results[0].contains("지금 노트"),results[0]); XCTAssertFalse(results[0].contains("OTHER_TEXT"))
        XCTAssertEqual(results[1],"NOTE_TEXT")
        let sources = try await lastAnswer().sources
        XCTAssertEqual(sources.map(\.title),["지금 노트"])
    }
    func testConversationBegunWithHistoryOffIsUnlistedAndGoneAfterRestart() async throws {
        NativeAssistantProtocol.body = try streamed("답")
        try await complete(identity.merging(["content":"남는 대화"]) { _,new in new })
        // The panel opens the row first; the setting is read with the first message.
        var quiet = identity; quiet["sessionId"] = UUID().uuidString
        _ = try await runtime.invoke("chat:open",request:quiet)
        quiet["ephemeral"] = true
        let capture = NativeAssistantAttachment(title:"손글씨",text:"영역",imageDataURL:"data:image/png;base64,AQID",page:1)
        try await complete(quiet.merging(["content":"남지 않는 대화","attachments":[capture.request]]) { _,new in new })
        let cached = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("NativeChatAttachments"),includingPropertiesForKeys:nil).first)
        let listed = try await runtime.invoke("chat:conversations",request:identity) as! [String:Any]
        XCTAssertEqual((listed["conversations"] as? [[String:Any]])?.compactMap { $0["id"] as? String },[identity["sessionId"] as! String])
        // It stays usable until the app closes.
        let open = try await runtime.invoke("chat:open",request:quiet) as! [String:Any]
        XCTAssertEqual((open["history"] as? [Any])?.count,2)
        let restarted = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy")); try await restarted.start()
        let gone = try await restarted.invokePrivate("nativeChat:open",request:quiet) as! [String:Any]
        XCTAssertEqual((gone["history"] as? [Any])?.count,0)
        XCTAssertFalse(FileManager.default.fileExists(atPath:cached.path),"its captured image leaves the cache too")
        let kept = try await restarted.invokePrivate("nativeChat:open",request:identity) as! [String:Any]
        XCTAssertEqual((kept["history"] as? [Any])?.count,2)
    }
    func testNoteScopeWithoutAnOpenNoteOffersNothingToRead() async throws {
        NativeAssistantProtocol.replies = [(200,try streamed("첨부만 봤어요"))]
        try await complete(identity.merging(["content":"설명","referenceScope":"note"]) { _,new in new })
        XCTAssertEqual((NativeAssistantProtocol.requests.first?["tools"] as? [[String:Any]])?.count,0)
        // The default scope keeps both course tools.
        NativeAssistantProtocol.requests = []; NativeAssistantProtocol.replies = [(200,try streamed("과목 전체"))]
        try await complete(identity.merging(["content":"설명"]) { _,new in new })
        XCTAssertEqual((NativeAssistantProtocol.requests.first?["tools"] as? [[String:Any]])?.compactMap { $0["name"] as? String },["list_materials","read_material"])
    }
}
