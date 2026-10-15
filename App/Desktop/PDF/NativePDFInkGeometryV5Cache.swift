import Foundation
import CoreGraphics

/// Cached raw-rate width factors plus V4's local centerline. Appends revisit
/// the old/new end-taper windows and their preceding segment, never the whole
/// resampled stroke. Estimated corrections may conservatively rebuild a suffix.
final class NativePDFInkGeometryV5Cache {
    private struct Configuration: Equatable {
        let width: Double
        let aspect: Double
        let highlighter: Bool
    }
    private var configuration: Configuration?
    private var raw: [NativePDFPoint] = []
    private var profile = NativePDFInkGeometryV5.Profile()
    private var segmentEnds: [Int] = []
    private var output: [[CGPoint]] = []
    private var measuredPolygonCount = 0
    private(set) var recomputedPointCount = 0
    private(set) var recomputedFactorCount = 0
    private(set) var recomputedSegmentCount = 0
    private(set) var retainedPrefixPolygonCount = 0
    private(set) var revision: UInt64 = 0
    var retainedPointCount: Int { raw.count }
    var retainedPolygonCount: Int { output.count }
    var retainedAnchorCount: Int { profile.points.count }

    func reset() {
        configuration = nil; raw = []; profile = NativePDFInkGeometryV5.Profile()
        segmentEnds = []; output = []; measuredPolygonCount = 0
        recomputedPointCount = 0; recomputedFactorCount = 0; recomputedSegmentCount = 0
        retainedPrefixPolygonCount = 0
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
        if output.count > measuredPolygonCount { output.removeSubrange(measuredPolygonCount...) }
        recomputedPointCount = points.count - prefix; recomputedFactorCount = 0; recomputedSegmentCount = 0
        retainedPrefixPolygonCount = measuredPolygonCount
        if prefix != raw.count || prefix != points.count {
            let oldCount = profile.points.count
            guard let changedAnchor = profile.update(raw: points, unchangedPrefix: prefix, width: width,
                                                       aspect: aspect, highlighter: highlighter) else { reset(); return [] }
            let oldTail = max(0, oldCount - 1 - NativePDFInkGeometryV5.tailSegmentCount)
            let newTail = max(0, profile.points.count - 1 - NativePDFInkGeometryV5.tailSegmentCount)
            let factorStart = highlighter ? changedAnchor : min(changedAnchor, oldTail, newTail)
            recomputedFactorCount = profile.points.count - factorStart
            // Centerline i reads anchors[i-1...i+2]. Taper changes also affect
            // the segment immediately preceding the first changed factor.
            let firstSegment = max(0, min(changedAnchor - 2, factorStart - 1))
            let keep = factorStart == 0 || changedAnchor == 0 ? 0 : firstSegment == 0 ? 1 : segmentEnds[firstSegment - 1]
            retainedPrefixPolygonCount = keep
            if output.count > keep { output.removeSubrange(keep...) }
            if segmentEnds.count > firstSegment { segmentEnds.removeSubrange(firstSegment...) }
            if output.isEmpty {
                output.append(NativePDFInkGeometryV5.disk(.init(x: profile.points[0].x, y: profile.points[0].y, factor: profile.factors[0]), width: width, aspect: aspect))
            }
            for index in firstSegment..<max(firstSegment, profile.points.count - 1) {
                NativePDFInkGeometryV5.forEachSegmentPolygon(profile: profile, index: index,
                    width: width, aspect: aspect, highlighter: highlighter) { output.append($0) }
                segmentEnds.append(output.count); recomputedSegmentCount += 1
            }
            measuredPolygonCount = output.count
        }
        raw = points
        NativePDFInkGeometryV5.forEachPredictionPolygon(lastPoint: profile.points[profile.points.count - 1], factor: profile.factors[profile.factors.count - 1],
            predictions: predictions, width: width, aspect: aspect) { output.append($0) }
        return output
    }
}
