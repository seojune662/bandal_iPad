import XCTest
import CoreGraphics
import Metal
@testable import Bandal

final class NativePDFInkVertexCacheTests: XCTestCase {
    private func triangles(_ polygons: [[CGPoint]]) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(polygons.reduce(0) { $0 + max(0, $1.count - 2) * 3 })
        for polygon in polygons where polygon.count >= 3 {
            let first = SIMD2(Float(polygon[0].x), Float(polygon[0].y))
            for index in 1..<(polygon.count - 1) {
                output.append(first)
                output.append(SIMD2(Float(polygon[index].x), Float(polygon[index].y)))
                output.append(SIMD2(Float(polygon[index + 1].x), Float(polygon[index + 1].y)))
            }
        }
        return output
    }

    private func referenceBounds(_ vertices: [SIMD2<Float>]) -> CGRect {
        guard let first = vertices.first else { return .null }
        var low = first, high = first
        for point in vertices.dropFirst() {
            low = SIMD2(min(low.x, point.x), min(low.y, point.y))
            high = SIMD2(max(high.x, point.x), max(high.y, point.y))
        }
        // Subtract as CGFloat to match the actual Float endpoints without a
        // second Float rounding of the width or height.
        return CGRect(x: CGFloat(low.x), y: CGFloat(low.y),
                      width: CGFloat(high.x)-CGFloat(low.x), height: CGFloat(high.y)-CGFloat(low.y))
    }

    private func samples(_ count: Int) -> [NativePDFPoint] {
        (0..<count).map { index in
            let step = Double(index)
            return .init(x: 0.1 + step * 0.0003, y: 0.4 + sin(step * 0.03) * 0.05,
                         p: 0.15 + sin(step * 0.19) * 0.05, t: step * 1000 / 240)
        }
    }

    func testSuffixMeshMatchesFullReplayAfterPredictionsCorrectionsAndTruncation() {
        let geometry = NativePDFInkGeometryV3Cache(), mesh = NativePDFInkVertexCache()
        let measured = samples(100)
        func check(_ points: [NativePDFPoint]) {
            let polygons = geometry.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
            mesh.update(polygons, retainedPrefix: geometry.retainedPrefixPolygonCount, revision: geometry.revision)
            XCTAssertEqual(mesh.vertices, triangles(polygons))
            XCTAssertEqual(mesh.bounds, referenceBounds(mesh.vertices))
        }
        check(Array(measured.prefix(40)))
        check(Array(measured.prefix(44)))
        XCTAssertEqual(mesh.rebuiltVertexCount, 4 * 96)
        var prediction = Array(measured.prefix(48))
        for index in 44..<48 { prediction[index].y += 0.01 }
        check(prediction)
        check(Array(measured.prefix(48)))
        XCTAssertEqual(mesh.rebuiltVertexCount, 4 * 96)
        var corrected = Array(measured.prefix(48)); corrected[5].p = 0.9
        check(corrected)
        check(Array(corrected.prefix(3)))
        XCTAssertEqual(mesh.rebuiltVertexCount, 0)
        check(Array(measured.prefix(12)))
        geometry.reset()
        check([.init(x: 0.7, y: 0.8, p: 0.4, t: 0)])
        XCTAssertEqual(mesh.vertices.count, 90)
    }

    func testSkippedGeometryRevisionCannotKeepAnUnrenderedCorrection() {
        let geometry = NativePDFInkGeometryV3Cache(), mesh = NativePDFInkVertexCache()
        var points = samples(40)
        let original = geometry.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        mesh.update(original, retainedPrefix: geometry.retainedPrefixPolygonCount, revision: geometry.revision)
        points[2].y += 0.1
        // Simulate currentDrawable being unavailable: geometry advanced but
        // the GPU encoder never received this correction.
        _ = geometry.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        points.append(contentsOf: samples(44).suffix(4))
        let latest = geometry.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        XCTAssertGreaterThan(geometry.retainedPrefixPolygonCount, 50)
        mesh.update(latest, retainedPrefix: geometry.retainedPrefixPolygonCount, revision: geometry.revision)
        XCTAssertLessThan(mesh.retainedPrefixPolygonCount, 5)
        XCTAssertEqual(mesh.vertices, triangles(latest))
        XCTAssertEqual(mesh.bounds, referenceBounds(mesh.vertices))
        mesh.update(latest, retainedPrefix: 0, revision: geometry.revision)
        XCTAssertEqual(mesh.rebuiltVertexCount, 0, "Retrying the same revision reuses an identical mesh")
    }

    func testBoundsShrinkWithTailReplacementCorrectionTruncationAndEmpty() {
        let mesh = NativePDFInkVertexCache()
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x+width, y: y),
             CGPoint(x: x+width, y: y+height), CGPoint(x: x, y: y+height)]
        }
        var polygons = [rect(0.1,0.2,0.05,0.1), rect(0.3,0.4,0.1,0.1), rect(0.8,0.9,0.15,0.05)]
        mesh.update(polygons, revision: 1)
        XCTAssertEqual(mesh.bounds, referenceBounds(triangles(polygons)))
        let predictedBounds = mesh.bounds
        polygons[2] = rect(0.45,0.5,0.02,0.01)
        mesh.update(polygons, retainedPrefix: 2, revision: 2)
        XCTAssertEqual(mesh.bounds, referenceBounds(triangles(polygons)))
        XCTAssertLessThan(mesh.bounds.maxX, predictedBounds.maxX)
        XCTAssertLessThan(mesh.bounds.maxY, predictedBounds.maxY)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 4)
        polygons[0] = rect(0.11,0.21,0.01,0.02) // Earlier pressure/shape correction.
        mesh.update(polygons, retainedPrefix: 0, revision: 3)
        XCTAssertEqual(mesh.bounds, referenceBounds(triangles(polygons)))
        polygons.removeLast(2)
        mesh.update(polygons, retainedPrefix: 1, revision: 4)
        XCTAssertEqual(mesh.bounds, referenceBounds(triangles(polygons)))
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 0)
        mesh.update([], retainedPrefix: 0, revision: 5)
        XCTAssertTrue(mesh.bounds.isNull); XCTAssertTrue(mesh.vertices.isEmpty)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 0)
        mesh.update(polygons, revision: 6)
        XCTAssertEqual(mesh.bounds, referenceBounds(triangles(polygons)))
    }

    func testBoundsReuseVisitsOnlyNewSuffixAndSkipsNonRenderingContours() {
        let mesh = NativePDFInkVertexCache()
        let triangle = [CGPoint(x: 0.123456789, y: 0.2), CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.7, y: 0.5)]
        var polygons = Array(repeating: triangle, count: 2_400)
        mesh.update(polygons, revision: 1)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 7_200)
        let before = mesh.bounds
        mesh.update(polygons, retainedPrefix: 2_400, revision: 2)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 0); XCTAssertEqual(mesh.bounds, before)
        polygons += [[], [CGPoint(x: 100, y: 100)], [CGPoint(x: -100, y: -100), CGPoint(x: 100, y: 100)]]
        mesh.update(polygons, retainedPrefix: 2_400, revision: 3)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 0); XCTAssertEqual(mesh.bounds, before)
        polygons.append(triangle.map { CGPoint(x: $0.x+0.5, y: $0.y) })
        mesh.update(polygons, retainedPrefix: 2_403, revision: 4)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 3)
        XCTAssertEqual(mesh.bounds, referenceBounds(triangles(polygons)))
        mesh.update(polygons, retainedPrefix: 0, revision: 4)
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, 0, "An identical revision retry must reuse bounds too")
        mesh.update([[CGPoint(x: 2, y: 3), CGPoint(x: 2, y: 3), CGPoint(x: 2, y: 3)]], revision: 5)
        XCTAssertEqual(mesh.bounds, CGRect(x: 2, y: 3, width: 0, height: 0))
    }

    func testBufferLeasesNeverOverwriteInflightStorageAndAccumulateDirtySuffixes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = NativePDFInkVertexBufferPool(device: device, maximumBuffers: 2)
        var vertices = (0..<100).map { SIMD2<Float>(Float($0), -Float($0)) }
        func contents(_ lease: NativePDFInkVertexBufferPool.Lease, _ count: Int) -> [SIMD2<Float>] {
            Array(UnsafeBufferPointer(start: lease.buffer.contents().assumingMemoryBound(to: SIMD2<Float>.self), count: count))
        }
        let first = try XCTUnwrap(pool.acquire(vertices: vertices)), original = vertices
        vertices[80] = SIMD2(80, 700); pool.invalidate(from: 80)
        let second = try XCTUnwrap(pool.acquire(vertices: vertices))
        XCTAssertFalse(first.buffer === second.buffer)
        XCTAssertEqual(contents(first, original.count), original, "The previous GPU frame retains its input")
        vertices[60] = SIMD2(60, 900); pool.invalidate(from: 60)
        XCTAssertNil(pool.acquire(vertices: vertices), "Backpressure must not allocate indefinitely or overwrite a busy buffer")
        pool.release(first)
        let third = try XCTUnwrap(pool.acquire(vertices: vertices))
        XCTAssertTrue(first.buffer === third.buffer)
        XCTAssertEqual(pool.uploadedVertexCount, 40)
        XCTAssertEqual(contents(third, vertices.count), vertices)
        XCTAssertEqual(contents(second, original.count)[60], original[60])
        pool.release(first)
        XCTAssertNil(pool.acquire(vertices: vertices), "A stale release cannot release a newer lease for the same slot")
        pool.release(second); pool.release(third)
        let fourth = try XCTUnwrap(pool.acquire(vertices: vertices))
        XCTAssertEqual(pool.uploadedVertexCount, 0)
        XCTAssertEqual(pool.allocationCount, 2)
        pool.release(fourth)
    }

    func testGrowingOneBufferPreservesTheOtherInflightFrame() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = NativePDFInkVertexBufferPool(device: device, maximumBuffers: 2)
        let initial = [SIMD2<Float>(0.3, 0.7)]
        let first = try XCTUnwrap(pool.acquire(vertices: initial))
        let second = try XCTUnwrap(pool.acquire(vertices: initial))
        pool.release(second)
        let long = (0..<20_000).map { SIMD2<Float>(Float($0), 0.5) }
        pool.invalidate(from: 0)
        let grown = try XCTUnwrap(pool.acquire(vertices: long))
        XCTAssertFalse(grown.buffer === second.buffer)
        XCTAssertEqual(first.buffer.contents().assumingMemoryBound(to: SIMD2<Float>.self).pointee, initial[0])
        XCTAssertGreaterThanOrEqual(grown.buffer.length, long.count * MemoryLayout<SIMD2<Float>>.stride)
        XCTAssertEqual(pool.uploadedVertexCount, long.count)
        pool.release(first); pool.release(grown)
    }

    func testTenSecondStrokeRebuildsAndUploadsOnlyFourNewSamples() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pool = NativePDFInkVertexBufferPool(device: device)
        let geometry = NativePDFInkGeometryV3Cache(), mesh = NativePDFInkVertexCache(), points = samples(2400)
        let prefix = geometry.polygons(points: Array(points.dropLast(4)), width: 0.004, aspect: 1.5, highlighter: false)
        pool.invalidate(from: mesh.update(prefix, retainedPrefix: geometry.retainedPrefixPolygonCount, revision: geometry.revision))
        let first = try XCTUnwrap(pool.acquire(vertices: mesh.vertices)); pool.release(first)
        let polygons = geometry.polygons(points: points, width: 0.004, aspect: 1.5, highlighter: false)
        let start = Date.timeIntervalSinceReferenceDate
        pool.invalidate(from: mesh.update(polygons, retainedPrefix: geometry.retainedPrefixPolygonCount, revision: geometry.revision))
        let second = try XCTUnwrap(pool.acquire(vertices: mesh.vertices))
        let incrementalMS = (Date.timeIntervalSinceReferenceDate - start) * 1000
        let referenceStart = Date.timeIntervalSinceReferenceDate
        let reference = triangles(polygons)
        let fullMS = (Date.timeIntervalSinceReferenceDate - referenceStart) * 1000
        XCTAssertEqual(mesh.vertices, reference)
        XCTAssertEqual(mesh.vertices.count, 2400 * 96 - 6)
        XCTAssertEqual(mesh.rebuiltVertexCount, 384)
        let changedBoundsPoints = polygons.dropFirst(geometry.retainedPrefixPolygonCount).filter { $0.count >= 3 }.reduce(0) { $0+$1.count }
        XCTAssertEqual(mesh.rebuiltBoundsPointCount, changedBoundsPoints)
        XCTAssertEqual(mesh.bounds, referenceBounds(reference))
        XCTAssertEqual(pool.uploadedVertexCount, 384)
        XCTAssertTrue(first.buffer === second.buffer)
        pool.release(second)
        print("Native ink mesh: 2400-point stroke, 384/230394 vertices rebuilt/uploaded; incremental mesh+upload \(incrementalMS) ms vs full CPU triangulation \(fullMS) ms; excludes input/display latency")
    }
}
