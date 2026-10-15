import Foundation
import CoreGraphics

/// Render-only centripetal curves derived from Doxens' CatmullRomSpline
/// control-point equations. Raw samples remain canonical. Unlike its original
/// whole-stroke RDP pass, only the final measured segment changes on append.
enum NativePDFInkGeometryV4 {
    static let circleSegments = 32
    static let maximumSubdivisionDepth = 5
    static let maximumPredictionPoints = 8
    static let epsilon = 1e-12

    struct Sample: Equatable {
        var x: Double
        var y: Double
        /// Already filtered once at the original measured sample rate.
        var p: Double
    }

    static func tolerance(width: Double) -> Double { min(0.0001, max(0.00001, width * 0.08)) }

    static func valid(points: [NativePDFPoint], width: Double, aspect: Double) -> Bool {
        width.isFinite && width > 0 && aspect.isFinite && aspect > 0 &&
        points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.p.isFinite && ($0.y * aspect).isFinite }
    }

    /// Input/output coordinates are in the aspect-correct page-width metric.
    /// This stable Hermite form is algebraically equivalent to Doxens' direct
    /// centripetal Bezier formula, without subtracting large absolute terms.
    static func controlPoints(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> (cp1: CGPoint, cp2: CGPoint) {
        let edge = subtract(p2, p1), length = hypot(edge.x, edge.y)
        guard length.isFinite, length > epsilon else { return (p1, p2) }
        let incoming = subtract(p1, p0), outgoing = subtract(p3, p2)
        let before = hypot(incoming.x, incoming.y), after = hypot(outgoing.x, outgoing.y)
        let d01 = sqrt(before), d12 = sqrt(length), d23 = sqrt(after)
        var first = CGPoint.zero, second = CGPoint.zero
        if before.isFinite, before > epsilon,
           dot(scale(incoming, 1 / before), scale(edge, 1 / length)) > 0.5 + epsilon {
            let tangent = add(subtract(scale(incoming, 1 / d01), scale(subtract(p2, p0), 1 / (d01 + d12))), scale(edge, 1 / d12))
            first = guardedHandle(scale(tangent, d12 / 3), edge: edge, length: length)
        }
        if after.isFinite, after > epsilon,
           dot(scale(edge, 1 / length), scale(outgoing, 1 / after)) > 0.5 + epsilon {
            let tangent = add(subtract(scale(edge, 1 / d12), scale(subtract(p3, p1), 1 / (d12 + d23))), scale(outgoing, 1 / d23))
            second = guardedHandle(scale(tangent, d12 / 3), edge: edge, length: length)
        }
        return (add(p1, first), subtract(p2, second))
    }

    private static func guardedHandle(_ handle: CGPoint, edge: CGPoint, length: Double) -> CGPoint {
        guard handle.x.isFinite, handle.y.isFinite else { return .zero }
        let axis = scale(edge, 1 / length), size = hypot(handle.x, handle.y)
        guard dot(handle, axis) > 0, size > epsilon else { return .zero }
        let normal = abs(handle.x * axis.y - handle.y * axis.x)
        var factor = min(1, 0.5 * length / size)
        if normal > 0 { factor = min(factor, 0.25 * length / normal) }
        return scale(handle, factor)
    }

    /// Emits only the segment's new endpoints, not its initial measured point.
    /// Storage is bounded by recursion depth; even a 250k-sample saved stroke
    /// can stream directly into CGPath without a giant resampled point array.
    static func forEachSegmentSample(points: [NativePDFPoint], pressures: [Double], index: Int,
                                     width: Double, aspect: Double, _ emit: (Sample) -> Void) {
        guard index >= 0, index + 1 < points.count, pressures.count == points.count else { return }
        let a = points[index], b = points[index + 1]
        let p1 = CGPoint(x: a.x, y: a.y * aspect), p2 = CGPoint(x: b.x, y: b.y * aspect)
        let p0 = index > 0 ? CGPoint(x: points[index - 1].x, y: points[index - 1].y * aspect)
            : subtract(scale(p1, 2), p2)
        let p3 = index + 2 < points.count ? CGPoint(x: points[index + 2].x, y: points[index + 2].y * aspect)
            : subtract(scale(p2, 2), p1)
        let controls = controlPoints(p0: p0, p1: p1, p2: p2, p3: p3)
        let precision = tolerance(width: width)
        func visit(_ start: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint,
                   _ t0: Double, _ t1: Double, _ depth: Int) {
            if depth == maximumSubdivisionDepth || flat(start, c1, c2, end, tolerance: precision) {
                if t1 == 1 {
                    emit(Sample(x: b.x, y: b.y, p: pressures[index + 1]))
                } else {
                    emit(Sample(x: end.x, y: end.y / aspect,
                                p: pressures[index] + (pressures[index + 1] - pressures[index]) * t1))
                }
                return
            }
            let a = midpoint(start, c1), b = midpoint(c1, c2), c = midpoint(c2, end)
            let d = midpoint(a, b), e = midpoint(b, c), center = midpoint(d, e), t = (t0 + t1) / 2
            visit(start, a, d, center, t0, t, depth + 1)
            visit(center, e, c, end, t, t1, depth + 1)
        }
        visit(p1, controls.cp1, controls.cp2, p2, 0, 1, 0)
    }

    private static func flat(_ start: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ end: CGPoint, tolerance: Double) -> Bool {
        let edge = subtract(end, start), length = hypot(edge.x, edge.y)
        guard length > epsilon else {
            return max(hypot(c1.x - start.x, c1.y - start.y), hypot(c2.x - start.x, c2.y - start.y)) <= tolerance
        }
        let axis = scale(edge, 1 / length), a = subtract(c1, start), b = subtract(c2, start)
        return max(abs(a.x * axis.y - a.y * axis.x), abs(b.x * axis.y - b.y * axis.x)) <= tolerance
    }

    static func forEachSegmentPolygon(points: [NativePDFPoint], pressures: [Double], index: Int,
                                      width: Double, aspect: Double, highlighter: Bool, _ emit: ([CGPoint]) -> Void) {
        guard points.indices.contains(index), pressures.indices.contains(index) else { return }
        var previous = Sample(x: points[index].x, y: points[index].y, p: pressures[index])
        forEachSegmentSample(points: points, pressures: pressures, index: index, width: width, aspect: aspect) { sample in
            forEachConnection(previous, sample, width: width, aspect: aspect, highlighter: highlighter, emit)
            previous = sample
        }
    }

    static func forEachPredictionPolygon(lastPoint: NativePDFPoint, pressure: Double, predictions: [NativePDFPoint],
                                         width: Double, aspect: Double, highlighter: Bool, _ emit: ([CGPoint]) -> Void) {
        var previous = Sample(x: lastPoint.x, y: lastPoint.y, p: pressure), count = 0
        for point in predictions {
            guard count < maximumPredictionPoints else { break }
            guard point.x.isFinite, point.y.isFinite, (point.y * aspect).isFinite else { continue }
            let sample = Sample(x: point.x, y: point.y, p: pressure)
            forEachConnection(previous, sample, width: width, aspect: aspect, highlighter: highlighter, emit)
            previous = sample; count += 1
        }
    }

    static func forEachPolygon(points: [NativePDFPoint], predictions: [NativePDFPoint] = [], width: Double,
                               aspect: Double, highlighter: Bool, _ emit: ([CGPoint]) -> Void) {
        guard valid(points: points, width: width, aspect: aspect), let first = points.first else { return }
        let pressures = NativePDFInkGeometryV3.filteredPressures(points)
        emit(disk(Sample(x: first.x, y: first.y, p: pressures[0]), width: width, aspect: aspect, highlighter: highlighter))
        for index in 0..<max(0, points.count - 1) {
            forEachSegmentPolygon(points: points, pressures: pressures, index: index, width: width,
                                  aspect: aspect, highlighter: highlighter, emit)
        }
        forEachPredictionPolygon(lastPoint: points[points.count - 1], pressure: pressures[pressures.count - 1],
                                 predictions: predictions, width: width, aspect: aspect, highlighter: highlighter, emit)
    }

    static func polygons(points: [NativePDFPoint], predictions: [NativePDFPoint] = [], width: Double,
                         aspect: Double, highlighter: Bool) -> [[CGPoint]] {
        var output: [[CGPoint]] = []
        forEachPolygon(points: points, predictions: predictions, width: width, aspect: aspect, highlighter: highlighter) { output.append($0) }
        return output
    }

    static func disk(_ sample: Sample, width: Double, aspect: Double, highlighter: Bool) -> [CGPoint] {
        let r = radius(sample.p, width: width, highlighter: highlighter)
        return (0..<circleSegments).map { step in
            let angle = Double(step) * 2 * .pi / Double(circleSegments)
            return CGPoint(x: sample.x + cos(angle) * r, y: sample.y + sin(angle) * r / aspect)
        }
    }

    /// Same disk/tangent union and winding as v3, with explicitly filtered
    /// pressure. Running v3.polygons on these samples would filter it twice.
    private static func forEachConnection(_ previous: Sample, _ sample: Sample, width: Double,
                                           aspect: Double, highlighter: Bool, _ emit: ([CGPoint]) -> Void) {
        let before = radius(previous.p, width: width, highlighter: highlighter)
        let r = radius(sample.p, width: width, highlighter: highlighter)
        let dx = sample.x - previous.x, dy = (sample.y - previous.y) * aspect
        let distance = hypot(dx, dy), difference = before - r
        if distance.isFinite, distance > abs(difference), distance > epsilon {
            let ux = dx / distance, uy = dy / distance, along = difference / distance
            let across = sqrt(max(0, 1 - along * along))
            let lowX = ux * along + uy * across, lowY = uy * along - ux * across
            let highX = ux * along - uy * across, highY = uy * along + ux * across
            emit([
                CGPoint(x: previous.x + lowX * before, y: previous.y + lowY * before / aspect),
                CGPoint(x: sample.x + lowX * r, y: sample.y + lowY * r / aspect),
                CGPoint(x: sample.x + highX * r, y: sample.y + highY * r / aspect),
                CGPoint(x: previous.x + highX * before, y: previous.y + highY * before / aspect)
            ])
        }
        emit(disk(sample, width: width, aspect: aspect, highlighter: highlighter))
    }

    private static func radius(_ pressure: Double, width: Double, highlighter: Bool) -> Double {
        width * (highlighter ? 1 : 0.42 + 0.20 * pressure) / 2
    }
    private static func add(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    private static func subtract(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    private static func scale(_ a: CGPoint, _ value: Double) -> CGPoint { CGPoint(x: a.x * value, y: a.y * value) }
    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private static func dot(_ a: CGPoint, _ b: CGPoint) -> Double { a.x * b.x + a.y * b.y }
}
