import Foundation
import CryptoKit
import WebKit

/// The desktop hover service owns its original queue/cache/three-second limit.
/// This boundary replaces only its disposable utility process. No worker gets
/// a real path, native bridge, network connection, or writable filesystem.
@MainActor
final class DesktopHoverPreviewService {
    private let root: URL
    private let script: () throws -> String
    private var workers: [String: HoverParser] = [:]
    private struct Job { let token: UUID; let task: Task<[String: Any], Error> }
    private var jobs: [String: Job] = [:]
    init(root: URL, script: (() throws -> String)? = nil) {
        self.root = root
        self.script = script ?? { try String(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("DesktopNative/hover-worker.js"), encoding: .utf8) }
    }
    func canHandle(_ channel: String) -> Bool { ["native:hoverExtract", "native:hoverTerminate"].contains(channel) }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        guard let id = request["workerID"] as? String, UUID(uuidString: id) != nil else { throw DesktopRuntimeError("Invalid preview worker") }
        if channel == "native:hoverTerminate" {
            jobs.removeValue(forKey: id)?.task.cancel()
            if let worker = workers.removeValue(forKey: id) { await worker.terminate() }
            return ["ok": true]
        }
        guard channel == "native:hoverExtract", jobs[id] == nil, jobs.count < 2,
              let input = request["input"] as? [String: Any], let path = input["absolutePath"] as? String,
              let ext = input["extension"] as? String,
              Self.extensions.contains(ext), URL(fileURLWithPath: path).pathExtension.lowercased() == String(ext.dropFirst()) else { throw DesktopRuntimeError("Invalid preview request") }
        let root = self.root
        let token = UUID()
        let task = Task { () throws -> [String: Any] in
            let loading = Task.detached(priority: .utility) { try Self.snapshot(path: path, extension: ext, root: root) }
            let snapshot = try await withTaskCancellationHandler { try await loading.value } onCancel: { loading.cancel() }
            try Task.checkCancellation()
            let parser: HoverParser
            if let existing = workers[id] { parser = existing }
            else {
                guard workers.count < 2 else { throw DesktopRuntimeError("Too many preview workers") }
                parser = HoverParser(); workers[id] = parser
            }
            return try await parser.extract(snapshot: snapshot, script: script())
        }
        jobs[id] = Job(token: token, task: task)
        defer { if jobs[id]?.token == token { jobs.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static let extensions: Set<String> = [".docx", ".xlsx", ".xls", ".csv", ".tsv", ".pptx", ".ppt", ".hwp", ".hwpx", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".avif", ".heic", ".svg"]
    private struct Snapshot: Sendable {
        var extensionName: String
        var bytes: Data
        var size: Int64
        var hash: String
        var cached: Data?
        var cachedSize: Int64?
    }
    nonisolated private static func snapshot(path: String, extension ext: String, root: URL) throws -> Snapshot {
        let file = try DesktopMaterialFile(path: path, root: root)
        let delimited = ext == ".csv" || ext == ".tsv"
        let image = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".avif", ".heic", ".svg"].contains(ext)
        let limit = delimited ? 64 * 1024 + 1 : image ? 4 * 1024 * 1024 : 32 * 1024 * 1024
        guard delimited || file.size <= limit else { throw DesktopRuntimeError("Preview file exceeds limit") }
        func capture(_ file: DesktopMaterialFile, limit: Int) throws -> Data {
            var result = Data()
            while result.count < min(Int64(limit), file.size) {
                try Task.checkCancellation()
                let chunk = try file.read(offset: UInt64(result.count), count: min(256 * 1024, limit - result.count))
                guard !chunk.isEmpty else { throw DesktopRuntimeError("Preview file changed while reading") }
                result.append(chunk)
            }
            _ = try file.read(offset: UInt64(result.count), count: 0)
            return result
        }
        let bytes = try capture(file, limit: limit)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var cached: Data?
        var cachedSize: Int64?
        if ext == ".ppt" {
            let path = root.appendingPathComponent("ConvertedPresentations/\(hash).pptx")
            if FileManager.default.fileExists(atPath: path.path) {
                let cache = try DesktopMaterialFile(path: path.path, root: root)
                cachedSize = cache.size
                cached = cache.size > 32 * 1024 * 1024 ? Data() : try capture(cache, limit: 32 * 1024 * 1024)
            }
        }
        return Snapshot(extensionName: ext, bytes: bytes, size: file.size, hash: hash, cached: cached, cachedSize: cachedSize)
    }

    @MainActor
    private final class HoverParser: NSObject, WKNavigationDelegate {
        private let view: WKWebView
        private var ready: CheckedContinuation<Void, Error>?
        private var loaded = false
        private var terminated = false
        override init() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            view = WKWebView(frame: .zero, configuration: configuration)
            super.init(); view.navigationDelegate = self
        }
        func extract(snapshot: Snapshot, script: String) async throws -> [String: Any] {
            try await withTaskCancellationHandler {
                guard !terminated else { throw CancellationError() }
                if !loaded {
                    try await withCheckedThrowingContinuation { continuation in
                        ready = continuation
                        view.loadHTMLString("<html><head><meta http-equiv=Content-Security-Policy content=\"default-src 'none'; script-src blob:; worker-src blob:; connect-src 'none'; base-uri 'none'; form-action 'none'\"></head><body></body></html>", baseURL: nil)
                    }
                    loaded = true
                }
                try Task.checkCancellation()
                var files: [[String: Any]] = [["path": "/source/file" + snapshot.extensionName, "data": snapshot.bytes.base64EncodedString(), "size": snapshot.size]]
                if let cached = snapshot.cached { files.append(["path": "/cache/file.pptx", "data": cached.base64EncodedString(), "size": snapshot.cachedSize ?? Int64(cached.count)]) }
                let result = try await view.callAsyncJavaScript(Self.run, arguments: ["source": script, "extensionName": snapshot.extensionName, "hash": snapshot.hash, "files": files], in: nil, contentWorld: .page)
                guard !terminated, let content = result as? [String: Any], let kind = content["kind"] as? String,
                      ["text", "markdown", "table", "slides", "image", "unsupported"].contains(kind),
                      JSONSerialization.isValidJSONObject(content), try JSONSerialization.data(withJSONObject: content).count <= 6 * 1024 * 1024 else { throw DesktopRuntimeError("Invalid preview result") }
                return content
            } onCancel: { Task { @MainActor [weak self] in await self?.terminate() } }
        }
        func terminate() async {
            guard !terminated else { return }; terminated = true
            let pending = ready; ready = nil; pending?.resume(throwing: CancellationError())
            _ = try? await view.evaluateJavaScript("globalThis.__hoverWorker?.terminate();globalThis.__hoverWorker=null;globalThis.__hoverReject?.(new Error('Preview terminated'));globalThis.__hoverReject=null")
            view.stopLoading()
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let pending = ready; ready = nil; pending?.resume() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let pending = ready; ready = nil; pending?.resume(throwing: error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { self.webView(webView, didFail: navigation, withError: error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { let pending = ready; ready = nil; pending?.resume(throwing: URLError(.networkConnectionLost)) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
        private static let run = """
        if (!globalThis.__hoverWorker) {
          const url=URL.createObjectURL(new Blob([source],{type:'text/javascript'}));
          globalThis.__hoverWorker=new Worker(url);URL.revokeObjectURL(url);
        }
        const worker=globalThis.__hoverWorker;
        return await new Promise((resolve,reject)=>{
          globalThis.__hoverReject=reject;
          worker.onerror=event=>{globalThis.__hoverReject=null;reject(new Error(event.message||'Preview worker failed'))};
          worker.onmessage=event=>{globalThis.__hoverReject=null;resolve(event.data.content)};
          const snapshots=files.map(file=>{const value=atob(file.data),bytes=new Uint8Array(value.length);for(let i=0;i<value.length;i++)bytes[i]=value.charCodeAt(i);return{path:file.path,size:file.size,bytes:bytes.buffer}});
          worker.postMessage({id:1,extension:extensionName,sha256:hash,files:snapshots},snapshots.map(file=>file.bytes));
        });
        """
    }
}
