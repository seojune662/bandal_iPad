import Foundation
import CoreGraphics

/// A clean figure in the page-width metric: x as on the page and y times the page's aspect (height / width), so
/// lengths and angles are physical on every page shape.
///
/// A recognized shape is saved as ordinary even-width ink (`kind` ink or highlighter, inkVersion 5, `fixedWidth`)
/// whose points trace this figure, plus `data.shape`, which says which of those points are its corners. Builds
/// before shapes became ink draw the row as the ink it is and drop `data.shape` when they rewrite it; the corners
/// are point indices, so moving, scaling or rotating the points (sync, a page rotation, an older build's lasso)
/// never leaves them stale.
struct NativePDFShapeFigure: Equatable {
    enum Kind: String { case line, arrow, polyline, polygon, ellipse }
    var kind: Kind
    /// What the user sees it as: line, arrow, polyline, triangle, rect, square, diamond, quad, pentagon, hexagon,
    /// polygon, circle, ellipse.
    var name: String
    /// line [start, end]; arrow [tail, tip, wing, wing]; polyline its open corners; polygon its corners, not repeated.
    var vertices: [CGPoint] = []
    /// ellipse: centre and two conjugate semi-axes (perpendicular as recognized).
    var center = CGPoint.zero, axisA = CGPoint.zero, axisB = CGPoint.zero

    static let ellipseSegments = 96
    /// Spacing of the traced ink along straight edges, in page widths: dense enough that the partial eraser and the
    /// lasso see the figure as they see handwriting.
    static let edgeStep = 0.004

    var isClosed: Bool { kind == .polygon || kind == .ellipse }
    var isCircle: Bool { name == "circle" }

    /// The centre closed figures scale and turn about.
    var pivot: CGPoint {
        switch kind {
        case .ellipse: return center
        case .line, .arrow: return vertices.first ?? .zero
        case .polygon: return Self.centroid(vertices)
        case .polyline:
            let box = bounds; return CGPoint(x: box.midX, y: box.midY)
        }
    }
    var bounds: CGRect {
        let points = outline(samples: 48)
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// The traced path, in metric coordinates: corners exactly, edges sampled.
    func outline(samples: Int = NativePDFShapeFigure.ellipseSegments) -> [CGPoint] {
        if kind == .ellipse {
            return (0...samples).map { i in
                let angle = Double(i) / Double(samples) * 2 * .pi
                return CGPoint(x: center.x + cos(angle) * axisA.x + sin(angle) * axisB.x,
                               y: center.y + cos(angle) * axisA.y + sin(angle) * axisB.y)
            }
        }
        return pathCorners
    }
    /// The corner sequence the ink visits: an arrow goes tail, tip, wing, back to the tip, other wing.
    var pathCorners: [CGPoint] {
        switch kind {
        case .arrow where vertices.count == 4: return [vertices[0], vertices[1], vertices[2], vertices[1], vertices[3]]
        case .polygon: return vertices + (vertices.first.map { [$0] } ?? [])
        default: return vertices
        }
    }

    // MARK: Ink

    /// Points in page coordinates and the descriptor saved beside them.
    func ink(aspect: Double) -> (points: [NativePDFPoint], corners: [Int]?, segments: Int?) {
        func page(_ p: CGPoint) -> NativePDFPoint {
            NativePDFPoint(x: min(1, max(0, Double(p.x))), y: min(1, max(0, Double(p.y) / aspect)), p: 0.5)
        }
        if kind == .ellipse {
            return (outline().map(page), nil, Self.ellipseSegments)
        }
        let path = pathCorners
        guard let first = path.first else { return ([], nil, nil) }
        var points = [page(first)], corners = [0]
        for (a, b) in zip(path, path.dropFirst()) {
            let count = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / Self.edgeStep)))
            for step in 1...count {
                let t = Double(step) / Double(count)
                points.append(page(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
            }
            corners.append(points.count - 1)
        }
        return (points, corners, nil)
    }

    /// Reads a saved figure back from its ink, and only when the points still trace it: a row an older build
    /// rewrote without `data.shape`, a piece the partial eraser cut, or anything else that no longer matches is
    /// plain ink.
    init?(data: [String: Any], aspect: Double) {
        guard aspect.isFinite, aspect > 0, let shape = data["shape"] as? [String: Any],
              let type = shape["type"] as? String, let kind = Kind(rawValue: type),
              let values = data["points"] as? [[String: Any]] else { return nil }
        let points = values.compactMap { value -> CGPoint? in
            guard let x = (value["x"] as? NSNumber)?.doubleValue, let y = (value["y"] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y * aspect)
        }
        guard points.count == values.count, points.count >= 2 else { return nil }
        // A few hundredths of a point on a page; JSON keeps doubles exactly, transforms add only rounding.
        let tolerance = 1e-5 + 1e-4 * Self.extent(points)
        if kind == .ellipse {
            guard let segments = (shape["segments"] as? NSNumber)?.intValue, segments >= 8, segments % 4 == 0,
                  points.count == segments + 1 else { return nil }
            let center = CGPoint(x: (points[0].x + points[segments / 2].x) / 2, y: (points[0].y + points[segments / 2].y) / 2)
            self.init(kind: .ellipse, name: "ellipse")
            self.center = center
            axisA = CGPoint(x: points[0].x - center.x, y: points[0].y - center.y)
            axisB = CGPoint(x: points[segments / 4].x - center.x, y: points[segments / 4].y - center.y)
            let traced = outline(samples: segments)
            guard zip(traced, points).allSatisfy({ hypot($0.x - $1.x, $0.y - $1.y) <= tolerance }) else { return nil }
            name = Self.ellipseName(axisA, axisB)
            return
        }
        guard let corners = (shape["corners"] as? [NSNumber])?.map(\.intValue), corners.count >= 2,
              corners.first == 0, corners.last == points.count - 1,
              zip(corners, corners.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        // Every sample between two corners lies on the straight edge between them.
        for (start, end) in zip(corners, corners.dropFirst()) {
            let a = points[start], b = points[end]
            guard (start...end).allSatisfy({ Self.distance(points[$0], a, b) <= tolerance }) else { return nil }
        }
        let path = corners.map { points[$0] }
        switch kind {
        case .line:
            guard path.count == 2 else { return nil }
            self.init(kind: .line, name: "line", vertices: path)
        case .arrow:
            guard path.count == 5, hypot(path[1].x - path[3].x, path[1].y - path[3].y) <= tolerance else { return nil }
            self.init(kind: .arrow, name: "arrow", vertices: [path[0], path[1], path[2], path[4]])
        case .polyline:
            self.init(kind: .polyline, name: "polyline", vertices: path)
        case .polygon:
            guard path.count >= 4, hypot(path[0].x - path[path.count - 1].x, path[0].y - path[path.count - 1].y) <= tolerance else { return nil }
            let corners = Array(path.dropLast())
            self.init(kind: .polygon, name: Self.polygonName(corners), vertices: corners)
        case .ellipse: return nil
        }
    }
    init(kind: Kind, name: String, vertices: [CGPoint] = [], center: CGPoint = .zero, axisA: CGPoint = .zero, axisB: CGPoint = .zero) {
        self.kind = kind; self.name = name; self.vertices = vertices
        self.center = center; self.axisA = axisA; self.axisB = axisB
    }

    var descriptor: [String: Any] { Self.descriptor(kind: kind, corners: ink(aspect: 1).corners, segments: kind == .ellipse ? Self.ellipseSegments : nil) }
    static func descriptor(kind: Kind, corners: [Int]?, segments: Int?) -> [String: Any] {
        var shape: [String: Any] = ["type": kind.rawValue]
        if let corners { shape["corners"] = corners }
        if let segments { shape["segments"] = segments }
        return shape
    }

    // MARK: Transforms

    /// Every point through one affine map of the metric plane. Ellipses stay ellipses; polygons keep their corners.
    func applying(_ t: CGAffineTransform) -> NativePDFShapeFigure {
        var result = self
        result.vertices = vertices.map { $0.applying(t) }
        result.center = center.applying(t)
        let linear = CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: 0, ty: 0)
        result.axisA = axisA.applying(linear); result.axisB = axisB.applying(linear)
        if kind == .ellipse { result.name = Self.ellipseName(result.axisA, result.axisB) }
        if kind == .polygon { result.name = Self.polygonName(result.vertices) }
        return result
    }
    func scaledRotated(about pivot: CGPoint, scale: Double, angle: Double) -> NativePDFShapeFigure {
        applying(CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: angle).scaledBy(x: scale, y: scale)
            .translatedBy(x: -pivot.x, y: -pivot.y))
    }
    /// Within this of 0°, 45° or 90°, a figure the pen is turning settles onto it.
    static let angleSnap = 4 * Double.pi / 180
    /// Reshaped by the pen still down after recognition, from where it was then (`start`) to `pen`: a line or
    /// arrow keeps its start and points to the pen; a closed figure keeps its centre, scales with the pen's
    /// distance from it and turns with its direction (a circle only scales). Snaps to 0°, 45° and 90°.
    func adjusted(from start: CGPoint, to pen: CGPoint, minimumSize: Double) -> (figure: NativePDFShapeFigure, snapped: Bool) {
        let figure = self
        let pivot = figure.pivot
        let before = CGPoint(x: start.x - pivot.x, y: start.y - pivot.y), after = CGPoint(x: pen.x - pivot.x, y: pen.y - pivot.y)
        let reach = hypot(before.x, before.y), size = NativePDFShapeFigure.extent(figure.outline(samples: 32))
        guard reach > 1e-9, size > 1e-9 else { return (figure, false) }
        let scale = max(hypot(after.x, after.y) / reach, minimumSize / size)
        let angle = figure.isCircle ? 0 : atan2(after.y, after.x) - atan2(before.y, before.x)
        var next: NativePDFShapeFigure
        if figure.kind == .arrow, figure.vertices.count == 4 {
            // The head keeps its size; only the shaft follows the pen.
            let tip = figure.vertices[1], tail = figure.vertices[0]
            let turned = CGPoint(x: tail.x + scale * ((tip.x - tail.x) * cos(angle) - (tip.y - tail.y) * sin(angle)),
                                 y: tail.y + scale * ((tip.x - tail.x) * sin(angle) + (tip.y - tail.y) * cos(angle)))
            next = figure.movingEnd(1, to: turned)
        } else { next = figure.scaledRotated(about: pivot, scale: scale, angle: angle) }
        // Settle onto 0°, 45° and 90° within a few degrees; the line keeps its length, the figure its size.
        guard let snap = next.snapCorrection(tolerance: Self.angleSnap) else { return (next, false) }
        if next.kind == .arrow, next.vertices.count == 4 {
            let tail = next.vertices[0], tip = next.vertices[1]
            let turned = CGPoint(x: tail.x + (tip.x - tail.x) * cos(snap) - (tip.y - tail.y) * sin(snap),
                                 y: tail.y + (tip.x - tail.x) * sin(snap) + (tip.y - tail.y) * cos(snap))
            return (next.movingEnd(1, to: turned), true)
        }
        return (next.scaledRotated(about: next.pivot, scale: 1, angle: snap), true)
    }
    /// A line or arrow with one end moved; an arrow's head keeps its size and its angle to the shaft.
    func movingEnd(_ index: Int, to point: CGPoint) -> NativePDFShapeFigure {
        guard kind == .line || kind == .arrow, vertices.count >= 2 else { return self }
        var result = self
        if kind == .arrow, vertices.count == 4 {
            let tail = index == 0 ? point : vertices[0], tip = index == 0 ? vertices[1] : point
            let wings = Self.arrowWings(tail: tail, tip: tip, like: self)
            result.vertices = [tail, tip, wings.0, wings.1]
        } else { result.vertices[index == 0 ? 0 : 1] = point }
        return result
    }
    /// The direction of its first edge (lines, rectangles) or major axis (ellipses), in radians.
    var orientation: Double {
        switch kind {
        case .ellipse:
            let major = hypot(axisA.x, axisA.y) >= hypot(axisB.x, axisB.y) ? axisA : axisB
            return atan2(major.y, major.x)
        default:
            guard vertices.count >= 2 else { return 0 }
            return atan2(vertices[1].y - vertices[0].y, vertices[1].x - vertices[0].x)
        }
    }
    /// The smallest turn that lays one of its edges (or axes) on a multiple of 45°, when that turn is within
    /// `tolerance`. Circles have no direction.
    func snapCorrection(tolerance: Double) -> Double? {
        if isCircle { return nil }
        var directions: [Double]
        switch kind {
        case .ellipse: directions = [orientation]
        case .line, .arrow: directions = [orientation]
        default: directions = zip(pathCorners, pathCorners.dropFirst()).map { atan2($1.y - $0.y, $1.x - $0.x) }
        }
        let step = Double.pi / 4
        let corrections = directions.map { direction -> Double in
            let snapped = (direction / step).rounded() * step
            return snapped - direction
        }
        guard let best = corrections.min(by: { abs($0) < abs($1) }), abs(best) <= tolerance else { return nil }
        return best
    }
    /// Shifted onto the page (`width` 1, `height` = aspect) and, when larger, scaled down about its pivot to fit.
    func keptOnPage(aspect: Double, margin: Double = 0) -> NativePDFShapeFigure {
        let box = bounds
        guard !box.isNull, box.width.isFinite, box.height.isFinite else { return self }
        let room = CGRect(x: margin, y: margin, width: max(0, 1 - 2 * margin), height: max(0, aspect - 2 * margin))
        var figure = self
        let fit = min(1, room.width / max(box.width, 1e-9), room.height / max(box.height, 1e-9))
        if fit < 1 {
            figure = figure.applying(CGAffineTransform(translationX: box.midX, y: box.midY).scaledBy(x: fit, y: fit)
                .translatedBy(x: -box.midX, y: -box.midY))
        }
        let next = figure.bounds
        let dx = next.minX < room.minX ? room.minX - next.minX : next.maxX > room.maxX ? room.maxX - next.maxX : 0
        let dy = next.minY < room.minY ? room.minY - next.minY : next.maxY > room.maxY ? room.maxY - next.maxY : 0
        return dx == 0 && dy == 0 ? figure : figure.applying(CGAffineTransform(translationX: dx, y: dy))
    }

    // MARK: Helpers

    static func arrowWings(tail: CGPoint, tip: CGPoint, like figure: NativePDFShapeFigure? = nil) -> (CGPoint, CGPoint) {
        let shaft = hypot(tip.x - tail.x, tip.y - tail.y)
        var length = max(0.012, shaft * 0.22), spread = Double.pi / 6
        if let figure, figure.kind == .arrow, figure.vertices.count == 4 {
            let old = figure.vertices, back = atan2(old[0].y - old[1].y, old[0].x - old[1].x)
            let lengths = [old[2], old[3]].map { hypot($0.x - old[1].x, $0.y - old[1].y) }
            length = (lengths[0] + lengths[1]) / 2
            spread = [old[2], old[3]].map { abs(Self.wrap(atan2($0.y - old[1].y, $0.x - old[1].x) - back)) }.reduce(0, +) / 2
        }
        length = min(length, shaft * 0.45)
        let back = atan2(tail.y - tip.y, tail.x - tip.x)
        func wing(_ side: Double) -> CGPoint {
            CGPoint(x: tip.x + cos(back + side * spread) * length, y: tip.y + sin(back + side * spread) * length)
        }
        return (wing(1), wing(-1))
    }
    static func wrap(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi } else if value < -.pi { value += 2 * .pi }
        return value
    }
    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
    static func extent(_ points: [CGPoint]) -> Double {
        guard let first = points.first else { return 0 }
        let box = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        return hypot(box.width, box.height)
    }
    static func centroid(_ polygon: [CGPoint]) -> CGPoint {
        var area = 0.0, x = 0.0, y = 0.0
        for index in polygon.indices {
            let p = polygon[index], q = polygon[(index + 1) % polygon.count], cross = p.x * q.y - q.x * p.y
            area += cross; x += (p.x + q.x) * cross; y += (p.y + q.y) * cross
        }
        guard abs(area) > 1e-12 else {
            let count = Double(max(1, polygon.count))
            return CGPoint(x: polygon.reduce(0) { $0 + $1.x } / count, y: polygon.reduce(0) { $0 + $1.y } / count)
        }
        return CGPoint(x: x / (3 * area), y: y / (3 * area))
    }
    static func ellipseName(_ a: CGPoint, _ b: CGPoint) -> String {
        let la = hypot(a.x, a.y), lb = hypot(b.x, b.y), dot = (a.x * b.x + a.y * b.y) / max(la * lb, 1e-12)
        return abs(la - lb) <= 1e-6 * max(la, lb) && abs(dot) <= 1e-6 ? "circle" : "ellipse"
    }
    static func polygonName(_ corners: [CGPoint]) -> String {
        switch corners.count {
        case 3: return "triangle"
        case 4:
            let sides = corners.indices.map { i -> Double in
                let a = corners[i], b = corners[(i + 1) % 4]; return hypot(b.x - a.x, b.y - a.y)
            }
            let right = corners.indices.allSatisfy { i in
                let a = corners[(i + 3) % 4], b = corners[i], c = corners[(i + 1) % 4]
                let u = CGPoint(x: a.x - b.x, y: a.y - b.y), v = CGPoint(x: c.x - b.x, y: c.y - b.y)
                return abs(u.x * v.x + u.y * v.y) <= 1e-6 * hypot(u.x, u.y) * hypot(v.x, v.y)
            }
            let equal = (sides.max()! - sides.min()!) <= 1e-6 * sides.max()!
            return right ? (equal ? "square" : "rect") : (equal ? "diamond" : "quad")
        case 5: return "pentagon"
        case 6: return "hexagon"
        default: return "polygon"
        }
    }
}

/// A measured-only fit carried with the immutable stroke journal. Raw samples remain available for one-step shape
/// reversal and exact receipt recovery.
struct NativePDFHeldShape: Codable, Equatable {
    /// The figure's name (`NativePDFShapeFigure.name`). Journals written before shapes became ink hold "ink",
    /// "line", "rect" or "ellipse" here and no `width`; they are saved the way those builds saved them.
    var kind: String
    var points: [NativePDFPoint]
    var box: [Double] // x, y, width, height
    /// The drawn stroke's own diameter, in page widths: the saved shape is even ink of exactly this width.
    var width: Double? = nil
    /// `NativePDFShapeFigure.Kind` and its corner point indices (or ellipse segments), saved as `data.shape`.
    var figure: String? = nil
    var corners: [Int]? = nil
    var segments: Int? = nil

    static let legacyKinds = ["ink", "line", "rect", "ellipse"]
    init(kind: String, points: [NativePDFPoint], box: [Double]) {
        self.kind = kind; self.points = points; self.box = box
    }
    init(_ shape: NativePDFShapeFigure, width: Double, aspect: Double) {
        let ink = shape.ink(aspect: aspect)
        let xs = ink.points.map(\.x), ys = ink.points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        self.init(kind: shape.name, points: ink.points, box: [minX, minY, (xs.max() ?? 0) - minX, (ys.max() ?? 0) - minY])
        self.width = width; figure = shape.kind.rawValue; corners = ink.corners; segments = ink.segments
    }
    var isValid: Bool {
        guard (2...4096).contains(points.count), points.allSatisfy(\.isValid),
              box.count == 4, box.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
        guard let width else { return Self.legacyKinds.contains(kind) }
        guard width.isFinite, width > 0, width <= 1, let figure, let kind = NativePDFShapeFigure.Kind(rawValue: figure) else { return false }
        if kind == .ellipse { return segments.map { $0 >= 8 && $0 % 4 == 0 && points.count == $0 + 1 } ?? false }
        guard let corners, corners.count >= 2, corners.first == 0, corners.last == points.count - 1 else { return false }
        return zip(corners, corners.dropFirst()).allSatisfy { $0 < $1 }
    }
    var journalPayload: [String: Any] {
        var payload: [String: Any] = ["kind": kind, "points": points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }, "box": box]
        if let width { payload["width"] = width }
        if let figure { payload["figure"] = figure }
        if let corners { payload["corners"] = corners }
        if let segments { payload["segments"] = segments }
        return payload
    }
    /// `data.shape` of the saved row.
    var descriptor: [String: Any]? {
        guard width != nil, let figure, let kind = NativePDFShapeFigure.Kind(rawValue: figure) else { return nil }
        return NativePDFShapeFigure.descriptor(kind: kind, corners: corners, segments: segments)
    }
    /// The row this fit replaces the measured stroke with: even ink at the stroke's own width (a highlighter keeps
    /// its style, already even). Journals from before keep their old line/rect/ellipse correction.
    func correction(kind strokeKind: String, style: [String: Any]) -> (kind: String, data: [String: Any], style: [String: Any]) {
        let samples = points.map { ["x": $0.x, "y": $0.y, "p": $0.p] }
        if let width, let descriptor {
            var next = style
            if strokeKind != "highlighter" { next["width"] = width; next["fixedWidth"] = true }
            return (strokeKind == "highlighter" ? "highlighter" : "ink", ["points": samples, "inkVersion": 5, "shape": descriptor], next)
        }
        if strokeKind == "highlighter" { return ("highlighter", ["points": samples, "inkVersion": 5], style) }
        let data: [String: Any]
        if kind == "rect" || kind == "ellipse" {
            data = ["box": ["x": box[0], "y": box[1], "width": box[2], "height": box[3]]]
        } else {
            data = kind == "ink" ? ["points": samples, "inkVersion": 5] : ["points": samples]
        }
        var scaled = style
        if kind != "ink", let width = (style["width"] as? NSNumber)?.doubleValue { scaled["width"] = width * Self.legacyWidthFactor }
        return (kind, data, scaled)
    }
    /// What 1.5.0 multiplied a snapped line/rect/ellipse's width by. Only replayed journals from it still use it.
    static let legacyWidthFactor = 0.6

    /// The drawn stroke's diameter in page widths along its body: the median render width of its samples, leaving
    /// out the start and end tapers. Pass the samples before the pen came to rest for the shape.
    static func measuredWidth(points: [NativePDFPoint], style: NativePDFInkStyle, inkVersion: Int,
                              highlighter: Bool, aspect: Double) -> Double {
        let width = style.width
        guard !highlighter, style.fixedWidth != true, !points.isEmpty, aspect.isFinite, aspect > 0 else { return width }
        var factors: [Double]
        if inkVersion == 4 {
            // NativePDFInkGeometryV4.radius: no taper; touchdown and lift are left to the median.
            factors = NativePDFInkGeometryV3.filteredPressures(points).map { 0.42 + 0.20 * $0 }
        } else {
            guard let profile = NativePDFInkGeometryV5.renderProfile(points: points, width: width, aspect: aspect, highlighter: false) else { return width }
            let total = profile.travel.last ?? 0
            let taper = NativePDFInkGeometryV5.taperLength(travel: profile.travel, width: width)
            // startGain reaches 1 after 1.2 widths; endGain leaves 1 inside the taper.
            factors = profile.bases.indices.filter { profile.travel[$0] >= 1.2 * width && profile.travel[$0] <= total - taper }
                .map { profile.bases[$0] }
            if factors.isEmpty { factors = profile.bases }
        }
        guard !factors.isEmpty else { return width }
        let sorted = factors.sorted(), middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return min(1, max(1e-5, width * median))
    }
}
