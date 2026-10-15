import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFVectorRegistrationTests: XCTestCase {
    typealias Base = NativePDFAsynchronousEditTests
    func testVectorCoordinatesMatchOriginalImageResizeThroughPanRotationAndShear() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }; try await f.settle()
        let mapper = try XCTUnwrap(f.surface.mapper)
        let canvas = f.surface.bounds
        let sources = [try XCTUnwrap(f.surface.renderViewport),
                       try XCTUnwrap(NativePDFRenderViewport(canvasBounds: canvas, visibleRect: canvas,
                           canvasToWindow: CGAffineTransform(scaleX: 4,y: 4), screenScale: 2)),
                       try XCTUnwrap(NativePDFRenderViewport(canvasBounds: canvas,
                           visibleRect: CGRect(x: 31.2,y: 42.7,width: 250.1,height: 300.8),
                           canvasToWindow: CGAffineTransform(scaleX: 3.1,y: 2.7), screenScale: 2))]
        let builder = NativePDFNavigationSnapshotBuilder()
        let initial = try XCTUnwrap(builder.make(page: f.page, objects: f.rows, tokens: f.tokens, highlights: [], image: { _ in nil }))
        let row: [String: Any] = ["id":"registration-local","clientMutationId":"registration-local","page":1,"kind":"ink",
            "data":["inkVersion":4,"points":[["x":0.1,"y":0.2,"p":0.3,"t":0.0],["x":0.8,"y":0.7,"p":0.9,"t":4.0]]],
            "style":["color":"blue","width":0.003,"opacity":0.45]]
        let objects=f.rows+[row], tokens=f.tokens+[NativePDFCommittedVisualToken(object:row)]
        let added = try XCTUnwrap(builder.make(page:f.page,objects:objects,tokens:tokens,highlights:[],image:{ _ in nil }))
        let canonical = try XCTUnwrap(NativePDFObjectRenderer.pageTransform(mapper))
        let moves: [CGAffineTransform] = [.identity, CGAffineTransform(translationX: 77.25,y: -31.6),
            CGAffineTransform(translationX: 350,y: 0).rotated(by: .pi/2).scaledBy(x: 0.7,y: 0.7),
            CGAffineTransform(a:1.4,b:0.18,c:-0.12,d:0.81,tx:20.4,ty:-32.2)]
        let current = try XCTUnwrap(NativePDFRenderViewport(canvasBounds: canvas,
            visibleRect:CGRect(x:80,y:50,width:160,height:210),canvasToWindow:.identity,screenScale:2))
        for source in sources {
            let raster = await Task.detached(priority:.userInitiated) {
                initial.raster(bounds:source.canvasRect,scale:source.pixelScale,canonicalToCanvas:canonical)
            }.value
            let image=UIImage(cgImage:try XCTUnwrap(raster?.image),scale:source.pixelScale,orientation:.up)
            let retained=try XCTUnwrap(NativePDFRetainedInkBackdrop(image:image,snapshot:initial,mapper:mapper,
                viewport:source,objects:f.rows,tokens:f.tokens,highlights:[],imageForObject:{ _ in nil }))
            let view=NativePDFNavigationView(frame:canvas)
            view.retainContinuity(retained,mapper:mapper,viewport:source)
            view.updateContinuity(snapshot:added,objects:objects,tokens:tokens,localInkIDs:["registration-local"])
            let clip=try XCTUnwrap(view.continuityLayer), pixels=try XCTUnwrap(clip.sublayers?.first)
            let vectors=try XCTUnwrap(pixels.sublayers?.first), shape=try XCTUnwrap(vectors.sublayers?.first as? CAShapeLayer)
            let path=try XCTUnwrap(shape.path)
            var probes:[CGPoint]=[]
            path.applyWithBlock { item in
                let e=item.pointee
                let count:Int
                switch e.type { case .moveToPoint,.addLineToPoint:count=1;case .addQuadCurveToPoint:count=2;case .addCurveToPoint:count=3;case .closeSubpath:count=0;@unknown default:count=0 }
                for i in 0..<count { probes.append(e.points[i]) }
            }
            XCTAssertGreaterThan(probes.count,10)
            for move in moves {
                let moved=InkCoordinateMapper(canvasToPDF:move.inverted().concatenating(mapper.canvasToPDF),geometry:mapper.geometry)
                view.reprojectContinuity(mapper:moved,viewport:current)
                XCTAssertEqual(clip.frame,current.canvasRect);XCTAssertTrue(clip.masksToBounds);XCTAssertTrue(pixels.masksToBounds)
                let sx=source.canvasRect.width/image.size.width, sy=source.canvasRect.height/image.size.height
                for point in probes {
                    let p=point.applying(canonical)
                    let crop=CGPoint(x:source.canvasRect.minX+(p.x-source.canvasRect.minX)*sx,
                                     y:source.canvasRect.minY+(p.y-source.canvasRect.minY)*sy)
                    let expected=crop.applying(move), actual=shape.convert(point,to:view.layer)
                    XCTAssertEqual(actual.x,expected.x,accuracy:1e-8)
                    XCTAssertEqual(actual.y,expected.y,accuracy:1e-8)
                }
            }
            view.clearContinuity()
        }
    }
}
