import Foundation
import CoreGraphics
#if !SHAPE_HARNESS
@testable import Bandal
#endif

/// Synthetic hand-drawn strokes for the shape recognizer: figures drawn the way hands draw them (closing past the
/// start or short of it, rounded corners, turned, wobbly, started anywhere, any size and proportion), and letters
/// written at handwriting size with a pause at the end. Deterministic: the same seed draws the same corpus.
/// Coordinates are screen points on a 600 pt wide page (the recognizer's default `screenScale`).
enum NativePDFShapeCorpus {
    static let pageWidth = 600.0, aspect = 1.4

    struct Stroke { var expected: String?; var variant: String; var points: [NativePDFPoint] }

    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * next() }
        mutating func pick<T>(_ values: [T]) -> T { values[min(values.count - 1, Int(next() * Double(values.count)))] }
        mutating func chance(_ probability: Double) -> Bool { next() < probability }
    }

    // MARK: Figures

    static func positives(seed: UInt64 = 1, perShape: Int = 120) -> [Stroke] {
        var random = Random(seed: seed), output: [Stroke] = []
        for shape in ["line", "circle", "ellipse", "rect", "square", "triangle", "diamond", "pentagon", "hexagon", "arrow", "polyline"] {
            for index in 0..<perShape { output.append(figure(shape, index: index, random: &random)) }
        }
        return output
    }

    private static func figure(_ shape: String, index: Int, random: inout Random) -> Stroke {
        let closing = random.pick(["exact", "past", "past", "short", "short"])
        let rotation = random.chance(0.35) ? 0 : random.range(-30, 30) * .pi / 180
        var variant = closing
        var path: [CGPoint]
        switch shape {
        case "line":
            let length = random.range(60, 420), angle = random.chance(0.3) ? random.pick([0, 90, 45, -45]) * .pi / 180 + random.range(-3, 3) * .pi / 180 : random.range(0, .pi)
            path = [CGPoint.zero, CGPoint(x: cos(angle) * length, y: sin(angle) * length)]
            return finish(shape, variant: "line", ideal: densify(path), closed: false, wobble: 0.008, random: &random)
        case "circle", "ellipse":
            let a = random.range(45, 170), b = shape == "circle" ? a * random.range(0.92, 1) : a * random.range(0.4, 0.72)
            let turn = shape == "circle" ? 0 : random.range(0, .pi)
            let start = random.range(0, 2 * .pi), direction = random.chance(0.5) ? 1.0 : -1.0
            let segments = 160
            path = (0...segments).map { i in
                let angle = start + direction * Double(i) / Double(segments) * 2 * .pi
                let x = cos(angle) * a, y = sin(angle) * b
                return CGPoint(x: x * cos(turn) - y * sin(turn), y: x * sin(turn) + y * cos(turn))
            }
            variant += shape == "ellipse" ? " turned" : ""
            return finishClosed(shape, variant: variant, loop: path, closing: closing, wobble: 0.01, random: &random)
        case "rect", "square":
            var w = random.range(90, 360), h: Double
            if shape == "square" { h = w * random.range(0.95, 1.05) }
            else { h = w * (random.chance(0.5) ? random.range(0.35, 0.78) : random.range(1.3, 2.4)); if h > 380 { w *= 380 / h; h = 380 } }
            let rounded = random.chance(0.3) ? random.range(0.05, 0.16) * min(w, h) : 0
            if rounded > 0 { variant += " rounded" }
            if rotation != 0 { variant += " turned" }
            path = roundedRectangle(width: w, height: h, radius: rounded)
            path = rotate(path, rotation)
            return finishClosed(shape, variant: variant, loop: startAnywhere(path, random: &random), closing: closing, wobble: 0.01, random: &random)
        case "triangle":
            var corners: [CGPoint]
            repeat {
                corners = (0..<3).map { _ in CGPoint(x: random.range(0, 300), y: random.range(0, 300)) }
            } while !triangleIsReasonable(corners)
            path = rotate(closedPolyline(corners), rotation)
            return finishClosed(shape, variant: variant, loop: startAnywhere(path, random: &random), closing: closing, wobble: 0.01, random: &random)
        case "diamond":
            // Clearly a rhombus: diagonals within 0.72 of each other look like a turned square, and are one.
            let d1 = random.range(60, 170), d2 = d1 * (random.chance(0.5) ? random.range(0.45, 0.72) : random.range(1.38, 2))
            let corners = [CGPoint(x: 0, y: -d2), CGPoint(x: d1, y: 0), CGPoint(x: 0, y: d2), CGPoint(x: -d1, y: 0)]
            path = rotate(closedPolyline(corners), random.range(-8, 8) * .pi / 180)
            return finishClosed(shape, variant: variant, loop: startAnywhere(path, random: &random), closing: closing, wobble: 0.01, random: &random)
        case "pentagon", "hexagon":
            let n = shape == "pentagon" ? 5 : 6, radius = random.range(55, 170), phase = random.range(0, 2 * .pi)
            let corners = (0..<n).map { i -> CGPoint in
                let angle = phase + Double(i) * 2 * .pi / Double(n), r = radius * random.range(0.95, 1.05)
                return CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            }
            path = closedPolyline(corners)
            return finishClosed(shape, variant: variant, loop: startAnywhere(path, random: &random), closing: closing, wobble: 0.01, random: &random)
        case "arrow":
            let shaft = random.range(110, 320), head = shaft * random.range(0.14, 0.3), spread = random.range(24, 42) * .pi / 180
            let angle = random.range(0, 2 * .pi)
            let tail = CGPoint.zero, tip = CGPoint(x: cos(angle) * shaft, y: sin(angle) * shaft)
            func wing(_ side: Double) -> CGPoint { CGPoint(x: tip.x + cos(angle + .pi + side * spread) * head, y: tip.y + sin(angle + .pi + side * spread) * head) }
            let retrace = random.chance(0.6)
            path = retrace ? [tail, tip, wing(1), tip, wing(-1)] : [tail, tip, wing(1), wing(-1), tip]
            return finish(shape, variant: retrace ? "retraced head" : "closed head", ideal: densify(path), closed: false, wobble: 0.006, random: &random)
        default: // polyline
            let count = random.pick([3, 3, 4]), step = random.range(70, 150)
            var heading = random.range(0, 2 * .pi), point = CGPoint.zero
            var corners = [point]
            for _ in 0..<count {
                point = CGPoint(x: point.x + cos(heading) * step * random.range(0.8, 1.2), y: point.y + sin(heading) * step * random.range(0.8, 1.2))
                corners.append(point)
                // A zigzag, as a line chart goes; turning one way four times would close a box.
                heading += (corners.count.isMultiple(of: 2) ? 1 : -1) * random.range(45, 120) * .pi / 180
            }
            return finish(shape, variant: "\(count) segments", ideal: densify(corners), closed: false, wobble: 0.008, random: &random)
        }
    }

    // MARK: Letters

    /// Letters a hand writes at handwriting size (16–48 pt tall, 3–9 mm on an iPad), each ending in the pause that
    /// triggers recognition.
    static func letters(seed: UInt64 = 2, perLetter: Int = 60, sizes: ClosedRange<Double> = 16...48) -> [Stroke] {
        var random = Random(seed: seed), output: [Stroke] = []
        for letter in ["ㅁ", "ㅇ", "ㄱ", "O", "D", "L", "V", "7", "2", "ㄴ", "ㄷ", "ㄹ", "S", "C", "U", "e", "a", "3", "8", "0", "1", "-"] {
            for _ in 0..<perLetter {
                let size = random.range(sizes.lowerBound, sizes.upperBound)
                output.append(finish(nil, variant: letter, ideal: densify(letterPath(letter, size: size, random: &random)), closed: false, wobble: 0.03, random: &random))
            }
        }
        return output
    }

    static func letterPath(_ letter: String, size s: Double, random: inout Random) -> [CGPoint] {
        func arc(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, from a: Double, to b: Double, steps: Int = 40) -> [CGPoint] {
            (0...steps).map { i in let t = a + (b - a) * Double(i) / Double(steps); return CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t)) }
        }
        let lean = random.range(-0.12, 0.12)
        var path: [CGPoint]
        switch letter {
        case "ㅁ": path = [CGPoint(x: 0, y: 0), CGPoint(x: s, y: 0), CGPoint(x: s, y: s * 0.9), CGPoint(x: 0, y: s * 0.9), CGPoint(x: 0, y: -s * 0.05)]
        case "ㅇ", "0": path = arc(0, 0, s * (letter == "0" ? 0.32 : 0.45), s * 0.45, from: -.pi / 2, to: 1.5 * .pi + random.range(0, 0.4))
        case "O": path = arc(0, 0, s * 0.42, s * 0.5, from: -.pi / 2, to: -.pi / 2 - 2 * .pi - random.range(0, 0.3))
        case "ㄱ": path = [CGPoint(x: 0, y: 0), CGPoint(x: s, y: 0), CGPoint(x: s * 0.95, y: s)]
        case "ㄴ": path = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: s), CGPoint(x: s, y: s)]
        case "ㄷ": path = [CGPoint(x: s, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: s), CGPoint(x: s, y: s)]
        case "ㄹ": path = [CGPoint(x: 0, y: 0), CGPoint(x: s, y: 0), CGPoint(x: s, y: s * 0.45), CGPoint(x: 0, y: s * 0.45), CGPoint(x: 0, y: s), CGPoint(x: s, y: s)]
        case "L": path = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: s), CGPoint(x: s * 0.7, y: s)]
        case "V": path = [CGPoint(x: 0, y: 0), CGPoint(x: s * 0.4, y: s), CGPoint(x: s * 0.8, y: 0)]
        case "7": path = [CGPoint(x: 0, y: 0), CGPoint(x: s * 0.7, y: 0), CGPoint(x: s * 0.2, y: s)]
        case "D": path = [CGPoint(x: 0, y: s), CGPoint(x: 0, y: 0)] + arc(0, s / 2, s * 0.7, s / 2, from: -.pi / 2, to: .pi / 2)
        case "2": path = arc(s * 0.35, s * 0.3, s * 0.35, s * 0.3, from: .pi, to: 2.3 * .pi) + [CGPoint(x: 0, y: s), CGPoint(x: s * 0.75, y: s)]
        case "S": path = arc(s * 0.3, s * 0.25, s * 0.3, s * 0.25, from: -0.2, to: -.pi * 1.5) + arc(s * 0.3, s * 0.75, s * 0.3, s * 0.25, from: -.pi / 2, to: .pi * 0.8)
        case "C": path = arc(0, 0, s * 0.45, s * 0.5, from: -0.6, to: -2 * .pi + 0.6)
        case "U": path = [CGPoint(x: 0, y: 0)] + arc(s * 0.35, s * 0.65, s * 0.35, s * 0.35, from: .pi, to: 0) + [CGPoint(x: s * 0.7, y: 0)]
        case "e": path = [CGPoint(x: 0, y: s * 0.5), CGPoint(x: s * 0.7, y: s * 0.5)] + arc(s * 0.35, s * 0.5, s * 0.35, s * 0.45, from: 0, to: -1.75 * .pi)
        case "a": path = arc(s * 0.3, s * 0.55, s * 0.3, s * 0.4, from: -0.3, to: -2 * .pi - 0.3) + [CGPoint(x: s * 0.6, y: s), CGPoint(x: s * 0.68, y: s * 0.95)]
        case "3": path = arc(s * 0.3, s * 0.25, s * 0.3, s * 0.25, from: -.pi, to: .pi / 2) + arc(s * 0.3, s * 0.75, s * 0.32, s * 0.25, from: -.pi / 2, to: .pi)
        case "8": path = arc(s * 0.3, s * 0.25, s * 0.25, s * 0.25, from: .pi / 2, to: 2.5 * .pi) + arc(s * 0.3, s * 0.75, s * 0.3, s * 0.25, from: -.pi / 2, to: -2.5 * .pi)
        case "1": path = [CGPoint(x: -s * 0.15, y: s * 0.15), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: s)]
        default: path = [CGPoint(x: 0, y: 0), CGPoint(x: s * 0.6, y: 0)] // "-"
        }
        return path.map { CGPoint(x: $0.x + lean * $0.y, y: $0.y) }
    }

    // MARK: Drawing

    private static func finishClosed(_ name: String, variant: String, loop: [CGPoint], closing: String, wobble: Double,
                                     random: inout Random) -> Stroke {
        let dense = densify(loop)
        let perimeter = length(dense)
        var path = dense
        if closing == "past" { path += walk(dense, distance: perimeter * random.range(0.04, 0.16)) }
        if closing == "short" { path = trim(dense, distance: perimeter * random.range(0.04, 0.1)) }
        return finish(name, variant: variant, ideal: path, closed: true, wobble: wobble, random: &random)
    }

    /// Wobble along the stroke, hand jitter, uneven Pencil sampling, the pause, then page coordinates.
    private static func finish(_ name: String?, variant: String, ideal: [CGPoint], closed: Bool, wobble: Double, random: inout Random) -> Stroke {
        let total = length(ideal), size = extent(ideal)
        let waves = (0..<3).map { _ in (amplitude: random.range(0.3, 1) * wobble * size, frequency: random.range(1, 3) / max(total, 1), phase: random.range(0, 2 * .pi)) }
        var points: [CGPoint] = [], travelled = 0.0, next = 0.0, segment = 1
        func sample(_ a: CGPoint, _ b: CGPoint, _ piece: Double, at distance: Double) -> CGPoint {
            let t = piece > 0 ? (distance - travelled) / piece : 0
            let base = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let normal = piece > 0 ? CGPoint(x: -(b.y - a.y) / piece, y: (b.x - a.x) / piece) : .zero
            let offset = waves.reduce(0) { $0 + $1.amplitude * sin(2 * .pi * $1.frequency * distance + $1.phase) }
            return CGPoint(x: base.x + normal.x * offset + random.range(-0.3, 0.3), y: base.y + normal.y * offset + random.range(-0.3, 0.3))
        }
        while segment < ideal.count {
            let a = ideal[segment - 1], b = ideal[segment], piece = hypot(b.x - a.x, b.y - a.y)
            if travelled + piece < next || piece == 0 {
                if segment == ideal.count - 1 { points.append(sample(a, b, piece, at: travelled + piece)) }
                travelled += piece; segment += 1; continue
            }
            points.append(sample(a, b, piece, at: next))
            next += random.range(0.8, 3.5)
        }
        // The pause: the Pencil rests, its tip still trembling under half a point.
        if let last = points.last {
            for _ in 0..<Int(random.range(20, 70)) { points.append(CGPoint(x: last.x + random.range(-0.4, 0.4), y: last.y + random.range(-0.4, 0.4))) }
        }
        // Place it on the page.
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let room = CGSize(width: pageWidth - box.width - 20, height: pageWidth * aspect - box.height - 20)
        let origin = CGPoint(x: 10 + random.range(0, max(0, room.width)) - box.minX, y: 10 + random.range(0, max(0, room.height)) - box.minY)
        var time = 0.0
        let samples = points.map { p -> NativePDFPoint in
            time += 4.2
            return NativePDFPoint(x: min(1, max(0, (p.x + origin.x) / pageWidth)), y: min(1, max(0, (p.y + origin.y) / (pageWidth * aspect))),
                                  p: random.range(0.3, 0.7), t: time)
        }
        return Stroke(expected: name, variant: variant, points: samples)
    }

    // MARK: Geometry

    static func densify(_ corners: [CGPoint], step: Double = 1) -> [CGPoint] {
        guard let first = corners.first else { return [] }
        var output = [first]
        for (a, b) in zip(corners, corners.dropFirst()) {
            let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / step)))
            for i in 1...count { let t = Double(i) / Double(count); output.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        }
        return output
    }
    private static func closedPolyline(_ corners: [CGPoint]) -> [CGPoint] { corners + [corners[0]] }
    private static func roundedRectangle(width w: Double, height h: Double, radius r: Double) -> [CGPoint] {
        guard r > 0 else { return closedPolyline([CGPoint(x: -w / 2, y: -h / 2), CGPoint(x: w / 2, y: -h / 2), CGPoint(x: w / 2, y: h / 2), CGPoint(x: -w / 2, y: h / 2)]) }
        var output: [CGPoint] = []
        let centres = [CGPoint(x: w / 2 - r, y: -h / 2 + r), CGPoint(x: w / 2 - r, y: h / 2 - r), CGPoint(x: -w / 2 + r, y: h / 2 - r), CGPoint(x: -w / 2 + r, y: -h / 2 + r)]
        for (index, centre) in centres.enumerated() {
            let start = -Double.pi / 2 + Double(index) * .pi / 2
            for step in 0...10 { let a = start + Double(step) / 10 * .pi / 2; output.append(CGPoint(x: centre.x + r * cos(a), y: centre.y + r * sin(a))) }
        }
        return output + [output[0]]
    }
    /// The same loop started somewhere along it (a corner or the middle of an edge), in either direction.
    private static func startAnywhere(_ loop: [CGPoint], random: inout Random) -> [CGPoint] {
        var path = densify(loop)
        path.removeLast()
        if random.chance(0.5) { path.reverse() }
        let offset = Int(random.range(0, Double(path.count)))
        let rotated = Array(path[offset...] + path[..<offset])
        return rotated + [rotated[0]]
    }
    private static func rotate(_ points: [CGPoint], _ angle: Double) -> [CGPoint] {
        points.map { CGPoint(x: $0.x * cos(angle) - $0.y * sin(angle), y: $0.x * sin(angle) + $0.y * cos(angle)) }
    }
    private static func triangleIsReasonable(_ corners: [CGPoint]) -> Bool {
        let sides = (0..<3).map { i in hypot(corners[(i + 1) % 3].x - corners[i].x, corners[(i + 1) % 3].y - corners[i].y) }
        guard sides.min()! >= 90 else { return false }
        return (0..<3).allSatisfy { i in
            let a = corners[i], b = corners[(i + 1) % 3], c = corners[(i + 2) % 3]
            let u = CGPoint(x: b.x - a.x, y: b.y - a.y), v = CGPoint(x: c.x - a.x, y: c.y - a.y)
            let angle = acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / (hypot(u.x, u.y) * hypot(v.x, v.y)))))
            return angle >= 28 * .pi / 180
        }
    }
    private static func walk(_ loop: [CGPoint], distance: Double) -> [CGPoint] {
        var output: [CGPoint] = [], travelled = 0.0
        for (a, b) in zip(loop, loop.dropFirst()) {
            travelled += hypot(b.x - a.x, b.y - a.y); output.append(b)
            if travelled >= distance { break }
        }
        return output
    }
    private static func trim(_ path: [CGPoint], distance: Double) -> [CGPoint] {
        var output = path, removed = 0.0
        while output.count > 2, removed < distance {
            let a = output[output.count - 2], b = output[output.count - 1]
            removed += hypot(b.x - a.x, b.y - a.y); output.removeLast()
        }
        return output
    }
    static func length(_ points: [CGPoint]) -> Double { zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
    private static func extent(_ points: [CGPoint]) -> Double {
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        return hypot(box.width, box.height)
    }
}
