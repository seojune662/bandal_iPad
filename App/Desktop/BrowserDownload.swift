import Foundation
import WebKit
import UIKit

@MainActor
final class DesktopBrowserDownload: NSObject, WKDownloadDelegate {
    let id = UUID().uuidString
    weak var host: DesktopBrowserHost?
    weak var page: DesktopBrowserPage?
    let webContentsID: Int
    let courseID: String?
    let profileID: String
    var download: WKDownload
    var destination: URL?
    var resumeData: Data?
    var state = "progressing"
    var paused = false
    var failureReason: String?
    var relPath: String?
    private var expectedCancellation = false
    private var observation: NSKeyValueObservation?
    private var lastProgress = Date.distantPast
    var payload: [String: Any] {
        ["id": id, "webContentsId": webContentsID, "fileName": destination?.lastPathComponent ?? download.originalRequest?.url?.lastPathComponent ?? "다운로드",
         "receivedBytes": max(0, download.progress.completedUnitCount), "totalBytes": max(0, download.progress.totalUnitCount),
         "state": state, "paused": paused, "relPath": relPath as Any? ?? NSNull(), "courseId": courseID as Any? ?? NSNull(),
         "recoverable": destination.map { FileManager.default.fileExists(atPath: $0.path) && state == "completed" } ?? false,
         "failureReason": failureReason as Any? ?? NSNull()]
    }
    init(download: WKDownload, page: DesktopBrowserPage, host: DesktopBrowserHost) {
        self.download = download; self.page = page; self.host = host
        webContentsID = page.id; courseID = page.courseID; profileID = page.profileID
        super.init(); observe()
    }
    private func observe() {
        download.delegate = self
        observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastProgress) > 0.15 else { return }
                self.lastProgress = Date(); self.publish()
            }
        }
    }
    func publish() { host?.emit("browser:download", payload) }
    func cancel(pause: Bool) async {
        expectedCancellation = true; paused = pause
        resumeData = await withCheckedContinuation { continuation in download.cancel { continuation.resume(returning: $0) } }
        if pause, resumeData != nil { state = "progressing" }
        else { state = "cancelled"; paused = false; if pause { failureReason = "이 서버는 다운로드 이어받기를 지원하지 않습니다." } }
        publish()
    }
    func resume() async throws {
        guard let resumeData, let page else { throw DesktopBrowserError.unavailable("이 다운로드를 이어받을 수 없습니다. 원래 탭에서 다시 다운로드해 주세요.") }
        download = await page.webView.resumeDownload(fromResumeData: resumeData)
        self.resumeData = nil; expectedCancellation = false; paused = false; state = "progressing"; failureReason = nil
        observe(); publish()
    }
    func retry() async throws {
        if resumeData != nil { try await resume(); return }
        guard let request = download.originalRequest, let page else { throw DesktopBrowserError.unavailable("원래 브라우저 탭을 연 뒤 다운로드해 주세요.") }
        download = await page.webView.startDownload(using: request)
        expectedCancellation = false; paused = false; state = "progressing"; failureReason = nil
        destination = nil; observe(); publish()
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            guard let host else { completionHandler(nil); return }
            let folder = host.root.appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let leaf = (suggestedFilename as NSString).lastPathComponent
            let safe = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: ":", with: "_")
            let name = String(safe.prefix(180))
            var file = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "다운로드" : name)
            if FileManager.default.fileExists(atPath: file.path) { file = folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + file.lastPathComponent) }
            destination = file; completionHandler(file); publish()
        } catch { failureReason = error.localizedDescription; state = "interrupted"; completionHandler(nil); publish() }
    }
    func downloadDidFinish(_ download: WKDownload) {
        state = "completed"; paused = false; observation = nil; publish()
        Task { [self] in
            do { if let destination, let callback = host?.onDownload { relPath = try await callback(destination, courseID) } }
            catch { failureReason = "파일은 보관했지만 과목에 추가하지 못했습니다: \(error.localizedDescription)" }
            publish()
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard !expectedCancellation else { return }
        self.resumeData = resumeData; state = "interrupted"; paused = false; observation = nil
        failureReason = error.localizedDescription; publish()
    }
}

extension DesktopBrowserHost {
    func track(_ download: WKDownload, page: DesktopBrowserPage) {
        let item = DesktopBrowserDownload(download: download, page: page, host: self)
        downloads[item.id] = item; item.publish()
    }
    func controlDownload(_ request: [String: Any]) async throws -> Any {
        guard let item = downloads[try Self.string(request, "id")] else { throw DesktopBrowserError.unavailable("다운로드 기록을 찾을 수 없습니다.") }
        switch try Self.string(request, "action") {
        case "cancel": await item.cancel(pause: false)
        case "pause": await item.cancel(pause: true)
        case "resume": try await item.resume()
        default: throw DesktopBrowserError.invalid("다운로드 동작")
        }
        return ["ok": true]
    }
    func downloadFile(_ request: [String: Any]) async throws -> Any {
        guard let item = downloads[try Self.string(request, "id")] else { throw DesktopBrowserError.unavailable("다운로드 기록을 찾을 수 없습니다.") }
        let action = try Self.string(request, "action")
        if action == "retry" { try await item.retry(); return ["ok": true] }
        guard item.state == "completed", let url = item.destination, FileManager.default.fileExists(atPath: url.path) else { throw DesktopBrowserError.unavailable("완료된 다운로드 파일이 없습니다.") }
        if action == "open", let course = item.courseID, let relPath = item.relPath {
            emit("ui:openMaterial", ["courseId": course, "relPath": relPath, "positionSec": 0, "playbackRate": 1]); return ["ok": true]
        }
        guard let presenter = presentingController, presenter.presentedViewController == nil else { throw DesktopBrowserError.unavailable("다른 창을 닫은 뒤 다시 시도해 주세요.") }
        switch action {
        case "saveAs", "reveal": presenter.present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
        case "open":
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = container
            share.popoverPresentationController?.sourceRect = CGRect(x: (container?.bounds.midX ?? 0), y: 48, width: 1, height: 1)
            presenter.present(share, animated: true)
        default: throw DesktopBrowserError.invalid("다운로드 파일 동작")
        }
        return ["ok": true]
    }
}
