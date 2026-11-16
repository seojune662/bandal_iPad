import Foundation
import CoreGraphics

/// Bounded, conservative recognition that runs once after the pen comes to rest, never per Pencil sample.
/// Geometry is in the page-width metric (y times the aspect); size limits are in screen points, because people
/// write letters at about the same size on screen whatever the zoom, and those letters must stay handwriting.
enum NativePDFShapeRecognition {
    /// Below these a figure is a letter: ㅁ, ㅇ, O, ㄱ, L, V written at handwriting size stay ink.
    static let minimumLine = 36.0, minimumClosed = 80.0, minimumOpenFigure = 80.0

    /// `screenScale`: screen points per page width.
    static func recognize(_ points: [NativePDFPoint], aspect: Double, screenScale: Double = 600) -> NativePDFShapeFigure? {
        guard points.count >= 6, aspect.isFinite, aspect > 0, screenScale.isFinite, screenScale > 0,
              points.allSatisfy(\.isValid) else { return nil }
        let unit = 1 / screenScale // one screen point in page widths
        var metric: [CGPoint] = []
        for point in points.prefix(8192) {
            let p = CGPoint(x: point.x, y: point.y * aspect)
            if let last = metric.last, hypot(p.x - last.x, p.y - last.y) < 0.5 * unit { continue }
            metric.append(p)
        }
        // The pause that asked for the shape: the tip resting, trembling within a few points.
        if let rest = metric.last, let moving = metric.lastIndex(where: { hypot($0.x - rest.x, $0.y - rest.y) > 3 * unit }) {
            metric.removeSubrange((moving + 2)...)
        }
        guard metric.count >= 4 else { return nil }
        let length = pathLength(metric)
        guard length >= minimumLine * unit else { return nil }
        let path = resample(metric, count: min(256, max(48, Int(length / (2.5 * unit)))))
        let diagonal = NativePDFShapeFigure.extent(path)
        if let line = line(path, unit: unit) { return line }
        if let contour = closedContour(path, unit: unit) {
            guard diagonal >= minimumClosed * unit else { return nil }
            return closedFigure(contour, unit: unit)
        }
        guard diagonal >= minimumOpenFigure * unit else { return nil }
        return openFigure(path, unit: unit)
    }

    // MARK: Lines and open figures

    private static func line(_ path: [CGPoint], unit: Double) -> NativePDFShapeFigure? {
        guard let first = path.first, let last = path.last else { return nil }
        let chord = hypot(last.x - first.x, last.y - first.y)
        guard chord >= minimumLine * unit, pathLength(path) <= chord * 1.08,
              path.allSatisfy({ NativePDFShapeFigure.distance($0, first, last) <= max(0.045 * chord, 2.5 * unit) }) else { return nil }
        // Fit the direction to every sample (a hand's start and end hooks barely move it), then keep the ends.
        let direction = principalDirection(path)
        let mid = CGPoint(x: path.reduce(0) { $0 + $1.x } / Double(path.count), y: path.reduce(0) { $0 + $1.y } / Double(path.count))
        func project(_ p: CGPoint) -> CGPoint {
            let t = (p.x - mid.x) * cos(direction) + (p.y - mid.y) * sin(direction)
            return CGPoint(x: mid.x + t * cos(direction), y: mid.y + t * sin(direction))
        }
        var figure = NativePDFShapeFigure(kind: .line, name: "line", vertices: [project(first), project(last)])
        if let snap = figure.snapCorrection(tolerance: 4 * .pi / 180) {
            figure = figure.scaledRotated(about: figure.vertices[0], scale: 1, angle: snap)
        }
        return figure
    }

    private static func openFigure(_ path: [CGPoint], unit: Double) -> NativePDFShapeFigure? {
        let diagonal = NativePDFShapeFigure.extent(path)
        var kept = simplify(path, epsilon: max(0.03 * diagonal, 2.5 * unit))
        // Drop joints that barely turn (one wavy edge is one edge) and corners a hair apart (a loop at a sharp turn).
        var changed = true
        while changed, kept.count > 2 {
            changed = false
            for i in 1..<(kept.count - 1) {
                let a = path[kept[i - 1]], b = path[kept[i]], c = path[kept[i + 1]]
                if abs(turn(a, b, c)) < 0.35 || (i + 1 < kept.count - 1 && hypot(c.x - b.x, c.y - b.y) < max(0.04 * diagonal, 6 * unit)) {
                    kept.remove(at: i); changed = true; break
                }
            }
        }
        let corners = kept.map { path[$0] }
        guard corners.count >= 3 else { return nil }
        // How far the samples of each edge stray from it, relative to its length.
        let straightness = zip(kept, kept.dropFirst()).map { a, b -> Double in
            let edge = max(Double(hypot(path[b].x - path[a].x, path[b].y - path[a].y)), unit)
            return (a...b).map { NativePDFShapeFigure.distance(path[$0], path[a], path[b]) }.max()! / max(edge, 50 * unit)
        }
        if corners.count == 5, straightness.allSatisfy({ $0 <= 0.12 }), let arrow = arrow(corners, unit: unit) { return arrow }
        let edges = zip(corners, corners.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        guard straightness.allSatisfy({ $0 <= 0.07 }), edges.allSatisfy({ $0 >= 40 * unit }), corners.count <= 7,
              // Every joint turns, and none folds straight back (a stroke retracing itself is not a chart).
              (1..<(corners.count - 1)).allSatisfy({ (0.35...2.6).contains(abs(turn(corners[$0 - 1], corners[$0], corners[$0 + 1]))) }) else { return nil }
        return NativePDFShapeFigure(kind: .polyline, name: "polyline", vertices: corners)
    }

    /// One stroke: tail → tip → wing → back to the tip → other wing, or tail → tip → wing → wing → tip.
    private static func arrow(_ corners: [CGPoint], unit: Double) -> NativePDFShapeFigure? {
        guard corners.count == 5 else { return nil }
        let tail = corners[0], tip = corners[1], shaft = hypot(tip.x - tail.x, tip.y - tail.y)
        guard shaft >= minimumOpenFigure * unit else { return nil }
        let wings: (CGPoint, CGPoint)
        if hypot(corners[3].x - tip.x, corners[3].y - tip.y) <= 0.3 * hypot(corners[2].x - tip.x, corners[2].y - tip.y) {
            wings = (corners[2], corners[4])
        } else if hypot(corners[4].x - tip.x, corners[4].y - tip.y) <= 0.3 * hypot(corners[2].x - tip.x, corners[2].y - tip.y) {
            wings = (corners[2], corners[3])
        } else { return nil }
        let back = atan2(tail.y - tip.y, tail.x - tip.x)
        let sides = [wings.0, wings.1].map { NativePDFShapeFigure.wrap(atan2($0.y - tip.y, $0.x - tip.x) - back) }
        let lengths = [wings.0, wings.1].map { hypot($0.x - tip.x, $0.y - tip.y) }
        guard sides[0] * sides[1] < 0, sides.allSatisfy({ (0.2...1.2).contains(abs($0)) }),
              lengths.allSatisfy({ $0 >= 0.06 * shaft && $0 <= 0.55 * shaft }) else { return nil }
        let length = (lengths[0] + lengths[1]) / 2, spread = (abs(sides[0]) + abs(sides[1])) / 2
        func wing(_ side: Double) -> CGPoint {
            CGPoint(x: tip.x + cos(back + side * spread) * length, y: tip.y + sin(back + side * spread) * length)
        }
        var figure = NativePDFShapeFigure(kind: .arrow, name: "arrow", vertices: [tail, tip, wing(1), wing(-1)])
        if let snap = figure.snapCorrection(tolerance: 4 * .pi / 180) {
            figure = figure.scaledRotated(about: tail, scale: 1, angle: snap)
        }
        return figure
    }

    // MARK: Closed figures

    /// The loop the stroke drew, without the part that ran past its start. Nil for an open stroke.
    private static func closedContour(_ path: [CGPoint], unit: Double) -> [CGPoint]? {
        let total = pathLength(path), diagonal = NativePDFShapeFigure.extent(path)
        guard let start = path.first, total > 0 else { return nil }
        var travelled = 0.0, best: (index: Int, distance: Double)?
        for index in 1..<path.count {
            travelled += Double(hypot(path[index].x - path[index - 1].x, path[index].y - path[index - 1].y))
            guard travelled >= 0.6 * total else { continue }
            let distance = Double(hypot(path[index].x - start.x, path[index].y - start.y))
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        guard let best else { return nil }
        // Run past the start and back over the first edge: the loop ends where it came closest to its start.
        let beginning = Array(path.prefix(max(2, (best.index + 1) * 2 / 5)))
        let retraced = path.dropFirst(best.index + 1).allSatisfy { p in
            zip(beginning, beginning.dropFirst()).contains { NativePDFShapeFigure.distance(p, $0, $1) <= max(0.1 * diagonal, 6 * unit) }
        }
        let limit = max(0.3 * diagonal, 10 * unit)
        let loop: [CGPoint]
        if retraced, best.distance <= limit { loop = Array(path[...best.index]) }
        // Left 5-10 % open (into a sharp corner, the closest point comes before the end).
        else if let end = path.last, Double(hypot(end.x - start.x, end.y - start.y)) <= limit { loop = path }
        else { return nil }
        // A loop, not a back-and-forth scribble.
        guard area(loop) >= 0.12 * pow(diagonal, 2) / 2 else { return nil }
        return loop
    }

    private struct Line { var point: CGPoint; var angle: Double; var points: [CGPoint] }
    private static func fitLine(_ points: [CGPoint]) -> Line {
        let n = Double(points.count)
        return Line(point: CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n),
                    angle: principalDirection(points), points: points)
    }
    private static func offset(_ p: CGPoint, from line: Line) -> Double {
        abs(-(p.x - line.point.x) * sin(line.angle) + (p.y - line.point.y) * cos(line.angle))
    }

    /// Corners are where the loop's turning gathers (the chords to 3 % of the loop before and after a sample turn
    /// 40° or more); the edges between them must be straight, and each corner is where its two edges' lines meet,
    /// so rounded corners, a loop at a sharp corner, a start mid-edge and a gap left open at a corner all land on
    /// the same clean polygon.
    private static func closedFigure(_ contour: [CGPoint], unit: Double) -> NativePDFShapeFigure? {
        let diagonal = NativePDFShapeFigure.extent(contour), count = 120, w = 4
        // The ring closes over the gap the hand left; samples on that closing chord were never drawn.
        guard let first = contour.first, let last = contour.last else { return nil }
        let drawn = pathLength(contour), gap = Double(hypot(last.x - first.x, last.y - first.y))
        let ring = Array(resample(contour + [first], count: count + 1).dropLast())
        let step = (drawn + gap) / Double(count)
        let onChord = (0..<count).map { Double($0) * step > drawn + 0.5 * step }
        let sign = area(ring, signed: true) >= 0 ? 1.0 : -1.0
        let turning = (0..<count).map { i -> Double in
            let a = ring[(i - w + count) % count], b = ring[i], c = ring[(i + w) % count]
            return sign * NativePDFShapeFigure.wrap(atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x))
        }
        var peaks: [Int] = []
        for i in 0..<count where turning[i] >= 40 * .pi / 180 {
            let around = (-2 * w...2 * w).filter { $0 != 0 }.map { (i + $0 + count) % count }
            if around.allSatisfy({ turning[$0] < turning[i] || (turning[$0] == turning[i] && $0 > i) }) { peaks.append(i) }
        }
        let sharp = peaks.filter { turning[$0] >= 70 * .pi / 180 }.count
        if let polygon = polygon(ring, onChord: onChord, peaks: peaks, window: w, diagonal: diagonal, unit: unit) {
            return regularize(polygon)
        }
        let ellipse = fitEllipse(contour)
        let radius = ellipse.map { sqrt($0.a * $0.b) } ?? 0
        let mean = ellipse.map { error(contour, ellipse: $0) / radius } ?? .infinity
        let worst = ellipse.map { maxError(contour, ellipse: $0) / radius } ?? .infinity
        if let ellipse, sharp <= 2, mean <= 0.05, worst <= 0.16 { return regularize(ellipse) }
        return nil
    }

    private static func polygon(_ ring: [CGPoint], onChord: [Bool], peaks: [Int], window w: Int, diagonal: Double, unit: Double) -> [CGPoint]? {
        guard (2...9).contains(peaks.count) else { return nil }
        let count = ring.count
        // Edges: the drawn samples clear of every corner window, split where the closing chord passes. An edge the
        // gap swallowed whole is the chord itself, the straight line the hand left open.
        var pieces: [[CGPoint]] = []
        for (index, peak) in peaks.enumerated() {
            let next = peaks[(index + 1) % peaks.count] + (index + 1 == peaks.count ? count : 0)
            var piece: [CGPoint] = [], drawn: [[CGPoint]] = [], chord: [CGPoint] = []
            for offset in stride(from: peak + w + 1, through: next - w - 1, by: 1) {
                let i = offset % count
                if onChord[i] { chord.append(ring[i]); if piece.count >= 3 { drawn.append(piece) }; piece = []; continue }
                piece.append(ring[i])
            }
            if piece.count >= 3 { drawn.append(piece) }
            // A sliver beside a corner or the gap has no reliable direction.
            drawn.removeAll { $0.count < 5 }
            if drawn.isEmpty, chord.count >= 3 { drawn = [chord] }
            pieces += drawn
        }
        var lines = pieces.map(fitLine)
        // Neighbouring pieces on one line are one edge (a gap left mid-edge, a corner that barely turned).
        var merged = true
        while merged, lines.count > 3 {
            merged = false
            for index in lines.indices {
                let a = lines[index], b = lines[(index + 1) % lines.count]
                let parallel = abs(NativePDFShapeFigure.wrap(2 * (a.angle - b.angle))) / 2 <= 15 * .pi / 180
                // The two ends of a stroke left open mid-edge rarely line up exactly.
                if parallel, b.points.allSatisfy({ offset($0, from: a) <= max(0.08 * diagonal, 5 * unit) }) {
                    let joined = fitLine(a.points + b.points)
                    if index + 1 == lines.count { lines[0] = joined; lines.removeLast() } else { lines[index] = joined; lines.remove(at: index + 1) }
                    merged = true; break
                }
            }
        }
        guard (3...6).contains(lines.count) else { return nil }
        var corners: [CGPoint] = []
        for index in lines.indices {
            let a = lines[(index + lines.count - 1) % lines.count], b = lines[index]
            let da = CGPoint(x: cos(a.angle), y: sin(a.angle)), db = CGPoint(x: cos(b.angle), y: sin(b.angle))
            guard let corner = intersection(a.point, CGPoint(x: a.point.x + da.x, y: a.point.y + da.y),
                                            b.point, CGPoint(x: b.point.x + db.x, y: b.point.y + db.y)),
                  ring.contains(where: { hypot($0.x - corner.x, $0.y - corner.y) <= max(0.15 * diagonal, 8 * unit) }) else { return nil }
            corners.append(corner)
        }
        // Each edge straight between its corners.
        for (index, line) in lines.enumerated() {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length >= max(0.08 * diagonal, 12 * unit),
                  line.points.allSatisfy({ NativePDFShapeFigure.distance($0, a, b) <= max(0.05 * length, 3 * unit) }) else { return nil }
        }
        guard convex(corners) else { return nil }
        return corners
    }

    /// Clean versions of what hands draw: axis-aligned when nearly so, squares, rhombi, equal-sided and level
    /// triangles, regular pentagons and hexagons.
    private static func regularize(_ input: [CGPoint]) -> NativePDFShapeFigure {
        var corners = input
        if area(corners, signed: true) < 0 { corners.reverse() }
        let n = corners.count, centre = NativePDFShapeFigure.centroid(corners)
        let sides = corners.indices.map { i -> Double in
            let a = corners[i], b = corners[(i + 1) % n]; return hypot(b.x - a.x, b.y - a.y)
        }
        let interior = corners.indices.map { i in .pi - abs(turn(corners[(i + n - 1) % n], corners[i], corners[(i + 1) % n])) }
        let meanSide = sides.reduce(0, +) / Double(n)
        let evenSides = sides.allSatisfy { abs($0 - meanSide) <= (n == 4 ? 0.2 : 0.15) * meanSide }
        let snap = 5 * Double.pi / 180
        // Four equal sides: a square when its diagonals match, a rhombus when one is clearly shorter (the
        // diagonals are steadier than corner angles read off hand-drawn edges). Otherwise near-square corners: a
        // rectangle.
        let offSquare = interior.map { abs($0 - .pi / 2) }.max() ?? .pi
        let diagonals = n == 4 ? [hypot(corners[2].x - corners[0].x, corners[2].y - corners[0].y), hypot(corners[3].x - corners[1].x, corners[3].y - corners[1].y)] : []
        let rhombus = evenSides && (diagonals.min() ?? 0) < 0.82 * (diagonals.max() ?? 0)
        if n == 4, !rhombus, offSquare <= 16 * .pi / 180 {
            // A rectangle: its direction is the mean of the four edge directions, folded onto a quarter turn.
            let folded = corners.indices.map { i -> Double in
                let a = corners[i], b = corners[(i + 1) % 4]; return 4 * atan2(b.y - a.y, b.x - a.x)
            }
            var angle = atan2(folded.map(sin).reduce(0, +), folded.map(cos).reduce(0, +)) / 4
            let frame = { (p: CGPoint) in CGPoint(x: (p.x - centre.x) * cos(angle) + (p.y - centre.y) * sin(angle),
                                                  y: -(p.x - centre.x) * sin(angle) + (p.y - centre.y) * cos(angle)) }
            let local = corners.map(frame)
            var half = CGSize(width: local.map { abs($0.x) }.reduce(0, +) / 4, height: local.map { abs($0.y) }.reduce(0, +) / 4)
            let square = abs(half.width - half.height) <= 0.1 * max(half.width, half.height)
            if square { let side = (half.width + half.height) / 2; half = CGSize(width: side, height: side) }
            let level = (angle / (.pi / 2)).rounded() * (.pi / 2)
            if abs(angle - level) <= snap { angle = level }
            else if square, abs(angle - ((angle / (.pi / 4)).rounded() * (.pi / 4))) <= snap { angle = (angle / (.pi / 4)).rounded() * (.pi / 4) }
            let box = [CGPoint(x: -half.width, y: -half.height), CGPoint(x: half.width, y: -half.height),
                       CGPoint(x: half.width, y: half.height), CGPoint(x: -half.width, y: half.height)]
            let placed = box.map { CGPoint(x: centre.x + $0.x * cos(angle) - $0.y * sin(angle), y: centre.y + $0.x * sin(angle) + $0.y * cos(angle)) }
            return NativePDFShapeFigure(kind: .polygon, name: NativePDFShapeFigure.polygonName(placed), vertices: placed)
        }
        if n == 4, rhombus {
            // A rhombus: perpendicular diagonals through one centre, upright when nearly so.
            let mid = CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4)
            let d1 = hypot(corners[2].x - corners[0].x, corners[2].y - corners[0].y) / 2
            let d2 = hypot(corners[3].x - corners[1].x, corners[3].y - corners[1].y) / 2
            let a1 = atan2(corners[2].y - corners[0].y, corners[2].x - corners[0].x)
            let a2 = atan2(corners[3].y - corners[1].y, corners[3].x - corners[1].x) - .pi / 2
            var angle = atan2(sin(2 * a1) + sin(2 * a2), cos(2 * a1) + cos(2 * a2)) / 2
            let level = (angle / (.pi / 2)).rounded() * (.pi / 2)
            if abs(angle - level) <= snap { angle = level }
            let axisX = CGPoint(x: cos(angle), y: sin(angle)), axisY = CGPoint(x: -sin(angle), y: cos(angle))
            let placed = [CGPoint(x: mid.x - axisX.x * d1, y: mid.y - axisX.y * d1), CGPoint(x: mid.x - axisY.x * d2, y: mid.y - axisY.y * d2),
                          CGPoint(x: mid.x + axisX.x * d1, y: mid.y + axisX.y * d1), CGPoint(x: mid.x + axisY.x * d2, y: mid.y + axisY.y * d2)]
            return NativePDFShapeFigure(kind: .polygon, name: "diamond", vertices: placed)
        }
        if n >= 5 || (n == 3 && evenSides), evenSides,
           interior.allSatisfy({ abs($0 - Double(n - 2) * .pi / Double(n)) <= 16 * .pi / 180 }) {
            // A regular polygon through the mean corner distance, a corner up when nearly so.
            let radius = corners.map { hypot($0.x - centre.x, $0.y - centre.y) }.reduce(0, +) / Double(n)
            let step = 2 * Double.pi / Double(n)
            let phases = corners.enumerated().map { index, p in Double(n) * (atan2(p.y - centre.y, p.x - centre.x) - Double(index) * step) }
            var phase = atan2(phases.map(sin).reduce(0, +), phases.map(cos).reduce(0, +)) / Double(n)
            // y grows downwards: "up" is -π/2. Also accept a flat bottom edge (a hexagon's other natural pose).
            for target in [-Double.pi / 2, -Double.pi / 2 + step / 2] {
                let k = ((phase - target) / step).rounded()
                if abs(phase - (target + k * step)) <= 8 * .pi / 180 { phase = target + k * step; break }
            }
            let placed = (0..<n).map { i in CGPoint(x: centre.x + radius * cos(phase + Double(i) * step), y: centre.y + radius * sin(phase + Double(i) * step)) }
            return NativePDFShapeFigure(kind: .polygon, name: NativePDFShapeFigure.polygonName(placed), vertices: placed)
        }
        var figure = NativePDFShapeFigure(kind: .polygon, name: NativePDFShapeFigure.polygonName(corners), vertices: corners)
        if n == 3, let correction = figure.snapCorrection(tolerance: snap) {
            figure = figure.scaledRotated(about: centre, scale: 1, angle: correction)
        }
        return figure
    }

    private struct Ellipse { var center: CGPoint; var a: Double; var b: Double; var angle: Double }

    /// From the loop's area moments (Green's theorem): a filled ellipse has covariance a²/4 and b²/4 on its axes.
    private static func fitEllipse(_ contour: [CGPoint]) -> Ellipse? {
        var area = 0.0, cx = 0.0, cy = 0.0, xx = 0.0, yy = 0.0, xy = 0.0
        for index in contour.indices {
            let p = contour[index], q = contour[(index + 1) % contour.count], cross = p.x * q.y - q.x * p.y
            area += cross; cx += (p.x + q.x) * cross; cy += (p.y + q.y) * cross
            xx += (p.x * p.x + p.x * q.x + q.x * q.x) * cross
            yy += (p.y * p.y + p.y * q.y + q.y * q.y) * cross
            xy += (p.x * q.y + 2 * p.x * p.y + 2 * q.x * q.y + q.x * p.y) * cross
        }
        area /= 2
        guard abs(area) > 1e-12 else { return nil }
        cx /= 6 * area; cy /= 6 * area
        let sxx = xx / (12 * area) - cx * cx, syy = yy / (12 * area) - cy * cy, sxy = xy / (24 * area) - cx * cy
        let mean = (sxx + syy) / 2, spread = sqrt(pow((sxx - syy) / 2, 2) + sxy * sxy)
        let major = mean + spread, minor = mean - spread
        guard major > 0, minor > 0 else { return nil }
        return Ellipse(center: CGPoint(x: cx, y: cy), a: 2 * sqrt(major), b: 2 * sqrt(minor), angle: atan2(2 * sxy, sxx - syy) / 2)
    }

    private static func regularize(_ input: Ellipse) -> NativePDFShapeFigure {
        var ellipse = input
        let circle = ellipse.b >= 0.86 * ellipse.a
        if circle { let r = (ellipse.a + ellipse.b) / 2; ellipse.a = r; ellipse.b = r; ellipse.angle = 0 }
        let level = (ellipse.angle / (.pi / 2)).rounded() * (.pi / 2)
        if abs(ellipse.angle - level) <= 8 * .pi / 180 { ellipse.angle = level }
        let axisA = CGPoint(x: cos(ellipse.angle) * ellipse.a, y: sin(ellipse.angle) * ellipse.a)
        let axisB = CGPoint(x: -sin(ellipse.angle) * ellipse.b, y: cos(ellipse.angle) * ellipse.b)
        return NativePDFShapeFigure(kind: .ellipse, name: circle ? "circle" : "ellipse", center: ellipse.center, axisA: axisA, axisB: axisB)
    }

    // MARK: Measures

    private static func radialDistance(_ p: CGPoint, _ e: Ellipse) -> Double {
        let dx = p.x - e.center.x, dy = p.y - e.center.y
        let x = dx * cos(e.angle) + dy * sin(e.angle), y = -dx * sin(e.angle) + dy * cos(e.angle)
        let rho = sqrt(pow(x / e.a, 2) + pow(y / e.b, 2))
        guard rho > 1e-9 else { return min(e.a, e.b) }
        return hypot(x, y) * abs(1 - 1 / rho)
    }
    private static func error(_ contour: [CGPoint], ellipse: Ellipse) -> Double {
        contour.reduce(0) { $0 + radialDistance($1, ellipse) } / Double(contour.count)
    }
    private static func maxError(_ contour: [CGPoint], ellipse: Ellipse) -> Double {
        contour.map { radialDistance($0, ellipse) }.max() ?? .infinity
    }
    private static func error(_ contour: [CGPoint], polygon: [CGPoint]) -> Double {
        contour.reduce(0) { sum, p in
            sum + polygon.indices.map { NativePDFShapeFigure.distance(p, polygon[$0], polygon[($0 + 1) % polygon.count]) }.min()!
        } / Double(contour.count)
    }
    private static func convex(_ corners: [CGPoint]) -> Bool {
        let turns = corners.indices.map { i in turn(corners[(i + corners.count - 1) % corners.count], corners[i], corners[(i + 1) % corners.count]) }
        return turns.allSatisfy { $0 > 0 } || turns.allSatisfy { $0 < 0 }
    }
    /// Signed turn at `b`, in radians.
    private static func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        NativePDFShapeFigure.wrap(atan2(c.y - b.y, c.x - b.x) - atan2(b.y - a.y, b.x - a.x))
    }
    private static func intersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGPoint? {
        let r = CGPoint(x: b.x - a.x, y: b.y - a.y), s = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 * hypot(r.x, r.y) * hypot(s.x, s.y) else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        return CGPoint(x: a.x + t * r.x, y: a.y + t * r.y)
    }
    private static func principalDirection(_ points: [CGPoint]) -> Double {
        let n = Double(points.count), mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points { sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my); sxy += (p.x - mx) * (p.y - my) }
        var angle = atan2(2 * sxy, sxx - syy) / 2
        // Keep the drawn direction, start to end.
        if let first = points.first, let last = points.last, cos(angle) * (last.x - first.x) + sin(angle) * (last.y - first.y) < 0 { angle += .pi }
        return angle
    }
    static func pathLength(_ points: [CGPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
    private static func area(_ points: [CGPoint], signed: Bool = false) -> Double {
        var value = 0.0
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            value += Double(p.x * q.y - q.x * p.y)
        }
        value /= 2
        return signed ? value : abs(value)
    }
    /// `count` points evenly spaced along the path, its ends included.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let total = pathLength(points)
        guard total > 0, count >= 2 else { return points }
        var output = [points[0]], segment = 1, start = 0.0
        var segmentLength = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        for step in 1..<(count - 1) {
            let target = total * Double(step) / Double(count - 1)
            while start + segmentLength < target, segment < points.count - 1 {
                start += segmentLength; segment += 1
                segmentLength = hypot(points[segment].x - points[segment - 1].x, points[segment].y - points[segment - 1].y)
            }
            let t = segmentLength > 0 ? (target - start) / segmentLength : 0
            let a = points[segment - 1], b = points[segment]
            output.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        output.append(points[points.count - 1])
        return output
    }
    /// Douglas–Peucker; returns the kept indices.
    private static func simplify(_ points: [CGPoint], epsilon: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep: Set<Int> = [0, points.count - 1], work = [(0, points.count - 1)]
        while let (start, end) = work.popLast() {
            var farthest = -1, maximum = epsilon
            if end > start + 1 {
                for i in (start + 1)..<end {
                    let d = NativePDFShapeFigure.distance(points[i], points[start], points[end])
                    if d > maximum { maximum = d; farthest = i }
                }
            }
            if farthest >= 0 { keep.insert(farthest); work.append((start, farthest)); work.append((farthest, end)) }
        }
        return keep.sorted()
    }
}
