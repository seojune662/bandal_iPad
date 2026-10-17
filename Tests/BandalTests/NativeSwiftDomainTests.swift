import XCTest
@testable import Bandal

@MainActor
final class NativeSwiftDomainTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var course = ""
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-domain-\(UUID().uuidString)")
        runtime = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy"))
        try await runtime.start()
        let created = try await runtime.invoke("courses:create",request:["name":"Swift 학습","color":"blue"]) as! [String:Any]
        course = created["id"] as! String
    }
    override func tearDown() async throws {
        runtime = nil; try? FileManager.default.removeItem(at:root)
    }
    func testPlannerPersistsAllDayRangeAndRejectsInvalidUpdate() async throws {
        let created = try await runtime.invoke("board:createTask",request:["courseId":course,"title":"시험","kind":"exam","color":"violet","allDay":true,"startAt":"2026-10-20","dueAt":"2026-10-22"]) as! [String:Any]
        let id = created["id"] as! String
        do {
            _ = try await runtime.invoke("board:updateTask",request:["id":id,"dueAt":"2026-10-19"])
            XCTFail("An inverted range must not be saved")
        } catch {}
        let range = try await runtime.invoke("calendar:range",request:["from":"2026-10-20T00:00:00Z","to":"2026-10-23T00:00:00Z"]) as! [[String:Any]]
        XCTAssertEqual(range.count,1); XCTAssertEqual(range[0]["dueAt"] as? String,"2026-10-22")
        _ = try await runtime.invoke("board:updateTask",request:["id":id,"status":"done"])
        let active = try await runtime.invoke("board:listTasks") as! [[String:Any]]; XCTAssertTrue(active.isEmpty)
        let restarted = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy")); try await restarted.start()
        let all = try await restarted.invoke("board:listTasks",request:["includeDone":true]) as! [[String:Any]]
        XCTAssertEqual(all.first?["status"] as? String,"done")
    }
    func testPreferencesMergeWithoutLosingOtherBrowserChoices() async throws {
        _ = try await runtime.invoke("settings:set",request:["browser":["doNotTrack":false,"homePage":"https://example.org"]])
        let next = try await runtime.invoke("settings:set",request:["browser":["swipeNavigation":false]]) as! [String:Any]
        let browser = next["browser"] as! [String:Any]
        XCTAssertEqual(browser["homePage"] as? String,"https://example.org"); XCTAssertEqual(browser["doNotTrack"] as? Bool,false)
        do { _ = try await runtime.invoke("settings:set",request:["browser":["homePage":"javascript:alert(1)"]]); XCTFail("Must reject non-web schemes") } catch {}
        let stored = try await runtime.invoke("settings:get") as! [String:Any]
        XCTAssertEqual((stored["browser"] as? [String:Any])?["homePage"] as? String,"https://example.org")
    }
    func testTranscriptCursorCommitIsAtomicAndReplaySafe() async throws {
        let created = try await runtime.invokePrivate("nativeRecording:create",request:["courseId":course,"title":"강의","modelId":LocalSpeechModel.allCases[0].rawValue]) as! [String:Any]
        let id = created["id"] as! String
        var session = created; session["status"] = "recording"
        _ = try await runtime.invokePrivate("nativeRecording:save",request:["session":session])
        let pcm = ["__bandalBytes":Data(repeating:0,count:32000).base64EncodedString()]
        let append: [String:Any] = ["id":id,"sequence":0,"pcm":pcm]
        _ = try await runtime.invokePrivate("nativeRecording:append",request:append)
        _ = try await runtime.invokePrivate("nativeRecording:append",request:append)
        let window: [String:Any] = ["id":id,"startSample":0,"endSample":16000,"text":"보존할 강의 내용"]
        _ = try await runtime.invokePrivate("nativeRecording:commitTranscriptWindow",request:window)
        _ = try await runtime.invokePrivate("nativeRecording:commitTranscriptWindow",request:window)
        let detail = try await runtime.invoke("recordings:read",request:["id":id]) as! [String:Any]
        XCTAssertEqual((detail["segments"] as? [Any])?.count,1)
        XCTAssertEqual((detail["session"] as? [String:Any])?["samples"] as? Int,16000)
        do {
            _ = try await runtime.invokePrivate("nativeRecording:replaceTranscript",request:["id":id,"transcribedSamples":16000,"segments":[["startSample":0,"endSample":32000,"text":"invalid"]]])
            XCTFail("Invalid replacement must roll back DELETE")
        } catch {}
        let after = try await runtime.invoke("recordings:read",request:["id":id]) as! [String:Any]
        XCTAssertEqual((after["segments"] as? [[String:Any]])?.first?["text"] as? String,"보존할 강의 내용")
        let path = try await runtime.invokePrivate("nativeRecording:audioPath",request:["id":id]) as! String
        XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:path)).count,32044)
    }
    func testChatCourseIsolationAndInterruptedTurnRecovery() async throws {
        let id = UUID().uuidString, identity: [String:Any] = ["courseId":course,"sessionId":id,"provider":"codex"]
        _ = try await runtime.invoke("chat:open",request:identity)
        let begin = try await runtime.invokePrivate("nativeChat:begin",request:identity.merging(["content":"새 질문"]) { _,new in new }) as! [String:Any]
        XCTAssertEqual(begin["turnSeq"] as? Int,1)
        do {
            _ = try await runtime.invokePrivate("nativeChat:begin",request:identity.merging(["content":"중복 질문"]) { _,new in new }); XCTFail("Concurrent turn must be rejected")
        } catch {}
        do { _ = try await runtime.invoke("chat:open",request:["courseId":UUID().uuidString,"sessionId":id]); XCTFail("Wrong course must not read chat") } catch {}
        let restarted = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy")); try await restarted.start()
        let reopened = try await restarted.invoke("chat:open",request:identity) as! [String:Any]
        let history = reopened["history"] as! [[String:Any]]
        XCTAssertEqual(history.count,2)
        let block = (history.last?["blocks"] as? [[String:Any]])?.first?["payload"] as? [String:Any]
        XCTAssertEqual(block?["interrupted"] as? Bool,true)
        XCTAssertEqual((reopened["sessionInfo"] as? [String:Any])?["status"] as? String,"idle")
    }
}
