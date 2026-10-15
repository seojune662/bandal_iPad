import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFRetainedInkBackdropTests: XCTestCase {
    private let size = CGSize(width: 400, height: 600)

    private func page() throws -> PDFPage {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage(); UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 33, y: 57, width: 59, height: 83))
        }
        return try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
    }
    private func object(_ index: Int) -> [String: Any] {
        ["id": "row-\(index)", "clientMutationId": "mutation-\(index)", "kind": index == 0 ? "highlighter" : "ink",
         "data": ["inkVersion": 4, "points": [["x": 0.2, "y": 0.3, "p": 0.3], ["x": 0.7, "y": 0.5, "p": 0.8]]],
         "style": ["color": index == 0 ? "yellow" : "blue", "width": 0.02, "opacity": 0.45]]
    }
    private func viewport(_ rect: CGRect? = nil, scale: CGFloat = 2) throws -> NativePDFRenderViewport {
        try XCTUnwrap(NativePDFRenderViewport(canvasBounds: CGRect(origin: .zero, size: size),
            visibleRect: rect ?? CGRect(x: 20, y: 30, width: 240, height: 320), canvasToWindow: .identity, screenScale: scale))
    }
    private func snapshot(_ builder: NativePDFNavigationSnapshotBuilder, page: PDFPage, objects: [[String: Any]],
                          tokens: [NativePDFCommittedVisualToken]? = nil, highlights: [[String: Any]] = [],
                          image: UIImage? = nil) throws -> NativePDFNavigationSnapshot {
        try XCTUnwrap(builder.make(page: page, objects: objects, tokens: tokens, highlights: highlights, image: { _ in image }))
    }
    private func capture(_ snapshot: NativePDFNavigationSnapshot, objects: [[String: Any]],
                         tokens: [NativePDFCommittedVisualToken]? = nil, highlights: [[String: Any]] = [],
                         image: UIImage? = nil, mapper: InkCoordinateMapper? = nil,
                         viewport suppliedViewport: NativePDFRenderViewport? = nil) throws -> NativePDFRetainedInkBackdrop {
        let mapper = mapper ?? .whiteboard(size: size), viewport = try suppliedViewport ?? self.viewport()
        let transform = try XCTUnwrap(NativePDFObjectRenderer.pageTransform(mapper))
        let raster = try XCTUnwrap(snapshot.raster(bounds: viewport.canvasRect, scale: viewport.pixelScale, canonicalToCanvas: transform))
        let pixels = UIImage(cgImage: raster.image, scale: raster.scale, orientation: .up)
        let retained = try XCTUnwrap(NativePDFRetainedInkBackdrop(image: pixels, snapshot: snapshot, mapper: mapper,
            viewport: viewport, objects: objects, tokens: tokens, highlights: highlights, imageForObject: { _ in image }))
        XCTAssertTrue(retained.image === pixels, "Capture must retain the exact accepted UIImage without resizing it")
        XCTAssertTrue(retained.snapshot === snapshot)
        return retained
    }

    func testSuffixAppendCorrectionDeletionAndReorderDoNotInvalidateCapturedPrefix() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let prefix = [object(0), object(1)], tokens = prefix.map(NativePDFCommittedVisualToken.init)
        let base = try capture(snapshot(builder, page: page, objects: prefix, tokens: tokens), objects: prefix, tokens: tokens)
        var rows = prefix + [object(2), object(3)]
        for operation in 0..<4 {
            switch operation {
            case 1: rows[2]["style"] = ["color": "red", "width": 0.04, "opacity": 0.7]
            case 2: rows.swapAt(2, 3)
            case 3: rows.removeLast()
            default: break
            }
            let currentTokens = rows.map(NativePDFCommittedVisualToken.init)
            let current = try snapshot(builder, page: page, objects: rows, tokens: currentTokens)
            XCTAssertTrue(base.canReuse(snapshot: current, mapper: .whiteboard(size: size), objects: rows,
                tokens: currentTokens, highlights: [], imageForObject: { _ in nil }))
            XCTAssertEqual(base.prefixCount, 2)
        }
    }

    func testCapturedPrefixMutationUndoAndOrderAreRejectedButAcknowledgementIsAccepted() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder(), original = [object(0), object(1)]
        let base = try capture(snapshot(builder, page: page, objects: original), objects: original)
        var acknowledged = original
        for index in acknowledged.indices {
            acknowledged[index]["id"] = "canonical-\(index)"; acknowledged[index]["updatedAt"] = "later"
        }
        XCTAssertTrue(base.canReuse(snapshot: try snapshot(builder, page: page, objects: acknowledged), mapper: .whiteboard(size: size),
            objects: acknowledged, tokens: nil, highlights: [], imageForObject: { _ in nil }))
        for operation in 0..<4 {
            var rows = original
            switch operation {
            case 0: rows[0]["style"] = ["color": "green", "width": 0.08, "opacity": 0.9]
            case 1: rows.removeLast()
            case 2: rows.swapAt(0, 1)
            default: rows[0]["clientMutationId"] = "different-row-with-identical-pixels"
            }
            XCTAssertFalse(base.canReuse(snapshot: try snapshot(builder, page: page, objects: rows), mapper: .whiteboard(size: size),
                objects: rows, tokens: nil, highlights: [], imageForObject: { _ in nil }))
        }
    }

    func testFallbackTokensFreezeMutableContainersAndIgnoreUntrustedEmbeddedToken() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let firstPoint = NSMutableDictionary(dictionary: ["x": 0.2, "y": 0.3, "p": 0.3])
        var row = object(0)
        row["data"] = ["inkVersion": 4, "points": [firstPoint, NSMutableDictionary(dictionary: ["x": 0.7, "y": 0.5, "p": 0.8])]]
        row["_nativeVisualToken"] = NativePDFCommittedVisualToken(object: row)
        let base = try capture(snapshot(builder, page: page, objects: [row]), objects: [row], tokens: [])
        firstPoint["p"] = 0.95
        let changed = try snapshot(builder, page: page, objects: [row])
        XCTAssertFalse(base.canReuse(snapshot: changed, mapper: .whiteboard(size: size), objects: [row], tokens: [],
            highlights: [], imageForObject: { _ in nil }))
    }

    func testWorkerContentAcceptsOnlyUnchangedCapturedRowsAndLaterAppend() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder(), mapper = InkCoordinateMapper.whiteboard(size: size)
        let pressure = NSMutableDictionary(dictionary: ["x": 0.2, "y": 0.3, "p": 0.3])
        var row = object(0)
        row["data"] = ["inkVersion": 4, "points": [pressure, NSMutableDictionary(dictionary: ["x": 0.7, "y": 0.5, "p": 0.8])]]
        let captured = try snapshot(builder, page: page, objects: [row])
        // No UIImage exists at worker dispatch. Metadata must already be
        // immutable so a changed NSMutableDictionary cannot validate old pixels.
        let content = try XCTUnwrap(NativePDFRetainedInkBackdrop.Content(snapshot: captured, mapper: mapper,
            objects: [row], tokens: nil, highlights: [], imageForObject: { _ in nil }))
        let appended = [row, object(1)]
        XCTAssertTrue(content.canReuse(snapshot: try snapshot(builder, page: page, objects: appended), mapper: mapper,
            objects: appended, tokens: nil, highlights: [], imageForObject: { _ in nil }))
        pressure["p"] = 0.95
        let corrected = [row, object(1)]
        XCTAssertFalse(content.canReuse(snapshot: try snapshot(builder, page: page, objects: corrected), mapper: mapper,
            objects: corrected, tokens: nil, highlights: [], imageForObject: { _ in nil }),
            "Even a correction to the last captured row requires a newer worker result; only rows after that capture are a suffix")
        XCTAssertNil(NativePDFRetainedInkBackdrop.Content(snapshot: captured, mapper: mapper,
            objects: [], tokens: nil, highlights: [], imageForObject: { _ in nil }))
    }

    func testFirstWorkerResultAdoptsCorrectedTailWithFrozenSeedAndExactReplay() throws {
        for change in 0..<3 {
            let page = try page(), builder = NativePDFNavigationSnapshotBuilder(), mapper = InkCoordinateMapper.whiteboard(size: size)
            let viewport = try viewport(scale: 1.7)
            let mutablePoint = NSMutableDictionary(dictionary: ["x": 0.2, "y": 0.3, "p": 0.2])
            var tail = object(1)
            tail["data"] = ["inkVersion": 4, "points": [mutablePoint,
                NSMutableDictionary(dictionary: ["x": 0.7, "y": 0.5, "p": 0.8])]]
            let dispatchedRows = [object(0), tail]
            let captured = try snapshot(builder, page: page, objects: dispatchedRows)
            let content = try XCTUnwrap(NativePDFRetainedInkBackdrop.Content(snapshot: captured, mapper: mapper,
                objects: dispatchedRows, tokens: nil, highlights: [], imageForObject: { _ in nil }))
            // Several updates happen while that first immutable snapshot is
            // in flight. The original dictionary itself aliases this point.
            mutablePoint["p"] = 0.45; mutablePoint["p"] = 0.95
            var currentRows = dispatchedRows + [object(2)]
            if change == 1 { currentRows[1]["style"] = ["color": "green", "width": 0.06, "opacity": 0.7] }
            if change == 2 {
                currentRows[1]["kind"] = "rect"
                currentRows[1]["data"] = ["box": ["x": 0.2, "y": 0.2, "width": 0.25, "height": 0.3]]
                currentRows[1]["style"] = ["color": "red", "width": 0.015, "opacity": 0.65]
            }
            let current = try snapshot(builder, page: page, objects: currentRows)
            XCTAssertFalse(content.canReuse(snapshot: current, mapper: mapper, objects: currentRows, tokens: nil,
                highlights: [], imageForObject: { _ in nil }), "A full opaque image cannot silently claim its tail was already corrected")
            XCTAssertTrue(content.canReuse(snapshot: current, mapper: mapper, objects: currentRows, tokens: nil,
                highlights: [], imageForObject: { _ in nil }, stablePrefixCount: 1, currentMutableStartIndex: currentRows.count),
                "The first completed worker result must be usable despite repeated corrections after its stable checkpoint")
            XCTAssertEqual(content.cacheSeedRows.count, dispatchedRows.count)
            XCTAssertEqual(content.cacheSeedRows[1]["id"] as? String, "mutation-1")
            XCTAssertTrue(content.cacheSeedRows.allSatisfy { Set($0.keys).isSubset(of: ["id"]) })
            XCTAssertFalse(content.cacheSeedTokens[1].hasSameAppearance(as: NativePDFCommittedVisualToken(object: currentRows[1])))
            // Raster the originally captured snapshot only once. It cannot see
            // the mutable point above: its paths were prepared at dispatch.
            let result = try XCTUnwrap(captured.raster(bounds: viewport.canvasRect, scale: viewport.pixelScale,
                canonicalToCanvas: XCTUnwrap(NativePDFObjectRenderer.pageTransform(mapper)), stablePrefixCount: 1))
            let paper = UIImage(cgImage: result.paper, scale: result.scale, orientation: .up)
            let oldImage = UIImage(cgImage: result.image, scale: result.scale, orientation: .up)
            let prefixImage = UIImage(cgImage: try XCTUnwrap(result.prefix), scale: result.scale, orientation: .up)
            let cache = NativePDFCommittedSceneCache()
            XCTAssertTrue(cache.adopt(paper: paper, image: oldImage, stablePrefixImage: prefixImage, stablePrefixCount: 1,
                mapper: mapper, bounds: viewport.canvasRect, highlights: [], objects: content.cacheSeedRows,
                visualTokens: content.cacheSeedTokens, mutableObjectStartIndex: 1))
            let rendered = try XCTUnwrap(cache.render(paper: paper, mapper: mapper, bounds: viewport.canvasRect,
                highlights: [], objects: currentRows, mutableObjectStartIndex: currentRows.count,
                drawHighlights: { _ in }, drawObject: { row, context in
                    NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil)
                }))
            let expected = try XCTUnwrap(NativePDFBackdropRenderer.render(page: page, mapper: mapper,
                bounds: viewport.canvasRect, scale: viewport.pixelScale, drawObjects: { context in
                    for row in currentRows { NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: nil) }
                }))
            XCTAssertEqual(cache.adoptCount, 1); XCTAssertEqual(cache.fullRenderCount, 0)
            XCTAssertEqual(cache.tailRenderCount, 1); XCTAssertEqual(cache.lastRenderMode, "tail")
            XCTAssertEqual(cache.lastReplayStartIndex, 1); XCTAssertEqual(cache.lastDrawnObjectCount, 2)
            XCTAssertEqual(try pixelBytes(rendered), try pixelBytes(expected), "change=\(change)")
            XCTAssertNotEqual(try pixelBytes(oldImage), try pixelBytes(expected), "The fixture must distinguish old and current pixels")
        }
    }

    func testTailAdoptionRequiresStableBoundaryOrderAndUnchangedResources() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder(), mapper = InkCoordinateMapper.whiteboard(size: size)
        let rows = [object(0), object(1)], captured = try snapshot(builder, page: page, objects: rows)
        let content = try XCTUnwrap(NativePDFRetainedInkBackdrop.Content(snapshot: captured, mapper: mapper,
            objects: rows, tokens: nil, highlights: [], imageForObject: { _ in nil }))
        for (prefix, mutable) in [(1, nil), (1, 0), (-1, 1), (3, 3), (1, 3)] as [(Int, Int?)] {
            XCTAssertFalse(content.canReuse(snapshot: captured, mapper: mapper, objects: rows, tokens: nil,
                highlights: [], imageForObject: { _ in nil }, stablePrefixCount: prefix, currentMutableStartIndex: mutable))
        }
        for operation in 0..<4 {
            var currentRows = rows
            switch operation {
            case 0: currentRows[0]["style"] = ["color": "red", "width": 0.07, "opacity": 0.9]
            case 1: currentRows.swapAt(0, 1)
            case 2: currentRows.removeLast()
            default: currentRows[1]["clientMutationId"] = "replacement"
            }
            XCTAssertFalse(content.canReuse(snapshot: try snapshot(builder, page: page, objects: currentRows), mapper: mapper,
                objects: currentRows, tokens: nil, highlights: [], imageForObject: { _ in nil },
                stablePrefixCount: 1, currentMutableStartIndex: currentRows.count))
        }
        let resource = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var imageRow = object(1)
        imageRow["kind"] = "image"; imageRow["data"] = ["box": ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.3]]
        let imageRows = [object(0), imageRow]
        let imageSnapshot = try snapshot(builder, page: page, objects: imageRows, image: resource)
        let imageContent = try XCTUnwrap(NativePDFRetainedInkBackdrop.Content(snapshot: imageSnapshot, mapper: mapper,
            objects: imageRows, tokens: nil, highlights: [], imageForObject: { _ in resource }))
        XCTAssertFalse(imageContent.canReuse(snapshot: try snapshot(builder, page: page, objects: imageRows), mapper: mapper,
            objects: imageRows, tokens: nil, highlights: [], imageForObject: { _ in nil }, stablePrefixCount: 1,
            currentMutableStartIndex: 2), "Tail resource changes must reject: the scene cache compares appearance tokens, not external UIImage identity")
        let highlights: [[String: Any]] = [["rects": [["x": 0.2, "y": 0.2, "width": 0.3, "height": 0.1]], "color": "yellow"]]
        XCTAssertFalse(content.canReuse(snapshot: try snapshot(builder, page: page, objects: rows, highlights: highlights), mapper: mapper,
            objects: rows, tokens: nil, highlights: highlights, imageForObject: { _ in nil }, stablePrefixCount: 1,
            currentMutableStartIndex: 2))
    }

    private func pixelBytes(_ image: UIImage) throws -> Data {
        let cg = try XCTUnwrap(image.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return Data(bytes: try XCTUnwrap(context.data), count: cg.width * cg.height * 4)
    }

    func testHighlightDisplayFieldsAreFrozenWhileMetadataDoesNotInvalidate() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let box = NSMutableDictionary(dictionary: ["x": 0.1, "y": 0.2, "width": 0.7, "height": 0.1])
        let highlights: [[String: Any]] = [["rects": [box], "color": "yellow", "nativeColor": [1.0, 0.8, 0.2, 1.0], "nativeOpacity": 0.4]]
        let base = try capture(snapshot(builder, page: page, objects: [], highlights: highlights), objects: [], highlights: highlights)
        var metadata = highlights; metadata[0]["id"] = "canonical-highlight"; metadata[0]["updatedAt"] = "later"
        XCTAssertTrue(base.canReuse(snapshot: try snapshot(builder, page: page, objects: [], highlights: metadata),
            mapper: .whiteboard(size: size), objects: [], tokens: nil, highlights: metadata, imageForObject: { _ in nil }))
        for field in ["color", "nativeColor", "nativeOpacity", "rects"] {
            var changed = highlights
            switch field {
            case "color": changed[0][field] = "pink"
            case "nativeColor": changed[0][field] = [0.2, 0.7, 1.0, 1.0]
            case "nativeOpacity": changed[0][field] = 0.7
            default: box["y"] = 0.7
            }
            XCTAssertFalse(base.canReuse(snapshot: try snapshot(builder, page: page, objects: [], highlights: changed),
                mapper: .whiteboard(size: size), objects: [], tokens: nil, highlights: changed, imageForObject: { _ in nil }), field)
        }
    }

    func testImageAndClipResourcesAreComparedByResolvedIdentityOnlyInPrefix() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        func image(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
                color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        }
        let firstImage = image(.red), replacement = image(.green)
        for kind in ["image", "clip"] {
            let row: [String: Any] = ["id": kind, "kind": kind, "data": ["box": ["x": 0.1, "y": 0.1, "width": 0.3, "height": 0.3]]]
            let tokens = [NativePDFCommittedVisualToken(object: row)]
            let initial = try snapshot(builder, page: page, objects: [row], tokens: tokens, image: firstImage)
            let base = try capture(initial, objects: [row], tokens: tokens, image: firstImage)
            XCTAssertTrue(base.canReuse(snapshot: initial, mapper: .whiteboard(size: size), objects: [row], tokens: tokens,
                highlights: [], imageForObject: { _ in firstImage }))
            for currentImage in [nil, replacement] as [UIImage?] {
                let changed = try snapshot(builder, page: page, objects: [row], tokens: tokens, image: currentImage)
                XCTAssertFalse(base.canReuse(snapshot: changed, mapper: .whiteboard(size: size), objects: [row], tokens: tokens,
                    highlights: [], imageForObject: { _ in currentImage }))
            }
            let empty = try snapshot(builder, page: page, objects: [])
            let emptyBase = try capture(empty, objects: [])
            XCTAssertTrue(emptyBase.canReuse(snapshot: initial, mapper: .whiteboard(size: size), objects: [row], tokens: tokens,
                highlights: [], imageForObject: { _ in replacement }), "Resources outside the prefix must be freshly drawn as suffix")
        }
    }

    func testPaperIdentityGeometryAndExplicitInvalidationRejectOldBackdrop() throws {
        for operation in 0..<5 {
            let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
            let initial = try snapshot(builder, page: page, objects: [])
            let base = try capture(initial, objects: [])
            var nextPage = page
            switch operation {
            case 0: nextPage = try self.page()
            case 1: page.rotation = 90
            case 2: page.setBounds(CGRect(x: 17, y: 23, width: 350, height: 500), for: .cropBox)
            case 3: page.displaysAnnotations.toggle()
            default: builder.invalidate()
            }
            let changed = try snapshot(builder, page: nextPage, objects: [])
            XCTAssertFalse(base.canReuse(snapshot: changed, mapper: .whiteboard(size: size), objects: [], tokens: nil,
                highlights: [], imageForObject: { _ in nil }))
        }
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let initial = try snapshot(builder, page: page, objects: [])
        let base = try capture(initial, objects: [])
        var mapper = InkCoordinateMapper.whiteboard(size: size)
        mapper.canvasToPDF = mapper.canvasToPDF.concatenating(CGAffineTransform(a: 1.4, b: 0.2, c: -0.1, d: 1.2, tx: 12, ty: -6))
        XCTAssertTrue(base.canReuse(snapshot: initial, mapper: mapper, objects: [], tokens: nil,
            highlights: [], imageForObject: { _ in nil }), "An affine navigation change must reuse the old sampling basis")
        mapper.geometry.width += 1
        XCTAssertFalse(base.canReuse(snapshot: initial, mapper: mapper, objects: [], tokens: nil,
            highlights: [], imageForObject: { _ in nil }))
    }

    func testCoverageChecksEveryPolygonVertexAndOnePixelAntialiasMargin() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder(), mapper = InkCoordinateMapper.whiteboard(size: size)
        let base = try capture(snapshot(builder, page: page, objects: []), objects: [])
        func polygon(_ rect: CGRect) -> [[CGPoint]] {
            [[CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
              CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].map {
                let p = mapper.normalized($0, pressure: 0.5); return CGPoint(x: p.x, y: p.y)
            }]
        }
        XCTAssertTrue(base.contains(normalizedPolygons: polygon(CGRect(x: 21, y: 31, width: 238, height: 318))))
        XCTAssertFalse(base.contains(normalizedPolygons: polygon(CGRect(x: 20.25, y: 31, width: 10, height: 10))))
        XCTAssertTrue(base.contains(normalizedPolygons: polygon(CGRect(x: 20.25, y: 31, width: 10, height: 10)), antialiasPixels: 0))
        var protruding = polygon(CGRect(x: 40, y: 50, width: 20, height: 20))
        protruding[0].append(CGPoint(x: 0.9, y: 0.9))
        XCTAssertFalse(base.contains(normalizedPolygons: protruding), "A centerline or average-bounds test would miss the protruding cap")
        XCTAssertFalse(base.contains(normalizedPolygons: [[CGPoint(x: .nan, y: 0.5)]]))
        XCTAssertFalse(base.contains(normalizedPolygons: [[CGPoint(x: 0.5, y: .infinity)]]))
        XCTAssertFalse(base.contains(normalizedPolygons: [], antialiasPixels: -1))
        XCTAssertFalse(base.contains(normalizedPolygons: [], antialiasPixels: .nan))
        XCTAssertTrue(base.contains(normalizedPolygons: []))
    }

    func testCoverageUsesCapturedAffineBasisAcrossRotationAndFractionalCrop() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder()
        let initial = try snapshot(builder, page: page, objects: [])
        let rect = CGRect(x: 20.125, y: 30.375, width: 239.625, height: 319.125)
        let viewport = try self.viewport(rect, scale: 1.7)
        for turns in 0..<4 {
            var mapper = InkCoordinateMapper.whiteboard(size: size)
            mapper.canvasToPDF = CGAffineTransform(translationX: -17.25, y: 23.125)
                .rotated(by: CGFloat(turns) * .pi / 2).scaledBy(x: 0.8, y: -1.3)
            let base = try capture(initial, objects: [], mapper: mapper, viewport: viewport)
            let points = [CGPoint(x: 50, y: 70), CGPoint(x: 130, y: 75), CGPoint(x: 120, y: 160)].map { canvas -> CGPoint in
                let p = mapper.normalized(canvas, pressure: 0.5); return CGPoint(x: p.x, y: p.y)
            }
            XCTAssertTrue(base.contains(normalizedPolygons: [points]), "turn=\(turns)")
            var outside = points
            let p = mapper.normalized(CGPoint(x: viewport.canvasRect.maxX + 1, y: 90), pressure: 0.5)
            outside.append(CGPoint(x: p.x, y: p.y))
            XCTAssertFalse(base.contains(normalizedPolygons: [outside]), "turn=\(turns)")
        }
    }

    func testCaptureRejectsMismatchedImageDimensionsScaleOrientationAndSnapshotCount() throws {
        let page = try page(), builder = NativePDFNavigationSnapshotBuilder(), mapper = InkCoordinateMapper.whiteboard(size: size)
        let initial = try snapshot(builder, page: page, objects: []), viewport = try viewport()
        let base = try capture(initial, objects: [])
        let cg = try XCTUnwrap(base.image.cgImage)
        let badScale = UIImage(cgImage: cg, scale: viewport.pixelScale + 1, orientation: .up)
        let badOrientation = UIImage(cgImage: cg, scale: viewport.pixelScale, orientation: .down)
        let small = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        for image in [badScale, badOrientation, small] {
            XCTAssertNil(NativePDFRetainedInkBackdrop(image: image, snapshot: initial, mapper: mapper, viewport: viewport,
                objects: [], tokens: nil, highlights: [], imageForObject: { _ in nil }))
        }
        XCTAssertNil(NativePDFRetainedInkBackdrop(image: base.image, snapshot: initial, mapper: mapper, viewport: viewport,
            objects: [object(0)], tokens: nil, highlights: [], imageForObject: { _ in nil }))
        var singular = mapper; singular.canvasToPDF = CGAffineTransform(scaleX: 0, y: 0)
        XCTAssertNil(NativePDFRetainedInkBackdrop(image: base.image, snapshot: initial, mapper: singular, viewport: viewport,
            objects: [], tokens: nil, highlights: [], imageForObject: { _ in nil }))
    }
}
