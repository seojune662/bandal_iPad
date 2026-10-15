import Foundation
import CoreGraphics

/// Versioned, render-only width shaping. V4 controls/sampling operate on the
/// render anchors; consecutive stationary pen samples share one anchor. Raw
/// pressure, time, coordinates and tilt remain untouched. Taper is evaluated
/// on local chord-distance samples, including sparse-line endpoint knots.
enum NativePDFInkGeometryV5 {
    static let circleSegments = NativePDFInkGeometryV4.circleSegments
    static let maximumSubdivisionDepth = NativePDFInkGeometryV4.maximumSubdivisionDepth
    static let maximumPredictionPoints = NativePDFInkGeometryV4.maximumPredictionPoints
    static let tailSegmentCount = 16
    static let epsilon = NativePDFInkGeometryV4.epsilon

    struct Sample: Equatable {
        var x: Double
        var y: Double
        /// Diameter divided by the tool's width; this is not pressure.
        var factor: Double
    }

    static func valid(points: [NativePDFPoint], width: Double, aspect: Double) -> Bool {
        NativePDFInkGeometryV4.valid(points: points, width: width, aspect: aspect)
    }

    static func filteredPressures(_ points: [NativePDFPoint]) -> [Double] {
        guard points.allSatisfy({ $0.p.isFinite }) else { return [] }
        return points.indices.map { filteredPressure(points, at: $0) }
    }

    /// At most four original samples, with no dependence on future samples.
    /// Missing/repeated/backwards/nonfinite times use a 4 ms filter interval.
    static func filteredPressure(_ points: [NativePDFPoint], at index: Int) -> Double {
        var sum = 0.0, weights = 0.0, age = 0.0
        for previous in stride(from: index, through: max(0, index - 3), by: -1) {
            if previous < index {
                let dt = interval(points[previous], points[previous + 1])
                age += dt.isFinite && dt > 0 ? min(dt, 32) : 4
            }
            guard age <= 24 else { break }
            let weight = exp(-age / 8)
            sum += clamp(points[previous].p) * weight
            weights += weight
        }
        return sum / weights
    }

    static func cumulativeTravel(_ points: [NativePDFPoint], aspect: Double) -> [Double] {
        guard aspect.isFinite, aspect > 0, !points.isEmpty else { return [] }
        var travel = [Double](); travel.reserveCapacity(points.count)
        travel.append(0)
        for index in 1..<points.count {
            let next = travel[index - 1] + distance(points[index - 1], points[index], aspect: aspect)
            guard next.isFinite else { return [] }
            travel.append(next)
        }
        return travel
    }

    /// Page widths per second. Invalid or widely separated clocks are neutral,
    /// rather than making a missing timestamp look like an unusually fast pen.
    static func speed(_ points: [NativePDFPoint], at index: Int, aspect: Double) -> Double {
        guard index > 0 else { return 0 }
        let dt = interval(points[index - 1], points[index])
        guard dt.isFinite, dt > 0, dt <= 64 else { return 0 }
        return min(3, max(0, distance(points[index - 1], points[index], aspect: aspect) * 1000 / dt))
    }

    static func speeds(_ points: [NativePDFPoint], aspect: Double) -> [Double] {
        points.indices.map { speed(points, at: $0, aspect: aspect) }
    }

    struct Profile {
        var points: [NativePDFPoint] = []
        var rawFirst: [Int] = []
        var rawLast: [Int] = []
        var bases: [Double] = []
        var travel: [Double] = []
        var factors: [Double] = []
        /// Integer endpoint values recover V4's dyadic subdivision parameter
        /// exactly, without modifying V4 or dividing by a pressure difference.
        var sampleTimes: [Double] = []

        /// Returns the first possibly changed render anchor. A stationary
        /// append updates one anchor without walking its previous raw run.
        mutating func update(raw: [NativePDFPoint], unchangedPrefix: Int, width: Double,
                             aspect: Double, highlighter: Bool) -> Int? {
            let previousCount = points.count
            var firstRaw = unchangedPrefix
            while let last = rawLast.last, last >= unchangedPrefix {
                firstRaw = min(firstRaw, rawFirst.last!)
                points.removeLast(); rawFirst.removeLast(); rawLast.removeLast()
                bases.removeLast(); travel.removeLast(); sampleTimes.removeLast()
            }
            var changed = points.count
            for index in firstRaw..<raw.count {
                let point = raw[index]
                if !highlighter, let last = points.last, last.x == point.x, last.y == point.y {
                    let anchor = points.count - 1
                    changed = min(changed, anchor)
                    points[anchor] = point; rawLast[anchor] = index
                    bases[anchor] = NativePDFInkGeometryV5.baseFactor(
                        pressure: NativePDFInkGeometryV5.filteredPressure(raw, at: index),
                        speed: NativePDFInkGeometryV5.speed(raw, at: rawFirst[anchor], aspect: aspect))
                } else {
                    let cumulative = points.isEmpty ? 0 : travel.last! + NativePDFInkGeometryV5.distance(points.last!, point, aspect: aspect)
                    guard cumulative.isFinite else { return nil }
                    points.append(point); rawFirst.append(index); rawLast.append(index); travel.append(cumulative)
                    sampleTimes.append(Double(points.count - 1))
                    bases.append(highlighter ? 1 : NativePDFInkGeometryV5.baseFactor(
                        pressure: NativePDFInkGeometryV5.filteredPressure(raw, at: index),
                        speed: NativePDFInkGeometryV5.speed(raw, at: index, aspect: aspect)))
                }
            }
            let oldTail = max(0, previousCount - 1 - NativePDFInkGeometryV5.tailSegmentCount)
            let newTail = max(0, points.count - 1 - NativePDFInkGeometryV5.tailSegmentCount)
            let factorStart = highlighter ? changed : min(changed, oldTail, newTail)
            if factors.count > factorStart { factors.removeSubrange(factorStart...) }
            for index in factorStart..<points.count {
                factors.append(highlighter ? 1 : bases[index] * NativePDFInkGeometryV5.startGain(travel: travel[index], width: width)
                    * NativePDFInkGeometryV5.endGain(index: index, travel: travel, width: width))
            }
            return changed
        }
    }

    /// Pen-only render anchors collapse consecutive exact positions. They keep
    /// the latest raw filtered force, and the first arrival's speed. Stationary
    /// time updates cannot consume the moving tail or release its speed gain.
    /// Highlighters keep every V4 raw anchor and polygon exactly.
    static func renderProfile(points: [NativePDFPoint], width: Double, aspect: Double, highlighter: Bool) -> Profile? {
        guard valid(points: points, width: width, aspect: aspect) else { return nil }
        var result = Profile()
        guard result.update(raw: points, unchangedPrefix: 0, width: width, aspect: aspect, highlighter: highlighter) != nil else { return nil }
        return result
    }

    /// Raw-index diagnostic API. Members of a stationary run share its latest
    /// render-anchor factor; the original input samples themselves are intact.
    static func widthFactors(points: [NativePDFPoint], width: Double, aspect: Double, highlighter: Bool) -> [Double] {
        guard let profile = renderProfile(points: points, width: width, aspect: aspect, highlighter: highlighter) else { return [] }
        var result = [Double](repeating: 0, count: points.count)
        for index in profile.points.indices {
            for rawIndex in profile.rawFirst[index]...profile.rawLast[index] { result[rawIndex] = profile.factors[index] }
        }
        return result
    }

    static func baseFactor(pressure: Double, speed: Double) -> Double {
        (0.24 + 0.68 * pow(pressure, 0.8)) * (1 - 0.12 * clamp(speed / 0.8))
    }

    static func startGain(travel: Double, width: Double) -> Double {
        0.75 + 0.25 * smoothstep(clamp(travel / (1.2 * width)))
    }

    static func taperLength(travel: [Double], width: Double) -> Double {
        guard let total = travel.last, total > 0 else { return 0 }
        let tailStart = max(0, travel.count - 1 - tailSegmentCount)
        return min(2.2 * width, 0.28 * total, max(0, total - travel[tailStart]))
    }

    static func endGain(index: Int, travel: [Double], width: Double) -> Double {
        guard travel.indices.contains(index) else { return 1 }
        return endGain(at: travel[index], travel: travel, width: width)
    }

    static func endGain(at position: Double, travel: [Double], width: Double) -> Double {
        let length = taperLength(travel: travel, width: width)
        guard length > 0, let total = travel.last else { return 1 }
        let strength = smoothstep(clamp(length / (0.75 * width)))
        return 1 - 0.68 * strength * (1 - smoothstep(clamp(max(0, total - position) / length)))
    }

    /// V4 centerline vertices for the same render anchors stay bit-identical.
    /// Extra taper samples lie on
    /// its accepted chords, so sparse straight lines retain a full-width body
    /// without densifying that body. At most 16 extra endpoints per segment.
    static func forEachSegmentSample(profile: Profile, index: Int, width: Double, aspect: Double,
                                     highlighter: Bool, _ emit: (Sample) -> Void) {
        guard index >= 0, index + 1 < profile.points.count else { return }
        let first = profile.points[index]
        var curve: [(t: Double, point: CGPoint)] = [(0, CGPoint(x: first.x, y: first.y))]
        NativePDFInkGeometryV4.forEachSegmentSample(points: profile.points, pressures: profile.sampleTimes,
            index: index, width: width, aspect: aspect) { sample in
                curve.append((sample.p - Double(index), CGPoint(x: sample.x, y: sample.y)))
            }
        var times = curve.dropFirst().map(\.t)
        let start = profile.travel[index], length = profile.travel[index + 1] - start
        if !highlighter, length > 0 {
            func include(_ position: Double) {
                let t = (position - start) / length
                if t > 0, t < 1, !times.contains(t) { times.append(t) }
            }
            for step in 1...8 { include((1.2 * width) * Double(step) / 8) }
            let taper = taperLength(travel: profile.travel, width: width)
            if taper > 0, let total = profile.travel.last {
                for step in 0..<8 { include(total - taper + taper * Double(step) / 8) }
            }
            times.sort()
        }
        var cursor = 1
        for t in times {
            while curve[cursor].t < t { cursor += 1 }
            let position: CGPoint
            if curve[cursor].t == t { position = curve[cursor].point }
            else {
                let before = curve[cursor - 1], after = curve[cursor]
                let fraction = (t - before.t) / (after.t - before.t)
                position = CGPoint(x: before.point.x + (after.point.x - before.point.x) * fraction,
                                   y: before.point.y + (after.point.y - before.point.y) * fraction)
            }
            let factor: Double
            if highlighter { factor = 1 }
            else if t == 1 { factor = profile.factors[index + 1] }
            else {
                let base = profile.bases[index] + (profile.bases[index + 1] - profile.bases[index]) * t
                let distance = start + length * t
                factor = base * startGain(travel: distance, width: width) * endGain(at: distance, travel: profile.travel, width: width)
            }
            emit(Sample(x: position.x, y: position.y, factor: factor))
        }
    }

    static func forEachSegmentPolygon(profile: Profile, index: Int, width: Double,
                                      aspect: Double, highlighter: Bool, _ emit: ([CGPoint]) -> Void) {
        guard profile.points.indices.contains(index) else { return }
        var previous = Sample(x: profile.points[index].x, y: profile.points[index].y, factor: profile.factors[index])
        forEachSegmentSample(profile: profile, index: index, width: width, aspect: aspect, highlighter: highlighter) { sample in
            forEachConnection(previous, sample, width: width, aspect: aspect, emit)
            previous = sample
        }
    }

    static func forEachPredictionPolygon(lastPoint: NativePDFPoint, factor: Double, predictions: [NativePDFPoint],
                                         width: Double, aspect: Double, _ emit: ([CGPoint]) -> Void) {
        var previous = Sample(x: lastPoint.x, y: lastPoint.y, factor: factor), count = 0
        for point in predictions {
            guard count < maximumPredictionPoints else { break }
            guard point.x.isFinite, point.y.isFinite, (point.y * aspect).isFinite else { continue }
            let sample = Sample(x: point.x, y: point.y, factor: factor)
            forEachConnection(previous, sample, width: width, aspect: aspect, emit)
            previous = sample; count += 1
        }
    }

    static func forEachPolygon(points: [NativePDFPoint], predictions: [NativePDFPoint] = [], width: Double,
                               aspect: Double, highlighter: Bool, _ emit: ([CGPoint]) -> Void) {
        guard let profile = renderProfile(points: points, width: width, aspect: aspect, highlighter: highlighter),
              let first = profile.points.first else { return }
        emit(disk(Sample(x: first.x, y: first.y, factor: profile.factors[0]), width: width, aspect: aspect))
        for index in 0..<max(0, profile.points.count - 1) {
            forEachSegmentPolygon(profile: profile, index: index, width: width, aspect: aspect, highlighter: highlighter, emit)
        }
        forEachPredictionPolygon(lastPoint: profile.points[profile.points.count - 1], factor: profile.factors[profile.factors.count - 1],
                                 predictions: predictions, width: width, aspect: aspect, emit)
    }

    static func polygons(points: [NativePDFPoint], predictions: [NativePDFPoint] = [], width: Double,
                         aspect: Double, highlighter: Bool) -> [[CGPoint]] {
        var output: [[CGPoint]] = []
        forEachPolygon(points: points, predictions: predictions, width: width, aspect: aspect,
                       highlighter: highlighter) { output.append($0) }
        return output
    }

    static func disk(_ sample: Sample, width: Double, aspect: Double) -> [CGPoint] {
        let radius = width * sample.factor / 2
        return (0..<circleSegments).map { step in
            let angle = Double(step) * 2 * .pi / Double(circleSegments)
            return CGPoint(x: sample.x + cos(angle) * radius, y: sample.y + sin(angle) * radius / aspect)
        }
    }

    /// Exact disk/tangent convex union, with a factor rather than an inverse
    /// pressure conversion. Every contour keeps the same winding as V3/V4.
    private static func forEachConnection(_ previous: Sample, _ sample: Sample, width: Double,
                                          aspect: Double, _ emit: ([CGPoint]) -> Void) {
        let before = width * previous.factor / 2, radius = width * sample.factor / 2
        let dx = sample.x - previous.x, dy = (sample.y - previous.y) * aspect
        let distance = hypot(dx, dy), difference = before - radius
        if distance.isFinite, distance > abs(difference), distance > epsilon {
            let ux = dx / distance, uy = dy / distance, along = difference / distance
            let across = sqrt(max(0, 1 - along * along))
            let lowX = ux * along + uy * across, lowY = uy * along - ux * across
            let highX = ux * along - uy * across, highY = uy * along + ux * across
            emit([
                CGPoint(x: previous.x + lowX * before, y: previous.y + lowY * before / aspect),
                CGPoint(x: sample.x + lowX * radius, y: sample.y + lowY * radius / aspect),
                CGPoint(x: sample.x + highX * radius, y: sample.y + highY * radius / aspect),
                CGPoint(x: previous.x + highX * before, y: previous.y + highY * before / aspect)
            ])
        }
        emit(disk(sample, width: width, aspect: aspect))
    }

    static func distance(_ a: NativePDFPoint, _ b: NativePDFPoint, aspect: Double) -> Double {
        hypot(b.x - a.x, (b.y - a.y) * aspect)
    }
    private static func interval(_ a: NativePDFPoint, _ b: NativePDFPoint) -> Double {
        guard let before = a.t, let after = b.t else { return .nan }
        return after - before
    }
    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func smoothstep(_ value: Double) -> Double { value * value * (3 - 2 * value) }
}
