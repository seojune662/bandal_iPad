import XCTest
import UIKit
import WebKit
@testable import Bandal

@MainActor
final class NativePDFShapeTests: XCTestCase {
    func testLegacyNormalizedShapeStrokeMatchesRealWebKitSVGOnPortraitPaperAndEveryQuarterTurn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration), navigation = NativePDFShapeNavigation()
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = navigation; controller.view.addSubview(view)
        let width = 600.0, height = 900.0, cropX = 40.0, cropY = 70.0
        let style: [String: Any] = ["color": "ink", "width": 0.016, "opacity": 1.0]
        let objects: [[String: Any]] = [
            ["kind": "line", "data": ["points": [["x": 0.15, "y": 0.10], ["x": 0.85, "y": 0.10]]], "style": style],
            ["kind": "line", "data": ["points": [["x": 0.08, "y": 0.15], ["x": 0.08, "y": 0.85]]], "style": style],
            ["kind": "rect", "data": ["box": ["x": 0.2, "y": 0.25, "width": 0.25, "height": 0.25]], "style": style],
            ["kind": "ellipse", "data": ["box": ["x": 0.55, "y": 0.25, "width": 0.3, "height": 0.25]], "style": style],
            ["kind": "arrow", "data": ["points": [["x": 0.25, "y": 0.8], ["x": 0.7, "y": 0.65]]], "style": style]
        ]
        // These SVG elements and attributes are InkLayer's original normalized
        // contract. WebKit supplies an independent rasterization oracle for
        // anisotropic strokes, mitered corners, round caps and arrow joins.
        let angle = atan2((0.65-0.8)*1.5, 0.7-0.25), head = 0.016*4
        let left = "\(0.7-cos(angle-Double.pi/6)*head),\(0.65-sin(angle-Double.pi/6)*head/1.5)"
        let right = "\(0.7-cos(angle+Double.pi/6)*head),\(0.65-sin(angle+Double.pi/6)*head/1.5)"
        let svg = """
        <svg width="600" height="900" viewBox="0 0 1 1" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">
          <g fill="none" stroke="rgb(20,23,31)" stroke-width="0.016">
            <g stroke-linecap="round" stroke-linejoin="round"><line x1=".15" y1=".10" x2=".85" y2=".10"/><line x1=".08" y1=".15" x2=".08" y2=".85"/></g>
            <rect x=".2" y=".25" width=".25" height=".25"/>
            <ellipse cx=".7" cy=".375" rx=".15" ry=".125"/>
            <g stroke-linecap="round" stroke-linejoin="round"><line x1=".25" y1=".8" x2=".7" y2=".65"/><polyline points="\(left) .7,.65 \(right)"/></g>
          </g>
        </svg>
        """
        for rotation in [0, 90, 180, 270] {
            let size = rotation % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
            let canvasFromPDF: CGAffineTransform, css: String
            switch rotation {
            case 90: canvasFromPDF = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: -cropY, ty: -cropX); css = "matrix(0,1,-1,0,900,0)"
            case 180: canvasFromPDF = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: cropX+width, ty: -cropY); css = "matrix(-1,0,0,-1,600,900)"
            case 270: canvasFromPDF = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: cropY+height, ty: cropX+width); css = "matrix(0,-1,1,0,0,600)"
            default: canvasFromPDF = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -cropX, ty: cropY+height); css = "none"
            }
            let mapper = InkCoordinateMapper(canvasToPDF: canvasFromPDF.inverted(), geometry: InkPageGeometry(cropBox: CGRect(x: cropX, y: cropY, width: width, height: height), rotation: rotation))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let native = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                UIColor.white.setFill(); renderer.fill(CGRect(origin: .zero, size: size))
                for object in objects { NativePDFObjectRenderer.draw(object, in: renderer.cgContext, mapper: mapper, image: nil) }
            }
            view.frame = CGRect(origin: .zero, size: size)
            let loaded = expectation(description: "SVG loaded at rotation \(rotation)"); navigation.onFinish = { loaded.fulfill() }
            view.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white;overflow:hidden}svg{display:block;transform-origin:0 0;transform:\(css)}</style>\(svg)", baseURL: nil)
            await fulfillment(of: [loaded], timeout: 10)
            let metrics = try await view.evaluateJavaScript("JSON.stringify({innerWidth,innerHeight,scale:visualViewport.scale,offsetX:visualViewport.offsetLeft,offsetY:visualViewport.offsetTop,svg:(()=>{const r=document.querySelector('svg').getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})()})") as? String ?? ""
            let options = WKSnapshotConfiguration(); options.rect = view.bounds; options.snapshotWidth = NSNumber(value: size.width)
            let shot = try await view.takeSnapshot(configuration: options)
            let reference = UIGraphicsImageRenderer(size: size, format: format).image { _ in shot.draw(in: CGRect(origin: .zero, size: size)) }
            let a = try mask(native), b = try mask(reference)
            XCTAssertEqual(a.count, b.count)
            let union = zip(a,b).filter { $0 || $1 }.count, difference = zip(a,b).filter { $0 != $1 }.count
            if Double(difference) / Double(max(1, union)) >= 0.065 {
                for (name,image) in [("native",native),("webkit",reference)] {
                    let attachment = XCTAttachment(image: image); attachment.name = "Shape-\(rotation)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
                }
                let geometry = XCTAttachment(string: "\(metrics) UIKit bounds=\(view.bounds) inset=\(view.scrollView.adjustedContentInset) snapshot=\(shot.size)@\(shot.scale) native=\(native.size)@\(native.scale)")
                geometry.name = "Shape-\(rotation)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
            }
            XCTAssertGreaterThan(union, 10_000, "Reference must actually contain the SVG shapes")
            XCTAssertLessThan(Double(difference) / Double(max(1, union)), 0.065, "Native versus real SVG stroke pixels differ at rotation \(rotation)")
            let measured = try XCTUnwrap(NativePDFObjectRenderer.hitBounds(objects[0], mapper: mapper))
            XCTAssertEqual(rotation % 180 == 0 ? measured.height : measured.width, 14.4, accuracy: 0.001)
            XCTAssertEqual(rotation % 180 == 0 ? measured.width : measured.height, 429.6, accuracy: 0.001)
        }
    }
    private func mask(_ image: UIImage) throws -> [Bool] {
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width*height*4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] < 150 }
    }
}

@MainActor
private final class NativePDFShapeNavigation: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
}
