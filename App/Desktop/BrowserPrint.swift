import Foundation
import UIKit
import WebKit

@MainActor
private final class BrowserPrintRenderer: UIPrintPageRenderer {
    let sheet: CGRect
    init(size: CGSize) { sheet = CGRect(origin: .zero, size: size); super.init() }
    override var paperRect: CGRect { sheet }
    override var printableRect: CGRect { sheet.insetBy(dx: 36, dy: 36) }
}

@MainActor
enum BrowserPrint {
    static func pdf(webView: WKWebView, options: [String: Any]) async throws -> Data {
        let pageSize = options["pageSize"] as? String ?? "A4"
        guard ["A4", "Letter"].contains(pageSize) else { throw DesktopBrowserError.unsupported("인쇄 용지 \(pageSize)") }
        var size = pageSize == "Letter" ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
        if options["landscape"] as? Bool == true { size = CGSize(width: size.height, height: size.width) }
        let styleID = "bandal-print-" + UUID().uuidString
        let background = options["printBackground"] as? Bool ?? true
        _ = try await webView.callAsyncJavaScript("const style=document.createElement('style');style.id=id;style.textContent=background?'@media print{*{-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}}':'@media print{*{background-image:none!important;background-color:transparent!important}}';document.head.append(style)", arguments: ["id": styleID, "background": background], in: nil, contentWorld: .defaultClient)
        let renderer = BrowserPrintRenderer(size: size)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        let count = renderer.numberOfPages
        let data: Data?
        if (1...500).contains(count) {
            data = UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { context in
                for page in 0..<count { context.beginPage(); renderer.drawPage(at: page, in: renderer.paperRect) }
            }
        } else { data = nil }
        _ = try? await webView.callAsyncJavaScript("document.getElementById(id)?.remove()", arguments: ["id": styleID], in: nil, contentWorld: .defaultClient)
        guard let data else { throw DesktopBrowserError.unavailable("인쇄할 페이지가 없거나 500페이지를 초과했습니다.") }
        return data
    }
}
