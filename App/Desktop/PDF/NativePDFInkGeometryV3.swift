import Foundation
import CoreGraphics

/// Versioned, causal geometry shared with src/shared/inkV3.ts. Raw measured
/// coordinates, pressure and timestamps remain untouched in canonical storage.
enum NativePDFInkGeometryV3 {
    static let circleSegments = 32

    static func filteredPressures(_ points: [NativePDFPoint]) -> [Double] {
        guard let first = points.first else { return [] }
        var filtered = min(1, max(0, first.p)), result = [filtered]
        for index in 1..<points.count {
            let point = points[index], previous = points[index - 1]
            let delta: Double
            if let time = point.t, let before = previous.t, time.isFinite, before.isFinite {
                delta = min(32, max(0, time - before))
            } else { delta = 4 }
            let alpha = -expm1(-delta / 24)
            filtered += alpha * (min(1, max(0, point.p)) - filtered)
            result.append(filtered)
        }
        return result
    }

    /// The polygons all wind alike and are filled as one union before opacity.
    /// Tangent quads avoid the radial shoulders of perpendicular width changes.
    static func polygons(points: [NativePDFPoint], width: Double, aspect: Double, highlighter: Bool) -> [[CGPoint]] {
        guard width.isFinite, width > 0, aspect.isFinite, aspect > 0,
              points.allSatisfy({ [$0.x, $0.y, $0.p].allSatisfy(\.isFinite) }) else { return [] }
        let radii = filteredPressures(points).map { width * (highlighter ? 1 : 0.42 + 0.20 * $0) / 2 }
        var output: [[CGPoint]] = []
        output.reserveCapacity(max(0, points.count * 2 - 1))
        for (index, point) in points.enumerated() {
            let radius = radii[index]
            if index > 0 {
                let previous = points[index - 1], before = radii[index - 1]
                let dx = point.x - previous.x, dy = (point.y - previous.y) * aspect
                let distance = hypot(dx, dy), difference = before - radius
                // A contained disk needs no bridge. Preserve its circle/sample
                // so stationary pressure-only input remains a valid visible dot.
                if distance > abs(difference), distance > 1e-12 {
                    let ux = dx / distance, uy = dy / distance, along = difference / distance
                    let across = sqrt(max(0, 1 - along * along))
                    let lowX = ux * along + uy * across, lowY = uy * along - ux * across
                    let highX = ux * along - uy * across, highY = uy * along + ux * across
                    output.append([
                        CGPoint(x: previous.x + lowX * before, y: previous.y + lowY * before / aspect),
                        CGPoint(x: point.x + lowX * radius, y: point.y + lowY * radius / aspect),
                        CGPoint(x: point.x + highX * radius, y: point.y + highY * radius / aspect),
                        CGPoint(x: previous.x + highX * before, y: previous.y + highY * before / aspect)
                    ])
                }
            }
            output.append((0..<circleSegments).map { step in
                let angle = Double(step) * 2 * .pi / Double(circleSegments)
                return CGPoint(x: point.x + cos(angle) * radius, y: point.y + sin(angle) * radius / aspect)
            })
        }
        return output
    }
}
