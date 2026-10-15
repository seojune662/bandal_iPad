import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFNavigationReuseTests: XCTestCase {
    private let size = CGSize(width: 400, height: 600)
    private func page() throws -> PDFPage {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage(); UIColor.red.setFill(); context.cgContext.fill(CGRect(x: 20, y: 30, width: 40, height: 60))
        }
        return try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
    }
    private func object(_ index: Int) -> [String: Any] {
        ["id": "row-\(index)", "clientMutationId": "mutation-\(index)", "page": 1,
         "kind": index.isMultiple(of: 3) ? "highlighter" : "ink",
         "data": ["inkVersion": 4, "points": [
            ["x": 0.15, "y": 0.2 + Double(index % 4) * 0.08, "p": 0.2],
            ["x": 0.5, "y": 0.4, "p": 0.7], ["x": 0.8, "y": 0.7, "p": 0.5]]],
         "style": ["color": index.isMultiple(of: 2) ? "blue" : "red", "width": 0.008, "opacity": 0.43]]
    }
    private func make(_ builder: NativePDFNavigationSnapshotBuilder, page: PDFPage, objects: [[String: Any]],
                      tokens: [NativePDFCommittedVisualToken]?, highlights: [[String: Any]] = [],
                      image: UIImage? = nil) throws -> NativePDFNavigationSnapshot {
        try XCTUnwrap(builder.make(page: page, objects: objects, tokens: tokens, highlights: highlights, image: { _ in image }))
    }
    private func pixels(_ snapshot: NativePDFNavigationSnapshot) throws -> Data {
        let raster = try XCTUnwrap(snapshot.raster(bounds: CGRect(origin: .zero, size: snapshot.size), scale: 1, canonicalToCanvas: .identity))
        return try XCTUnwrap(raster.image.dataProvider?.data) as Data
    }
    private func onlyTileLayer(in view: NativePDFNavigationView,
                               file: StaticString = #filePath, line: UInt = #line) throws -> CATiledLayer {
        // The continuity clip is a persistent auxiliary layer. Observe the
        // actual tile, not a layer-tree position that can hide replacements.
        let tiles = (view.layer.sublayers ?? []).compactMap { $0 as? CATiledLayer }
        XCTAssertEqual(tiles.count, 1, "Exactly one snapshot tile layer must be installed", file: file, line: line)
        return try XCTUnwrap(tiles.first, file: file, line: line)
    }
    func testHundredIdenticalImmutableScenesKeepSnapshotAndTileLayer() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let objects = (0..<71).map(object), tokens = objects.map(NativePDFCommittedVisualToken.init)
        let first = try make(builder, page: page, objects: objects, tokens: tokens)
        let view = NativePDFNavigationView(frame: CGRect(origin: .zero, size: size)), mapper = InkCoordinateMapper.whiteboard(size: size)
        view.install(first, mapper: mapper)
        let layer = try onlyTileLayer(in: view)
        let started = CACurrentMediaTime()
        var replacements = 0, revisions = Set<UInt64>()
        for _ in 0..<100 {
            let next = try make(builder, page: page, objects: objects, tokens: tokens)
            view.install(next, mapper: mapper); revisions.insert(next.revision)
            if try onlyTileLayer(in: view) !== layer { replacements += 1 }
            XCTAssertTrue(next === first); XCTAssertEqual(builder.preparedObjectCount, 0)
        }
        XCTAssertEqual(replacements, 0); XCTAssertEqual(revisions, [first.revision])
        print("NAV_REUSE rows=71 calls=100 replacements=\(replacements) uniqueRevisions=\(revisions.count) elapsedMS=\((CACurrentMediaTime()-started)*1000)")
    }
    func testAcknowledgementReusesSnapshotAndLaterVisualChangesMatchFreshReplay() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        var objects = (0..<4).map(object), tokens = objects.map(NativePDFCommittedVisualToken.init)
        let first = try make(builder, page: page, objects: objects, tokens: tokens)
        for index in objects.indices { objects[index]["id"] = "canonical-\(index)"; objects[index]["updatedAt"] = "later" }
        tokens = objects.map(NativePDFCommittedVisualToken.init)
        XCTAssertTrue(try make(builder, page: page, objects: objects, tokens: tokens) === first)
        XCTAssertEqual(builder.preparedObjectCount, 0)
        objects.append(object(4)); tokens.append(NativePDFCommittedVisualToken(object: objects[4]))
        var previous = try make(builder, page: page, objects: objects, tokens: tokens)
        XCTAssertEqual(builder.preparedObjectCount, 1, "New ACK tokens must retain the old immutable commands")
        for operation in 0..<3 {
            if operation == 0 { objects[0]["style"] = ["color": "green", "width": 0.02, "opacity": 0.8] }
            else if operation == 1 { objects.swapAt(0, 1) }
            else { objects.removeLast() }
            tokens = objects.map(NativePDFCommittedVisualToken.init)
            let next = try make(builder, page: page, objects: objects, tokens: tokens)
            let reference = try make(NativePDFNavigationSnapshotBuilder(), page: page, objects: objects, tokens: tokens)
            XCTAssertFalse(next === previous); XCTAssertTrue(try pixels(next) == pixels(reference))
            previous = next
        }
    }
    func testPaperInvalidationGeometryRotationAndVisibilityChangeTheRecording() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        var previous = try make(builder, page: page, objects: [], tokens: [])
        for operation in 0..<4 {
            switch operation {
            case 0: page.rotation = 90
            case 1: page.setBounds(CGRect(x: 10, y: 20, width: 350, height: 550), for: .cropBox)
            case 2: page.displaysAnnotations.toggle()
            default: builder.invalidate()
            }
            let next = try make(builder, page: page, objects: [], tokens: [])
            let reference = try make(NativePDFNavigationSnapshotBuilder(), page: page, objects: [], tokens: [])
            XCTAssertFalse(next === previous); XCTAssertFalse(next.paper === previous.paper)
            XCTAssertTrue(try pixels(next) == pixels(reference)); previous = next
        }
        let replacement = try make(builder, page: try self.page(), objects: [], tokens: [])
        XCTAssertFalse(replacement.paper === previous.paper)
    }
    func testExplicitInvalidationCapturesInPlaceAnnotationEdits() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let annotation = PDFAnnotation(bounds: CGRect(x: 100, y: 150, width: 120, height: 160), forType: .square, withProperties: nil)
        annotation.color = .green; annotation.interiorColor = .green; page.addAnnotation(annotation)
        let first = try make(builder, page: page, objects: [], tokens: [])
        annotation.color = .blue; annotation.interiorColor = .blue
        builder.invalidate()
        let changed = try make(builder, page: page, objects: [], tokens: [])
        XCTAssertFalse(changed.paper === first.paper)
        XCTAssertNotEqual(try pixels(changed), try pixels(first))
        XCTAssertTrue(try pixels(changed) == pixels(make(NativePDFNavigationSnapshotBuilder(), page: page, objects: [], tokens: [])))
    }
    func testChangedPageAspectRevalidatesPreparedInkAgainstRawStroke() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        var raw = object(1)
        raw["style"] = ["color": "blue", "width": 0.05, "opacity": 0.8]
        var preparedRow = raw
        let prepared = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(raw, aspect: 1.5))
        preparedRow["_nativeInk"] = prepared
        let token = NativePDFCommittedVisualToken(object: preparedRow)
        var previous = try make(builder, page: page, objects: [preparedRow], tokens: [token])
        for operation in 0..<2 {
            if operation == 0 { page.rotation = 90 }
            else { page.setBounds(CGRect(x: 10, y: 20, width: 300, height: 550), for: .cropBox) }
            let next = try make(builder, page: page, objects: [preparedRow], tokens: [token])
            let reference = try make(NativePDFNavigationSnapshotBuilder(), page: page, objects: [raw], tokens: nil)
            XCTAssertFalse(next === previous); XCTAssertEqual(builder.preparedObjectCount, 1)
            XCTAssertTrue(try pixels(next) == pixels(reference), "A prepared path from the old aspect must not be stretched into the new page geometry")
            previous = next
        }
    }
    func testMutableHighlightsAndImageResourceChangesCannotReuseStalePixels() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let box = NSMutableDictionary(dictionary: ["x": 0.1, "y": 0.1, "width": 0.7, "height": 0.2])
        let highlights: [[String: Any]] = [["rects": [box], "color": "yellow", "nativeOpacity": 0.4]]
        let first = try make(builder, page: page, objects: [], tokens: [], highlights: highlights)
        box["y"] = 0.6
        let changed = try make(builder, page: page, objects: [], tokens: [], highlights: highlights)
        XCTAssertFalse(changed === first); XCTAssertNotEqual(try pixels(changed), try pixels(first))
        var metadata = highlights; metadata[0]["id"] = "irrelevant-highlight-metadata"
        XCTAssertTrue(try make(builder, page: page, objects: [], tokens: [], highlights: metadata) === changed)
        let objects: [[String: Any]] = [["id": "image", "kind": "image", "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.4, "height": 0.4]], "style": ["opacity": 1]]]
        let tokens = objects.map(NativePDFCommittedVisualToken.init)
        func image(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }
        }
        let red = image(.red), green = image(.green)
        let before = try make(builder, page: page, objects: objects, tokens: tokens, image: red)
        XCTAssertTrue(try make(builder, page: page, objects: objects, tokens: tokens, image: red) === before)
        let after = try make(builder, page: page, objects: objects, tokens: tokens, image: green)
        XCTAssertFalse(after === before); XCTAssertNotEqual(try pixels(after), try pixels(before))
        XCTAssertTrue(try pixels(after) == pixels(make(NativePDFNavigationSnapshotBuilder(), page: page, objects: objects, tokens: tokens, image: green)))
    }
    func testUntrustedDictionaryAndMismatchedTokensAlwaysValidateCurrentPayload() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        var object = object(1)
        object["_nativeInk"] = NativePDFObjectRenderer.prepareInk(object, aspect: 1.5)
        object["_nativeVisualToken"] = NativePDFCommittedVisualToken(object: object)
        let first = try make(builder, page: page, objects: [object], tokens: nil)
        object["style"] = ["color": "green", "width": 0.03, "opacity": 0.9]
        let next = try make(builder, page: page, objects: [object], tokens: [])
        XCTAssertFalse(next === first); XCTAssertNotEqual(try pixels(next), try pixels(first))
        let reference = try make(NativePDFNavigationSnapshotBuilder(), page: page, objects: [object], tokens: nil)
        XCTAssertTrue(try pixels(next) == pixels(reference))
    }
    func testViewUpdatesMapperAndDifferentSnapshotEvenWithEqualRevisionNumber() throws {
        let page = try page(), snapshot = try make(NativePDFNavigationSnapshotBuilder(), page: page, objects: [], tokens: [])
        let view = NativePDFNavigationView(frame: CGRect(origin: .zero, size: size))
        let firstMapper = InkCoordinateMapper.whiteboard(size: size)
        view.install(snapshot, mapper: firstMapper)
        let firstLayer = try onlyTileLayer(in: view), oldTransform = firstLayer.affineTransform()
        var secondMapper = firstMapper; secondMapper.canvasToPDF.tx += 12
        view.install(snapshot, mapper: secondMapper)
        XCTAssertTrue(try onlyTileLayer(in: view) === firstLayer)
        XCTAssertNotEqual(firstLayer.affineTransform(), oldTransform)
        let expectedTransform = try XCTUnwrap(NativePDFObjectRenderer.pageTransform(secondMapper))
        XCTAssertEqual(firstLayer.affineTransform(), expectedTransform)
        let replacement = try make(NativePDFNavigationSnapshotBuilder(), page: try self.page(), objects: [object(1)], tokens: nil)
        XCTAssertEqual(replacement.revision, snapshot.revision)
        view.install(replacement, mapper: secondMapper)
        let replacementLayer = try onlyTileLayer(in: view)
        XCTAssertFalse(replacementLayer === firstLayer)
        XCTAssertNil(firstLayer.superlayer)
        XCTAssertEqual(replacementLayer.affineTransform(), expectedTransform)

        // Populate continuity so removal proves pixels are released, rather
        // than merely checking a value that had always been nil.
        let viewport = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: view.bounds,
            visibleRect: view.bounds, canvasToWindow: .identity, screenScale: 1))
        let transform = try XCTUnwrap(NativePDFObjectRenderer.pageTransform(firstMapper))
        let raster = try XCTUnwrap(snapshot.raster(bounds: viewport.canvasRect,
            scale: viewport.pixelScale, canonicalToCanvas: transform))
        let image = UIImage(cgImage: raster.image, scale: viewport.pixelScale, orientation: .up)
        let retained = try XCTUnwrap(NativePDFRetainedInkBackdrop(image: image, snapshot: snapshot,
            mapper: firstMapper, viewport: viewport, objects: [], tokens: [], highlights: [], imageForObject: { _ in nil }))
        view.retainContinuity(retained, mapper: secondMapper, viewport: viewport)
        XCTAssertTrue(view.continuityImage === image)
        XCTAssertEqual(view.continuityBitmapCount, 1)
        view.removeSnapshot()
        XCTAssertTrue((view.layer.sublayers ?? []).allSatisfy { !($0 is CATiledLayer) })
        XCTAssertNil(replacementLayer.superlayer)
        XCTAssertNil(view.revision)
        XCTAssertNil(view.continuityImage)
        XCTAssertEqual(view.continuityBitmapCount, 0)
    }

    func testPendingGeometryOwnsTokenUntilItsSuffixRetires() {
        var cache = NativePDFNavigationGeometryCache()
        let path = CGPath(rect: CGRect(x: 20, y: 30, width: 80, height: 90), transform: nil)
        weak var retired: NativePDFCommittedVisualToken?
        func insertRetired() -> ObjectIdentifier {
            let token = NativePDFCommittedVisualToken(object: object(1))
            retired = token
            _ = cache.polygons(token: token, path: path, size: size)
            return ObjectIdentifier(token)
        }
        let retiredID = insertRetired()
        XCTAssertNotNil(retired, "The cache must own the identity, even after its row/ACK owner releases it")
        XCTAssertEqual(cache.count, 1)
        weak var current: NativePDFCommittedVisualToken?
        func replaceSuffix() {
            let token = NativePDFCommittedVisualToken(object: object(1))
            current = token
            // This proves simultaneous ownership, not allocator reuse in the old implementation.
            XCTAssertNotEqual(ObjectIdentifier(token), retiredID)
            _ = cache.polygons(token: token, path: path, size: size)
            cache.retainOnly([ObjectIdentifier(token)])
        }
        replaceSuffix()
        XCTAssertNil(retired, "ACK replacement must retire the previous suffix token")
        XCTAssertNotNil(current)
        XCTAssertEqual(cache.count, 1)
        cache.retainOnly([])
        XCTAssertNil(current, "An empty suffix must release all identity owners")
        XCTAssertEqual(cache.count, 0)
    }

    func testPendingGeometryValidatesPathAndPageSizeWithTheSameToken() {
        var cache = NativePDFNavigationGeometryCache()
        let token = NativePDFCommittedVisualToken(object: object(1))
        let firstPath = CGPath(rect: CGRect(x: 20, y: 30, width: 80, height: 90), transform: nil)
        let secondPath = CGPath(rect: CGRect(x: 120, y: 180, width: 40, height: 60), transform: nil)
        let first = cache.polygons(token: token, path: firstPath, size: size)
        XCTAssertEqual(cache.polygons(token: token, path: firstPath, size: size), first)
        let changed = cache.polygons(token: token, path: secondPath, size: size)
        XCTAssertNotEqual(changed, first)
        XCTAssertEqual(changed.first?.first, CGPoint(x: 0.3, y: 0.3))
        let resized = cache.polygons(token: token, path: secondPath,
            size: CGSize(width: 800, height: 1200))
        XCTAssertEqual(resized.first?.first, CGPoint(x: 0.15, y: 0.15))
        XCTAssertNotEqual(resized, changed)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.polygons(token: token, path: firstPath, size: size), first)
        let otherToken = NativePDFCommittedVisualToken(object: object(2))
        cache.retainOnly([ObjectIdentifier(otherToken)])
        XCTAssertEqual(cache.count, 0, "Equal suffix counts do not imply equal identities")
        _ = cache.polygons(token: token, path: firstPath, size: size)
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
    }

    func testPendingGeometryWithoutTrustedTokenRemainsUncached() {
        var cache = NativePDFNavigationGeometryCache()
        let first = CGPath(rect: CGRect(x: 20, y: 30, width: 80, height: 90), transform: nil)
        let changed = CGPath(rect: CGRect(x: 120, y: 180, width: 40, height: 60), transform: nil)
        let before = cache.polygons(token: nil, path: first, size: size)
        let after = cache.polygons(token: nil, path: changed, size: size)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.first?.first, CGPoint(x: 0.3, y: 0.3))
        XCTAssertEqual(cache.count, 0)
    }

    func testPendingGeometryAckPressureCorrectionAndOrderMatchUncachedNavigation() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        var objects = [object(1), object(3)] // Translucent ordinary ink and multiply ink.
        var tokens = objects.map(NativePDFCommittedVisualToken.init)
        var cache = NativePDFNavigationGeometryCache()

        // Compare the existing uncached navigation representation. This is not
        // a claim of antialias parity between Metal/CA and a full opaque crop.
        func navigationPixels(_ snapshot: NativePDFNavigationSnapshot,
                              tokens: [NativePDFCommittedVisualToken]?,
                              cache: inout NativePDFNavigationGeometryCache) throws -> Data {
            var used: Set<ObjectIdentifier> = []
            defer { cache.retainOnly(used) }
            var commands: [NativePDFNavigationSnapshot.Command] = []
            for (index, command) in snapshot.objects.enumerated() {
                guard case let .path(path, color, opacity, multiply) = command.content else {
                    commands.append(command); continue
                }
                let token = tokens?[index]
                if let token { used.insert(ObjectIdentifier(token)) }
                let polygons = cache.polygons(token: token, path: path, size: snapshot.size)
                let replay = CGMutablePath()
                for polygon in polygons {
                    guard let first = polygon.first else { continue }
                    replay.move(to: CGPoint(x: first.x * snapshot.size.width, y: first.y * snapshot.size.height))
                    for point in polygon.dropFirst() {
                        replay.addLine(to: CGPoint(x: point.x * snapshot.size.width, y: point.y * snapshot.size.height))
                    }
                    replay.closeSubpath()
                }
                commands.append(.init(bounds: command.bounds, content: .path(replay, color, opacity, multiply)))
            }
            return try pixels(NativePDFNavigationSnapshot(paper: snapshot.paper,
                highlights: snapshot.highlights, objects: commands, revision: snapshot.revision))
        }
        func check(_ snapshot: NativePDFNavigationSnapshot) throws -> Data {
            let actual = try navigationPixels(snapshot, tokens: tokens, cache: &cache)
            var uncached = NativePDFNavigationGeometryCache()
            let reference = try navigationPixels(snapshot, tokens: nil, cache: &uncached)
            XCTAssertTrue(actual == reference, "Cached navigation must preserve raw path order, alpha and pressure")
            XCTAssertEqual(cache.count, snapshot.objects.count)
            XCTAssertEqual(uncached.count, 0)
            return actual
        }

        let first = try make(builder, page: page, objects: objects, tokens: tokens)
        let firstPixels = try check(first)
        weak var oldToken = tokens[0]
        for index in objects.indices { objects[index]["id"] = "canonical-\(index)" }
        tokens = objects.map(NativePDFCommittedVisualToken.init)
        let acknowledged = try make(builder, page: page, objects: objects, tokens: tokens)
        XCTAssertTrue(acknowledged === first)
        XCTAssertNotNil(oldToken, "The pending geometry entry owns the token after the builder rekeys its ACK")
        XCTAssertTrue(try check(acknowledged) == firstPixels)
        XCTAssertNil(oldToken, "The ACK frame prunes the retired identity")

        var data = try XCTUnwrap(objects[0]["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Double]])
        points[1]["p"] = 0.05; data["points"] = points; objects[0]["data"] = data
        // Keep the same drawing ID; a new immutable row must not hit old geometry.
        tokens[0] = NativePDFCommittedVisualToken(object: objects[0])
        let corrected = try make(builder, page: page, objects: objects, tokens: tokens)
        XCTAssertFalse(try check(corrected) == firstPixels)
        let fullReference = try make(NativePDFNavigationSnapshotBuilder(), page: page, objects: objects, tokens: nil)
        XCTAssertTrue(try pixels(corrected) == pixels(fullReference))

        objects.reverse(); tokens.reverse()
        _ = try check(make(builder, page: page, objects: objects, tokens: tokens))
        objects.removeLast(); tokens.removeLast()
        _ = try check(make(builder, page: page, objects: objects, tokens: tokens))
        _ = try check(make(builder, page: page, objects: [], tokens: []))
    }
}
