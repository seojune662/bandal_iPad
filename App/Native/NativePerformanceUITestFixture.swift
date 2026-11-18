#if DEBUG
import UIKit

/// `--native-perf-fixture`: each course gets two 40-page lecture PDFs (text, a picture per page), one of them with
/// a few hundred pen strokes, a Markdown note and a folder of thirty small files, so switching courses and opening
/// tabs can be timed on something the size of a real course. Kept behind the isolated UI-test root.
@MainActor
enum NativePerformanceUITestFixture {
    static let argument = "--native-perf-fixture"
    static var requested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--native-ui-testing") && arguments.contains(argument)
    }
    private static var seeded = Set<String>()
    private static var lecture: Data?

    static func seedIfRequested(store: NativeWorkspaceStore, courseID: String?) async {
        guard requested, let courseID, store.root.lastPathComponent.hasPrefix("BandalDesktop-Native-UI-Tests"), seeded.insert(courseID).inserted else { return }
        do {
            let page = CGRect(x: 0, y: 0, width: 960, height: 540)
            let data = lecture ?? render(page: page)
            lecture = data
            for name in ["강의 1.pdf", "강의 2.pdf"] {
                _ = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "", "fileName": name, "encoding": "base64", "data": data.base64EncodedString()])
            }
            for line in 0..<12 {
                for stroke in NativeHandwritingFixture.strokes("필기 줄 \(line + 1) 엔트로피 dS=dQ/T", at: CGPoint(x: 60, y: 60 + CGFloat(line % 6) * 70), fontSize: 34, pageSize: page.size) {
                    _ = try await store.invoke("drawings:create", stroke.merging(["courseId": courseID, "relPath": "강의 1.pdf", "page": 1 + line / 6, "kind": "ink"]) { _, new in new })
                }
            }
            _ = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "", "fileName": "정리.md", "encoding": "utf8",
                "data": "# 정리\n\n" + (1...40).map { "- 항목 \($0): 엔트로피와 열역학 제2법칙" }.joined(separator: "\n") + "\n"])
            _ = try await store.invoke("materials:createFolder", ["courseId": courseID, "dirRelPath": "", "name": "과제"])
            for index in 1...30 {
                _ = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "과제", "fileName": "과제 \(index).md", "encoding": "utf8", "data": "# 과제 \(index)\n"])
            }
            await store.refreshMaterials()
        } catch { store.errorMessage = "perf fixture: " + error.localizedDescription }
    }

    private static func render(page: CGRect) -> Data {
        UIGraphicsPDFRenderer(bounds: page).pdfData { renderer in
            for index in 0..<40 {
                renderer.beginPage()
                UIColor.white.setFill(); UIRectFill(page)
                ("\(index + 1). 열역학과 엔트로피" as NSString).draw(at: CGPoint(x: 48, y: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor.black])
                for row in 0..<9 {
                    ("• 고립계의 엔트로피는 감소하지 않는다. 가역 과정에서 dS = dQ/T 이고 상태 함수다. (\(row + 1))" as NSString)
                        .draw(at: CGPoint(x: 56, y: 100 + CGFloat(row) * 36), withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.darkGray])
                }
                picture(seed: index).draw(in: CGRect(x: 640, y: 300, width: 280, height: 200))
            }
        }
    }
    /// A photo-like bitmap (gradient and noise) so each page carries an image as lecture slides do.
    private static func picture(seed: Int) -> UIImage {
        let size = CGSize(width: 560, height: 400)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(hue: CGFloat(seed % 12) / 12, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor, UIColor.white.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            var generator = SystemRandomNumberGenerator()
            for _ in 0..<1500 {
                UIColor(white: CGFloat.random(in: 0...1, using: &generator), alpha: 0.35).setFill()
                UIRectFill(CGRect(x: CGFloat.random(in: 0..<size.width, using: &generator), y: CGFloat.random(in: 0..<size.height, using: &generator), width: 6, height: 6))
            }
        }
    }
}
#endif
