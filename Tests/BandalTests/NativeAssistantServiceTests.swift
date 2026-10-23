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
        var environment = DesktopAIEnvironment(); environment.session = URLSession(configuration:config); environment.readKey = { _ in "fixture-not-a-real-key" }; environment.writeKey = { _,_ in }
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

}
