import XCTest
import PDFKit
import MetalKit
@testable import Bandal

@MainActor
final class NativePDFRenderViewportTests: XCTestCase {
    func testDensityIncludesAncestorZoomWhileMemoryDependsOnlyOnVisibleScreenPixels() throws {
        let page = CGRect(x: 0, y: 0, width: 600, height: 900)
        let visible = CGRect(x: 101.125, y: 301.25, width: 200, height: 225)
        let viewport = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: page, visibleRect: visible,
            canvasToWindow: CGAffineTransform(scaleX: 4, y: 4), screenScale: 2))
        XCTAssertEqual(viewport.canvasRect, visible)
        XCTAssertEqual(viewport.pixelScale, 8)
        XCTAssertEqual(viewport.pixelSize, CGSize(width: 1600, height: 1800))
        XCTAssertEqual(viewport.localPoint(CGPoint(x: 141.125, y: 341.25)), CGPoint(x: 40, y: 40))
        let thirteenInchVisible = CGRect(x: 100, y: 100, width: 1366.0/4, height: 1024.0/4)
        let largePage = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: CGRect(x: 0,y: 0,width: 60_000,height: 90_000),
            visibleRect: thirteenInchVisible, canvasToWindow: CGAffineTransform(scaleX: 4,y: 4), screenScale: 2))
        XCTAssertEqual(largePage.pixelScale, 8, "The full 13-inch screen remains sharp at 4x")
        XCTAssertEqual(largePage.pixelSize, CGSize(width: 2732,height: 2048))
        XCTAssertLessThan(largePage.pixelSize.width*largePage.pixelSize.height, NativePDFRenderViewport.maximumPixels)
        let extreme = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: page, visibleRect: page,
            canvasToWindow: CGAffineTransform(scaleX: 100,y: 100), screenScale: 3))
        XCTAssertLessThanOrEqual(extreme.pixelSize.width*extreme.pixelSize.height, NativePDFRenderViewport.maximumPixels+10_000)
        XCTAssertLessThanOrEqual(max(extreme.pixelSize.width,extreme.pixelSize.height), NativePDFRenderViewport.maximumDimension)
        XCTAssertNil(NativePDFRenderViewport(canvasBounds: page, visibleRect: CGRect(x: 700,y: 0,width: 10,height: 10), canvasToWindow: .identity, screenScale: 2))
    }

    func testFourTimesZoomRerendersRealPDFGlyphsSharplyInBothScrolledRegions() throws {
        let (document, mapper) = try fixture()
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(page.string?.contains("Sharp PDF text") == true, "Fixture must contain real PDF text")
        for region in [CGRect(x: 20,y: 40,width: 180,height: 100), CGRect(x: 340,y: 490,width: 180,height: 100)] {
            let viewport = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: CGRect(x: 0,y: 0,width: 600,height: 900),
                visibleRect: region, canvasToWindow: CGAffineTransform(scaleX: 4,y: 4), screenScale: 2))
            let sharp = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page,mapper: mapper,bounds: region,scale: viewport.pixelScale))
            XCTAssertEqual(sharp.cgImage?.width, 1440); XCTAssertEqual(sharp.cgImage?.height, 800)
            let low = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page,mapper: mapper,bounds: region,scale: 2))
            let format = UIGraphicsImageRendererFormat(); format.scale = 8; format.opaque = true
            let enlarged = UIGraphicsImageRenderer(size: region.size,format: format).image { _ in low.draw(in: CGRect(origin: .zero,size: region.size)) }
            let crispEdges = try grayEdgeFraction(sharp), blurryEdges = try grayEdgeFraction(enlarged)
            XCTAssertLessThan(crispEdges, blurryEdges * 0.8, "4x glyphs must be rasterized again, not magnify an old full-page bitmap")
        }
    }

    func testSurfaceKeepsOnlyVisibleChildrenAndMovesTheirSceneAndSelectionTogether() async throws {
        let (document, mapper) = try fixture(), page = try XCTUnwrap(document.page(at: 0))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.frame = CGRect(x: 0,y: 0,width: 600,height: 800)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let holder = UIView(frame: CGRect(x: 0,y: 0,width: 600,height: 900))
        holder.layer.anchorPoint = .zero; holder.layer.position = .zero
        holder.transform = CGAffineTransform(scaleX: 4,y: 4); controller.view.addSubview(holder)
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(x: 0,y: 0,width: 600,height: 900)))
        surface.pdfPage = page; surface.mapper = mapper
        surface.selectedTextRects = [["x": 0.05,"y": 0.05,"width": 0.1,"height": 0.02]]
        surface.selectionBox = ["x": 0.05,"y": 0.05,"width": 0.1,"height": 0.02]
        surface.selectionResizable = true
        var visible = CGRect(x: 20,y: 40,width: 100,height: 100)
        surface.viewportProvider = { visible }
        holder.addSubview(surface); surface.layoutIfNeeded(); surface.refreshViewport()
        let imageView = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first)
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        let metalLayer = try XCTUnwrap(metal.layer as? CAMetalLayer)
        // Keep test visibility independent of the host window's physical size.
        for region in [CGRect(x: 20,y: 40,width: 100,height: 100), CGRect(x: 40,y: 70,width: 100,height: 100)] {
            let previousViewport = surface.renderViewport, previousImage = imageView.image
            visible = region; surface.refreshViewport()
            let viewport = try XCTUnwrap(surface.renderViewport)
            let expectedGeometry = try XCTUnwrap(NativePDFMetalInk.FrameGeometry(canvasRect: viewport.canvasRect,
                pixelScale: viewport.pixelScale, canvasToPage: mapper.canvasToPDF))
            func isSettled() -> Bool {
                !imageView.isHidden && imageView.image != nil &&
                    (previousViewport == viewport || imageView.image !== previousImage) &&
                    imageView.frame == viewport.canvasRect &&
                    imageView.image?.cgImage?.width == Int(viewport.pixelSize.width) &&
                    imageView.image?.cgImage?.height == Int(viewport.pixelSize.height) &&
                    metal.pendingFrameGeometry == expectedGeometry && metal.submittedFrameGeometry == expectedGeometry &&
                    metalLayer.drawableSize == viewport.pixelSize && metal.strokes.isEmpty &&
                    surface.inputDiagnostics["navigationDisplayActive"] as? Bool == false &&
                    surface.inputDiagnostics["frameRequested"] as? Bool == false
            }
            let deadline = CACurrentMediaTime() + 3
            while !isSettled(), CACurrentMediaTime() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(isSettled(), "Wait for the actual new crop, submitted geometry, and synchronized clear; an elapsed sleep is not a handoff")
            let image = try XCTUnwrap(imageView.image)
            XCTAssertEqual(imageView.frame, viewport.canvasRect); XCTAssertEqual(metal.frame, viewport.canvasRect)
            XCTAssertEqual(surface.subviews.last?.frame, viewport.canvasRect, "Selection stays in the same crop above Metal")
            XCTAssertEqual(image.cgImage?.width, Int(viewport.pixelSize.width))
            XCTAssertEqual(image.cgImage?.height, Int(viewport.pixelSize.height))
            XCTAssertEqual(metal.pendingFrameGeometry?.pixelSize, viewport.pixelSize)
            XCTAssertEqual(metal.submittedFrameGeometry?.pixelSize, viewport.pixelSize)
            XCTAssertEqual(metalLayer.drawableSize, viewport.pixelSize,
                "Staged drawing targets CAMetalLayer directly without resizing the previous front through MTKView's setter")
            XCTAssertEqual(viewport.pixelScale, window.screen.scale*4, accuracy: 0.001)
            XCTAssertLessThan(image.size.width, surface.bounds.width)
            XCTAssertNil(surface.layer.contents, "Input surface must never allocate a full-page painted backing")
        }
    }

    func testLiveMultiplyUsesCropLocalCoordinatesInTwoDifferentPageRegions() throws {
        let renderer = try XCTUnwrap(NativePDFMetalInk())
        let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true; format.preferredRange = .standard
        for origin in [CGPoint(x: 20,y: 80), CGPoint(x: 300,y: 610)] {
            let viewport = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: CGRect(x: 0,y: 0,width: 600,height: 900),
                visibleRect: CGRect(origin: origin,size: CGSize(width: 32,height: 32)), canvasToWindow: .identity, screenScale: 2))
            renderer.frame = viewport.canvasRect
            let image = UIGraphicsImageRenderer(size: viewport.canvasRect.size,format: format).image { context in
                UIColor.white.setFill(); context.fill(CGRect(x: 0,y: 0,width: 32,height: 32))
                UIColor.black.setFill(); context.fill(CGRect(x: 6,y: 0,width: 4,height: 32))
            }
            renderer.backdrop = image.cgImage
            let canvasPolygon = [CGPoint(x: origin.x+2,y: origin.y+12), CGPoint(x: origin.x+30,y: origin.y+12),
                                 CGPoint(x: origin.x+30,y: origin.y+20), CGPoint(x: origin.x+2,y: origin.y+20)]
            renderer.strokes = [.init(polygons: [canvasPolygon.map(viewport.localPoint)],color: .yellow,opacity: 0.5,multiply: true)]
            let bytes = try XCTUnwrap(renderer.renderedPixels(width: 64,height: 64))
            func sample(_ x: Int,_ y: Int) -> [UInt8] { Array(bytes[(y*64+x)*4..<(y*64+x)*4+4]) }
            XCTAssertEqual(sample(16,32),[0,0,0,255], "PDF text stays black beneath a cropped live highlighter")
            XCTAssertEqual(sample(30,32)[0],128,accuracy: 1); XCTAssertEqual(sample(30,32)[1],255)
            XCTAssertEqual(sample(30,10),[255,255,255,255], "Live ink must not shift when the crop origin changes")
        }
    }

    private func fixture() throws -> (PDFDocument,InkCoordinateMapper) {
        let bounds = CGRect(x: 0,y: 0,width: 600,height: 900)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage(); UIColor.white.setFill(); renderer.cgContext.fill(bounds)
            for point in [CGPoint(x: 30,y: 50),CGPoint(x: 350,y: 500)] {
                let text = "Sharp PDF text: minimum 4x\nLetters stay crisp while scrolling.\n0123456789 ABCDEFGH"
                (text as NSString).draw(in: CGRect(origin: point,size: CGSize(width: 165,height: 75)),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 7),.foregroundColor: UIColor.black])
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let mapper = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: 1,b: 0,c: 0,d: -1,tx: 0,ty: 900),
            geometry: InkPageGeometry(cropBox: bounds,rotation: 0))
        return (document,mapper)
    }
    private func grayEdgeFraction(_ image: UIImage) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage), count = cg.width*cg.height
        var bytes = [UInt8](repeating: 0,count: count*4)
        let context = try XCTUnwrap(CGContext(data: &bytes,width: cg.width,height: cg.height,bitsPerComponent: 8,bytesPerRow: cg.width*4,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg,in: CGRect(x: 0,y: 0,width: cg.width,height: cg.height))
        var dark = 0, gray = 0
        for index in stride(from: 0,to: bytes.count,by: 4) {
            if bytes[index] < 245 { dark += 1; if bytes[index] > 25 { gray += 1 } }
        }
        XCTAssertGreaterThan(dark,2_000,"The sampled crop must contain PDF glyphs")
        return Double(gray)/Double(max(1,dark))
    }
}
