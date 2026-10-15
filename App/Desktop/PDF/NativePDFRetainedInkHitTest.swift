import Foundation
import CoreGraphics

/// Whole-stroke native erasing against the actual rendered convex union.
/// Coordinates are normalized page coordinates; distance uses (x, y * aspect)
/// so radius is measured in page-width units, independent of page orientation.
/// The default .005 padding follows the old eraser's outer margin. It is NOT
/// the old centerline rule max(.007, style.width/2 + .005): actual V3/V4 pressure
/// changes the filled width. Opacity-zero strokes remain erasable, as before.
@MainActor
final class NativePDFRetainedInkHitTest {
    typealias Entry = NativePDFRetainedInkScene.Entry
    private struct Polygon {
        let points: [CGPoint]
        let bounds: CGRect
    }
    private struct Geometry {
        let prepared: NativePDFPreparedInk
        let polygons: [Polygon]
        let accountedBytes: Int
    }
    private struct Segment {
        let start: CGPoint, end: CGPoint, bounds: CGRect
    }
    private var cache: [ObjectIdentifier: Geometry] = [:]
    let maximumCachedBytes: Int
    private(set) var retainedBytes = 0
    private(set) var geometryBuildCount = 0
    private(set) var geometryReuseCount = 0
    private(set) var streamingFallbackCount = 0
    var retainedGeometryCount: Int { cache.count }

    /// Conservative cache accounting, not a measurement of Swift heap bytes.
    /// Oversized paths are tested contour-by-contour without a retained copy.
    init(maximumCachedBytes: Int = 64 * 1024 * 1024) {
        self.maximumCachedBytes = max(0, maximumCachedBytes)
    }

    /// Pass all measured/coalesced points in event order. A previous event's
    /// last measured point closes the gap; predicted points must not erase.
    /// Results retain scene order and distinct exact-UTF8 identities. This
    /// performs no mutation, writes, ACK processing, or tombstone retirement.
    func hits(entries: [Entry], points: [CGPoint], previous: CGPoint? = nil,
              radius: CGFloat = 0.005) -> [Entry] {
        retainOnly(entries)
        guard radius.isFinite, radius >= 0, !points.isEmpty,
              points.allSatisfy(Self.finite), previous.map(Self.finite) ?? true else { return [] }
        let source = previous.map { [$0] + points } ?? points
        var result: [Entry] = []
        // A scene normally has one aspect. Keep an exact per-aspect segment
        // cache so accidental mixed scenes never borrow another page's metric.
        var byAspect: [Double: [Segment]] = [:]
        for entry in entries {
            let aspect = entry.prepared.aspect
            let segments: [Segment]
            if let old = byAspect[aspect] { segments = old }
            else {
                let metric = source.map { CGPoint(x: $0.x, y: $0.y * aspect) }
                guard metric.allSatisfy(Self.finite) else { continue }
                segments = Self.segments(metric, radius: radius); byAspect[aspect] = segments
            }
            let rawBounds = entry.prepared.bounds
            let bounds = CGRect(x: rawBounds.minX, y: rawBounds.minY * aspect,
                                width: rawBounds.width, height: rawBounds.height * aspect)
            guard Self.finite(bounds), segments.contains(where: { Self.overlaps(bounds, $0.bounds) }) else { continue }
            let key = ObjectIdentifier(entry.prepared)
            if let geometry = cache[key], geometry.prepared === entry.prepared {
                geometryReuseCount += 1
                if Self.hit(geometry.polygons, segments: segments, radius: radius) { result.append(entry) }
                continue
            }
            let size = entry.prepared.vertexCount.multipliedReportingOverflow(by: 64)
            let charge = size.partialValue.addingReportingOverflow(256)
            if !size.overflow, !charge.overflow, charge.partialValue <= maximumCachedBytes - retainedBytes {
                let polygons = Self.polygons(entry.path, aspect: aspect)
                geometryBuildCount += 1
                cache[key] = Geometry(prepared: entry.prepared, polygons: polygons, accountedBytes: charge.partialValue)
                retainedBytes += charge.partialValue
                if Self.hit(polygons, segments: segments, radius: radius) { result.append(entry) }
            } else {
                streamingFallbackCount += 1
                if Self.streamHit(entry.path, aspect: aspect, segments: segments, radius: radius) { result.append(entry) }
            }
        }
        return result
    }

    func removeAll() { cache.removeAll(); retainedBytes = 0 }
    private func retainOnly(_ entries: [Entry]) {
        let used = Set(entries.map { ObjectIdentifier($0.prepared) })
        let retired = cache.keys.filter { !used.contains($0) }
        for key in retired {
            if let old = cache.removeValue(forKey: key) { retainedBytes -= old.accountedBytes }
        }
    }
    private static func segments(_ points: [CGPoint], radius: CGFloat) -> [Segment] {
        if points.count == 1 { return [segment(points[0], points[0], radius: radius)] }
        return (1..<points.count).map { segment(points[$0 - 1], points[$0], radius: radius) }
    }
    private static func segment(_ a: CGPoint, _ b: CGPoint, radius: CGFloat) -> Segment {
        Segment(start: a, end: b, bounds: CGRect(x: min(a.x,b.x)-radius, y: min(a.y,b.y)-radius,
            width: abs(b.x-a.x)+radius*2, height: abs(b.y-a.y)+radius*2))
    }
    private static func polygons(_ path: CGPath, aspect: Double) -> [Polygon] {
        var result: [Polygon] = []
        forEachPolygon(path, aspect: aspect) { result.append($0) }
        return result
    }
    private static func streamHit(_ path: CGPath, aspect: Double, segments: [Segment], radius: CGFloat) -> Bool {
        var found = false
        forEachPolygon(path, aspect: aspect) { polygon in
            if !found { found = segments.contains { hit(polygon, segment: $0, radius: radius) } }
        }
        return found
    }
    private static func forEachPolygon(_ path: CGPath, aspect: Double, _ body: @escaping (Polygon) -> Void) {
        var contour: [CGPoint] = []
        path.applyWithBlock { value in
            switch value.pointee.type {
            case .moveToPoint: contour.removeAll(keepingCapacity: true); fallthrough
            case .addLineToPoint:
                let p = value.pointee.points[0]; contour.append(CGPoint(x: p.x, y: p.y * aspect))
            case .closeSubpath:
                if contour.count >= 3, contour.allSatisfy(finite) {
                    var left = contour[0].x, right = left, top = contour[0].y, bottom = top
                    for p in contour.dropFirst() {
                        left = min(left,p.x); right = max(right,p.x)
                        top = min(top,p.y); bottom = max(bottom,p.y)
                    }
                    let bounds = CGRect(x: left, y: top, width: right-left, height: bottom-top)
                    if finite(bounds) { body(Polygon(points: contour, bounds: bounds)) }
                }
                contour.removeAll(keepingCapacity: true)
            default: break // Only generated PreparedInk reaches this helper.
            }
        }
    }
    private static func hit(_ polygons: [Polygon], segments: [Segment], radius: CGFloat) -> Bool {
        polygons.contains { polygon in segments.contains { hit(polygon, segment: $0, radius: radius) } }
    }
    private static func hit(_ polygon: Polygon, segment: Segment, radius: CGFloat) -> Bool {
        guard overlaps(polygon.bounds, segment.bounds) else { return false }
        if contains(segment.start, polygon.points) || contains(segment.end, polygon.points) { return true }
        let points = polygon.points
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            if intersects(segment.start, segment.end, a, b) { return true }
            let distance = min(min(pointDistance(segment.start, a, b), pointDistance(segment.end, a, b)),
                               min(pointDistance(a, segment.start, segment.end), pointDistance(b, segment.start, segment.end)))
            if distance <= radius { return true }
        }
        return false
    }
    private static func contains(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
        var positive = false, negative = false
        for index in polygon.indices {
            let value = cross(polygon[index], polygon[(index + 1) % polygon.count], point)
            if value > 0 { positive = true }
            else if value < 0 { negative = true }
            if positive && negative { return false }
        }
        return positive || negative
    }
    private static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        guard max(min(a.x,b.x),min(c.x,d.x)) <= min(max(a.x,b.x),max(c.x,d.x)),
              max(min(a.y,b.y),min(c.y,d.y)) <= min(max(a.y,b.y),max(c.y,d.y)) else { return false }
        func oppositeOrZero(_ x: CGFloat, _ y: CGFloat) -> Bool { x == 0 || y == 0 || (x < 0) != (y < 0) }
        return oppositeOrZero(cross(a,b,c),cross(a,b,d)) && oppositeOrZero(cross(c,d,a),cross(c,d,b))
    }
    private static func pointDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y, length = hypot(dx,dy)
        if length == 0 { return hypot(p.x-a.x,p.y-a.y) }
        let ux = dx/length, uy = dy/length
        let projection = min(length,max(0,(p.x-a.x)*ux+(p.y-a.y)*uy))
        return hypot(p.x-a.x-projection*ux,p.y-a.y-projection*uy)
    }
    private static func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
    }
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY
    }
    private static func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
    private static func finite(_ r: CGRect) -> Bool {
        [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite) && r.width >= 0 && r.height >= 0
    }
}
