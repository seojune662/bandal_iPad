import Foundation
import CoreGraphics

/// One live stroke only. Identical measured prefixes keep their polygons;
/// prediction replacement and late corrections invalidate the causal suffix.
/// All geometry still comes from the versioned pure implementation.
final class NativePDFInkGeometryV3Cache {
    private struct Configuration: Equatable {
        let width: Double
        let aspect: Double
        let highlighter: Bool
    }
    private var configuration: Configuration?
    private var raw: [NativePDFPoint] = []
    private var pressures: [Double] = []
    private var polygonEnds: [Int] = []
    private var output: [[CGPoint]] = []
    /// Changed raw samples, excluding the one preceding EMA anchor.
    private(set) var recomputedPointCount = 0
    var retainedPointCount: Int { raw.count }
    var retainedPolygonCount: Int { output.count }

    func reset() {
        configuration = nil
        raw = []; pressures = []; polygonEnds = []; output = []
        recomputedPointCount = 0
    }

    func polygons(points: [NativePDFPoint], width: Double, aspect: Double, highlighter: Bool) -> [[CGPoint]] {
        guard width.isFinite, width > 0, aspect.isFinite, aspect > 0, !points.isEmpty else {
            reset(); return []
        }
        let next = Configuration(width: width, aspect: aspect, highlighter: highlighter)
        if configuration != next { reset(); configuration = next }
        var prefix = 0
        while prefix < min(raw.count, points.count), raw[prefix] == points[prefix] { prefix += 1 }
        // The retained prefix was already validated. Checking only the suffix
        // avoids a second complete traversal on every new measured batch.
        guard points.dropFirst(prefix).allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.p.isFinite }) else {
            reset(); return []
        }
        recomputedPointCount = points.count - prefix
        if prefix < raw.count {
            let keep = prefix == 0 ? 0 : polygonEnds[prefix - 1]
            // Drop both old predictions and their storage on truncate/replace;
            // no prior stroke's tail or pressure state stays in the cache.
            output = Array(output.prefix(keep))
            pressures = Array(pressures.prefix(prefix))
            polygonEnds = Array(polygonEnds.prefix(prefix))
        }
        if prefix < points.count {
            var tail = Array(points[(prefix == 0 ? 0 : prefix - 1)...])
            if prefix > 0 {
                // The pure causal filter starts at its first pressure. Seeding
                // it with the preceding EMA state reproduces a full replay
                // exactly, while retaining that sample's original time/point.
                tail[0].p = pressures[prefix - 1]
            }
            let filtered = NativePDFInkGeometryV3.filteredPressures(tail)
            let polygons = NativePDFInkGeometryV3.polygons(points: tail, width: width, aspect: aspect, highlighter: highlighter)
            let anchor = prefix == 0 ? 0 : 1
            pressures.append(contentsOf: filtered.dropFirst(anchor))
            output.reserveCapacity(output.count + polygons.count - anchor)
            polygonEnds.reserveCapacity(points.count)
            // The anchor's first circle is already in output; its following
            // tangent belongs to the changed suffix and must be retained.
            for polygon in polygons.dropFirst(anchor) {
                output.append(polygon)
                if polygon.count == NativePDFInkGeometryV3.circleSegments { polygonEnds.append(output.count) }
            }
        }
        raw = points
        return output
    }
}
