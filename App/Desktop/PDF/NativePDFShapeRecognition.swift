import Foundation
import CoreGraphics

/// A measured-only fit carried with the immutable stroke journal. Raw samples
/// remain available for one-step shape reversal and exact receipt recovery.
struct NativePDFHeldShape: Codable, Equatable {
    var kind: String
    var points: [NativePDFPoint]
    var box: [Double] // x, y, width, height
    var isValid: Bool {
        ["ink", "line", "rect", "ellipse"].contains(kind) && (2...4096).contains(points.count)
            && points.allSatisfy(\.isValid) && box.count == 4 && box.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    var journalPayload: [String: Any] {
        ["kind": kind, "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }, "box": box]
    }
    var payload: [String: Any] {
        let data: [String: Any]
        if kind == "rect" || kind == "ellipse" {
            data = ["box": ["x": box[0], "y": box[1], "width": box[2], "height": box[3]]]
        } else {
            let geometry: [String: Any] = ["points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }]
            data = kind == "ink" ? geometry.merging(["inkVersion": 5]) { _, next in next } : geometry
        }
        return ["kind": kind, "data": data]
    }
    var inkPayload: [String: Any] {
        ["kind": "ink", "data": ["points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }, "inkVersion": 5]]
    }
    /// Match saved SVG shape widths, caps and joins instead of running a
    /// geometric line through the fountain-pen pressure/taper profile.
    func outlinePolygons(width: Double) -> [[CGPoint]] {
        guard width.isFinite, width > 0 else { return [] }
        let radius = width / 2
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
        }
        if kind == "rect" {
            let x = box[0], y = box[1], w = box[2], h = box[3]
            if w <= width || h <= width { return [rect(x - radius, y - radius, w + width, h + width)] }
            return [rect(x - radius, y - radius, w + width, width), rect(x - radius, y + h - radius, w + width, width),
                    rect(x - radius, y + radius, width, h - width), rect(x + w - radius, y + radius, width, h - width)]
        }
        var output: [[CGPoint]] = []
        let path = points.map { CGPoint(x: $0.x, y: $0.y) }
        for point in path {
            output.append((0..<32).map { i in
                let angle = Double(i) / 32 * .pi * 2
                return CGPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius)
            })
        }
        for (a, b) in zip(path, path.dropFirst()) {
            let dx = b.x - a.x, dy = b.y - a.y, distance = hypot(dx, dy)
            guard distance > 0 else { continue }
            let nx = -dy / distance * radius, ny = dx / distance * radius
            output.append([CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny),
                           CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)])
        }
        return output
    }
}

/// Bounded, conservative recognition runs once after stillness, never for each
/// Pencil sample. Metrics use page-width units, including landscape PDFs.
enum NativePDFShapeRecognition {
    private struct P {
        var x: Double, y: Double
        func distance(_ p: P) -> Double { hypot(x - p.x, y - p.y) }
    }
    private static func distance(_ p: P, _ a: P, _ b: P) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return p.distance(P(x: a.x + t * dx, y: a.y + t * dy))
    }
    private static func simplify(_ points: [P], _ epsilon: Double) -> [P] {
        guard points.count > 2 else { return points }
        var keep: Set<Int> = [0, points.count - 1], work = [(0, points.count - 1)]
        while let (start, end) = work.popLast() {
            var farthest = -1, maximum = epsilon
            if end > start + 1 {
                for i in (start + 1)..<end {
                    let d = distance(points[i], points[start], points[end])
                    if d > maximum { maximum = d; farthest = i }
                }
            }
            if farthest >= 0 { keep.insert(farthest); work.append((start, farthest)); work.append((farthest, end)) }
        }
        return keep.sorted().map { points[$0] }
    }
    private static func length(_ points: [P]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance($1.1) }
    }
    private static func area(_ points: [P]) -> Double {
        abs(points.indices.reduce(0) { sum, i in
            let p = points[i], q = points[(i + 1) % points.count]
            return sum + p.x * q.y - q.x * p.y
        }) / 2
    }
    private static func corners(_ points: [P], _ epsilon: Double) -> [P] {
        let farthest = points.indices.max { points[0].distance(points[$0]) < points[0].distance(points[$1]) } ?? 1
        var output = Array(simplify(Array(points[...farthest]), epsilon).dropLast())
            + Array(simplify(Array(points[farthest...]) + [points[0]], epsilon).dropLast())
        var changed = true
        while changed && output.count > 3 {
            changed = false
            for i in output.indices {
                if distance(output[i], output[(i + output.count - 1) % output.count], output[(i + 1) % output.count]) <= epsilon {
                    output.remove(at: i); changed = true; break
                }
            }
        }
        return output
    }
    private static func polygon(_ corners: [P], aspect: Double) -> [NativePDFPoint] {
        var output: [NativePDFPoint] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let count = max(2, Int(ceil(a.distance(b) / 0.006)))
            for j in 0..<count {
                let t = Double(j) / Double(count)
                output.append(NativePDFPoint(x: a.x + (b.x - a.x) * t, y: (a.y + (b.y - a.y) * t) / aspect, p: 0.5))
            }
        }
        if let first = output.first { output.append(first) }
        return output
    }
    static func recognize(_ points: [NativePDFPoint], aspect: Double) -> NativePDFHeldShape? {
        guard points.count >= 8, aspect.isFinite, aspect > 0, points.allSatisfy(\.isValid) else { return nil }
        var metric: [P] = []
        for point in points {
            let p = P(x: point.x, y: point.y * aspect)
            if metric.last.map({ $0.distance(p) >= 0.001 }) ?? true { metric.append(p) }
        }
        guard metric.count >= 6 else { return nil }
        let samples = metric.count <= 512 ? metric : (0..<512).map { metric[Int((Double($0 * (metric.count - 1)) / 511).rounded())] }
        let minX = samples.map(\.x).min()!, maxX = samples.map(\.x).max()!
        let minY = samples.map(\.y).min()!, maxY = samples.map(\.y).max()!
        let width = maxX - minX, height = maxY - minY, diagonal = hypot(width, height)
        guard diagonal >= 0.025 else { return nil }
        let first = samples[0], last = samples[samples.count - 1], chord = first.distance(last)
        let pathLength = length(samples), box = [minX, minY / aspect, width, height / aspect]
        if chord >= diagonal * 0.18 {
            guard chord >= diagonal * 0.9, pathLength <= chord * 1.18,
                  samples.allSatisfy({ distance($0, first, last) <= diagonal * 0.035 }) else { return nil }
            return NativePDFHeldShape(kind: "line", points: [NativePDFPoint(x: first.x, y: first.y / aspect, p: 0.5), NativePDFPoint(x: last.x, y: last.y / aspect, p: 0.5)], box: box)
        }
        guard min(width, height) >= 0.012 else { return nil }
        let vertices = corners(samples, diagonal * 0.035), fill = area(samples) / (width * height)
        guard let start = vertices.first, pathLength <= length(vertices + [start]) * 1.22, fill >= 0.2 else { return nil }
        if (3...4).contains(vertices.count) {
            let cross = vertices.indices.map { i -> Double in
                let p = vertices[i], q = vertices[(i + 1) % vertices.count], r = vertices[(i + 2) % vertices.count]
                return (q.x - p.x) * (r.y - q.y) - (q.y - p.y) * (r.x - q.x)
            }
            let convex = cross.allSatisfy { $0 > 0 } || cross.allSatisfy { $0 < 0 }
            let longEdges = vertices.indices.allSatisfy { vertices[$0].distance(vertices[($0 + 1) % vertices.count]) >= diagonal * 0.15 }
            if convex && longEdges {
                if vertices.count == 4 && fill > 0.86 {
                    let fitted = [P(x: minX, y: minY), P(x: maxX, y: minY), P(x: maxX, y: maxY), P(x: minX, y: maxY)]
                    return NativePDFHeldShape(kind: "rect", points: polygon(fitted, aspect: aspect), box: box)
                }
                return NativePDFHeldShape(kind: "ink", points: polygon(vertices, aspect: aspect), box: box)
            }
        }
        if vertices.count >= 6, fill >= 0.65, fill <= 0.86 {
            let cx = minX + width / 2, cy = minY + height / 2
            let errors = samples.map { abs(hypot(($0.x - cx) / (width / 2), ($0.y - cy) / (height / 2)) - 1) }
            if errors.reduce(0, +) / Double(errors.count) <= 0.11, errors.max()! <= 0.3 {
                let fitted = (0...96).map { i -> NativePDFPoint in
                    let angle = Double(i) / 96 * .pi * 2
                    return NativePDFPoint(x: cx + width / 2 * cos(angle), y: (cy + height / 2 * sin(angle)) / aspect, p: 0.5)
                }
                return NativePDFHeldShape(kind: "ellipse", points: fitted, box: box)
            }
        }
        return nil
    }
}
