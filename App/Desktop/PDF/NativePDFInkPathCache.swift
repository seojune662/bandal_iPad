import Foundation
import CoreGraphics

fileprivate struct NativePDFInkPathInput: Equatable {
    let points: [NativePDFPoint]
    let version: Int
    let width: Double
    let aspect: Double
    let highlighter: Bool
}

/// Native presentation only. This object never enters the JSON drawing model.
/// The path uses the same normalized polygons as the versioned desktop ink.
final class NativePDFPreparedInk: NSObject {
    let path: CGPath
    /// Immutable broad-phase bounds. Eraser input must not ask CoreGraphics to
    /// walk every completed path again for each coalesced Pencil event.
    let bounds: CGRect
    fileprivate let input: NativePDFInkPathInput
    var aspect: Double { input.aspect }
    var pointCount: Int { input.points.count }
    let vertexCount: Int
    fileprivate init(path: CGPath, input: NativePDFInkPathInput, vertexCount: Int) {
        self.path = path; self.bounds = path.boundingBoxOfPath
        self.input = input; self.vertexCount = vertexCount
    }
}

/// A bounded cache for completed ink. Identity alone is never enough: undo,
/// estimated-property corrections and remote edits can replace the same ID.
final class NativePDFInkPathCache {
    private struct Entry {
        let ink: NativePDFPreparedInk
        let cost: Int
        var access: UInt64
    }
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    let byteLimit: Int
    let countLimit: Int
    private(set) var retainedCost = 0
    private(set) var buildCount = 0
    var retainedCount: Int { entries.count }

    init(byteLimit: Int = 32 * 1024 * 1024, countLimit: Int = 64) {
        self.byteLimit = max(0, byteLimit); self.countLimit = max(0, countLimit)
    }
    func removeAll() { entries.removeAll(); retainedCost = 0 }

    func prepare(_ input: NativePDFStrokeInput, aspect: Double, reusing: NativePDFPreparedInk? = nil) -> NativePDFPreparedInk? {
        prepare(key: input.clientMutationId, points: input.data.points, version: input.data.inkVersion,
                width: input.style.width, aspect: aspect, highlighter: input.kind == "highlighter", reusing: reusing)
    }
    func prepare(_ object: [String: Any], aspect: Double, reusing: NativePDFPreparedInk? = nil) -> NativePDFPreparedInk? {
        guard let kind = object["kind"] as? String, ["ink", "highlighter"].contains(kind),
              let data = object["data"] as? [String: Any], let version = number(data["inkVersion"]),
              version == 2 || version == 3 || version == 4 || version == 5,
              let style = object["style"] as? [String: Any], let width = number(style["width"]),
              let values = data["points"] as? [[String: Any]], values.count <= 250_000 else { return nil }
        var points: [NativePDFPoint] = []; points.reserveCapacity(values.count)
        for value in values {
            guard let x = number(value["x"]), let y = number(value["y"]), let p = number(value["p"]) else { return nil }
            let optional = ["t", "tiltX", "tiltY"]
            guard optional.allSatisfy({ value[$0] == nil || value[$0] is NSNull || number(value[$0]) != nil }) else { return nil }
            points.append(.init(x: x, y: y, p: p, t: number(value["t"]), tiltX: number(value["tiltX"]), tiltY: number(value["tiltY"])))
        }
        return prepare(key: object["id"] as? String ?? object["clientMutationId"] as? String,
                       points: points, version: Int(version), width: width, aspect: aspect, highlighter: kind == "highlighter",
                       reusing: reusing ?? object["_nativeInk"] as? NativePDFPreparedInk)
    }

    func prepare(key: String?, points: [NativePDFPoint], version: Int, width: Double, aspect: Double, highlighter: Bool, reusing: NativePDFPreparedInk? = nil) -> NativePDFPreparedInk? {
        guard [2, 3, 4, 5].contains(version), !points.isEmpty, points.count <= 250_000,
              width.isFinite, width > 0, aspect.isFinite, aspect > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.p.isFinite }) else {
            if let key { remove(key) }; return nil
        }
        let input = NativePDFInkPathInput(points: points, version: version, width: width, aspect: aspect, highlighter: highlighter)
        // Visible overlays already own these immutable paths. Reuse them
        // without creating an unbounded second cache or churning a small LRU
        // while repeatedly scanning a page containing more than 64 strokes.
        // The full input comparison also protects same-ID remote edits/undo.
        if let reusing, reusing.input == input { return reusing }
        clock &+= 1
        if let key, var entry = entries[key], entry.ink.input == input {
            entry.access = clock; entries[key] = entry; return entry.ink
        }
        if let key { remove(key) }
        let path = CGMutablePath()
        var vertices = 0, start = 0, pressure: Double?
        func append(_ polygon: [CGPoint]) {
            guard let first = polygon.first else { return }
            path.move(to: first)
            for point in polygon.dropFirst() { path.addLine(to: point) }
            path.closeSubpath(); vertices += polygon.count
        }
        if version == 5 {
            NativePDFInkGeometryV5.forEachPolygon(points: points, width: width,
                aspect: aspect, highlighter: highlighter, append)
        } else if version == 4 {
            // The curve needs neighbors on both sides of each measured
            // segment. Stream those segments with global pressure context;
            // arbitrary 256-point chunks would introduce visible seams.
            NativePDFInkGeometryV4.forEachPolygon(points: points, width: width,
                aspect: aspect, highlighter: highlighter, append)
        }
        // Keep temporary polygons bounded even for a long recorded stroke.
        // One preceding sample carries the causal EMA/tangent across chunks.
        while version < 4 && start < points.count {
            let end = min(points.count, start + 256), anchor = start > 0 ? 1 : 0
            var chunk = Array(points[(start - anchor)..<end])
            if version == 3, let pressure { chunk[0].p = pressure }
            let polygons: [[CGPoint]]
            if version == 3 {
                pressure = NativePDFInkGeometryV3.filteredPressures(chunk).last
                polygons = NativePDFInkGeometryV3.polygons(points: chunk, width: width, aspect: aspect, highlighter: highlighter)
            } else { polygons = NativePDFInkGeometry.polygons(points: chunk, width: width, aspect: aspect, highlighter: highlighter) }
            for polygon in polygons.dropFirst(anchor) { append(polygon) }
            start = end
        }
        guard !path.isEmpty, let immutable = path.copy() else { return nil }
        let ink = NativePDFPreparedInk(path: immutable, input: input, vertexCount: vertices)
        buildCount += 1
        // Conservative retained payload accounting (raw samples + path
        // vertices/commands). Oversized paths render but are never cached.
        let cost = points.count * MemoryLayout<NativePDFPoint>.stride + vertices * (MemoryLayout<CGPoint>.stride + 16)
        if let key, countLimit > 0, cost <= byteLimit {
            while entries.count >= countLimit || retainedCost + cost > byteLimit {
                guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
                remove(oldest)
            }
            entries[key] = Entry(ink: ink, cost: cost, access: clock); retainedCost += cost
        }
        return ink
    }
    private func remove(_ key: String) {
        if let old = entries.removeValue(forKey: key) { retainedCost -= old.cost }
    }
    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
