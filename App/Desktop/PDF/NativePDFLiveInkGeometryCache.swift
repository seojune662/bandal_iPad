import CoreGraphics

/// Keeps a failed completion on its original geometry version while new
/// contacts use v5. Version changes invalidate the mesh prefix, not saved ink.
final class NativePDFLiveInkGeometryCache {
    private let legacy = NativePDFInkGeometryV4Cache()
    private let natural = NativePDFInkGeometryV5Cache()
    private var version: Int?
    private var shape: NativePDFHeldShape?
    private var shapeWidth: Double?
    private var shapePolygons: [[CGPoint]] = []
    private(set) var revision: UInt64 = 0
    private(set) var retainedPrefixPolygonCount = 0

    func reset() {
        legacy.reset(); natural.reset(); version = nil
        retainedPrefixPolygonCount = 0
        shape = nil; shapeWidth = nil; shapePolygons = []
    }

    func polygons(version nextVersion: Int, points: [NativePDFPoint], predictions: [NativePDFPoint] = [],
                  width: Double, aspect: Double, highlighter: Bool, heldShape: NativePDFHeldShape? = nil) -> [[CGPoint]] {
        revision &+= 1
        if let heldShape, heldShape.kind != "ink", !highlighter {
            if shape == heldShape && shapeWidth == width {
                retainedPrefixPolygonCount = shapePolygons.count
            } else {
                reset(); shape = heldShape; shapeWidth = width
                shapePolygons = heldShape.outlinePolygons(width: width)
            }
            return shapePolygons
        }
        if shape != nil { reset() }
        let changedVersion = version != nextVersion
        if changedVersion { reset(); version = nextVersion }
        let output: [[CGPoint]]
        switch nextVersion {
        case 4:
            output = legacy.polygons(points: points, predictions: predictions, width: width,
                                     aspect: aspect, highlighter: highlighter)
            retainedPrefixPolygonCount = changedVersion ? 0 : legacy.retainedPrefixPolygonCount
        case 5:
            output = natural.polygons(points: points, predictions: predictions, width: width,
                                      aspect: aspect, highlighter: highlighter)
            retainedPrefixPolygonCount = changedVersion ? 0 : natural.retainedPrefixPolygonCount
        default:
            reset(); return []
        }
        return output
    }
}
