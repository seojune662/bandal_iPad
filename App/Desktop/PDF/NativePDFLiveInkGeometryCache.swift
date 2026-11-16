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

    /// `taper` false draws the live tail at full measured width; the stroke's
    /// end taper applies once the contact is complete.
    func polygons(version nextVersion: Int, points: [NativePDFPoint], predictions: [NativePDFPoint] = [],
                  width: Double, aspect: Double, highlighter: Bool, fixedWidth: Bool = false, heldShape: NativePDFHeldShape? = nil,
                  taper: Bool = true) -> [[CGPoint]] {
        revision &+= 1
        let constantWidth = highlighter || fixedWidth
        // A held shape is drawn exactly as it is saved: even inkVersion 5 ink at the stroke's own width.
        if let heldShape {
            let evenWidth = heldShape.width ?? width
            if shape == heldShape && shapeWidth == evenWidth {
                retainedPrefixPolygonCount = shapePolygons.count
            } else {
                reset(); shape = heldShape; shapeWidth = evenWidth
                shapePolygons = NativePDFInkGeometryV5.polygons(points: heldShape.points, width: evenWidth, aspect: aspect, highlighter: true)
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
                                     aspect: aspect, highlighter: constantWidth)
            retainedPrefixPolygonCount = changedVersion ? 0 : legacy.retainedPrefixPolygonCount
        case 5:
            output = natural.polygons(points: points, predictions: predictions, width: width,
                                      aspect: aspect, highlighter: constantWidth, taper: taper)
            retainedPrefixPolygonCount = changedVersion ? 0 : natural.retainedPrefixPolygonCount
        default:
            reset(); return []
        }
        return output
    }
}
