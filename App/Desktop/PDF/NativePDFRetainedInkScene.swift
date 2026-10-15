import UIKit

/// Native, immutable display resources only. This scene never rewrites a row,
/// journals input, or makes a deletion authoritative in the drawing repository.
@MainActor
final class NativePDFRetainedInkScene {
    typealias Renderer = NativePDFRetainedInkRenderer
    enum UpdateResult: Equatable {
        case supported
        case unsupported(Reason)
    }
    enum Reason: Equatable {
        case invalidAspect
        case invalidIdentity(Int)
        case duplicateIdentity(Int)
        case unsupportedKind(Int)
        case invalidInk(Int)
        case invalidStyle(Int)
        case invalidGeometry(Int)
        case allocationFailed(Int)
        case geometryBudgetExceeded
    }
    struct Entry {
        let savedID: String
        let mutationID: String?
        let kind: String
        let prepared: NativePDFPreparedInk
        var path: CGPath { prepared.path }
        let mesh: Renderer.Mesh
        let style: NativePDFInkStyle
        let color: SIMD4<Float>
        let visualToken: NativePDFCommittedVisualToken?
        var multiply: Bool { kind == "highlighter" }
    }
    private struct Geometry {
        // Own the key's object so allocator address reuse cannot hit stale ink.
        let prepared: NativePDFPreparedInk
        let mesh: Renderer.Mesh
    }
    private struct Candidate {
        let savedID: String, mutationID: String?, kind: String
        let prepared: NativePDFPreparedInk
        let style: NativePDFInkStyle
        let color: SIMD4<Float>
        let token: NativePDFCommittedVisualToken?
    }
    private let renderer: Renderer
    let geometryByteLimit: Int
    private var geometry: [ObjectIdentifier: Geometry] = [:]
    private(set) var entries: [Entry] = []
    private(set) var meshBuildCount = 0
    private(set) var retainedGeometryBytes = 0
    var retainedGeometryCount: Int { geometry.count }

    /// Bounds the accepted live mesh buffers. Already-submitted commands may
    /// temporarily retain an older revision until the GPU finishes using it.
    init(renderer: Renderer, geometryByteLimit: Int = 128 * 1024 * 1024) {
        self.renderer = renderer; self.geometryByteLimit = max(0, geometryByteLimit)
    }

    /// Tokens are accepted only as a separate native-owner array, paired with
    /// Row.prepared payloads. As in NavigationSnapshotBuilder, this trusted path
    /// may use that row's validated immutable _nativeInk directly. Dictionary
    /// markers cannot establish this contract; untrusted rows validate raw input.
    /// An unsupported row or allocation failure leaves the accepted scene intact.
    @discardableResult
    func update(objects: [[String: Any]], visualTokens: [NativePDFCommittedVisualToken]? = nil,
                aspect: Double) -> UpdateResult {
        guard aspect.isFinite, aspect > 0 else { return .unsupported(.invalidAspect) }
        let tokens = visualTokens?.count == objects.count ? visualTokens : nil
        var identities: [Data: Int] = [:]
        var priorByIdentity: [Data: Entry] = [:]
        for entry in entries {
            priorByIdentity[Data(entry.savedID.utf8)] = entry
            if let alias = entry.mutationID { priorByIdentity[Data(alias.utf8)] = entry }
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(objects.count)
        // Validate the complete list before allocating any new GPU meshes.
        for (index, object) in objects.enumerated() {
            guard let id = object["id"] as? String, !id.isEmpty else { return .unsupported(.invalidIdentity(index)) }
            let alias: String?
            if let raw = object["clientMutationId"] {
                guard let value = raw as? String, !value.isEmpty else { return .unsupported(.invalidIdentity(index)) }
                alias = value
            } else { alias = nil }
            for value in [id] + (alias.map { [$0] } ?? []) {
                let key = Data(value.utf8)
                if let owner = identities[key], owner != index { return .unsupported(.duplicateIdentity(index)) }
                identities[key] = index
            }
            guard let kind = object["kind"] as? String, kind == "ink" || kind == "highlighter" else {
                return .unsupported(.unsupportedKind(index))
            }
            guard let data = object["data"] as? [String: Any], let version = number(data["inkVersion"]),
                  [2.0, 3.0, 4.0, 5.0].contains(version),
                  let points = data["points"] as? [Any], !points.isEmpty, points.count <= 250_000 else {
                return .unsupported(.invalidInk(index))
            }
            guard let rawStyle = object["style"] as? [String: Any], let name = rawStyle["color"] as? String,
                  let width = number(rawStyle["width"]), let opacity = number(rawStyle["opacity"]) else {
                return .unsupported(.invalidStyle(index))
            }
            let style = NativePDFInkStyle(color: name, width: width, opacity: opacity)
            guard style.isValid else { return .unsupported(.invalidStyle(index)) }
            let token = tokens?[index]
            let candidate = token != nil ? object["_nativeInk"] as? NativePDFPreparedInk : nil
            // An ID only nominates an old path for prepareInk's complete input
            // equality check. It is never a geometry-cache authorization key.
            let prior = priorByIdentity[Data(id.utf8)] ?? alias.flatMap { priorByIdentity[Data($0.utf8)] }
            let prepared = candidate?.aspect == aspect ? candidate :
                NativePDFObjectRenderer.prepareInk(object, aspect: aspect, reusing: prior?.prepared)
            guard let prepared else { return .unsupported(.invalidGeometry(index)) }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard NativePDFObjectRenderer.color(name).getRed(&r, green: &g, blue: &b, alpha: &a) else {
                return .unsupported(.invalidStyle(index))
            }
            let alpha = Float(opacity) * Float(a)
            let color = SIMD4(Float(r) * alpha, Float(g) * alpha, Float(b) * alpha, alpha)
            candidates.append(Candidate(savedID: id, mutationID: alias, kind: kind,
                prepared: prepared, style: style, color: color, token: token))
        }
        // Preflight every distinct path before copying polygons or allocating
        // GPU buffers. Unchanged resources use their actual retained length;
        // new paths count fan vertices without materializing geometry arrays.
        var plannedBytes: [ObjectIdentifier: Int] = [:], totalBytes = 0
        for (index, value) in candidates.enumerated() {
            let key = ObjectIdentifier(value.prepared)
            if plannedBytes[key] != nil { continue }
            let bytes: Int
            if let old = geometry[key], old.prepared === value.prepared { bytes = old.mesh.buffer.length }
            else {
                guard let count = Self.meshByteCount(value.prepared.path) else {
                    return .unsupported(.invalidGeometry(index))
                }
                bytes = count
            }
            guard bytes <= Renderer.maximumMeshBytes, bytes <= geometryByteLimit - totalBytes else {
                return .unsupported(.geometryBudgetExceeded)
            }
            totalBytes += bytes; plannedBytes[key] = bytes
        }
        var nextGeometry: [ObjectIdentifier: Geometry] = [:]
        var nextEntries: [Entry] = []
        var builds = 0
        for (index, value) in candidates.enumerated() {
            let key = ObjectIdentifier(value.prepared)
            let resource: Geometry
            if let old = nextGeometry[key] ?? geometry[key], old.prepared === value.prepared { resource = old }
            else {
                guard let polygons = Self.convexPolygons(value.prepared.path) else {
                    return .unsupported(.invalidGeometry(index))
                }
                guard let mesh = renderer.makeMesh(convexPolygons: polygons) else {
                    return .unsupported(.allocationFailed(index))
                }
                resource = Geometry(prepared: value.prepared, mesh: mesh); builds += 1
            }
            nextGeometry[key] = resource
            nextEntries.append(Entry(savedID: value.savedID, mutationID: value.mutationID, kind: value.kind,
                prepared: value.prepared, mesh: resource.mesh, style: value.style,
                color: value.color, visualToken: value.token))
        }
        // Publish once. Old command buffers retain any meshes they still use;
        // this cache retains only geometries in the current accepted scene.
        entries = nextEntries; geometry = nextGeometry; meshBuildCount += builds
        retainedGeometryBytes = totalBytes
        return .supported
    }

    /// The affine maps the prepared path's normalized page coordinates into
    /// the destination viewport. Pan/zoom/order/omission never upload geometry.
    func items(transform: CGAffineTransform = .identity, excludingIDs: [String] = []) -> [Renderer.Item] {
        let excluded = Set(excludingIDs.map { Data($0.utf8) })
        return entries.compactMap { entry in
            guard !excluded.contains(Data(entry.savedID.utf8)),
                  entry.mutationID.map({ !excluded.contains(Data($0.utf8)) }) ?? true else { return nil }
            return Renderer.Item(mesh: entry.mesh, color: entry.color, transform: transform, multiply: entry.multiply)
        }
    }

    private func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func meshByteCount(_ path: CGPath) -> Int? {
        var vertices = 0, contour = 0, valid = true, closed = false
        path.applyWithBlock { value in
            switch value.pointee.type {
            case .moveToPoint:
                if contour != 0 { valid = false }
                contour = 1
            case .addLineToPoint:
                if contour == 0 { valid = false }
                let next = contour.addingReportingOverflow(1)
                if next.overflow { valid = false } else { contour = next.partialValue }
            case .closeSubpath:
                guard contour >= 3 else { valid = false; contour = 0; return }
                let triangles = (contour - 2).multipliedReportingOverflow(by: 3)
                let sum = vertices.addingReportingOverflow(triangles.partialValue)
                if triangles.overflow || sum.overflow { valid = false } else { vertices = sum.partialValue }
                contour = 0; closed = true
            default: valid = false
            }
        }
        let bytes = vertices.multipliedReportingOverflow(by: MemoryLayout<SIMD2<Float>>.stride)
        return valid && closed && contour == 0 && !bytes.overflow && bytes.partialValue > 0 ? bytes.partialValue : nil
    }

    private static func convexPolygons(_ path: CGPath) -> [[CGPoint]]? {
        // This parser is private to generated PreparedInk paths. General
        // non-convex/Bezier/nativePath data must never enter a triangle fan.
        var result: [[CGPoint]] = [], contour: [CGPoint] = [], valid = true
        path.applyWithBlock { value in
            let element = value.pointee
            switch element.type {
            case .moveToPoint:
                if !contour.isEmpty { valid = false }
                contour = [element.points[0]]
            case .addLineToPoint:
                if contour.isEmpty { valid = false }
                contour.append(element.points[0])
            case .closeSubpath:
                if contour.count < 3 { valid = false }
                else { result.append(contour) }
                contour.removeAll(keepingCapacity: true)
            default: valid = false
            }
        }
        return valid && contour.isEmpty && !result.isEmpty ? result : nil
    }
}
