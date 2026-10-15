import XCTest
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFNavigationSnapshotTests: XCTestCase {
    private let size = CGSize(width: 384, height: 512)
    private func activeWindowScene() async throws -> UIWindowScene {
        let deadline = CACurrentMediaTime() + 1
        repeat {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) { return scene }
            try await Task.sleep(for: .milliseconds(20))
        } while CACurrentMediaTime() < deadline
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }), "The tile fixture requires a foreground-active scene")
    }
    private func page(rotation: Int = 0, marked: Bool = false) throws -> PDFPage {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { renderer in
            renderer.beginPage()
            if marked {
                UIColor(white: 0.8, alpha: 1).setFill(); renderer.cgContext.fill(CGRect(x: 51, y: 61, width: 37, height: 39))
                ("PDF glyphs" as NSString).draw(at: CGPoint(x: 35, y: 155), withAttributes: [.font: UIFont.systemFont(ofSize: 17)])
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(document.page(at: 0))
        if marked { page.setBounds(CGRect(x: 11, y: 13, width: 350, height: 470), for: .cropBox) }
        page.rotation = rotation
        return page
    }
    private func stroke(_ index: Int, aspect: Double = 512.0/384, count: Int = 24) throws -> [String: Any] {
        let points: [[String: Any]] = (0..<count).map { sample in
            let t = Double(sample)/Double(count-1)
            return ["x": 0.05+t*0.9, "y": 0.025+Double(index%20)*0.047+sin(t * .pi * 4)*0.009, "p": 0.2+t*0.6, "t": Double(sample)*4]
        }
        var object: [String: Any] = ["id": "ink-\(index)", "clientMutationId": "local-\(index)", "kind": index.isMultiple(of: 7) ? "highlighter" : "ink",
            "data": ["inkVersion": 4, "points": points], "style": ["color": index.isMultiple(of: 2) ? "blue" : "red", "width": 0.006, "opacity": 0.43]]
        object["_nativeInk"] = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(object, aspect: aspect))
        return object
    }
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width*image.height*4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        return bytes
    }
    func testBackgroundSnapshotMatchesOrderedInkAndMultiplyInNewlyExposedCrops() async throws {
        let page = try page(), mapper = InkCoordinateMapper.whiteboard(size: size)
        let objects = try (0..<24).map { try stroke($0) }, tokens = objects.map(NativePDFCommittedVisualToken.init)
        let snapshot = try XCTUnwrap(NativePDFNavigationSnapshotBuilder().make(page: page, objects: objects, tokens: tokens, highlights: [], image: { _ in nil }))
        for bounds in [CGRect(x: 0,y: 0,width: 190,height: 160), CGRect(x: 130,y: 300,width: 190,height: 160)] {
            let result = await Task.detached { snapshot.raster(bounds: bounds, scale: 2, canonicalToCanvas: .identity) }.value
            let raster = try XCTUnwrap(result)
            let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper, bounds: bounds, scale: 2) { context in
                for object in objects { NativePDFObjectRenderer.draw(object, in: context, mapper: mapper, image: nil) }
            })
            XCTAssertEqual(try pixels(raster.image), try pixels(XCTUnwrap(reference.cgImage)))
            let bytes = try pixels(raster.image)
            XCTAssertGreaterThan(bytes.enumerated().filter { $0.offset%4 != 3 && $0.element < 220 }.count, 100,
                "The second crop contains actual ink, not uncovered blank paper")
        }
    }
    func testPaperCropRotationAndVectorObjectsKeepTheirGeometryAndOrder() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20,height: 10)).image { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0,y: 0,width: 20,height: 10))
        }
        for rotation in [0,90,180,270] {
            let page = try page(rotation: rotation, marked: true), coordinates = NativePDFPageCoordinates(page: page)
            let size = CGSize(width: coordinates.width,height: coordinates.height), mapper = InkCoordinateMapper.whiteboard(size: size)
            var objects = try [stroke(4, aspect: size.height/size.width)]
            objects += [
                ["id": "legacy", "kind": "ink", "nativePath": "M 0.1 0.1 L 0.3 0.1 L 0.3 0.13 L 0.1 0.13 Z", "data": [:], "style": ["color": "red", "opacity": 0.5]],
                ["id": "text", "kind": "textbox", "data": ["box": ["x": 0.15,"y": 0.55,"width": 0.65,"height": 0.2], "text": "Native text"], "style": ["color": "blue", "fontSizePt": 18]],
                ["id": "image", "kind": "image", "data": ["box": ["x": 0.2,"y": 0.35,"width": 0.4,"height": 0.1]], "style": ["opacity": 0.8]]]
            let snapshot = try XCTUnwrap(NativePDFNavigationSnapshotBuilder().make(page: page, objects: objects, tokens: nil, highlights: [], image: { _ in image }))
            let bounds = CGRect(origin: .zero,size: size)
            let result = await Task.detached { snapshot.raster(bounds: bounds, scale: 1, canonicalToCanvas: .identity) }.value
            let raster = try XCTUnwrap(result)
            let reference = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper, bounds: bounds, scale: 1) { context in
                for object in objects { NativePDFObjectRenderer.draw(object, in: context, mapper: mapper, image: image) }
            })
            let actual = try pixels(raster.image), expected = try pixels(XCTUnwrap(reference.cgImage))
            let differences = zip(actual,expected).map { abs(Int($0)-Int($1)) }
            let mean = Double(differences.reduce(0,+))/Double(differences.count)
            XCTAssertLessThan(mean, 0.5, "PDF command recording may change edge quantization, not object geometry. rotation=\(rotation) mean=\(mean)")
        }
    }
    func testTwoHundredImmutableCommandsAreReusedAndInvalidRasterSizesAreRejected() throws {
        let page = try page(), objects = try (0..<200).map { try stroke($0, count: 96) }
        let tokens = objects.map(NativePDFCommittedVisualToken.init), builder = NativePDFNavigationSnapshotBuilder()
        let first = try XCTUnwrap(builder.make(page: page, objects: objects, tokens: tokens, highlights: [], image: { _ in nil }))
        XCTAssertEqual(builder.preparedObjectCount, 200)
        _ = try XCTUnwrap(builder.make(page: page, objects: objects, tokens: tokens, highlights: [], image: { _ in nil }))
        XCTAssertEqual(builder.preparedObjectCount, 0, "Viewport motion must not parse or rebuild committed paths")
        XCTAssertNil(first.raster(bounds: CGRect(x: 0,y: 0,width: CGFloat.greatestFiniteMagnitude,height: 10), scale: 2, canonicalToCanvas: .identity))
    }
    func testHeavySurfaceNavigationDoesNotSynchronouslyReplayAndAdoptsExactSettledScene() async throws {
        let page = try page(), objects = try (0..<200).map { try stroke($0,count: 96) }
        let tokens = objects.map(NativePDFCommittedVisualToken.init)
        let scene = try await activeWindowScene()
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero,size: size)))
        surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
        surface.applyObjects(objects: objects, visualTokens: tokens)
        var visible = CGRect(x: 0,y: 0,width: 190,height: 160)
        surface.viewportProvider = { visible }; controller.view.addSubview(surface); surface.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        let fullBefore = surface.inputDiagnostics["sceneFullRenders"] as? Int ?? 0
        for step in 1...30 {
            visible = CGRect(x: Double(step)*4,y: Double(step)*10,width: 190,height: 160)
            surface.refreshViewport()
        }
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, fullBefore)
        XCTAssertLessThan(surface.inputDiagnostics["navigationRefreshMaxCPUMS"] as? Double ?? .infinity, 50)
        let deadline = Date().addingTimeInterval(5)
        while surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(surface.inputDiagnostics["navigationDisplayActive"] as? Bool, false)
        XCTAssertGreaterThan(surface.inputDiagnostics["navigationAsyncRasterCount"] as? Int ?? 0, 0)
        try await Task.sleep(for: .milliseconds(100))
        let actual = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first?.image?.cgImage)
        let viewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
        let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page,mapper: mapper,bounds: viewport.canvasRect,scale: viewport.pixelScale) { context in
            for object in objects { NativePDFObjectRenderer.draw(object,in: context,mapper: mapper,image: nil) }
        }?.cgImage)
        XCTAssertEqual(try pixels(actual),try pixels(expected))
    }
    func testMapperRoundoffKeepsSettledSceneAndRealChangeUsesAsyncHandoff() async throws {
        let page = try page(), objects = try (0..<71).map { try stroke($0, count: 96) }
        let scene = try await activeWindowScene(), window = UIWindow(windowScene: scene)
        let previous = scene.windows.first(where: \.isKeyWindow), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero, size: size)))
        let original = InkCoordinateMapper.whiteboard(size: size)
        surface.pdfPage = page; surface.mapper = original; surface.isLoading = false
        surface.applyObjects(objects: objects, visualTokens: objects.map(NativePDFCommittedVisualToken.init))
        surface.viewportProvider = { CGRect(x: 0,y: 0,width: 190,height: 160) }
        controller.view.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        let viewport = surface.renderViewport
        let fullBefore = surface.inputDiagnostics["sceneFullRenders"] as? Int
        let mapperBefore = surface.inputDiagnostics["mapperInvalidations"] as? Int
        let rendersBefore = surface.inputDiagnostics["renderAttempts"] as? Int
        // This exact drift was measured through PDFKit on an A4 document after
        // a fractional layout: 1 became 1.0000000000000009 without page motion.
        for iteration in 0..<12 {
            var transform = original.canvasToPDF
            transform.a += iteration.isMultiple(of: 2) ? 8.881784197001252e-16 : -8.881784197001252e-16
            transform.tx += iteration.isMultiple(of: 2) ? 1.1368683772161603e-13 : -1.1368683772161603e-13
            surface.mapper = InkCoordinateMapper(canvasToPDF: transform, geometry: original.geometry)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(surface.renderViewport, viewport)
        XCTAssertEqual(surface.mapper?.canvasToPDF, original.canvasToPDF)
        XCTAssertEqual(surface.inputDiagnostics["mapperInvalidations"] as? Int, mapperBefore)
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, fullBefore)
        XCTAssertEqual(surface.inputDiagnostics["renderAttempts"] as? Int, rendersBefore,
            "Equivalent layout coordinates must not schedule another scene replay")
        var moved = original.canvasToPDF; moved.tx += 2
        surface.mapper = InkCoordinateMapper(canvasToPDF: moved, geometry: original.geometry)
        XCTAssertEqual(surface.renderViewport, viewport, "Exercise mapper motion independently of viewport changes")
        XCTAssertEqual(surface.inputDiagnostics["navigationDisplayActive"] as? Bool, true)
        XCTAssertEqual(surface.mapper?.canvasToPDF, moved)
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, fullBefore)
        let deadline = CACurrentMediaTime()+5
        while surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true, CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(surface.inputDiagnostics["navigationDisplayActive"] as? Bool, false)
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, fullBefore)
        try await Task.sleep(for: .milliseconds(100))
        let actual = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first?.image?.cgImage)
        let settledViewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
        let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
            bounds: settledViewport.canvasRect, scale: settledViewport.pixelScale) { context in
                for object in objects { NativePDFObjectRenderer.draw(object, in: context, mapper: mapper, image: nil) }
            }?.cgImage)
        XCTAssertEqual(try pixels(actual), try pixels(expected), "Real coordinate changes must preserve final scene geometry")
    }
    func testFullBoundsMappingPreservesRotatedCropGeometryAndRejectsRealPixelMotion() throws {
        let bounds = CGRect(x: 0.1,y: 0.3,width: 595,height: 842)
        for rotation in [0,90,180,270] {
            let page = try page(rotation: rotation, marked: true), coordinates = NativePDFPageCoordinates(page: page)
            for zoom in [0.4,1.0,3.274,8.0] as [CGFloat] {
                let expected = CGAffineTransform(a: zoom,b: 0,c: 0,d: -zoom,tx: 13.7,ty: 903.1)
                let actual = try XCTUnwrap(NativePDFCoordinateMapping.sample(bounds: bounds) { point in
                    let physical = point.applying(expected)
                    let normalized = CGPoint(x: physical.x/coordinates.width,y: 1-physical.y/coordinates.height)
                    return coordinates.displayPhysical(coordinates.pdfPoint(normalized))
                })
                let mapper = InkCoordinateMapper(canvasToPDF: expected, geometry: coordinates.geometry)
                let sample = InkCoordinateMapper(canvasToPDF: actual, geometry: coordinates.geometry)
                XCTAssertTrue(NativePDFCoordinateMapping.isPixelEquivalent(mapper,sample,bounds: bounds,pixelScale: 16))
                var shifted = actual; shifted.tx += zoom/512
                XCTAssertFalse(NativePDFCoordinateMapping.isPixelEquivalent(mapper,
                    InkCoordinateMapper(canvasToPDF: shifted,geometry: coordinates.geometry),bounds: bounds,pixelScale: 1))
                var scaled = actual; scaled.a += zoom/Double(bounds.width)/512
                XCTAssertFalse(NativePDFCoordinateMapping.isPixelEquivalent(mapper,
                    InkCoordinateMapper(canvasToPDF: scaled,geometry: coordinates.geometry),bounds: bounds,pixelScale: 1))
            }
        }
        XCTAssertNil(NativePDFCoordinateMapping.sample(bounds: .zero,convert: { $0 }))
        XCTAssertNil(NativePDFCoordinateMapping.sample(bounds: bounds,convert: { _ in .zero }))
        XCTAssertNil(NativePDFCoordinateMapping.sample(bounds: bounds,convert: { _ in CGPoint(x: CGFloat.nan,y: 0) }))
    }
    func testPencilDoesNotPreventDirectOnlyNavigationRecognizers() {
        let pencil = NativePDFPencilGestureRecognizer(), pan = UIPanGestureRecognizer(), pinch = UIPinchGestureRecognizer()
        for gesture in [pan,pinch] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            XCTAssertFalse(pencil.canPrevent(gesture))
        }
    }
    func testActualTiledLayerShowsNewlyExposedInkWhileNavigationContinues() async throws {
        let page = try page(rotation: 90, marked: true), coordinates = NativePDFPageCoordinates(page: page)
        let pageSize = CGSize(width: coordinates.width,height: coordinates.height)
        let scene = try await activeWindowScene()
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let holder = UIView(frame: CGRect(x: 20,y: 20,width: 180,height: 160)); holder.clipsToBounds = true
        controller.view.addSubview(holder)
        // A separate UIKit marker distinguishes an unpresented test window
        // from a CATiledLayer that has not supplied the newly exposed tile.
        let marker = UIView(frame: CGRect(x: 240,y: 30,width: 20,height: 20)); marker.backgroundColor = .green
        controller.view.addSubview(marker)
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero,size: pageSize)))
        surface.pdfPage = page; surface.mapper = .whiteboard(size: pageSize); surface.isLoading = false
        let object: [String: Any] = ["id": "new-region", "kind": "ink", "data": [:],
            "style": ["color": "red", "opacity": 1.0], "nativePath": "M 0.55 0.6 L 0.85 0.6 L 0.85 0.9 L 0.55 0.9 Z"]
        surface.applyObjects(objects: [object], visualTokens: [NativePDFCommittedVisualToken(object: object)])
        surface.viewportProvider = { [weak surface, weak holder] in
            guard let surface, let holder else { return nil }; return surface.convert(holder.bounds,from: holder)
        }
        holder.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        func displayedPixel(at point: CGPoint) throws -> [UInt8] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 1,height: 1),format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: CGRect(x: -point.x,y: -point.y,
                    width: window.bounds.width,height: window.bounds.height),afterScreenUpdates: true))
            }
            return try pixels(XCTUnwrap(image.cgImage))
        }
        let windowDeadline = CACurrentMediaTime() + 2
        var markerPixel = try displayedPixel(at: marker.convert(CGPoint(x: 10,y: 10),to: window))
        while markerPixel[1] < 200, CACurrentMediaTime() < windowDeadline {
            try await Task.sleep(for: .milliseconds(20))
            markerPixel = try displayedPixel(at: marker.convert(CGPoint(x: 10,y: 10),to: window))
        }
        XCTAssertGreaterThan(markerPixel[1],200,"The UIKit test window must be presented before testing asynchronous tiles")
        surface.navigationInProgress = { true }
        surface.frame.origin = CGPoint(x: -pageSize.width*0.5,y: -pageSize.height*0.5)
        surface.refreshViewport()
        let target = surface.convert(CGPoint(x: pageSize.width*0.65,y: pageSize.height*0.75),to: window)
        let tileStarted = CACurrentMediaTime(), tileDeadline = tileStarted + 2
        var tilePixel = try displayedPixel(at: target)
        while !(tilePixel[0] > 150 && tilePixel[1] < 80 && tilePixel[2] < 90), CACurrentMediaTime() < tileDeadline {
            try await Task.sleep(for: .milliseconds(20))
            tilePixel = try displayedPixel(at: target)
        }
        print("[NAVIGATION_TILE_READINESS] elapsedMS=\((CACurrentMediaTime()-tileStarted)*1000) marker=\(markerPixel) tile=\(tilePixel) scene=\(scene.activationState.rawValue)")
        XCTAssertEqual(surface.inputDiagnostics["navigationDisplayActive"] as? Bool,true,
            "This capture must exercise CATiledLayer, not a settled crop")
        XCTAssertTrue(surface.subviews.compactMap { $0 as? UIImageView }.first?.isHidden == true)
        let screenshot = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds,afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(screenshot.cgImage), bytes = try pixels(cg)
        let x = Int(target.x*screenshot.scale), y = Int(target.y*screenshot.scale)
        let pixel = Array(bytes[(y*cg.width+x)*4..<(y*cg.width+x)*4+4])
        XCTAssertGreaterThan(pixel[0],150); XCTAssertLessThan(pixel[1],80); XCTAssertLessThan(pixel[2],90,
            "Opaque red ink in the newly revealed quadrant must be visible during motion: \(pixel)")
        let attachment = XCTAttachment(image: screenshot); attachment.name = "Live CATiledLayer new crop, 90-degree PDF"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testImmediatePenAfterPanKeepsCompletedContactsUntilBackgroundHandoff() async throws {
        let page = try page()
        var objects = try (0..<200).map { try stroke($0,count: 96) }
        var tokens = objects.map(NativePDFCommittedVisualToken.init)
        let scene = try await activeWindowScene()
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: CGRect(origin: .zero,size: size)))
        surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
        surface.tool = .init(name: "pen",style: .init(color: "blue",width: 0.006,opacity: 0.45))
        surface.applyObjects(objects: objects,visualTokens: tokens)
        var visible = CGRect(x: 0,y: 0,width: 190,height: 160)
        surface.viewportProvider = { visible }; controller.view.addSubview(surface); surface.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        var saved: [NativePDFCompletedStroke] = []
        surface.onStroke = { stroke in
            saved.append(stroke)
            var object: [String: Any] = ["id": stroke.mutationID,"clientMutationId": stroke.mutationID,"kind": stroke.kind,
                "data": ["inkVersion": stroke.inkVersion, "points": stroke.points.map { point -> [String: Double] in
                    var value = ["x": point.x, "y": point.y, "p": point.p]
                    if let time = point.t { value["t"] = time }
                    if let tilt = point.tiltX { value["tiltX"] = tilt }
                    if let tilt = point.tiltY { value["tiltY"] = tilt }
                    return value
                }],
                "style": ["color": stroke.style.color,"width": stroke.style.width,"opacity": stroke.style.opacity]]
            object["_nativeInk"] = NativePDFObjectRenderer.prepareInk(object,aspect: 512.0/384)
            objects.append(object); tokens.append(NativePDFCommittedVisualToken(object: object))
            surface.applyObjects(objects: objects,visualTokens: tokens)
        }
        visible = CGRect(x: 120,y: 280,width: 190,height: 160); surface.refreshViewport()
        let fullBefore = surface.inputDiagnostics["sceneFullRenders"] as? Int ?? 0
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        var maxCallbackMS = 0.0
        for index in 0..<20 {
            let touch = NavigationPencilTouch(point: surface.convert(CGPoint(x: 150,y: 300+Double(index)*4),to: window))
            var started = CACurrentMediaTime()
            XCTAssertTrue(surface.beginPencilGesture(touch,with: nil))
            maxCallbackMS = max(maxCallbackMS,(CACurrentMediaTime()-started)*1000)
            if index == 0 {
                XCTAssertFalse(metal.strokes.isEmpty,"The first pen must be submitted over tiles before the settled crop exists")
                XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int,fullBefore)
            }
            try await Task.sleep(for: .milliseconds(8))
            touch.point.x += 12; touch.time += 0.008; touch.touchPhase = .moved
            surface.movePencilGesture(touch,with: nil)
            try await Task.sleep(for: .milliseconds(16))
            touch.point.x += 12; touch.time += 0.016; touch.touchPhase = .ended
            started = CACurrentMediaTime(); surface.endPencilGesture(touch,with: nil)
            maxCallbackMS = max(maxCallbackMS,(CACurrentMediaTime()-started)*1000)
            XCTAssertEqual(saved.count,index+1)
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertEqual(saved.flatMap(\.points).count,60)
        XCTAssertLessThan(maxCallbackMS,50,"No full-page CPU replay is allowed in a pen callback after navigation")
        let deadline = Date().addingTimeInterval(5)
        while surface.inputDiagnostics["navigationDisplayActive"] as? Bool == true, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(surface.inputDiagnostics["navigationDisplayActive"] as? Bool,false,"Continuous contacts must not starve background handoff")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(metal.strokes.isEmpty)
        let actual = try XCTUnwrap(surface.subviews.compactMap { $0 as? UIImageView }.first?.image?.cgImage)
        let viewport = try XCTUnwrap(surface.renderViewport), mapper = try XCTUnwrap(surface.mapper)
        let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page,mapper: mapper,bounds: viewport.canvasRect,scale: viewport.pixelScale) { context in
            for object in objects { NativePDFObjectRenderer.draw(object,in: context,mapper: mapper,image: nil) }
        }?.cgImage)
        XCTAssertEqual(try pixels(actual),try pixels(expected),"All completed contacts appear exactly once after the atomic handoff")
    }
}

@MainActor
private final class NavigationPencilTouch: UITouch {
    var point: CGPoint
    var time = ProcessInfo.processInfo.systemUptime
    var touchPhase = UITouch.Phase.began
    init(point: CGPoint) { self.point = point; super.init() }
    override var type: UITouch.TouchType { .pencil }
    override var timestamp: TimeInterval { time }
    override var phase: UITouch.Phase { touchPhase }
    override var force: CGFloat { 0.5 }
    override var maximumPossibleForce: CGFloat { 1 }
    override var estimatedProperties: UITouch.Properties { [] }
    override var estimatedPropertiesExpectingUpdates: UITouch.Properties { [] }
    override func location(in view: UIView?) -> CGPoint { view?.convert(point,from: view?.window) ?? point }
    override func preciseLocation(in view: UIView?) -> CGPoint { location(in: view) }
}
