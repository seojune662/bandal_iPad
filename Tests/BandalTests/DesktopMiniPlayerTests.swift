import AVFoundation
import XCTest
import WebKit
@testable import Bandal

@MainActor
final class DesktopMiniPlayerTests: XCTestCase {
    private func fixtureMovie(_ path: URL) async throws {
        let writer = try AVAssetWriter(outputURL: path, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<24 {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { throw writer.error ?? DesktopRuntimeError("Fixture encoder unavailable") }
            var buffer: CVPixelBuffer?; XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer); CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), 120, CVPixelBufferGetDataSize(pixel)); CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 12)))
        }
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
    }
    func testOriginalPlayerLoadsActualVideoReportsProgressAndRestoresTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mini-player-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let created = try await runtime.invoke("courses:create", request: ["name": "영상 검증", "color": "#888888"]) as! [String: Any]
        let course = created["id"] as! String, movie = root.appendingPathComponent("fixture.mp4")
        try await fixtureMovie(movie)
        _ = try await runtime.invoke("materials:import", request: ["courseId": course, "paths": [movie.path]])
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768)), service = DesktopMiniPlayer(runtime: runtime)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; controller.view.addSubview(container); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        service.attach(to: container)
        var opened: [String: Any]?
        service.emit = { channel, payload in if channel == "ui:openMaterial" { opened = payload as? [String: Any] } }
        let source: [String: Any] = ["kind": "local", "courseId": course, "relPath": "fixture.mp4", "title": "영상 검증"]
        _ = try await service.handle("pip:open", ["source": source, "positionSec": 0.5, "playbackRate": 1.5, "paused": true])
        defer { Task { _ = try? await service.handle("pip:close", [:]) } }
        let panel = try XCTUnwrap(container.subviews.first), web = try XCTUnwrap(panel.subviews.first as? WKWebView)
        let deadline = Date().addingTimeInterval(20)
        var snapshot: [String: Any] = [:]
        while Date() < deadline {
            snapshot = (try? await web.evaluateJavaScript("(()=>{let v=document.querySelector('video');return {ready:v?.readyState??0,network:v?.networkState??0,src:v?.currentSrc??'',width:v?.videoWidth??0,position:v?.currentTime??0,error:v?.error?.message??null,title:document.querySelector('.pip-player__title')?.textContent??null}})()")) as? [String: Any] ?? [:]
            if snapshot["ready"] as? Int ?? 0 >= 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(snapshot["width"] as? Int, 64, "Actual WK video decoding failed: \(snapshot)")
        XCTAssertEqual(snapshot["title"] as? String, "영상 검증")
        _ = try await service.handle("pip:report", ["positionSec": 1.25, "playbackRate": 1.5, "paused": true])
        let progress = try await runtime.invoke("media:getProgress", request: ["courseId": course, "relPath": "fixture.mp4"]) as? [String: Any]
        XCTAssertEqual(progress?["positionSec"] as? Double, 1.25)
        _ = try await service.handle("pip:moveBy", ["dx": -100_000.0, "dy": 100_000.0]); XCTAssertGreaterThanOrEqual(panel.frame.minX, 0); XCTAssertLessThanOrEqual(panel.frame.maxY, container.bounds.height)
        _ = try await web.evaluateJavaScript("document.querySelector('[aria-label=\"원래 화면으로 돌아가기\"]').click()")
        let restored = Date().addingTimeInterval(3)
        while opened == nil, Date() < restored { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(opened?["courseId"] as? String, course); XCTAssertEqual(opened?["relPath"] as? String, "fixture.mp4")
        XCTAssertEqual(service.state["open"] as? Bool, false)
    }
}
