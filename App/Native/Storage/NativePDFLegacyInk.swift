import Foundation
import CoreGraphics

/// Swift port of the configured perfect-freehand 1.2.3 path used by the
/// desktop's unversioned strokes. Versioned ink retains its existing geometry.
/// Algorithm adapted from perfect-freehand, Copyright (c) 2021 Steve Ruiz,
/// MIT License (see NativePDFLegacyInk-LICENSE.txt).
enum NativePDFLegacyInk {
    private struct Point: Equatable {
        var x: Double, y: Double
        static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, y: a.y * b) }
        var length: Double { hypot(x, y) }
        var perpendicular: Self { .init(x: y, y: -x) }
        var unit: Self { self * (1 / length) }
        func dot(_ other: Self) -> Double { x * other.x + y * other.y }
        func lerp(_ other: Self, _ t: Double) -> Self { self + (other - self) * t }
        func distanceSquared(_ other: Self) -> Double { let d = self - other; return d.x * d.x + d.y * d.y }
        func rotated(around center: Self, _ angle: Double) -> Self {
            let d = self - center, c = cos(angle), s = sin(angle)
            return .init(x: d.x * c - d.y * s + center.x, y: d.x * s + d.y * c + center.y)
        }
    }
    private struct StrokePoint { var point: Point, pressure: Double, vector: Point, distance: Double, runningLength: Double }
    static func path(_ row: [String: Any], aspect: Double) throws -> String {
        let v = NativePDFRepositoryValidation.self
        let data = try v.object(row["data"], "data"), style = try v.object(row["style"], "style")
        guard let raw = data["points"] as? [[String: Any]], !raw.isEmpty else { throw v.error("Legacy ink is missing its points") }
        let points: [NativePDFPoint] = try raw.map { .init(x: try v.number($0["x"], "x"), y: try v.number($0["y"], "y"), p: try v.number($0["p"], "p")) }
        let width = try v.number(style["width"], "width", positive: true), highlighter = row["kind"] as? String == "highlighter"
        guard aspect.isFinite, aspect > 0 else { throw v.error("Invalid PDF page aspect") }
        if !points.contains(where: { $0.x != points[0].x || $0.y != points[0].y }) {
            return NativePDFInkGeometry.polygons(points: points, width: width, aspect: aspect, highlighter: highlighter).map { polygon in
                guard let first = polygon.first else { return "" }
                return "M \(Double(first.x)) \(Double(first.y))" + polygon.dropFirst().map { " L \(Double($0.x)) \(Double($0.y))" }.joined() + " Z"
            }.joined(separator: " ")
        }
        let outline = outline(points: points, width: width, aspect: aspect, highlighter: highlighter)
        guard outline.count >= 3, outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw v.error("Legacy ink outline could not be reconstructed") }
        func normalized(_ point: Point) -> Point { .init(x: point.x / 1000, y: point.y / 1000 / aspect) }
        let first = normalized(outline[0]); var result = "M \(first.x) \(first.y)"
        for index in 1..<(outline.count - 1) {
            let a = normalized(outline[index]), b = normalized(outline[index + 1])
            result += " Q \(a.x) \(a.y) \((a.x + b.x) / 2) \((a.y + b.y) / 2)"
        }
        return result + " Z"
    }
    private static func strokePoints(_ values: [NativePDFPoint], size: Double, aspect: Double) -> [StrokePoint] {
        var input = values.map { (Point(x: $0.x * 1000, y: $0.y * aspect * 1000), Optional($0.p)) }
        // The library intentionally omits pressure on the interpolated points
        // in its two-point special case, falling back to 0.5 afterwards.
        if input.count == 2 {
            let first = input[0], last = input[1]; input = [first]
            for index in 1..<5 { input.append((first.0.lerp(last.0, Double(index) / 4), nil)) }
        }
        if input.count == 1 { input.append((input[0].0 + Point(x: 1, y: 1), input[0].1)) }
        var previous = StrokePoint(point: input[0].0, pressure: input[0].1 ?? 0.25, vector: .init(x: 1, y: 1), distance: 0, runningLength: 0)
        var result = [previous], reached = false, running = 0.0
        for index in 1..<input.count {
            let point = index == input.count - 1 ? input[index].0 : previous.point.lerp(input[index].0, 0.15 + (1 - 0.42) * 0.85)
            if point == previous.point { continue }
            let distance = (point - previous.point).length; running += distance
            if index < input.count - 1, !reached { if running < size { continue }; reached = true }
            previous = StrokePoint(point: point, pressure: input[index].1 ?? 0.5, vector: (previous.point - point).unit, distance: distance, runningLength: running)
            result.append(previous)
        }
        result[0].vector = result.count > 1 ? result[1].vector : .init(x: 0, y: 0)
        return result
    }
    private static func outline(points input: [NativePDFPoint], width: Double, aspect: Double, highlighter: Bool) -> [Point] {
        let size = width * 1000, thinning = highlighter ? 0.08 : 0.62, taper = size * 2
        let points = strokePoints(input, size: size, aspect: aspect), total = points.last!.runningLength
        let minimumDistance = pow(size * 0.55, 2), pi = Double.pi + 0.0001
        var left: [Point] = [], right: [Point] = [], firstRadius: Double?
        var radius = size * (0.5 - thinning * (0.5 - points.last!.pressure))
        var previousVector = points[0].vector, previousLeft = points[0].point, previousRight = points[0].point, previousSharp = false
        for index in points.indices {
            let value = points[index], last = index == points.count - 1
            if !last, total - value.runningLength < 3 { continue }
            radius = size * (0.5 - thinning * (0.5 - value.pressure))
            if firstRadius == nil { firstRadius = radius }
            let start = value.runningLength < taper ? value.runningLength / taper : 1
            let end = total - value.runningLength < taper ? (total - value.runningLength) / taper : 1
            radius = max(0.01, radius * min(start * (2 - start), pow(end - 1, 3) + 1))
            let next = last ? value.vector : points[index + 1].vector
            let nextDot = last ? 1 : value.vector.dot(next), previousDot = value.vector.dot(previousVector)
            let sharp = previousDot < 0 && !previousSharp, nextSharp = nextDot < 0
            if sharp || nextSharp {
                let offset = previousVector.perpendicular * radius, step = 1.0 / 13
                var t = 0.0
                while t <= 1 {
                    previousLeft = (value.point - offset).rotated(around: value.point, pi * t)
                    previousRight = (value.point + offset).rotated(around: value.point, pi * -t)
                    left.append(previousLeft); right.append(previousRight); t += step
                }
                if nextSharp { previousSharp = true }; continue
            }
            previousSharp = false
            if last {
                let offset = value.vector.perpendicular * radius
                left.append(value.point - offset); right.append(value.point + offset); continue
            }
            let offset = next.lerp(value.vector, nextDot).perpendicular * radius
            let a = value.point - offset, b = value.point + offset
            if index <= 1 || previousLeft.distanceSquared(a) > minimumDistance { left.append(a); previousLeft = a }
            if index <= 1 || previousRight.distanceSquared(b) > minimumDistance { right.append(b); previousRight = b }
            previousVector = value.vector
        }
        if points.count == 1 {
            let center = points[0].point, first = center + Point(x: -1, y: 1).unit * -(firstRadius ?? radius)
            var dot: [Point] = [], t = 1.0 / 13
            while t <= 1 { dot.append(first.rotated(around: center, pi * 2 * t)); t += 1.0 / 13 }
            return dot
        }
        // Both ends are always tapered in Bandal's stored legacy contract.
        return left + [points.last!.point] + right.reversed()
    }
}
