import XCTest
import WebKit
@testable import Bandal

@MainActor
final class DesktopCaptureTests: XCTestCase {
    private func fixtureImage(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.blue.setFill(); context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
    }
    private func decoded(_ value: Any) throws -> UIImage {
        let attachment = try XCTUnwrap(value as? [String: String])
        XCTAssertEqual(attachment["mediaType"], "image/png")
        return try XCTUnwrap(UIImage(data: XCTUnwrap(Data(base64Encoded: XCTUnwrap(attachment["dataBase64"])))))
    }
    private func mounted() throws -> (UIWindow, UIView) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        controller.view.addSubview(container)
        return (window, container)
    }
    private func runtime() -> DesktopRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-\(UUID().uuidString)")
        return DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
    }
    private func selectionReady(_ service: DesktopCaptureService) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let web = service.selectionWebView,
               (try? await web.evaluateJavaScript("document.querySelector('.screen-selection')?.style.backgroundImage.startsWith('url(\"data:image/png;base64,') || false")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw DesktopRuntimeError("Original capture renderer did not receive its snapshot")
    }
    func testOriginalPixelRoundingAndBoundedAttachment() throws {
        let image = fixtureImage(CGSize(width: 1600, height: 1200))
        let cropped = try DesktopCaptureService.crop(image, rect: CGRect(x: 100.25, y: 50.25, width: 100, height: 70), viewport: CGSize(width: 400, height: 300))
        XCTAssertEqual(cropped.cgImage?.width, 400); XCTAssertEqual(cropped.cgImage?.height, 280)
        let edge = try DesktopCaptureService.crop(image, rect: CGRect(x: -2, y: -3, width: 10, height: 10), viewport: CGSize(width: 400, height: 300))
        XCTAssertEqual(edge.cgImage?.width, 32); XCTAssertEqual(edge.cgImage?.height, 28)
        XCTAssertThrowsError(try DesktopCaptureService.crop(image, rect: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), viewport: CGSize(width: 400, height: 300)))
        XCTAssertThrowsError(try DesktopCaptureService.crop(image, rect: CGRect(x: 0, y: 0, width: 1, height: 10), viewport: CGSize(width: 400, height: 300)))
        let output = try decoded(DesktopCaptureService.attachment(fixtureImage(CGSize(width: 2400, height: 1200))))
        XCTAssertEqual(output.cgImage?.width, 1800); XCTAssertEqual(output.cgImage?.height, 900)
    }
    func testActualWKSnapshotReturnsOriginalAttachmentContract() async throws {
        let (window, container) = try mounted(); defer { window.isHidden = true }
        let web = WKWebView(frame: container.bounds); container.addSubview(web)
        web.loadHTMLString("<body style='margin:0;background:#00ff00'><p>실제 반달 화면</p></body>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while (try? await web.evaluateJavaScript("document.body?.textContent.includes('실제 반달 화면')")) as? Bool != true, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        let service = DesktopCaptureService(runtime: runtime()); service.attach(to: container)
        let image = try decoded(try await service.handle(channel: "assistant:capture", request: ["region": false]))
        XCTAssertGreaterThan(image.cgImage?.width ?? 0, 100); XCTAssertEqual(image.size.width / image.size.height, 4 / 3, accuracy: 0.01)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -image.size.width / 2, y: -image.size.height / 2); image.draw(at: .zero)
        }
        let color = try XCTUnwrap(pixel.cgImage?.dataProvider?.data)
        let components = try XCTUnwrap(CFDataGetBytePtr(color))
        XCTAssertGreaterThan(components[1], 200, "Real WK content must be captured, rather than a blank UIKit backing layer")
    }
    func testOriginalSelectionUIOnlyHasSelectionBridgeAndReturnsCrop() async throws {
        let (window, container) = try mounted(); defer { window.isHidden = true }
        let service = DesktopCaptureService(runtime: runtime(), snapshot: { _ in self.fixtureImage(CGSize(width: 800, height: 600)) }); service.attach(to: container)
        let capture = Task { try await service.handle(channel: "assistant:capture", request: ["region": true]) }
        let web = try await selectionReady(service)
        let status = try await web.evaluateJavaScript("document.querySelector('[role=status]')?.textContent") as? String
        XCTAssertEqual(status, "질문할 영역을 드래그하세요 · Esc 취소")
        let denied = try await web.callAsyncJavaScript("try {await window.bandal.invoke('courses:list',{});return false}catch{return true}", arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(denied, true)
        do { _ = try await service.handle(channel: "assistant:capture", request: ["region": false]); XCTFail("Concurrent capture must reject") } catch {}
        _ = try await web.callAsyncJavaScript("await window.bandal.invoke('assistant:selection',{action:'select',rect:{x:100,y:50,width:200,height:150}})", arguments: [:], in: nil, contentWorld: .page)
        let image = try decoded(try await capture.value)
        XCTAssertEqual(image.cgImage?.width, 400); XCTAssertEqual(image.cgImage?.height, 300); XCTAssertNil(service.selectionWebView)
    }
    func testSelectionCancelAndResizeDoNotCreateAttachments() async throws {
        let (window, container) = try mounted(); defer { window.isHidden = true }
        let service = DesktopCaptureService(runtime: runtime(), snapshot: { _ in self.fixtureImage(CGSize(width: 800, height: 600)) }); service.attach(to: container)
        let capture = Task { try await service.handle(channel: "assistant:capture", request: ["region": true]) }
        let web = try await selectionReady(service)
        _ = try await web.callAsyncJavaScript("await window.bandal.invoke('assistant:selection',{action:'cancel'})", arguments: [:], in: nil, contentWorld: .page)
        let cancelled = try await capture.value; XCTAssertTrue(cancelled is NSNull); XCTAssertNil(service.selectionWebView)
        let resized = Task { try await service.handle(channel: "assistant:capture", request: ["region": true]) }
        let second = try await selectionReady(service)
        second.frame.size.width += 10; second.setNeedsLayout(); second.layoutIfNeeded()
        let result = try await resized.value; XCTAssertTrue(result is NSNull); XCTAssertNil(service.selectionWebView)
    }
}
