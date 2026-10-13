import XCTest
import AVFoundation
@testable import Bandal

final class DesktopRecordingTests: XCTestCase {
    @MainActor
    func testEngineStartFailureClosesPCMAndPersistsRetryableStateWithoutLosingTranscript() async throws {
        let fixture = try await captureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = try XCTUnwrap(fixture.session["id"] as? String)
        var order: [String] = []
        let service = DesktopRecordingService(root: fixture.root) { channel, request in
            let result = try await fixture.runtime.invokePrivate(channel, request: request)
            if channel == "nativeRecording:save", let session = request["session"] as? [String: Any], let status = session["status"] as? String {
                order.append("save:\(status)")
                if status == "recording" {
                    _ = try await fixture.runtime.invokePrivate("nativeRecording:commitTranscriptWindow", request: ["id": id, "startSample": 0, "endSample": 4000, "text": "보존할 자막"])
                }
            }
            return result
        }
        var events: [[String: Any]] = []
        service.emit = { channel, value in
            if channel == "recordings:event", let event = value as? [String: Any], let session = event["session"] as? [String: Any] { events.append(session) }
        }
        let before = try Data(contentsOf: fixture.audio)
        let output = try PCMRecordingWriter(url: fixture.audio, resuming: true, encoding: .signed16)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4000)); buffer.frameLength = 4000
        for index in 0..<4000 { buffer.floatChannelData![0][index] = 0.2 }
        do {
            _ = try await service.commitCaptureStart(fixture.session, output: output, startEngine: {
                order.append("start"); output.append(buffer)
                throw NSError(domain: "RecordingStartFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input device disconnected"])
            }, stopEngine: { order.append("stop") })
            XCTFail("A failed engine must never report a started recording")
        } catch { XCTAssertEqual(error.localizedDescription, "Input device disconnected") }
        XCTAssertEqual(order, ["save:recording", "start", "stop", "save:interrupted"])
        let value = try await fixture.runtime.invokePrivate("nativeRecording:get", request: ["id": id])
        let recovered = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(recovered["status"] as? String, "interrupted")
        XCTAssertEqual(recovered["error"] as? String, "Input device disconnected")
        XCTAssertEqual((recovered["samples"] as? NSNumber)?.intValue, 12000)
        XCTAssertEqual((recovered["transcribedSamples"] as? NSNumber)?.intValue, 4000)
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?["status"] as? String, "interrupted")
        let detail = try await fixture.runtime.invoke("recordings:read", request: ["id": id]) as? [String: Any]
        XCTAssertEqual((detail?["segments"] as? [[String: Any]])?.first?["text"] as? String, "보존할 자막")
        XCTAssertEqual(try AVAudioFile(forReading: fixture.audio).length, 12000)
        XCTAssertEqual(try Data(contentsOf: fixture.audio).subdata(in: 44..<before.count), before.dropFirst(44))
        let resumed = try PCMRecordingWriter(url: fixture.audio, resuming: true, encoding: .signed16)
        XCTAssertEqual(resumed.samples, 12000); try resumed.closeOrThrow()
    }

    @MainActor
    func testInitialMetadataFailureDoesNotStartEngineAndPreservesOriginalAudio() async throws {
        let fixture = try await captureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.audio)
        let service = DesktopRecordingService(root: fixture.root) { channel, request in
            if channel == "nativeRecording:save", (request["session"] as? [String: Any])?["status"] as? String == "recording" {
                throw DesktopRuntimeError("Injected save failure")
            }
            return try await fixture.runtime.invokePrivate(channel, request: request)
        }
        let output = try PCMRecordingWriter(url: fixture.audio, resuming: true, encoding: .signed16)
        var starts = 0, stops = 0
        do {
            _ = try await service.commitCaptureStart(fixture.session, output: output, startEngine: { starts += 1 }, stopEngine: { stops += 1 })
            XCTFail("A failed metadata write must stop capture before microphone use")
        } catch { XCTAssertEqual(error.localizedDescription, "Injected save failure") }
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.audio), original)
        let saved = try await fixture.runtime.invokePrivate("nativeRecording:get", request: ["id": fixture.session["id"]!]) as? [String: Any]
        XCTAssertEqual(saved?["status"] as? String, "interrupted")
        XCTAssertEqual((saved?["samples"] as? NSNumber)?.intValue, 8000)
    }

    @MainActor
    func testRecoveryMetadataFailureIsReportedAndRestartRecoversDurableAudio() async throws {
        let fixture = try await captureFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = DesktopRecordingService(root: fixture.root) { channel, request in
            if channel == "nativeRecording:save", (request["session"] as? [String: Any])?["status"] as? String == "interrupted" {
                throw DesktopRuntimeError("Recovery storage unavailable")
            }
            return try await fixture.runtime.invokePrivate(channel, request: request)
        }
        var events = 0, stops = 0
        service.emit = { _, _ in events += 1 }
        let output = try PCMRecordingWriter(url: fixture.audio, resuming: true, encoding: .signed16)
        do {
            _ = try await service.commitCaptureStart(fixture.session, output: output, startEngine: {
                throw DesktopRuntimeError("Engine failed")
            }, stopEngine: { stops += 1 })
            XCTFail("Recovery persistence failure must not be swallowed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Engine failed"))
            XCTAssertTrue(error.localizedDescription.contains("Recovery storage unavailable"))
        }
        XCTAssertEqual(stops, 1); XCTAssertEqual(events, 0)
        XCTAssertEqual(try AVAudioFile(forReading: fixture.audio).length, 8000)
        _ = try await fixture.runtime.invokePrivate("nativeRecording:recover")
        let saved = try await fixture.runtime.invokePrivate("nativeRecording:get", request: ["id": fixture.session["id"]!]) as? [String: Any]
        XCTAssertEqual(saved?["status"] as? String, "interrupted")
        XCTAssertEqual((saved?["samples"] as? NSNumber)?.intValue, 8000)
    }

    @MainActor
    private func captureFixture() async throws -> (root: URL, runtime: DesktopRuntime, session: [String: Any], audio: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-start-\(UUID())")
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let course = try await runtime.invoke("courses:create", request: ["name": "녹음 시작 복구", "color": "#60a5fa"]) as? [String: Any]
        let courseID = try XCTUnwrap(course?["id"] as? String)
        let created = try await runtime.invokePrivate("nativeRecording:create", request: ["courseId": courseID, "title": "복구할 강의", "modelId": "zipformer-ko"]) as? [String: Any]
        let id = try XCTUnwrap(created?["id"] as? String)
        _ = try await runtime.invokePrivate("nativeRecording:status", request: ["id": id, "status": "recording"])
        _ = try await runtime.invokePrivate("nativeRecording:append", request: ["id": id, "sequence": 0, "pcm": ["__bandalBytes": Data(repeating: 16, count: 16000).base64EncodedString()]])
        _ = try await runtime.invokePrivate("nativeRecording:status", request: ["id": id, "status": "paused"])
        let session = try await runtime.invokePrivate("nativeRecording:get", request: ["id": id]) as? [String: Any]
        let path = try await runtime.invokePrivate("nativeRecording:audioPath", request: ["id": id]) as? String
        return (root, runtime, try XCTUnwrap(session), URL(fileURLWithPath: try XCTUnwrap(path)))
    }

    func testDesktopPCM16EncodingRecoversPartialTailAndResumesWithoutFloatHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-pcm-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PCMRecordingWriter(url: url, encoding: .signed16)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)); buffer.frameLength = 16000
        for index in 0..<16000 { buffer.floatChannelData![0][index] = 0.2 * sin(Float(index) * 2 * .pi * 440 / 16000) }
        writer.append(buffer); try writer.closeOrThrow()
        XCTAssertEqual(writer.samples, 16000)
        let original = try Data(contentsOf: url)
        XCTAssertEqual(original.count, 44 + 32000); XCTAssertEqual(original[20], 1); XCTAssertEqual(original[34], 16)
        let handle = try FileHandle(forUpdating: url); try handle.seekToEnd(); try handle.write(contentsOf: Data([123])); try handle.close()
        XCTAssertEqual(try PCMRecordingWriter.repair(url: url, encoding: .signed16), 16000)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let resumed = try PCMRecordingWriter(url: url, resuming: true, encoding: .signed16)
        resumed.append(buffer); try resumed.closeOrThrow()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000)
        XCTAssertThrowsError(try PCMRecordingWriter.repair(url: url))
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32000)
    }

    @MainActor
    func testNativeRecordingUsesOriginalRepositoryAndRecoversUncheckpointedPCM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let service = DesktopRecordingService(root: root) { channel, request in try await runtime.invokePrivate(channel, request: request) }
        let courses = try await runtime.invoke("courses:create", request: ["name": "음성 저장 검증", "color": "#60a5fa"])
        let course = try XCTUnwrap(courses as? [String: Any]), courseID = try XCTUnwrap(course["id"] as? String)
        let states = try await service.handle(channel: "recordings:models", request: [:]) as? [[String: Any]]
        XCTAssertEqual(Set(states?.compactMap { $0["id"] as? String } ?? []), Set(["zipformer-ko", "sensevoice"]))
        XCTAssertTrue(states?.allSatisfy { $0["status"] as? String == "available" } == true)
        let value = try await service.handle(channel: "recordings:create", request: ["courseId": courseID, "title": "강의", "modelId": "zipformer-ko"])
        var session = try XCTUnwrap(value as? [String: Any]); let id = try XCTUnwrap(session["id"] as? String)
        let pathValue = try await runtime.invokePrivate("nativeRecording:audioPath", request: ["id": id])
        let url = URL(fileURLWithPath: try XCTUnwrap(pathValue as? String))
        session["status"] = "recording"; _ = try await runtime.invokePrivate("nativeRecording:save", request: ["session": session])
        let output = try PCMRecordingWriter(url: url, resuming: true, encoding: .signed16)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)); buffer.frameLength = 8000
        for index in 0..<8000 { buffer.floatChannelData![0][index] = 0.15 }
        output.append(buffer); try output.closeOrThrow()
        // Simulate termination after durable WAV data but before metadata save.
        _ = try await runtime.invokePrivate("nativeRecording:recover", request: [:])
        let recoveredValue = try await runtime.invokePrivate("nativeRecording:get", request: ["id": id])
        let recovered = try XCTUnwrap(recoveredValue as? [String: Any])
        XCTAssertEqual(recovered["status"] as? String, "interrupted")
        XCTAssertEqual((recovered["samples"] as? NSNumber)?.intValue, 8000)
        _ = try await runtime.invokePrivate("nativeRecording:segment", request: ["id": id, "startSample": 0, "endSample": 8000, "text": "보존할 자막"])
        do {
            _ = try await service.handle(channel: "recordings:control", request: ["id": id, "action": "retry", "modelId": "sensevoice"])
            XCTFail("A missing model must fail before deleting the existing transcript")
        } catch { XCTAssertTrue(error is RecordingError) }
        let detailValue = try await runtime.invoke("recordings:read", request: ["id": id])
        let detail = try XCTUnwrap(detailValue as? [String: Any])
        XCTAssertEqual((detail["segments"] as? [[String: Any]])?.first?["text"] as? String, "보존할 자막")
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 8000)
    }
}
