import AVFoundation
import XCTest
@testable import Bandal

@MainActor
final class NativeMediaPlaybackTests: XCTestCase {
    func testNativePlayerRestoresPositionRateAndFlushesBeforeReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = NativeWorkspaceStore(storageRoot:root); await store.start()
        try await store.createCourse(name:"강의")
        let course = try XCTUnwrap(store.selectedCourseID)
        var wav = PCMRecordingWriter.header(samples:160_000,encoding:.signed16)
        wav.append(Data(repeating:0,count:320_000))
        let file = try await store.invoke("materials:writeFile",["courseId":course,"dirRelPath":"","fileName":"강의.wav","encoding":"base64","data":wav.base64EncodedString()]) as! [String:Any]
        let path = try XCTUnwrap(file["relPath"] as? String)
        let document = NativeDocumentReference(courseID:course,relativePath:path,title:"강의",kind:"audio")
        _ = try await store.invoke("media:setProgress",["courseId":course,"relPath":path,"positionSec":2,"durationSec":10,"playbackRate":1.25])
        let playback = NativeMediaPlayback(); await playback.open(document,store:store)
        XCTAssertNil(playback.error)
        let player = try XCTUnwrap(playback.player)
        XCTAssertEqual(player.currentTime().seconds,2,accuracy:0.05)
        XCTAssertEqual(player.defaultRate,1.25)
        await player.seek(to:CMTime(seconds:4,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        player.defaultRate = 1.5
        _ = try await store.withExternalMutation {
            XCTAssertTrue(playback.frozen)
            let progress = try await store.invoke("media:getProgress",["courseId":course,"relPath":path]) as? [String:Any]
            XCTAssertEqual((progress?["positionSec"] as? NSNumber)?.doubleValue ?? -1,4,accuracy:0.05)
            XCTAssertEqual((progress?["playbackRate"] as? NSNumber)?.doubleValue,1.5)
            return ["changedCourseIDs":[course]]
        }
        XCTAssertNil(playback.player)
        try await playback.save()
        let restarted = NativeMediaPlayback(); await restarted.open(document,store:store)
        XCTAssertNil(restarted.error)
        XCTAssertEqual(try XCTUnwrap(restarted.player).currentTime().seconds,4,accuracy:0.05)
        XCTAssertEqual(restarted.player?.defaultRate,1.5)
        restarted.close()
    }

    func testPlayerOpeningDuringReplacementWaitsAndCannotOverwriteRemoteProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-late-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = NativeWorkspaceStore(storageRoot:root); await store.start()
        try await store.createCourse(name:"강의")
        let course = try XCTUnwrap(store.selectedCourseID)
        var wav = PCMRecordingWriter.header(samples:160_000,encoding:.signed16)
        wav.append(Data(repeating:0,count:320_000))
        let file = try await store.invoke("materials:writeFile",["courseId":course,"dirRelPath":"","fileName":"강의.wav","encoding":"base64","data":wav.base64EncodedString()]) as! [String:Any]
        let path = try XCTUnwrap(file["relPath"] as? String)
        let document = NativeDocumentReference(courseID:course,relativePath:path,title:"강의",kind:"audio")
        var finishReplacement: CheckedContinuation<Void,Never>?
        let replacement = Task {
            try await store.withExternalMutation {
                await withCheckedContinuation { finishReplacement = $0 }
                _ = try await store.invoke("media:setProgress",["courseId":course,"relPath":path,"positionSec":6,"durationSec":10,"playbackRate":1.75])
                return ["changedCourseIDs":[course]]
            }
        }
        while finishReplacement == nil { await Task.yield() }
        let playback = NativeMediaPlayback()
        let opening = Task { await playback.open(document,store:store) }
        while !playback.frozen { await Task.yield() }
        XCTAssertNil(playback.player)
        var finishedSaving = false
        let saving = Task { try await playback.save(); finishedSaving = true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(finishedSaving)
        finishReplacement?.resume()
        _ = try await replacement.value
        await opening.value
        try await saving.value
        XCTAssertNil(playback.player)
        let reopened = NativeMediaPlayback(); await reopened.open(document,store:store)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(try XCTUnwrap(reopened.player).currentTime().seconds,6,accuracy:0.05)
        XCTAssertEqual(reopened.player?.defaultRate,1.75)
        reopened.close()
    }
}

extension NativeMediaPlaybackTests {
    func testDuplicatePlayersRestoreSeparatePositionsAndRatesAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-media-windows-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root); await store.start()
        try await store.createCourse(name: "Lecture")
        let course = try XCTUnwrap(store.selectedCourseID)
        var wav = PCMRecordingWriter.header(samples: 160_000, encoding: .signed16)
        wav.append(Data(repeating: 0, count: 320_000))
        let file = try await store.invoke("materials:writeFile", ["courseId": course, "dirRelPath": "", "fileName": "lecture.wav", "encoding": "base64", "data": wav.base64EncodedString()]) as! [String: Any]
        let path = try XCTUnwrap(file["relPath"] as? String)
        let original = NativeDocumentReference(courseID: course, relativePath: path, title: "Lecture", kind: "audio"), copy = original.duplicated()
        let first = NativeMediaPlayback(), second = NativeMediaPlayback()
        await first.open(original, store: store); await second.open(copy, store: store)
        let firstPlayer = try XCTUnwrap(first.player), secondPlayer = try XCTUnwrap(second.player)
        await firstPlayer.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        await secondPlayer.seek(to: CMTime(seconds: 6, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        firstPlayer.defaultRate = 1.25; secondPlayer.defaultRate = 1.75
        try await first.save(); try await second.save(); first.close(); second.close()
        let restarted = NativeWorkspaceStore(storageRoot: root); await restarted.start()
        let restoredFirst = NativeMediaPlayback(), restoredSecond = NativeMediaPlayback()
        await restoredFirst.open(original, store: restarted); await restoredSecond.open(copy, store: restarted)
        XCTAssertEqual(try XCTUnwrap(restoredFirst.player).currentTime().seconds, 2, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(restoredSecond.player).currentTime().seconds, 6, accuracy: 0.05)
        XCTAssertEqual(restoredFirst.player?.defaultRate, 1.25); XCTAssertEqual(restoredSecond.player?.defaultRate, 1.75)
        restoredFirst.close(); restoredSecond.close()
    }
}
