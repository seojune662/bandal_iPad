import UIKit

/// Provenance for an opaque scene that was actually installed. Navigation may
/// reproject these pixels and replay a later suffix, but may not reinterpret
/// them as a newer revision or use them outside their captured crop.
@MainActor
final class NativePDFRetainedInkBackdrop {
    let image: UIImage
    let snapshot: NativePDFNavigationSnapshot
    let mapper: InkCoordinateMapper
    let viewport: NativePDFRenderViewport
    var prefixCount: Int { snapshot.objects.count }

    /// A worker can capture this before rasterization, without already having
    /// an image. It freezes all visual dependencies; a later result is usable
    /// only if that entire captured prefix still means the same pixels.
    @MainActor
    struct Content {
        let snapshot: NativePDFNavigationSnapshot
        let geometry: InkPageGeometry
        var prefixCount: Int { snapshot.objects.count }
        private let tokens: [NativePDFCommittedVisualToken]
        private let identifiers: [String?]
        private let highlightToken: NativePDFCommittedVisualToken
        private let resolvedImages: [UIImage?]

        /// `adopt` reads only row count/identity and these frozen visual tokens;
        /// it never renders these identity-only rows. Keep the old raster's
        /// appearance metadata even if mutable source containers changed while
        /// its worker was running. Later replay draws the owner's current rows.
        var cacheSeedRows: [[String: Any]] { identifiers.map { $0.map { ["id": $0] } ?? [:] } }
        var cacheSeedTokens: [NativePDFCommittedVisualToken] { tokens }
        var continuityIdentifiers: Set<String> { Set(identifiers.compactMap { $0 }) }

        init?(snapshot: NativePDFNavigationSnapshot, mapper: InkCoordinateMapper,
              objects: [[String: Any]], tokens: [NativePDFCommittedVisualToken]?,
              highlights: [[String: Any]], imageForObject: ([String: Any]) -> UIImage?) {
            guard snapshot.objects.count == objects.count, NativePDFRetainedInkBackdrop.valid(mapper) else { return nil }
            self.snapshot = snapshot; geometry = mapper.geometry
            self.tokens = NativePDFRetainedInkBackdrop.visualTokens(objects: objects, supplied: tokens)
            identifiers = objects.map(NativePDFRetainedInkBackdrop.identifier)
            highlightToken = NativePDFRetainedInkBackdrop.highlightsToken(highlights)
            resolvedImages = objects.map { NativePDFRetainedInkBackdrop.resolvedImage($0, imageForObject: imageForObject) }
        }

        /// A display-only result may advance during continuous erasing only
        /// when it cannot restore any row already absent from the prior display.
        /// Compare captured metadata, never a newer caller-owned dictionary.
        /// The owner separately validates the crop/transform and must prove
        /// displayed -> captured -> latest before accepting an intermediate crop.
        func isDeletionSuccessor(of earlier: Content) -> Bool {
            guard snapshot.paper === earlier.snapshot.paper, snapshot.size == earlier.snapshot.size,
                  geometry == earlier.geometry, identifiers.count <= earlier.identifiers.count,
                  highlightToken.hasSameAppearance(as: earlier.highlightToken),
                  let earlierKeys = Self.uniqueIdentifierKeys(earlier.identifiers),
                  let laterKeys = Self.uniqueIdentifierKeys(identifiers) else { return false }
            var cursor = 0
            for (laterIndex, key) in laterKeys.enumerated() {
                while cursor < earlierKeys.count, earlierKeys[cursor] != key { cursor += 1 }
                guard cursor < earlierKeys.count,
                      tokens[laterIndex].hasSameAppearance(as: earlier.tokens[cursor]),
                      resolvedImages[laterIndex] === earlier.resolvedImages[cursor] else { return false }
                cursor += 1
            }
            return true
        }

        private static func uniqueIdentifierKeys(_ identifiers: [String?]) -> [Data]? {
            var keys: [Data] = [], seen = Set<Data>()
            keys.reserveCapacity(identifiers.count); seen.reserveCapacity(identifiers.count)
            for identifier in identifiers {
                // Swift String equality normalizes canonically equivalent text;
                // wire IDs are exact UTF8, like the editor scene's identity map.
                guard let identifier, !identifier.isEmpty else { return nil }
                let key = Data(identifier.utf8)
                guard seen.insert(key).inserted else { return nil }
                keys.append(key)
            }
            return keys
        }

        func canReuse(snapshot current: NativePDFNavigationSnapshot, mapper currentMapper: InkCoordinateMapper,
                      objects: [[String: Any]], tokens supplied: [NativePDFCommittedVisualToken]?,
                      highlights: [[String: Any]], imageForObject: ([String: Any]) -> UIImage?,
                      stablePrefixCount: Int? = nil, currentMutableStartIndex: Int? = nil) -> Bool {
            guard current.paper === snapshot.paper, current.size == snapshot.size,
                  currentMapper.geometry == geometry, NativePDFRetainedInkBackdrop.valid(currentMapper),
                  current.objects.count == objects.count, objects.count >= prefixCount,
                  highlightToken.hasSameAppearance(as: NativePDFRetainedInkBackdrop.highlightsToken(highlights)) else { return false }
            // A worker's separate stable-prefix bitmap allows corrected tail
            // rows to be replayed without rejecting every result during rapid
            // writing. A retained full backdrop leaves this argument nil and
            // still requires every captured row's appearance to be identical.
            let strictCount = stablePrefixCount ?? prefixCount
            if stablePrefixCount != nil {
                guard (0...prefixCount).contains(strictCount), let currentMutableStartIndex,
                      (strictCount...objects.count).contains(currentMutableStartIndex) else { return false }
            }
            let trusted = supplied?.count == objects.count ? supplied : nil
            for index in 0..<prefixCount {
                let row = objects[index]
                guard identifiers[index] == NativePDFRetainedInkBackdrop.identifier(row),
                      resolvedImages[index] === NativePDFRetainedInkBackdrop.resolvedImage(row, imageForObject: imageForObject) else { return false }
                if index < strictCount {
                    guard tokens[index].hasSameAppearance(as: trusted?[index] ?? NativePDFCommittedVisualToken(object: row)) else { return false }
                } else if identifiers[index] == nil {
                    // The scene cache must be able to prove tail row order.
                    // Unknown IDs cannot establish safe correction ownership.
                    return false
                }
            }
            return true
        }
    }

    var continuityIdentifiers: Set<String> { content.continuityIdentifiers }

    let content: Content

    /// The owner must supply the rows/snapshot that produced `image`, from the
    /// successful scene-install transaction. This validates their dimensions
    /// and freezes comparison metadata; it never rebuilds or resamples pixels.
    convenience init?(image: UIImage, snapshot: NativePDFNavigationSnapshot,
          mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport,
          objects: [[String: Any]], tokens: [NativePDFCommittedVisualToken]?,
          highlights: [[String: Any]], imageForObject: ([String: Any]) -> UIImage?) {
        guard let content = Content(snapshot: snapshot, mapper: mapper, objects: objects, tokens: tokens,
                  highlights: highlights, imageForObject: imageForObject) else { return nil }
        self.init(image: image, content: content, mapper: mapper, viewport: viewport)
    }

    /// Retain worker pixels with the exact metadata captured before rendering.
    /// Reconstructing Content from current rows could mislabel an older image.
    init?(image: UIImage, content: Content, mapper: InkCoordinateMapper, viewport: NativePDFRenderViewport) {
        guard content.geometry == mapper.geometry, Self.valid(mapper), Self.valid(viewport),
              image.imageOrientation == .up, image.scale == viewport.pixelScale, let pixels = image.cgImage,
              CGFloat(pixels.width) == viewport.pixelSize.width,
              CGFloat(pixels.height) == viewport.pixelSize.height else { return nil }
        self.image = image; self.snapshot = content.snapshot; self.mapper = mapper; self.viewport = viewport
        self.content = content
    }

    /// Only the captured prefix is baked into these pixels. Appending,
    /// correcting, deleting or reordering later rows is safe if the owner
    /// rebuilds that entire suffix in current canonical order. Affine viewport
    /// changes are allowed; page/annotation recording and page geometry are not.
    func canReuse(snapshot current: NativePDFNavigationSnapshot, mapper currentMapper: InkCoordinateMapper,
                  objects: [[String: Any]], tokens supplied: [NativePDFCommittedVisualToken]?,
                  highlights: [[String: Any]], imageForObject: ([String: Any]) -> UIImage?) -> Bool {
        content.canReuse(snapshot: current, mapper: currentMapper, objects: objects, tokens: supplied,
            highlights: highlights, imageForObject: imageForObject)
    }

    /// Ink polygons are display-normalized, including their full width/caps.
    /// An affine transform maps a polygon's edges into the convex crop; testing
    /// every vertex therefore covers the whole polygon, not just its centerline.
    /// Inset by one captured pixel so antialias/filter coverage has a destination.
    func contains(normalizedPolygons: [[CGPoint]], antialiasPixels: CGFloat = 1) -> Bool {
        guard antialiasPixels.isFinite, antialiasPixels >= 0 else { return false }
        let inset = antialiasPixels / viewport.pixelScale
        let safe = viewport.canvasRect.insetBy(dx: inset, dy: inset)
        guard !safe.isNull, safe.width > 0, safe.height > 0 else { return false }
        for polygon in normalizedPolygons {
            for point in polygon {
                guard point.x.isFinite, point.y.isFinite else { return false }
                let canvas = mapper.canvasPoint(InkPoint(x: point.x, y: point.y, p: 0.5))
                guard canvas.x.isFinite, canvas.y.isFinite,
                      canvas.x >= safe.minX, canvas.x <= safe.maxX,
                      canvas.y >= safe.minY, canvas.y <= safe.maxY else { return false }
            }
        }
        return true
    }

    private static func identifier(_ object: [String: Any]) -> String? {
        object["clientMutationId"] as? String ?? object["id"] as? String
    }
    private static func visualTokens(objects: [[String: Any]], supplied: [NativePDFCommittedVisualToken]?) -> [NativePDFCommittedVisualToken] {
        if let supplied, supplied.count == objects.count { return supplied }
        return objects.map(NativePDFCommittedVisualToken.init)
    }
    private static func highlightsToken(_ highlights: [[String: Any]]) -> NativePDFCommittedVisualToken {
        let fields = highlights.map { row in
            row.filter { ["rects", "color", "nativeColor", "nativeOpacity"].contains($0.key) }
        }
        return NativePDFCommittedVisualToken(object: ["data": ["highlights": fields]])
    }
    private static func resolvedImage(_ object: [String: Any], imageForObject: ([String: Any]) -> UIImage?) -> UIImage? {
        ["image", "clip"].contains(object["kind"] as? String ?? "") ? imageForObject(object) : nil
    }
    private static func valid(_ mapper: InkCoordinateMapper) -> Bool {
        let t = mapper.canvasToPDF, g = mapper.geometry
        let determinant = t.a*t.d-t.b*t.c
        return [t.a,t.b,t.c,t.d,t.tx,t.ty,determinant].allSatisfy(\.isFinite)
            && [g.cropX,g.cropY,g.width,g.height].allSatisfy(\.isFinite)
            && determinant != 0 && g.width > 0 && g.height > 0
    }
    private static func valid(_ viewport: NativePDFRenderViewport) -> Bool {
        let r = viewport.canvasRect
        return [r.minX,r.minY,r.width,r.height,viewport.pixelScale,
                viewport.pixelSize.width,viewport.pixelSize.height].allSatisfy(\.isFinite)
            && r.width > 0 && r.height > 0 && viewport.pixelScale > 0
    }
}
