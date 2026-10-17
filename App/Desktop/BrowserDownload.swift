import Foundation
import WebKit
import UIKit

@MainActor
final class DesktopBrowserDownload: NSObject, WKDownloadDelegate {
    let id: String
    weak var host: DesktopBrowserHost?
    weak var page: DesktopBrowserPage?
    let webContentsID: Int
    let sourceTabID: String?
    let courseID: String?
    let profileID: String
    let isPrivate: Bool
    private(set) var download: WKDownload?
    private var recoveryView: WKWebView?
    private var retryURL: URL?
    private var savedFileName = "다운로드"
    private var receivedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    var destination: URL?
    var resumeData: Data?
    var state = "progressing"
    var paused = false
    var failureReason: String?
    var relPath: String?
    private var expectedCancellation = false
    private var controlling = false
    private var savingMaterial = false
    var isChangingTransfer: Bool { controlling || savingMaterial }
    private var observation: NSKeyValueObservation?
    private var lastProgress = Date.distantPast
    var payload: [String: Any] {
        ["id": id, "webContentsId": page == nil ? NSNull() : webContentsID as Any,
         "tabId": sourceTabID as Any? ?? NSNull(), "profileId": profileID, "isPrivate": isPrivate,
         "fileName": destination?.lastPathComponent ?? savedFileName,
         "receivedBytes": max(0, download?.progress.completedUnitCount ?? receivedBytes), "totalBytes": max(0, download?.progress.totalUnitCount ?? totalBytes),
         "state": state, "paused": paused, "relPath": relPath as Any? ?? NSNull(), "courseId": courseID as Any? ?? NSNull(),
         "recoverable": state == "completed" && courseID != nil && relPath == nil && !savingMaterial && destination.map { FileManager.default.fileExists(atPath: $0.path) } == true,
         "failureReason": failureReason as Any? ?? NSNull()]
    }
    init(download: WKDownload, page: DesktopBrowserPage, host: DesktopBrowserHost) {
        id = UUID().uuidString; self.download = download; self.page = page; self.host = host
        webContentsID = page.id; sourceTabID = page.tabID; courseID = page.courseID; profileID = page.profileID; isPrivate = page.isPrivate
        if (download.originalRequest?.httpMethod ?? "GET") == "GET" { retryURL = download.originalRequest?.url }
        savedFileName = retryURL?.lastPathComponent ?? "다운로드"
        super.init(); observe()
    }
    init(restoring record: BrowserDownloadStore.Record, host: DesktopBrowserHost) {
        id = record.id; self.host = host; webContentsID = 0; sourceTabID = nil; courseID = record.courseID; profileID = record.profileID; isPrivate = false
        savedFileName = record.fileName; retryURL = record.url.flatMap(URL.init(string:)); receivedBytes = record.receivedBytes; totalBytes = record.totalBytes
        relPath = record.relPath; state = record.state; failureReason = record.failureReason
        destination = record.destinationLeaf.map { host.root.appendingPathComponent("Downloads").appendingPathComponent(record.id).appendingPathComponent($0) }
        resumeData = host.downloadStore?.resumeData(record.id)
        if state == "progressing" || state == "interrupted" {
            state = resumeData == nil ? "interrupted" : "progressing"; paused = resumeData != nil
            failureReason = resumeData == nil ? "앱이 종료되어 다운로드가 중단됐습니다. 다시 받기를 선택해 주세요." : nil
        }
        if state == "completed", destination.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            state = "interrupted"; failureReason = "내려받은 파일을 찾을 수 없습니다. 다시 받아 주세요."
        }
        super.init()
    }
    private func observe() {
        guard let download else { return }
        download.delegate = self
        observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastProgress) > 0.5 else { return }
                self.lastProgress = Date(); self.publish()
            }
        }
    }
    func publish() {
        if let download { receivedBytes = max(0, download.progress.completedUnitCount); totalBytes = max(0, download.progress.totalUnitCount) }
        if !isPrivate, host?.isProfileAvailable(profileID) == true {
            do {
                try host?.downloadStore?.save(.init(id: id, profileID: profileID, courseID: courseID,
                    fileName: destination?.lastPathComponent ?? savedFileName, url: retryURL?.absoluteString,
                    destinationLeaf: destination?.lastPathComponent, relPath: relPath, state: state,
                    receivedBytes: receivedBytes, totalBytes: totalBytes, failureReason: failureReason), resumeData: resumeData)
            } catch { failureReason = "다운로드 복구 기록을 저장하지 못했습니다. 저장 공간을 확인해 주세요." }
        }
        host?.emit("browser:download", payload)
    }
    func cancel(pause: Bool) async {
        guard !controlling else { return }; controlling = true; defer { controlling = false }
        guard state != "completed" && state != "cancelled" else { return }
        expectedCancellation = true
        if let download, !paused { resumeData = await withCheckedContinuation { continuation in download.cancel { continuation.resume(returning: $0) } } }
        if let download { receivedBytes = max(0, download.progress.completedUnitCount); totalBytes = max(0, download.progress.totalUnitCount) }
        observation = nil; download = nil; recoveryView = nil
        if pause, resumeData != nil { state = "progressing"; paused = true }
        else if pause { state = "interrupted"; paused = false; failureReason = "이 서버는 이어받기 정보를 제공하지 않습니다. 다시 받기를 선택해 주세요." }
        else { state = "cancelled"; paused = false; resumeData = nil }
        publish()
    }
    private func transferView() throws -> WKWebView {
        guard let host, host.isProfileAvailable(profileID) else { throw DesktopBrowserError.unavailable("다운로드 프로필이 삭제됐습니다.") }
        if let page, host.pages[page.tabID] === page { return page.webView }
        if let recoveryView { return recoveryView }
        // Resumption keeps the exact profile store. Private transfers cannot outlive their session.
        guard !isPrivate, let persistence = host.persistence else { throw DesktopBrowserError.unavailable("비공개 탭을 다시 열어 다운로드해 주세요.") }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = persistence.dataStore(profile: profileID, isPrivate: false)
        DesktopBrowserIdentity.configure(configuration)
        host.configurePrivacy(configuration.userContentController)
        let view = WKWebView(frame: .zero, configuration: configuration); recoveryView = view; return view
    }
    func resume() async throws {
        guard !controlling, let resumeData else { throw DesktopBrowserError.unavailable("이 다운로드는 이어받을 수 없습니다. 다시 받기를 선택해 주세요.") }
        controlling = true; defer { controlling = false }
        try await host?.prepareBrowserNetwork()
        let view = try transferView()
        download = await view.resumeDownload(fromResumeData: resumeData)
        self.resumeData = nil; expectedCancellation = false; paused = false; state = "progressing"; failureReason = nil
        observe(); publish()
    }
    func retry() async throws {
        if state == "completed" {
            guard !isChangingTransfer else { throw DesktopBrowserError.unavailable("과목 자료에 저장하고 있습니다. 잠시 기다려 주세요.") }
            guard relPath == nil else { return }
            guard let destination, courseID != nil, let callback = host?.onDownload else { throw DesktopBrowserError.unavailable("자료 저장을 다시 시작할 수 없습니다.") }
            savingMaterial = true; publish()
            try await importMaterial(destination, using: callback); return
        }
        if resumeData != nil { try await resume(); return }
        guard !controlling, let host, let retryURL, ["https", "http"].contains(retryURL.scheme ?? ""), retryURL.host != nil else { throw DesktopBrowserError.unavailable("원래 웹사이트에서 다시 다운로드해 주세요. 양식 제출은 자동으로 반복하지 않습니다.") }
        controlling = true; defer { controlling = false }
        try await host.prepareBrowserNetwork()
        let view = try transferView()
        download = await view.startDownload(using: host.navigationRequest(retryURL))
        expectedCancellation = false; paused = false; state = "progressing"; failureReason = nil
        destination = nil; observe(); publish()
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard self.download === download else { completionHandler(nil); return }
        do {
            guard let host else { completionHandler(nil); return }
            let base = isPrivate ? FileManager.default.temporaryDirectory.appendingPathComponent("BandalPrivateBrowserDownloads", isDirectory: true) : host.root.appendingPathComponent("Downloads", isDirectory: true)
            let folder = base.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let leaf = (suggestedFilename as NSString).lastPathComponent
            let safe = String(leaf.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: ":", with: "_")
            let name = String(safe.prefix(180))
            var file = folder.appendingPathComponent(name.isEmpty || name.hasPrefix(".") ? "다운로드" : name)
            if FileManager.default.fileExists(atPath: file.path) { file = folder.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + file.lastPathComponent) }
            destination = file; savedFileName = file.lastPathComponent; completionHandler(file); publish()
        } catch { failureReason = error.localizedDescription; state = "interrupted"; completionHandler(nil); publish() }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard self.download === download, state != "completed" else { return }
        state = "completed"; paused = false; resumeData = nil; observation = nil
        // Claim the import before publishing completion. Otherwise the visible
        // "save again" action can race this asynchronous automatic import.
        if !isPrivate, let destination, courseID != nil, let callback = host?.onDownload {
            savingMaterial = true; publish()
            Task { [self] in
                try? await importMaterial(destination, using: callback)
                recoveryView = nil
            }
        } else { publish(); recoveryView = nil }
    }
    private func importMaterial(_ file: URL, using callback: (URL, String?) async throws -> String?) async throws {
        defer { savingMaterial = false; publish() }
        do { relPath = try await callback(file, courseID); failureReason = nil }
        catch {
            failureReason = "파일은 보관했지만 과목에 추가하지 못했습니다: \(error.localizedDescription)"
            throw error
        }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard self.download === download, !expectedCancellation else { return }
        self.resumeData = resumeData; state = "interrupted"; paused = false; observation = nil
        failureReason = error.localizedDescription; publish(); recoveryView = nil
    }
}

extension DesktopBrowserHost {
    func pauseDownloadsForBackground() async {
        for item in downloads.values where item.state == "progressing" && !item.paused { await item.cancel(pause: true) }
    }
    func dismissDownload(_ request: [String: Any]) throws -> Any {
        let id = try Self.string(request, "id")
        guard let item = downloads[id], item.state != "progressing", !item.isChangingTransfer else { throw DesktopBrowserError.invalid("진행 중인 다운로드 또는 자료 저장") }
        if !item.isPrivate { try downloadStore?.dismiss(id) }
        downloads.removeValue(forKey: id); return ["ok": true]
    }
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
            // The import can finish between a download row snapshot and its
            // action. Resolve the current canonical material in this route too.
            if let onOpenMaterial { onOpenMaterial(course, relPath) }
            else { emit("ui:openMaterial", ["courseId": course, "relPath": relPath, "positionSec": 0, "playbackRate": 1]) }
            return ["ok": true]
        }
        guard let presenter = presentingController, presenter.presentedViewController == nil else { throw DesktopBrowserError.unavailable("다른 창을 닫은 뒤 다시 시도해 주세요.") }
        switch action {
        case "saveAs", "reveal": presenter.present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
        case "open":
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            let source = container ?? presenter.view
            share.popoverPresentationController?.sourceView = source
            share.popoverPresentationController?.sourceRect = CGRect(x: source?.bounds.midX ?? 0, y: 48, width: 1, height: 1)
            presenter.present(share, animated: true)
        default: throw DesktopBrowserError.invalid("다운로드 파일 동작")
        }
        return ["ok": true]
    }
}
