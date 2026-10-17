import AVFoundation
import XCTest
@testable import Bandal

@MainActor
final class NativeToolsModelTests: XCTestCase {
    func testBrowserAddressPreservesHTTPSAndEncodesSearchText() throws {
        XCTAssertEqual(try NativeBrowserSession.addressURL("  example.org/한글  ").host, "example.org")
        XCTAssertEqual(try NativeBrowserSession.addressURL("http://localhost:8123/page").port, 8123)
        let search = try NativeBrowserSession.addressURL("미적분 & 그래프")
        let components = try XCTUnwrap(URLComponents(url: search, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "미적분 & 그래프")
        XCTAssertThrowsError(try NativeBrowserSession.addressURL("https://name:secret@example.org"))
        XCTAssertThrowsError(try NativeBrowserSession.addressURL("file:///private/document.pdf"))
        XCTAssertThrowsError(try NativeBrowserSession.addressURL("  "))
    }
    func testChatPreservesTextAndMarksAnInterruptedSavedResponse() throws {
        let message = try XCTUnwrap(NativeChatMessage(["id": "message", "role": "assistant", "blocks": [
            ["kind": "text", "payload": ["text": "한글 🌙", "interrupted": true]],
            ["kind": "thinking", "payload": ["text": "internal"]]
        ]]))
        XCTAssertTrue(message.text.contains("한글 🌙"))
        XCTAssertTrue(message.text.contains("응답이 중단되었습니다."))
        XCTAssertFalse(message.text.contains("internal"))
    }
    func testPlannerDecodesNullCourseAndAllDayDateWithoutUTCShift() throws {
        let task: NativePlannerTask = try NativeToolJSON.decode([
            "id": "task", "courseId": NSNull(), "title": "Review", "notes": "", "status": "todo",
            "kind": "assignment", "color": "none", "dueAt": "2026-10-17", "startAt": NSNull(), "allDay": true
        ])
        XCTAssertNil(task.courseId)
        XCTAssertEqual(NativePlannerTask.dayFormatter.string(from: try XCTUnwrap(task.dueDate)), "2026-10-17")
        XCTAssertFalse(task.completed)
    }
    func testPlannerCalendarIncludesEveryDayOfAnAllDayRange() throws {
        let task: NativePlannerTask = try NativeToolJSON.decode([
            "id": "range", "courseId": NSNull(), "title": "시험", "notes": "", "status": "todo",
            "kind": "exam", "color": "none", "dueAt": "2026-10-19", "startAt": "2026-10-17", "allDay": true
        ])
        let formatter = NativePlannerTask.dayFormatter
        for day in ["2026-10-17", "2026-10-18", "2026-10-19"] {
            XCTAssertTrue(task.occurs(on: try XCTUnwrap(formatter.date(from: day))))
        }
        XCTAssertFalse(task.occurs(on: try XCTUnwrap(formatter.date(from: "2026-10-16"))))
        XCTAssertFalse(task.occurs(on: try XCTUnwrap(formatter.date(from: "2026-10-20"))))
    }
    func testDeletedRecordingPageNeverBecomesAnOpenableDefaultPage() throws {
        let removed: NativeRecordingAnchor = try NativeToolJSON.decode([
            "id": "removed", "sample": 16000, "label": "시험 범위", "relPath": "강의.pdf",
            "page": NSNull(), "removedPage": 4, "originalRevision": "before-edit"
        ])
        XCTAssertFalse(removed.canOpenDocument)
        XCTAssertNil(removed.page)
        XCTAssertEqual(removed.locationTitle, "삭제된 PDF 페이지")
        let document: NativeRecordingAnchor = try NativeToolJSON.decode([
            "id": "document", "sample": 0, "label": "강의 시작", "relPath": "강의.pdf", "page": NSNull()
        ])
        XCTAssertTrue(document.canOpenDocument)
        XCTAssertNil(document.page)
        XCTAssertEqual(document.locationTitle, "강의.pdf")
    }
    func testDelayedRecordingPlaybackCannotReopenAfterLeavingTheScreen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("playback-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        for index in 0..<1600 { buffer.floatChannelData![0][index] = 0 }
        let writer = try PCMRecordingWriter(url: url)
        writer.append(buffer); writer.close()
        let player = NativeRecordingPlayback()
        player.activate()
        var resolve: CheckedContinuation<URL, Never>?
        let waiting = expectation(description: "audio path lookup is pending")
        let operation = Task {
            try await player.prepare(id: "old-recording") {
                await withCheckedContinuation { continuation in resolve = continuation; waiting.fulfill() }
            }
        }
        await fulfillment(of: [waiting], timeout: 2)
        player.deactivate()
        player.activate()
        try XCTUnwrap(resolve).resume(returning: url)
        do { try await operation.value; XCTFail("A delayed lookup must not reopen audio after navigation") }
        catch is CancellationError { }
        XCTAssertFalse(player.playing)
        XCTAssertEqual(player.duration, 0)
        // A fresh action after returning to the screen can still load real audio.
        try await player.prepare(id: "new-recording") { url }
        XCTAssertGreaterThan(player.duration, 0)
        player.deactivate()
    }
    func testDesktopBrandGeometryIsBundledForNativeRendering() {
        XCTAssertEqual(NativeBandalGeometry.shared.shapes.count, 2)
        XCTAssertTrue(NativeBandalGeometry.shared.shapes.allSatisfy { !$0.points.isEmpty })
    }
    func testAppearanceUsesPortableSettingsAndSurvivesRuntimeRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-\(UUID().uuidString)")
        let suite = "appearance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await runtime.start()
        // Desktop's legacy theme IDs resolve at the same compatibility boundary.
        let imported = try await runtime.invoke("settings:set", request: ["theme": "midnight"]) as! [String: Any]
        NativeAppearancePreference.apply(imported, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "native.appearance"), "dark")
        _ = try await NativeAppearancePreference.save("light", invoke: { channel, request in
            try await runtime.invoke(channel, request: request)
        }, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "native.appearance"), "light")
        let restarted = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await restarted.start()
        let stored = try await restarted.invoke("settings:get") as! [String: Any]
        XCTAssertEqual(stored["theme"] as? String, "light")
        defaults.set("dark", forKey: "native.appearance")
        NativeAppearancePreference.apply(stored, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "native.appearance"), "light", "Portable settings must replace a stale rendering cache")
    }
    func testAppearanceWriteFailurePreservesPreviouslySavedMode() async throws {
        let suite = "appearance-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "native.appearance")
        do {
            _ = try await NativeAppearancePreference.save("light", invoke: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }, defaults: defaults)
            XCTFail("An unsuccessful setting write must be reported")
        } catch { }
        XCTAssertEqual(defaults.string(forKey: "native.appearance"), "dark")
    }
}
