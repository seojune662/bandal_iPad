import XCTest
@testable import Bandal

private final class NativeAssistantProtocol: URLProtocol {
    static var body = ""
    static var hold = false
    static var began: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.began?()
        guard !Self.hold else { return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"text/event-stream"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(Self.body.utf8)); client?.urlProtocolDidFinishLoading(self)
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
        var environment = DesktopAIEnvironment(); environment.session = URLSession(configuration:config); environment.readKey = { _ in "fixture-not-a-real-key" }; environment.writeKey = { _,_ in }; environment.hasConsent = { _ in true }
        NativeAssistantProtocol.hold = false; NativeAssistantProtocol.began = nil
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
}
