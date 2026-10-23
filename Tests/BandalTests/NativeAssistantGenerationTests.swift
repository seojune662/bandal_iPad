import Combine
import XCTest
@testable import Bandal

@MainActor
final class NativeAssistantGenerationTests: XCTestCase {
    private var root: URL!
    private var store: NativeWorkspaceStore!
    private var identity: [String:Any] = [:]
    private var course: String!
    private var subscription: AnyCancellable?
    private var held: CheckedContinuation<[String:Any],Error>?
    private var holding = false
    private var began: XCTestExpectation?
    private let quiz = #"{"kind":"quiz","title":"통합 예상문제","questions":[{"type":"choice","prompt":"벡터는?","options":[{"id":"a","text":"크기와 방향"},{"id":"b","text":"시간"}],"answer":"a","explanation":"벡터는 크기와 방향을 가집니다."}]}"#
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-generation-" + UUID().uuidString)
        store = NativeWorkspaceStore(storageRoot:root); await store.start()
        let result = try await store.invoke("courses:create",["name":"시험 과목","color":"blue"]) as! [String:Any]
        course = result["id"] as? String
        identity = ["courseId":course!,"sessionId":UUID().uuidString,"provider":"codex","workspace":NativeWorkspaceContext(kind:.course,courseID:course,title:"시험 과목").request]
        _ = try await store.invokePrivate("nativeChat:open",identity)
        store.runtime.onNativeCall = { [weak self] channel,request in
            guard let self else { throw CancellationError() }
            switch channel {
            case "native:aiAvailability": return ["loggedIn":true]
            case "native:aiRun":
                self.began?.fulfill()
                if self.holding { return try await withCheckedThrowingContinuation { self.held = $0 } }
                return ["text":self.quiz]
            case "native:aiCancel": self.held?.resume(throwing:CancellationError()); self.held = nil; return ["ok":true]
            default: throw DesktopRuntimeError("Unexpected fixture native channel: " + channel)
            }
        }
    }
    override func tearDown() async throws {
        held?.resume(throwing:CancellationError()); held = nil
        subscription = nil; store.runtime.onNativeCall = nil; store = nil; try? FileManager.default.removeItem(at:root)
    }
    private func request() -> [String:Any] {
        let capture = NativeAssistantAttachment(title:"벡터 필기",text:"벡터는 크기와 방향을 가집니다.",courseID:course)
        return ["courseId":course!,"packId":"quiz","generationMode":"expected-exam","questionCount":1,"difficulty":"어려움","scope":"벡터 개념","prompt":"시험지 만들어 줘","attachments":[capture.request],"chat":identity,"ai":["provider":"codex"]]
    }
    private func watchCompletion() -> XCTestExpectation {
        let complete = expectation(description:"generation finished")
        subscription = store.events.sink { event in if event.channel == "nativeAssistant:studyFinished" { complete.fulfill() } }
        return complete
    }
    func testExpectedExamStaysInOriginalSpaceAndReusesReviewProject() async throws {
        let completion = watchCompletion()
        let accepted = try await store.invoke("study:generate",request()) as! [String:Any]
        // Navigation must not retarget the asynchronous save.
        store.selectedCourseID = "another-visible-space"
        await fulfillment(of:[completion],timeout:8)
        let binding = try XCTUnwrap(accepted["binding"] as? [String:Any])
        let first = try await store.invoke("learning:get",["binding":binding]) as! [String:Any]
        XCTAssertEqual(first["linkedCourseId"] as? String,course)
        let artifactID = try XCTUnwrap((first["artifacts"] as? [[String:Any]])?.first?["id"] as? String)
        let artifact = try await store.invoke("learning:getArtifact",["binding":binding,"id":artifactID]) as! [String:Any]
        XCTAssertEqual(artifact["generationMode"] as? String,"expected-exam")
        XCTAssertEqual(artifact["difficulty"] as? String,"어려움")
        XCTAssertEqual(artifact["scope"] as? String,"벡터 개념")
        XCTAssertEqual((artifact["attachments"] as? [Any])?.count,1)
        let completeAgain = watchCompletion()
        let next = try await store.invoke("study:generate",request()) as! [String:Any]
        await fulfillment(of:[completeAgain],timeout:8)
        XCTAssertEqual((next["binding"] as? [String:Any])?["courseId"] as? String,binding["courseId"] as? String)
        let after = try await store.invoke("learning:get",["binding":binding]) as! [String:Any]
        XCTAssertEqual((after["artifacts"] as? [Any])?.count,2)
        let opened = try await store.invokePrivate("nativeChat:open",identity) as! [String:Any]
        let messages = (opened["history"] as! [[String:Any]]).compactMap(NativeChatMessage.init)
        XCTAssertEqual(messages.count,4); XCTAssertEqual(messages.filter { !$0.artifacts.isEmpty }.count,2)
        XCTAssertNotEqual(messages[1].artifacts.first?.document.id,messages[3].artifacts.first?.document.id)
    }
    func testCancellingGenerationSavesInterruptedConversationWithoutResultArtifact() async throws {
        holding = true; began = expectation(description:"generation started")
        let completion = watchCompletion()
        let accepted = try await store.invoke("study:generate",request()) as! [String:Any]
        await fulfillment(of:[began!],timeout:8)
        _ = try await store.invoke("learning:runCancel",["binding":accepted["binding"]!,"runId":accepted["runId"]!])
        await fulfillment(of:[completion],timeout:8)
        let state = try await store.invoke("learning:get",["binding":accepted["binding"]!]) as! [String:Any]
        XCTAssertEqual((state["artifacts"] as? [Any])?.count,0)
        XCTAssertEqual((state["runs"] as? [[String:Any]])?.first?["status"] as? String,"cancelled")
        let opened = try await store.invokePrivate("nativeChat:open",identity) as! [String:Any]
        let messages = (opened["history"] as! [[String:Any]]).compactMap(NativeChatMessage.init)
        XCTAssertEqual(messages.first?.attachments.first?.text,"벡터는 크기와 방향을 가집니다.")
        XCTAssertEqual(messages.last?.interrupted,true)
        XCTAssertEqual((opened["sessionInfo"] as? [String:Any])?["status"] as? String,"idle")
    }
}
