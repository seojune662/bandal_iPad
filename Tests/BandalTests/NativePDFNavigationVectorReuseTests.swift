import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFNavigationVectorReuseTests: XCTestCase {
    typealias Base = NativePDFAsynchronousEditTests
    func testUnchangedAndCorrectedSiblingsReuseLayersAndRawPathsInCurrentOrder() async throws {
        let f = try await Base.Fixture.make(); defer { f.close() }; try await f.settle()
        let mapper = try XCTUnwrap(f.surface.mapper), viewport = try XCTUnwrap(f.surface.renderViewport)
        let builder = NativePDFNavigationSnapshotBuilder()
        let original = try XCTUnwrap(builder.make(page: f.page, objects: f.rows, tokens: f.tokens,
            highlights: [], image: { _ in nil }))
        let retained = try XCTUnwrap(NativePDFRetainedInkBackdrop(image: XCTUnwrap(f.imageView.image), snapshot: original,
            mapper: mapper, viewport: viewport, objects: f.rows, tokens: f.tokens, highlights: [], imageForObject: { _ in nil }))
        let view = NativePDFNavigationView(frame: f.surface.bounds)
        view.retainContinuity(retained, mapper: mapper, viewport: viewport)
        var additions = Self.rows(count: 3, opacity: 0.45)
        let ids = Set(additions.compactMap { $0["id"] as? String })
        var tokens = f.tokens + additions.map(NativePDFCommittedVisualToken.init)
        var snapshot = try XCTUnwrap(builder.make(page: f.page, objects: f.rows + additions, tokens: tokens,
            highlights: [], image: { _ in nil }))
        view.updateContinuity(snapshot: snapshot, objects: f.rows + additions, tokens: tokens, localInkIDs: ids)
        let first = try shapes(view)
        XCTAssertEqual(first.count, 3); XCTAssertEqual(view.continuityShapeCreationCount, 3)
        for (shape, command) in zip(first, snapshot.objects.suffix(3)) {
            guard case .path(let path, _, _, false) = command.content else { return XCTFail("ordinary") }
            XCTAssertEqual(shape.path, path, "CAShapeLayer copies on assignment; copied path must retain exact canonical geometry")
            XCTAssertEqual(shape.bounds.origin, shape.position); XCTAssertEqual(shape.anchorPoint, .zero)
            XCTAssertEqual(shape.fillRule, .nonZero); XCTAssertNil(shape.strokeColor)
            XCTAssertFalse(shape.shouldRasterize)
        }
        view.updateContinuity(snapshot: snapshot, objects: f.rows + additions, tokens: tokens, localInkIDs: ids)
        XCTAssertEqual(view.continuityVectorUpdateCount, 1)
        XCTAssertEqual(view.continuityShapeCreationCount, 3)
        var data = try XCTUnwrap(additions[1]["data"] as? [String: Any])
        var points = try XCTUnwrap(data["points"] as? [[String: Double]])
        points[47]["p"] = 0.97; data["points"] = points; additions[1]["data"] = data
        tokens = f.tokens + additions.map(NativePDFCommittedVisualToken.init)
        snapshot = try XCTUnwrap(builder.make(page: f.page, objects: f.rows + additions, tokens: tokens,
            highlights: [], image: { _ in nil }))
        let oldMiddlePath = first[1].path
        view.updateContinuity(snapshot: snapshot, objects: f.rows + additions, tokens: tokens, localInkIDs: ids)
        let corrected = try shapes(view)
        XCTAssertTrue(zip(first, corrected).allSatisfy { $0 === $1 })
        XCTAssertFalse(corrected[1].path === oldMiddlePath); XCTAssertEqual(view.continuityShapeCreationCount, 3)
        let reordered = [additions[2], additions[0]]
        tokens = f.tokens + reordered.map(NativePDFCommittedVisualToken.init)
        snapshot = try XCTUnwrap(builder.make(page: f.page, objects: f.rows + reordered, tokens: tokens,
            highlights: [], image: { _ in nil }))
        view.updateContinuity(snapshot: snapshot, objects: f.rows + reordered, tokens: tokens, localInkIDs: ids)
        let last = try shapes(view)
        XCTAssertEqual(last.count, 2); XCTAssertTrue(last[0] === first[2]); XCTAssertTrue(last[1] === first[0])
        XCTAssertNil(first[1].superlayer)
        view.clearContinuity(); XCTAssertNil(view.continuityLayer); XCTAssertEqual(view.continuityBitmapCount, 0)
        XCTAssertTrue(last.allSatisfy { $0.superlayer == nil })
    }

    private func shapes(_ view: NativePDFNavigationView) throws -> [CAShapeLayer] {
        let clip = try XCTUnwrap(view.continuityLayer)
        let pixels = try XCTUnwrap(clip.sublayers?.first)
        let vectors = try XCTUnwrap(pixels.sublayers?.first)
        return (vectors.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    }
    private static func rows(count: Int, opacity: Double) -> [[String: Any]] {
        (0..<count).map { i in
            let points: [[String: Double]] = (0..<96).map { j in
                let t=Double(j)/95
                return ["x":0.06+t*0.87,"y":0.12+Double(i%20)*0.035+sin(t*6.28)*0.018,"p":0.2+t*0.65,"t":Double(j)*4]
            }
            return ["id":"vector-\(i)","clientMutationId":"vector-\(i)","page":1,"kind":"ink",
                    "data":["inkVersion":4,"points":points],"style":["color":"blue","width":0.003,"opacity":opacity]]
        }
    }
}
