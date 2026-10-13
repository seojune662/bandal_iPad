import CoreText
import CryptoKit
import PDFKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct OfficeWorkspaceView: View {
    let url: URL
    let materialID: String
    let revision: String
    let loadPage: (Int) -> Data?
    let savePage: (Int, Data) -> Void
    let onExport: (URL) -> Void
    @State private var convertedPDF: URL?
    @State private var conversionError: String?
    @State private var attempt = 0

    private var extensionName: String { url.pathExtension.lowercased() }
    private var identity: String { materialID + ":" + revision }
    private var isWebDocument: Bool { ["docx", "xlsx", "xls", "csv", "tsv", "hwp", "hwpx", "pptx"].contains(extensionName) }

    var body: some View {
        Group {
            if !FileManager.default.fileExists(atPath: url.path) {
                ContentUnavailableView("원본 파일이 필요해요", systemImage: "doc.badge.arrow.up", description: Text("동기화에서 자료를 내려받거나 파일을 다시 가져오세요."))
            } else if extensionName == "pptx", let convertedPDF {
                PDFWorkspaceView(documentURL: convertedPDF, materialID: materialID, revision: revision,
                                 loadPage: loadPage, savePage: savePage, onExport: onExport)
                    .id(identity)
            } else if isWebDocument {
                VStack(spacing: 0) {
                    if let conversionError {
                        HStack { Text(conversionError).font(.caption); Spacer(); Button("다시 열기") { self.conversionError = nil; attempt += 1 } }.padding(12)
                    }
                    OfficeWebView(url: url, materialID: materialID, revision: revision,
                                  onPDF: { convertedPDF = $0 }, onError: { conversionError = $0 })
                        .id(identity + ":\(attempt)")
                }
            } else {
                VStack(spacing: 0) {
                    if extensionName == "ppt" {
                        Text("구형 PPT는 시스템 미리보기로 열립니다. 슬라이드 필기는 PPTX 또는 PDF로 변환한 자료에서 사용할 수 있어요.")
                            .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1))
                    }
                    OfficeQuickLook(url: url)
                }
            }
        }
        .task(id: identity) {
            convertedPDF = nil
            if extensionName == "pptx", let cached = try? OfficePDFCache.destination(materialID: materialID, revision: revision),
               PDFDocument(url: cached)?.pageCount ?? 0 > 0 { convertedPDF = cached }
        }
    }
}

private struct OfficeQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url { context.coordinator.url = url; controller.reloadData() }
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(_ url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

private struct OfficeWebView: UIViewRepresentable {
    let url: URL
    let materialID: String
    let revision: String
    let onPDF: (URL) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(url: url, materialID: materialID, revision: revision, onPDF: onPDF, onError: onError) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(OfficeAssets(source: url), forURLScheme: "bandal-document")
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "bandalDocument")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        view.load(URLRequest(url: URL(string: "bandal-document://app/documents.html")!))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelled = true
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "bandalDocument", contentWorld: .page)
        uiView.stopLoading()
        coordinator.cleanUp()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
        weak var webView: WKWebView?
        let url: URL
        let materialID: String
        let revision: String
        let onPDF: (URL) -> Void
        let onError: (String) -> Void
        var cancelled = false
        private var pages: [OfficePDFCache.Page] = []
        private var expectedCount: Int?
        private let staging = FileManager.default.temporaryDirectory.appendingPathComponent("BandalOffice-" + UUID().uuidString, isDirectory: true)

        init(url: URL, materialID: String, revision: String, onPDF: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.url = url; self.materialID = materialID; self.revision = revision; self.onPDF = onPDF; self.onError = onError
        }
        func cleanUp() { try? FileManager.default.removeItem(at: staging) }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard !cancelled, message.frameInfo.isMainFrame, message.webView === webView,
                  message.frameInfo.securityOrigin.protocol == "bandal-document", message.frameInfo.securityOrigin.host == "app",
                  message.frameInfo.request.url?.path == "/documents.html",
                  let body = message.body as? [String: Any], body["version"] as? Int == 1,
                  let type = body["type"] as? String else { replyHandler(nil, "Invalid document origin"); return }
            if type == "ready" {
                let document: [String: Any] = ["version": 1, "materialID": materialID, "fileName": url.lastPathComponent,
                                               "extension": url.pathExtension.lowercased(), "source": "bandal-document://app/source/document"]
                webView?.callAsyncJavaScript("window.bandalOffice.load(document)", arguments: ["document": document], in: nil, in: .page) { [weak self] result in
                    if case .failure(let error) = result { self?.onError(error.localizedDescription) }
                }
                replyHandler(["accepted": true], nil); return
            }
            guard body["materialID"] as? String == materialID else { replyHandler(nil, "Wrong document"); return }
            do {
                switch type {
                case "slide":
                    guard let index = body["index"] as? Int, index == pages.count,
                          let count = body["count"] as? Int, (1...500).contains(count),
                          expectedCount == nil || expectedCount == count,
                          let width = body["width"] as? Double, width.isFinite, width > 0, width < 10000,
                          let height = body["height"] as? Double, height.isFinite, height > 0, height < 10000,
                          let png = body["png"] as? String, png.count < 32 * 1024 * 1024,
                          let bytes = Data(base64Encoded: png), UIImage(data: bytes) != nil else { throw OfficeError.invalidPage }
                    expectedCount = count
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let image = staging.appendingPathComponent("\(index).png")
                    try bytes.write(to: image, options: .atomic)
                    let runsData = try JSONSerialization.data(withJSONObject: body["text"] as? [[String: Any]] ?? [])
                    let runs = try JSONDecoder().decode([OfficePDFCache.TextRun].self, from: runsData)
                    guard runs.count <= 20000, runs.allSatisfy(\.isValid) else { throw OfficeError.invalidPage }
                    pages.append(.init(image: image, width: width, height: height, text: runs))
                    replyHandler(["accepted": true], nil)
                case "complete":
                    guard let count = body["count"] as? Int, count == pages.count, count == expectedCount, !pages.isEmpty else { throw OfficeError.invalidPage }
                    let destination = try OfficePDFCache.destination(materialID: materialID, revision: revision)
                    // Images are decoded one page at a time; no full-deck bitmap array.
                    try OfficePDFCache.write(pages: pages, to: destination)
                    guard PDFDocument(url: destination)?.pageCount == count else { throw OfficeError.invalidPage }
                    replyHandler(["accepted": true], nil)
                    cleanUp()
                    onPDF(destination)
                case "error":
                    onError(String((body["message"] as? String ?? "문서를 열지 못했어요.").prefix(500)))
                    replyHandler(["accepted": true], nil)
                default: replyHandler(nil, "Unknown document operation")
                }
            } catch {
                onError("슬라이드를 준비하지 못했어요: \(error.localizedDescription)")
                replyHandler(nil, "Document conversion failed")
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let target = navigationAction.request.url
            decisionHandler(target?.scheme == "bandal-document" && target?.host == "app" && target?.path == "/documents.html" ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            pages.removeAll(); expectedCount = nil; cleanUp()
            onError("문서 처리에 필요한 메모리가 부족했어요. 다른 자료 탭을 닫고 다시 열어 주세요.")
        }
    }
}

private enum OfficeError: Error { case invalidPage }

private enum OfficePDFCache {
    struct TextRun: Decodable {
        let text: String
        let x: Double, y: Double, width: Double, height: Double, fontSize: Double, rotation: Double
        var isValid: Bool { text.utf8.count <= 100000 && [x, y, width, height, fontSize, rotation].allSatisfy { $0.isFinite && abs($0) < 1_000_000 } }
    }
    struct Page { let image: URL; let width: Double; let height: Double; let text: [TextRun] }
    static func destination(materialID: String, revision: String) throws -> URL {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OfficePDF", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(("renderer-v1:" + materialID + ":" + revision).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".pdf")
    }
    static func write(pages: [Page], to destination: URL) throws {
        let output = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        do {
            try renderer.writePDF(to: output) { rendererContext in
                for page in pages {
                    autoreleasepool {
                        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
                        rendererContext.beginPage(withBounds: bounds, pageInfo: [:])
                        UIImage(contentsOfFile: page.image.path)?.draw(in: bounds)
                        let context = rendererContext.cgContext
                        for run in page.text where !run.text.isEmpty {
                            context.saveGState()
                            context.translateBy(x: run.x, y: run.y + max(1, run.height) * 0.8)
                            context.rotate(by: run.rotation * .pi / 180)
                            context.scaleBy(x: 1, y: -1)
                            context.textMatrix = .identity
                            context.setTextDrawingMode(.invisible)
                            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, run.fontSize), nil)
                            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
                            let line = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: attributes))
                            let measured = CTLineGetTypographicBounds(line, nil, nil, nil)
                            if measured > 0 && run.width > 0 { context.scaleBy(x: run.width / measured, y: 1) }
                            context.textPosition = .zero
                            CTLineDraw(line, context)
                            context.restoreGState()
                        }
                    }
                }
            }
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: output) }
            else { try FileManager.default.moveItem(at: output, to: destination) }
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}

private final class OfficeAssets: NSObject, WKURLSchemeHandler {
    let source: URL
    init(source: URL) { self.source = source }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "bandal-document", url.host == "app",
              let root = Bundle.main.resourceURL?.appendingPathComponent("Editor", isDirectory: true) else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return }
        let file: URL
        if url.path == "/source/document" { file = source }
        else {
            let path = url.path.removingPercentEncoding ?? url.path
            file = root.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path).standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else { urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        }
        guard let info = try? file.resourceValues(forKeys: [.fileSizeKey]), (info.fileSize ?? 0) <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { urlSchemeTask.didFailWithError(URLError(.cannotDecodeContentData)); return }
        let mime: String
        switch file.pathExtension {
        case "js", "mjs": mime = "text/javascript"
        case "html": mime = "text/html"
        case "css": mime = "text/css"
        case "wasm": mime = "application/wasm"
        default: mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
