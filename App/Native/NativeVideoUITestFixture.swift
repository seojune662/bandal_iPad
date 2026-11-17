#if DEBUG
import AVFoundation
import UIKit
import WebKit

/// PiP's UI tests work offline. `--native-video-fixture` writes a short generated clip into the folder a test
/// creates; `--native-video-web-fixture` with `--native-browser-ui-fixture` opens a local page that plays the
/// same clip in a `<video>` (the path a YouTube video takes in the app, without the network).
@MainActor
enum NativeVideoUITestFixture {
    static let fileName = "PiP 테스트 영상.mp4"
    static var requested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--native-ui-testing") && arguments.contains("--native-video-fixture")
    }
    static var webRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--native-ui-testing") && arguments.contains("--native-video-web-fixture")
    }
    private static var seeded = Set<String>()
    private static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("bandal-video-fixture", isDirectory: true) }

    static func seedIfRequested(store: NativeWorkspaceStore, courseID: String?) async {
        guard requested, let courseID, store.root.lastPathComponent.hasPrefix("BandalDesktop-Native-UI-Tests"), seeded.insert(courseID).inserted else { return }
        do {
            let clip = try await makeClip()
            _ = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "", "fileName": fileName,
                                                               "encoding": "base64", "data": try Data(contentsOf: clip).base64EncodedString()])
            await store.refreshMaterials()
        } catch { store.errorMessage = "video fixture: " + error.localizedDescription }
    }

    /// A page whose only content is the clip, playing on a loop. Its file URL is allowed in the browser only here.
    static func loadWebPage(into page: DesktopBrowserPage) async {
        do {
            let clip = try await makeClip()
            let html = directory.appendingPathComponent("video.html")
            try """
            <!doctype html><html lang="ko"><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Video fixture</title>
            <style>body{font:16px -apple-system;margin:0;padding:24px}video{width:640px;max-width:100%;background:#000;display:block}</style></head>
            <body><h1>Video fixture</h1><video id="clip" src="\(clip.lastPathComponent)" autoplay loop playsinline></video>
            <p>Below the video.</p></body></html>
            """.write(to: html, atomically: true, encoding: .utf8)
            page.webView.loadFileURL(html, allowingReadAccessTo: directory)
        } catch { NSLog("[bandal.video.fixture] %@", error.localizedDescription) }
    }
    static func allowsFileNavigation(_ url: URL) -> Bool {
        webRequested && url.isFileURL && url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    /// 2 minutes of 640 × 360 at 10 fps: each second its own colour, the elapsed time written large, a bar sweeping.
    static func makeClip() async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("clip-120s.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let partial = directory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let width = 640, height = 360, fps: Int32 = 10, seconds = 120
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 150_000, AVVideoMaxKeyFrameIntervalKey: 20]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * Int(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                let time = Double(frame) / Double(fps)
                context.setFillColor(UIColor(hue: CGFloat(Int(time) % 12) / 12, saturation: 0.55, brightness: 0.75, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.setFillColor(UIColor.white.cgColor)
                context.fill(CGRect(x: CGFloat(frame % Int(fps)) / CGFloat(fps) * CGFloat(width - 40), y: 24, width: 40, height: 12))
                UIGraphicsPushContext(context)
                context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
                (String(format: "%.1f s", time) as NSString).draw(at: CGPoint(x: 40, y: 120), withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold), .foregroundColor: UIColor.white])
                UIGraphicsPopContext()
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }
}
#endif
