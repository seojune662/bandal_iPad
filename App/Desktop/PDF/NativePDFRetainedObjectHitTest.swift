import Foundation
import CoreGraphics

/// Prepared deletion geometry for legacy ink and non-ink objects. Modern
/// versioned ink keeps NativePDFRetainedInkHitTest's pressure-polygon policy.
/// This preserves the JS kind geometry and width threshold, but sweeps between
/// measured samples instead of testing isolated samples. Predictions must not
/// reach this API. Display/GPU eligibility and durable deletion are caller-owned.
enum NativePDFRetainedObjectHitTest {
    final class Geometry {
        let aspect: Double
        let threshold: CGFloat
        let pointCount: Int
        /// Metric bounds including the eraser threshold, prepared once.
        let bounds: CGRect
        fileprivate let points: [CGPoint]
        fileprivate let filledBox: CGRect?

        fileprivate init(aspect: Double, threshold: CGFloat, points: [CGPoint], bounds: CGRect, filledBox: CGRect?) {
            self.aspect = aspect; self.threshold = threshold; self.points = points
            self.pointCount = points.count; self.bounds = bounds; self.filledBox = filledBox
        }
    }

    struct Entry {
        let savedID: String
        let mutationID: String?
        let geometry: Geometry
    }

    private struct Segment {
        let start: CGPoint, end: CGPoint, bounds: CGRect
    }
    static let maximumPointCount = 250_000

    /// Copies only hit-test primitives, never retaining mutable JSON containers.
    /// Caller reuses this immutable result until the row's hit inputs change.
    /// nil means unsupported: malformed/locationless rows never authorize an
    /// everywhere-delete. This is not a full text/image source schema validator.
    static func prepare(object: [String: Any], aspect: Double) -> Geometry? {
        guard aspect.isFinite, aspect > 0,
              let kind = object["kind"] as? String,
              let data = object["data"] as? [String: Any],
              let style = object["style"] as? [String: Any],
              let width = number(style["width"]), width > 0 else { return nil }
        let threshold = max(0.007, width / 2 + 0.005)
        let points: [CGPoint]
        var filledBox: CGRect?
        switch kind {
        case "ink", "highlighter":
            // An absent version is the historical perfect-freehand renderer.
            // Explicit 2/3/4, and unknown versions, belong to another policy.
            guard data["inkVersion"] == nil,
                  let source = data["points"] as? [[String: Any]],
                  !source.isEmpty, source.count <= maximumPointCount else { return nil }
            var copied: [CGPoint] = []; copied.reserveCapacity(source.count)
            for value in source {
                guard let point = metricPoint(value, aspect: aspect) else { return nil }
                copied.append(point)
            }
            points = copied
        case "line", "arrow":
            // JS uses first/last endpoints, not intermediate points or the
            // arrow's visible wings. A box is the historical endpoint fallback.
            if let raw = data["points"] {
                guard let source = raw as? [[String: Any]], source.count <= maximumPointCount else { return nil }
                if source.count >= 2 {
                    guard let first = metricPoint(source[0], aspect: aspect),
                          let last = metricPoint(source[source.count - 1], aspect: aspect) else { return nil }
                    points = [first, last]
                } else {
                    guard let box = metricBox(data["box"], aspect: aspect) else { return nil }
                    points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
                }
            } else {
                guard let box = metricBox(data["box"], aspect: aspect) else { return nil }
                points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)]
            }
        case "rect", "ellipse", "textbox", "image", "clip":
            guard let box = metricBox(data["box"], aspect: aspect) else { return nil }
            if kind == "ellipse" {
                points = (0...32).map { index in
                    let angle = CGFloat(index) / 32 * .pi * 2
                    return CGPoint(x: box.midX + cos(angle) * box.width / 2,
                                   y: box.midY + sin(angle) * box.height / 2)
                }
            } else {
                points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                          CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY),
                          CGPoint(x: box.minX, y: box.minY)]
                if kind == "textbox" { filledBox = box }
            }
        default: return nil
        }
        guard let rawBounds = bounds(points), threshold.isFinite else { return nil }
        let expanded = rawBounds.insetBy(dx: -threshold, dy: -threshold)
        guard finite(expanded) else { return nil }
        return Geometry(aspect: aspect, threshold: threshold, points: points, bounds: expanded, filledBox: filledBox)
    }

    /// Results are an ordered subset of entries. No String equality/set is used:
    /// canonically-equivalent but distinct UTF8 IDs and aliases remain distinct.
    /// The scene owner validates identity uniqueness before calling this helper.
    static func hits(entries: [Entry], points: [CGPoint], previous: CGPoint? = nil) -> [Entry] {
        guard !points.isEmpty, points.allSatisfy(finite), previous.map(finite) ?? true else { return [] }
        let source = previous.map { [$0] + points } ?? points
        var byAspect: [Double: [Segment]] = [:]
        var result: [Entry] = []
        for entry in entries {
            let geometry = entry.geometry
            let segments: [Segment]
            if let cached = byAspect[geometry.aspect] { segments = cached }
            else {
                let metric = source.map { CGPoint(x: $0.x, y: $0.y * geometry.aspect) }
                guard metric.allSatisfy(finite), let prepared = makeSegments(metric) else { continue }
                segments = prepared; byAspect[geometry.aspect] = prepared
            }
            if segments.contains(where: { hit(geometry, segment: $0) }) { result.append(entry) }
        }
        return result
    }

    private static func hit(_ geometry: Geometry, segment: Segment) -> Bool {
        guard overlaps(geometry.bounds, segment.bounds) else { return false }
        if let box = geometry.filledBox,
           contains(box, segment.start) || contains(box, segment.end) { return true }
        let points = geometry.points
        if points.count == 1 { return pointDistance(points[0], segment.start, segment.end) <= geometry.threshold }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            if intersects(segment.start, segment.end, a, b) { return true }
            let distance = min(min(pointDistance(segment.start, a, b), pointDistance(segment.end, a, b)),
                               min(pointDistance(a, segment.start, segment.end), pointDistance(b, segment.start, segment.end)))
            if distance <= geometry.threshold { return true }
        }
        return false
    }

    private static func metricPoint(_ value: [String: Any], aspect: Double) -> CGPoint? {
        guard let x = number(value["x"]), let y = number(value["y"]) else { return nil }
        let point = CGPoint(x: x, y: y * aspect)
        return finite(point) ? point : nil
    }
    private static func metricBox(_ value: Any?, aspect: Double) -> CGRect? {
        guard let value = value as? [String: Any], let x = number(value["x"]), let y = number(value["y"]),
              let width = number(value["width"]), let height = number(value["height"]),
              width >= 0, height >= 0 else { return nil }
        let box = CGRect(x: x, y: y * aspect, width: width, height: height * aspect)
        return finite(box) ? box : nil
    }
    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return CGFloat(number.doubleValue)
    }
    private static func bounds(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first, points.allSatisfy(finite) else { return nil }
        var left = first.x, right = first.x, top = first.y, bottom = first.y
        for point in points.dropFirst() {
            left = min(left, point.x); right = max(right, point.x)
            top = min(top, point.y); bottom = max(bottom, point.y)
        }
        let result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        return finite(result) ? result : nil
    }
    private static func makeSegments(_ points: [CGPoint]) -> [Segment]? {
        guard let first = points.first else { return nil }
        if points.count == 1 { return [Segment(start: first, end: first, bounds: CGRect(origin: first, size: .zero))] }
        var result: [Segment] = []; result.reserveCapacity(points.count - 1)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            guard let box = bounds([a, b]), hypot(b.x - a.x, b.y - a.y).isFinite else { return nil }
            result.append(Segment(start: a, end: b, bounds: box))
        }
        return result
    }
    private static func pointDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
        if length == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let ux = dx / length, uy = dy / length
        let projection = min(length, max(0, (p.x - a.x) * ux + (p.y - a.y) * uy))
        return hypot(p.x - a.x - projection * ux, p.y - a.y - projection * uy)
    }
    private static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        guard max(min(a.x,b.x),min(c.x,d.x)) <= min(max(a.x,b.x),max(c.x,d.x)),
              max(min(a.y,b.y),min(c.y,d.y)) <= min(max(a.y,b.y),max(c.y,d.y)) else { return false }
        func side(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y, px = p.x - a.x, py = p.y - a.y
            let scale = max(max(abs(dx), abs(dy)), max(abs(px), abs(py)))
            if scale == 0 { return 0 }
            return (dx / scale) * (py / scale) - (dy / scale) * (px / scale)
        }
        func oppositeOrZero(_ x: CGFloat, _ y: CGFloat) -> Bool { x == 0 || y == 0 || (x < 0) != (y < 0) }
        return oppositeOrZero(side(a,b,c),side(a,b,d)) && oppositeOrZero(side(c,d,a),side(c,d,b))
    }
    private static func contains(_ box: CGRect, _ p: CGPoint) -> Bool {
        p.x >= box.minX && p.x <= box.maxX && p.y >= box.minY && p.y <= box.maxY
    }
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY
    }
    private static func finite(_ p: CGPoint) -> Bool { p.x.isFinite && p.y.isFinite }
    private static func finite(_ r: CGRect) -> Bool {
        [r.minX,r.minY,r.maxX,r.maxY,r.width,r.height].allSatisfy(\.isFinite) && r.width >= 0 && r.height >= 0
    }
}
