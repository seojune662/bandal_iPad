import UIKit

/// One presentation owner for ink meshes and independently prepared object
/// textures. A pending texture never replaces the last complete scene with a
/// partial candidate. Native local ink remains an optimistic tail of that
/// scene until the complete candidate can be adopted.
@MainActor
final class NativePDFRetainedMixedScene {
    typealias Renderer = NativePDFRetainedInkRenderer
    typealias InkEntry = NativePDFRetainedInkScene.Entry
    typealias Textures = NativePDFRetainedObjectTextures
    enum UpdateResult: Equatable { case supported, preparing, unsupported }
    private struct ObjectEntry {
        let id: String
        let alias: String?
        let source: Textures.Source
        let hit: NativePDFRetainedObjectHitTest.Geometry
        let resource: Textures.Resource
    }
    private enum Node {
        case ink(InkEntry)
        case object(ObjectEntry)
        var id: String { switch self { case .ink(let e): return e.savedID; case .object(let e): return e.id } }
        var alias: String? { switch self { case .ink(let e): return e.mutationID; case .object(let e): return e.alias } }
        var identities: [Data] { [Data(id.utf8)] + (alias.map { [Data($0.utf8)] } ?? []) }
    }
    private enum Candidate {
        case ink(Int)
        case object(String, String?, Textures.Source, NativePDFRetainedObjectHitTest.Geometry)
    }
    private struct Capture {
        let id: String
        let alias: String?
        let source: Textures.Source
        let hit: NativePDFRetainedObjectHitTest.Geometry
    }
    private let ink: NativePDFRetainedInkScene
    let textures: Textures
    private let inkHit = NativePDFRetainedInkHitTest()
    private var accepted: [Node] = []
    private var candidateInk: [InkEntry] = []
    private var captures: [Data: Capture] = [:]
    private var desiredIdentities = Set<Data>()
    private var localIdentities = Set<Data>()
    private var pageSize: CGSize = .zero
    private(set) var hasAcceptedScene = false
    private(set) var preparing = false
    private(set) var acceptedRevision: UInt64 = 0
    var onResourcesChanged: (() -> Void)?
    var retainedGeometryCount: Int { ink.retainedGeometryCount }
    var meshBuildCount: Int { ink.meshBuildCount }
    var requiresObjectTextures: Bool { !captures.isEmpty }
    var objectCount: Int { accepted.reduce(0) { count, node in if case .object = node { return count + 1 }; return count } }

    init(renderer: Renderer, textures: Textures? = nil) {
        ink = NativePDFRetainedInkScene(renderer: renderer)
        self.textures = textures ?? Textures(renderer: renderer)
        self.textures.onChange = { [weak self] in self?.onResourcesChanged?() }
    }

    func reset() {
        textures.reset(); inkHit.removeAll(); accepted = []; candidateInk = []; captures = [:]
        desiredIdentities = []; localIdentities = []; pageSize = .zero
        hasAcceptedScene = false; preparing = false
        _ = ink.update(objects: [], visualTokens: [], aspect: 1)
    }

    /// These identities come only from the native input/acknowledgement owner,
    /// never from an object dictionary's claimed private marker.
    func rememberLocalMutation(_ mutationID: String) {
        if !mutationID.isEmpty { localIdentities.insert(Data(mutationID.utf8)) }
    }
    func rememberNativeAlias(mutationID: String, drawingID: String) {
        guard !mutationID.isEmpty, !drawingID.isEmpty else { return }
        localIdentities.insert(Data(mutationID.utf8)); localIdentities.insert(Data(drawingID.utf8))
    }

    @discardableResult
    func update(objects: [[String: Any]], visualTokens: [NativePDFCommittedVisualToken]?,
                pageSize: CGSize, scale: CGFloat,
                image: ([String: Any]) -> UIImage?) -> UpdateResult {
        guard pageSize.width.isFinite, pageSize.height.isFinite,
              pageSize.width > 0, pageSize.height > 0, scale.isFinite, scale > 0 else { return .unsupported }
        let aspect = pageSize.height / pageSize.width
        let tokens = visualTokens?.count == objects.count ? visualTokens : nil
        var seen: [Data: Int] = [:]
        var modern: [[String: Any]] = [], modernTokens: [NativePDFCommittedVisualToken] = []
        var candidates: [Candidate] = [], nextCaptures: [Data: Capture] = [:]
        var sources: [Textures.Source] = []
        // Bound accepted plus this candidate's recordings before publishing
        // them. Replaced pending recordings can coexist during this synchronous
        // capture pass (at most one prior candidate), then leave the model/cache.
        // Charging obsolete pending captures here would prevent their eviction.
        var ownedSources = Set<ObjectIdentifier>()
        var sourceBytes = 0
        func reserve(_ source: Textures.Source) -> Bool {
            if ownedSources.contains(ObjectIdentifier(source)) { return true }
            guard source.byteCost <= textures.byteLimit - sourceBytes else { return false }
            ownedSources.insert(ObjectIdentifier(source)); sourceBytes += source.byteCost
            return true
        }
        for node in accepted {
            if case .object(let entry) = node, !reserve(entry.source) { return .unsupported }
        }
        // Validate identity and every drawable/hit contract before preparing a
        // partial ink model or scheduling an object texture request.
        for (index, object) in objects.enumerated() {
            guard let id = object["id"] as? String, !id.isEmpty,
                  let kind = object["kind"] as? String else { return .unsupported }
            let alias: String?
            if let raw = object["clientMutationId"] {
                guard let value = raw as? String, !value.isEmpty else { return .unsupported }
                alias = value
            } else { alias = nil }
            let keys = [Data(id.utf8)] + (alias.map { [Data($0.utf8)] } ?? [])
            for key in keys {
                if let owner = seen[key], owner != index { return .unsupported }
                seen[key] = index
            }
            let data = object["data"] as? [String: Any]
            let version = (data?["inkVersion"] as? NSNumber).flatMap {
                CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite ? $0.doubleValue : nil
            }
            if ["ink", "highlighter"].contains(kind), let version, [2.0, 3.0, 4.0, 5.0].contains(version) {
                candidates.append(.ink(modern.count)); modern.append(object)
                if let token = tokens?[index] { modernTokens.append(token) }
                continue
            }
            let previous = captures[Data(id.utf8)] ?? alias.flatMap { captures[Data($0.utf8)] }
            guard let source = Textures.capture(object: object, visualToken: tokens?[index],
                      image: ["image", "clip"].contains(kind) ? image(object) : nil,
                      pageSize: pageSize, reusing: previous?.source) else { return .unsupported }
            guard reserve(source) else { return .unsupported }
            let hit: NativePDFRetainedObjectHitTest.Geometry
            if let previous, previous.source === source { hit = previous.hit }
            else {
                guard let prepared = NativePDFRetainedObjectHitTest.prepare(object: object, aspect: aspect) else { return .unsupported }
                hit = prepared
            }
            let capture = Capture(id: id, alias: alias, source: source, hit: hit)
            for key in keys { nextCaptures[key] = capture }
            candidates.append(.object(id, alias, source, capture.hit)); sources.append(source)
        }
        guard ink.update(objects: modern,
            visualTokens: modernTokens.count == modern.count ? modernTokens : nil,
            aspect: aspect) == .supported else { return .unsupported }
        candidateInk = ink.entries
        for entry in candidateInk {
            let keys = [Data(entry.savedID.utf8)] + (entry.mutationID.map { [Data($0.utf8)] } ?? [])
            if keys.contains(where: localIdentities.contains) { localIdentities.formUnion(keys) }
        }
        desiredIdentities = Set(seen.keys); captures = nextCaptures
        let protected = accepted.compactMap { node -> Textures.Source? in
            if case .object(let entry) = node { return entry.source }; return nil
        }
        let protectedResources = accepted.compactMap { node -> Textures.Resource? in
            if case .object(let entry) = node { return entry.resource }; return nil
        }
        textures.update(requests: sources.map { .init(source: $0, scale: scale) },
            keeping: protected, keepingResources: protectedResources)
        guard !sources.contains(where: { textures.status(for: $0) == .unavailable }) else {
            preparing = false
            return .unsupported
        }
        var ready: [Node] = []
        ready.reserveCapacity(candidates.count)
        for candidate in candidates {
            switch candidate {
            case .ink(let index): ready.append(.ink(candidateInk[index]))
            case .object(let id, let alias, let source, let hit):
                guard let resource = textures.resource(for: source) else {
                    preparing = true
                    // On an initial or different-sized page the old projection
                    // is not a valid stand-in. The surface keeps its exact
                    // legacy initial display until this candidate is ready.
                    if self.pageSize != pageSize { hasAcceptedScene = false }
                    return .preparing
                }
                ready.append(.object(.init(id: id, alias: alias, source: source, hit: hit, resource: resource)))
            }
        }
        accepted = ready; self.pageSize = pageSize; hasAcceptedScene = true
        preparing = false; acceptedRevision &+= 1
        return .supported
    }

    private func presentation() -> [Node] {
        guard hasAcceptedScene else { return [] }
        guard preparing else { return accepted }
        // Structural removal is immediate, even if some unrelated replacement
        // texture is waiting. Optimistic locally completed ink never needs a
        // bitmap worker before the next Pencil contact can appear.
        var latestLocal: [Data: InkEntry] = [:]
        for entry in candidateInk {
            let keys = [Data(entry.savedID.utf8)] + (entry.mutationID.map { [Data($0.utf8)] } ?? [])
            if keys.contains(where: localIdentities.contains) {
                for key in keys { latestLocal[key] = entry }
            }
        }
        var shown = Set<Data>(), result: [Node] = []
        for node in accepted where node.identities.contains(where: desiredIdentities.contains) {
            let next: Node
            if case .ink = node, let updated = node.identities.compactMap({ latestLocal[$0] }).first {
                next = .ink(updated)
            } else { next = node }
            guard !next.identities.contains(where: shown.contains) else { continue }
            shown.formUnion(next.identities); result.append(next)
        }
        for entry in candidateInk {
            let node = Node.ink(entry)
            guard node.identities.contains(where: localIdentities.contains),
                  !node.identities.contains(where: shown.contains) else { continue }
            shown.formUnion(node.identities); result.append(node)
        }
        return result
    }

    func items(transform: CGAffineTransform, excludingIDs: [String]) -> [Renderer.Item] {
        let excluded = Set(excludingIDs.map { Data($0.utf8) })
        return presentation().compactMap { node in
            guard !node.identities.contains(where: excluded.contains) else { return nil }
            switch node {
            case .ink(let entry):
                return .init(mesh: entry.mesh, color: entry.color, transform: transform, multiply: entry.multiply)
            case .object(let entry):
                let b = entry.resource.bounds, size = entry.source.pageSize
                let uv = CGAffineTransform(a: b.width / size.width, b: 0, c: 0,
                    d: b.height / size.height, tx: b.minX / size.width, ty: b.minY / size.height)
                return .init(texture: entry.resource.texture, transform: uv.concatenating(transform), multiply: entry.source.multiply)
            }
        }
    }

    func hits(points: [CGPoint], previous: CGPoint?) -> [NativePDFEraseTarget] {
        let nodes = presentation()
        let modern = nodes.compactMap { node -> InkEntry? in if case .ink(let entry) = node { return entry }; return nil }
        let nonInk = nodes.compactMap { node -> NativePDFRetainedObjectHitTest.Entry? in
            if case .object(let entry) = node { return .init(savedID: entry.id, mutationID: entry.alias, geometry: entry.hit) }; return nil
        }
        let inkKeys = Set(inkHit.hits(entries: modern, points: points, previous: previous).map { Data($0.savedID.utf8) })
        let objectKeys = Set(NativePDFRetainedObjectHitTest.hits(entries: nonInk, points: points, previous: previous).map { Data($0.savedID.utf8) })
        return nodes.compactMap { node in
            guard inkKeys.contains(Data(node.id.utf8)) || objectKeys.contains(Data(node.id.utf8)) else { return nil }
            return .init(drawingID: node.id, mutationID: node.alias)
        }
    }
}
