import Foundation
import CoreGraphics

/// Eraser geometry on canonical rows. Distances are page-width units: y is
/// scaled by the page aspect, like stroke widths and the eraser radius.
enum NativePDFEraseSplit {
    /// Kinds whose points are a freehand centre line. The partial eraser never
    /// cuts shapes, text, images or anything else.
    static let cuttableKinds: Set<String> = ["ink", "highlighter"]

    /// The partial eraser. nil: the eraser missed these samples. Otherwise the
    /// surviving pieces, each with at least two samples; empty means all of it
    /// is gone. Only segments near the eraser are resampled, so the rest of the
    /// stroke keeps its exact samples (pressure, time and tilt included).
    static func cut(_ points: [[String: Any]], path: [CGPoint], reach: Double, aspect: Double) -> [[[String: Any]]]? {
        guard !points.isEmpty, !path.isEmpty, reach > 0, reach.isFinite, aspect > 0, aspect.isFinite else { return nil }
        let eraser = path.map { CGPoint(x: $0.x, y: $0.y * aspect) }
        let near = bounds(eraser).insetBy(dx: -reach, dy: -reach)
        let spacing = max(0.0005, reach / 3)
        var samples: [[String: Any]] = []; samples.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            if index > 0, let a = metric(points[index - 1], aspect), let b = metric(point, aspect),
               near.intersects(bounds([a, b]).insetBy(dx: -spacing, dy: -spacing)) {
                let steps = Int((hypot(b.x - a.x, b.y - a.y) / spacing).rounded(.up))
                if steps > 1 {
                    for step in 1..<steps { samples.append(interpolate(points[index - 1], point, Double(step) / Double(steps))) }
                }
            }
            samples.append(point)
        }
        var pieces: [[[String: Any]]] = [], current: [[String: Any]] = [], erased = false
        for sample in samples {
            guard let p = metric(sample, aspect) else { current.append(sample); continue }
            if near.contains(p), distance(p, to: eraser) <= reach {
                erased = true
                if current.count >= 2 { pieces.append(current) }
                current = []
            } else { current.append(sample) }
        }
        guard erased else { return nil }
        if current.count >= 2 { pieces.append(current) }
        return pieces
    }

    /// The whole-object eraser when the native retained eraser is unavailable:
    /// does the eraser path come within `radius` of this row's ink or box?
    static func touches(_ row: [String: Any], path: [CGPoint], radius: Double, aspect: Double) -> Bool {
        guard let data = row["data"] as? [String: Any], !path.isEmpty, aspect > 0 else { return false }
        let eraser = path.map { CGPoint(x: $0.x, y: $0.y * aspect) }
        if let samples = data["points"] as? [[String: Any]] {
            let width = number((row["style"] as? [String: Any])?["width"]) ?? 0
            let reach = radius + width / 2
            let line = samples.compactMap { metric($0, aspect) }
            guard !line.isEmpty, bounds(line).insetBy(dx: -reach, dy: -reach).intersects(bounds(eraser)) else { return false }
            if line.count == 1 { return distance(line[0], to: eraser) <= reach }
            if eraser.count == 1 { return distance(eraser[0], to: line) <= reach }
            // Segment pairs: a fast eraser crossing a sparse line has no sample near the other's.
            for i in 1..<line.count {
                for j in 1..<eraser.count where crosses(line[i - 1], line[i], eraser[j - 1], eraser[j]) { return true }
            }
            return line.contains { distance($0, to: eraser) <= reach } || eraser.contains { distance($0, to: line) <= reach }
        }
        guard let box = data["box"] as? [String: Any], let x = number(box["x"]), let y = number(box["y"]),
              let width = number(box["width"]), let height = number(box["height"]) else { return false }
        let rect = CGRect(x: x, y: y * aspect, width: width, height: height * aspect).insetBy(dx: -radius, dy: -radius)
        return eraser.contains(where: rect.contains)
    }

    private static func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        return (side(a, b, c) > 0) != (side(a, b, d) > 0) && (side(c, d, a) > 0) != (side(c, d, b) > 0)
    }
    private static func interpolate(_ a: [String: Any], _ b: [String: Any], _ t: Double) -> [String: Any] {
        var value = a
        for key in ["x", "y", "p", "t", "tiltX", "tiltY"] {
            if let start = number(a[key]), let end = number(b[key]) { value[key] = start + (end - start) * t }
        }
        return value
    }
    private static func metric(_ value: [String: Any], _ aspect: Double) -> CGPoint? {
        guard let x = number(value["x"]), let y = number(value["y"]) else { return nil }
        return CGPoint(x: x, y: y * aspect)
    }
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    private static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
    /// Distance from a point to a polyline (or to its only point).
    private static func distance(_ p: CGPoint, to line: [CGPoint]) -> Double {
        guard let first = line.first else { return .infinity }
        if line.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = Double.infinity
        for index in 1..<line.count {
            let a = line[index - 1], b = line[index], dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }
}
