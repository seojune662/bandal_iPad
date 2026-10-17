import Foundation
import UIKit

/// Kept behind both the isolated UI-test storage root and an explicit launch
/// argument, so production paper creation can never become a test document.
enum NativePDFPageTestFixture {
    static func makeIfRequested(root: URL) throws -> Data? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard root.lastPathComponent == "BandalDesktop-Native-UI-Tests", args.contains("--native-ui-testing"), args.contains("--native-pages-fixture") else { return nil }
        let rect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        return UIGraphicsPDFRenderer(bounds: rect).pdfData { renderer in
            for title in ["Page One", "Page Two", "Page Three"] {
                renderer.beginPage()
                UIColor.white.setFill(); UIRectFill(rect)
                (title as NSString).draw(in: CGRect(x: 165, y: 375, width: 320, height: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
            }
        }
        #else
        return nil
        #endif
    }
}
