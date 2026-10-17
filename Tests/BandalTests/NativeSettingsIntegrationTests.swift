import XCTest
@testable import Bandal

@MainActor
final class NativeSettingsIntegrationTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-parity-\(UUID().uuidString)")
        runtime = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy")); try await runtime.start()
    }
    override func tearDown() async throws { runtime = nil; try? FileManager.default.removeItem(at:root) }
    func testSidebarSchoolChangesPreserveChosenUniversityAndCustomServicesAfterRestart() async throws {
        _ = try await runtime.invoke("settings:set", request: ["university": ["universityId": "snu", "customServices": [["id": "custom:reference", "label": "자료", "url": "https://example.edu", "kind": "other"]], "openExternallyOverrides": ["snu.portal": true]]])
        _ = try await runtime.invoke("settings:set", request: ["university": ["hiddenServiceIds": ["snu.portal"]]])
        _ = try await runtime.invoke("settings:set", request: ["university": ["serviceOrder": ["custom:reference", "snu.myetl"]]])
        let reopened = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await reopened.start()
        let result = try await reopened.invoke("settings:get") as! [String: Any]
        let school = try XCTUnwrap(result["university"] as? [String: Any])
        XCTAssertEqual(school["universityId"] as? String, "snu")
        XCTAssertEqual((school["customServices"] as? [[String: Any]])?.first?["id"] as? String, "custom:reference")
        XCTAssertEqual(school["hiddenServiceIds"] as? [String], ["snu.portal"])
        XCTAssertEqual(school["serviceOrder"] as? [String], ["custom:reference", "snu.myetl"])
        XCTAssertEqual((school["openExternallyOverrides"] as? [String: Bool])?["snu.portal"], true)
    }
    func testDesktopPreferenceGroupsMergeButShortcutOverridesReplaceAndSurviveRestart() async throws {
        _ = try await runtime.invoke("settings:set",request:["tabs":["markdownTitlePrefix":"강의 노트","whiteboardBackground":"dots"],"keybindings":["close-tab":"mod+alt+w"],"futureDesktopOption":["v":7],"browserSearchEngine":"daum"])
        _ = try await runtime.invoke("settings:set",request:["tabs":["boardHideDone":true],"keybindings":[String:String]()])
        let restarted = DesktopRuntime(root:root,legacyRoot:root.appendingPathComponent("Legacy")); try await restarted.start()
        let settings = try await restarted.invoke("settings:get") as! [String:Any], tabs = settings["tabs"] as! [String:Any]
        XCTAssertEqual(tabs["markdownTitlePrefix"] as? String,"강의 노트"); XCTAssertEqual(tabs["whiteboardBackground"] as? String,"dots")
        XCTAssertEqual(tabs["boardHideDone"] as? Bool,true); XCTAssertEqual(tabs["recordingFollowTranscript"] as? Bool,true)
        XCTAssertTrue((settings["keybindings"] as! [String:Any]).isEmpty)
        XCTAssertEqual((settings["futureDesktopOption"] as? [String:Int])?["v"],7)
        XCTAssertEqual(settings["editorFont"] as? String,"sans")
        XCTAssertEqual(settings["browserSearchEngine"] as? String,"daum")
    }
    func testWhiteboardCreationUsesSavedPaperPreferenceWithoutChangingExistingBoards() async throws {
        let course = try await runtime.invoke("courses:create",request:["name":"설정 검증","color":"blue"]) as! [String:Any]
        let identity: [String:Any] = ["courseId":course["id"]!,"title":"첫 보드"]
        let first = try await runtime.invoke("canvas:create",request:identity) as! [String:Any]
        _ = try await runtime.invoke("settings:set",request:["tabs":["whiteboardBackground":"lines"]])
        let second = try await runtime.invoke("canvas:create",request:identity) as! [String:Any]
        let unchanged = try await runtime.invoke("canvas:get",request:["courseId":course["id"]!,"id":first["id"]!]) as! [String:Any]
        XCTAssertEqual(second["background"] as? String,"lines"); XCTAssertEqual(unchanged["background"] as? String,"grid")
    }
    func testUsageRecordsActualProviderTotalsOnceForReplayedCompletion() async throws {
        let course = try await runtime.invoke("courses:create",request:["name":"사용량","color":"blue"]) as! [String:Any]
        let id = UUID().uuidString
        var request: [String:Any] = ["courseId":course["id"]!,"sessionId":id,"provider":"codex"]
        _ = try await runtime.invoke("chat:open",request:request)
        request["content"] = "질문"; _ = try await runtime.invokePrivate("nativeChat:begin",request:request)
        request.merge(["turnSeq":1,"text":"응답","usage":["inputTokens":123,"outputTokens":45],"durationMs":2500]) { _,new in new }
        _ = try await runtime.invokePrivate("nativeChat:finish",request:request)
        _ = try await runtime.invokePrivate("nativeChat:finish",request:request)
        let result = try await runtime.invokePrivate("nativeSettings:usage",request:["windowDays":0]) as! [String:Any]
        XCTAssertEqual((result["sessions"] as? NSNumber)?.intValue,1)
        XCTAssertEqual((result["inputTokens"] as? NSNumber)?.intValue,123)
        XCTAssertEqual((result["outputTokens"] as? NSNumber)?.intValue,45)
        XCTAssertEqual((result["durationSeconds"] as? NSNumber)?.doubleValue,2.5)
        XCTAssertEqual((result["providers"] as? [[String:Any]])?.first?["provider"] as? String,"codex")
    }
    func testDeadlinePlanHonorsLocalAllDayDatesDisabledAndCompletedTasks() throws {
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:9*3600)!
        let now = NativeNotificationPlan.date("2026-10-10T00:00:00Z")!
        let tasks: [[String:Any]] = [["id":"due","title":"중간고사","dueAt":"2026-10-17","allDay":true,"status":"todo"],["id":"done","title":"완료","dueAt":"2026-10-17","allDay":true,"status":"done"]]
        let plan = NativeNotificationPlan.deadlines(tasks:tasks,settings:["deadlineLeadDays":[3,1,1]],now:now,calendar:calendar)
        XCTAssertEqual(plan.count,2); XCTAssertEqual(Set(plan.map(\.taskID)),["due"])
        XCTAssertEqual(calendar.component(.hour,from:plan[0].date),9)
        XCTAssertEqual(calendar.component(.day,from:plan[0].date),14)
        XCTAssertTrue(NativeNotificationPlan.deadlines(tasks:tasks,settings:["enabled":false],now:now).isEmpty)
        XCTAssertTrue(NativeNotificationPlan.deadlines(tasks:tasks,settings:["deadlines":false],now:now).isEmpty)
    }
    func testGregorianDeadlineRemainsTheSameUnderBuddhistSystemCalendar() throws {
        var gregorian = Calendar(identifier:.gregorian); gregorian.timeZone = TimeZone(secondsFromGMT:9*3600)!
        var buddhist = Calendar(identifier:.buddhist); buddhist.timeZone = gregorian.timeZone
        let date = NativeNotificationPlan.date("2026-10-21",calendar:gregorian)
        XCTAssertEqual(NativeNotificationPlan.date("2026-10-21",calendar:buddhist),date)
        let task: [[String:Any]] = [["id":"deadline","title":"시험","dueAt":"2026-10-21","allDay":true,"status":"todo"]]
        let now = NativeNotificationPlan.date("2026-10-17T00:00:00Z")!
        XCTAssertEqual(NativeNotificationPlan.deadlines(tasks:task,settings:[:],now:now,calendar:gregorian),NativeNotificationPlan.deadlines(tasks:task,settings:[:],now:now,calendar:buddhist))
    }
    func testCalendarExportEscapesContentFoldsUTF8AndUsesExclusiveAllDayEnd() throws {
        let title = String(repeating:"한글🌙",count:30) + ",;"
        let bytes = NativeCalendarExport.data(tasks:[["id":"task","title":title,"notes":"첫째\n둘째;셋째","startAt":"2026-10-17","dueAt":"2026-10-19","allDay":true]])
        let text = try XCTUnwrap(String(data:bytes,encoding:.utf8)), unfolded = text.replacingOccurrences(of:"\r\n ",with:"")
        XCTAssertTrue(unfolded.contains("DTSTART;VALUE=DATE:20261017")); XCTAssertTrue(unfolded.contains("DTEND;VALUE=DATE:20261020"))
        XCTAssertTrue(unfolded.contains("DESCRIPTION:첫째\\n둘째\\;셋째"))
        XCTAssertTrue(unfolded.contains("\\,\\;"))
        XCTAssertTrue(text.components(separatedBy:"\r\n").allSatisfy { $0.utf8.count <= 75 })
    }
}
