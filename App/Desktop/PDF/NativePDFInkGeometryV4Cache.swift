import Foundation
import CoreGraphics

/// Measured segments own their controls. Appending a new measured sample
/// revises the old last segment, while replacing predictions changes only the
/// separate speculative tail. No resampled pressure is filtered a second time.
final class NativePDFInkGeometryV4Cache {
    private struct Configuration: Equatable {
        let width: Double
        let aspect: Double
        let highlighter: Bool
    }
    private var configuration: Configuration?
    private var raw: [NativePDFPoint] = []
    private var pressures: [Double] = []
    private var segmentEnds: [Int] = []
    private var output: [[CGPoint]] = []
    private var measuredPolygonCount = 0
    private(set) var recomputedPointCount = 0
    private(set) var recomputedSegmentCount = 0
    private(set) var retainedPrefixPolygonCount = 0
    private(set) var revision: UInt64 = 0
    var retainedPointCount: Int { raw.count }
    var retainedPolygonCount: Int { output.count }

    func reset() {
        configuration = nil; raw = []; pressures = []; segmentEnds = []; output = []
        measuredPolygonCount = 0; recomputedPointCount = 0; recomputedSegmentCount = 0; retainedPrefixPolygonCount = 0
    }

    func polygons(points: [NativePDFPoint], predictions: [NativePDFPoint] = [], width: Double,
                  aspect: Double, highlighter: Bool) -> [[CGPoint]] {
        revision &+= 1
        guard width.isFinite, width > 0, aspect.isFinite, aspect > 0, !points.isEmpty else { reset(); return [] }
        let next = Configuration(width: width, aspect: aspect, highlighter: highlighter)
        if configuration != next { reset(); configuration = next }
        var prefix = 0
        while prefix < min(raw.count, points.count), raw[prefix] == points[prefix] { prefix += 1 }
        guard points.dropFirst(prefix).allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.p.isFinite && ($0.y * aspect).isFinite }) else {
            reset(); return []
        }
        // Remove the old speculative geometry before modifying measured ink.
        if output.count > measuredPolygonCount { output.removeSubrange(measuredPolygonCount...) }
        recomputedPointCount = points.count - prefix; recomputedSegmentCount = 0
        let changed = prefix != raw.count || prefix != points.count
        retainedPrefixPolygonCount = measuredPolygonCount
        if changed {
            if prefix < pressures.count { pressures.removeSubrange(prefix...) }
            if prefix < points.count {
                let anchor = prefix == 0 ? 0 : prefix - 1
                var tail = Array(points[anchor...])
                if prefix > 0 { tail[0].p = pressures[prefix - 1] }
                pressures.append(contentsOf: NativePDFInkGeometryV3.filteredPressures(tail).dropFirst(prefix == 0 ? 0 : 1))
            }
            // Segment i reads raw[i-1...i+2]. A correction at j starts at
            // j-2; append/truncate revises only the previous/final live segment.
            let firstSegment = max(0, prefix - 2)
            let keep = prefix == 0 ? 0 : firstSegment == 0 ? 1 : segmentEnds[firstSegment - 1]
            retainedPrefixPolygonCount = keep
            if output.count > keep { output.removeSubrange(keep...) }
            if segmentEnds.count > firstSegment { segmentEnds.removeSubrange(firstSegment...) }
            if output.isEmpty {
                output.append(NativePDFInkGeometryV4.disk(.init(x: points[0].x, y: points[0].y, p: pressures[0]),
                                                         width: width, aspect: aspect, highlighter: highlighter))
            }
            for index in firstSegment..<max(firstSegment, points.count - 1) {
                NativePDFInkGeometryV4.forEachSegmentPolygon(points: points, pressures: pressures, index: index,
                    width: width, aspect: aspect, highlighter: highlighter) { output.append($0) }
                segmentEnds.append(output.count); recomputedSegmentCount += 1
            }
            measuredPolygonCount = output.count
        }
        raw = points
        NativePDFInkGeometryV4.forEachPredictionPolygon(lastPoint: points[points.count - 1], pressure: pressures[pressures.count - 1],
            predictions: predictions, width: width, aspect: aspect, highlighter: highlighter) { output.append($0) }
        return output
    }
}
