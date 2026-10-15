import UIKit
import PDFKit

/// Immutable vector display lists. Background work never touches PDFKit,
/// mutable drawing dictionaries, path caches, or a UIView.
final class NativePDFNavigationSnapshot: @unchecked Sendable {
    final class Paper {
        let document: CGPDFDocument
        let page: CGPDFPage
        let size: CGSize
        // Successive scene revisions share paper and recorded object pages.
        // Serialize their Core Graphics PDF interpreter access as well.
        let lock = NSLock()
        init?(data: Data, size: CGSize) {
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
            self.document = document; self.page = page; self.size = size
        }
    }
    struct Command {
        enum Content { case path(CGPath, CGColor, CGFloat, Bool); case pdf(Paper) }
        let bounds: CGRect
        let content: Content
        func draw(in context: CGContext) {
            guard bounds.intersects(context.boundingBoxOfClipPath) else { return }
            context.saveGState(); defer { context.restoreGState() }
            switch content {
            case let .path(path, color, opacity, multiply):
                if multiply { context.setBlendMode(.multiply) }
                context.setAlpha(opacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                context.setFillColor(color); context.addPath(path); context.fillPath()
                context.endTransparencyLayer()
            case let .pdf(recording):
                recording.lock.lock(); defer { recording.lock.unlock() }
                context.translateBy(x: 0, y: recording.size.height); context.scaleBy(x: 1, y: -1)
                context.drawPDFPage(recording.page)
            }
        }
    }
    struct Raster: @unchecked Sendable {
        let paper: CGImage
        let prefix: CGImage?
        let image: CGImage
        let scale: CGFloat
        let prefixCount: Int
    }
    let paper: Paper
    let highlights: [Command]
    let objects: [Command]
    let revision: UInt64
    var size: CGSize { paper.size }

    init(paper: Paper, highlights: [Command], objects: [Command], revision: UInt64) {
        self.paper = paper; self.highlights = highlights; self.objects = objects; self.revision = revision
    }
    private func drawPaper(in context: CGContext) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.saveGState()
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
        paper.lock.lock()
        context.drawPDFPage(paper.page)
        paper.lock.unlock()
        context.restoreGState()
    }
    func draw(in context: CGContext) {
        drawPaper(in: context)
        for command in highlights { command.draw(in: context) }
        for command in objects { command.draw(in: context) }
    }
    /// One background pass produces the settled crop and the same four-object
    /// checkpoint used by the live scene cache. No replay on the next contact.
    func raster(bounds: CGRect, scale: CGFloat, canonicalToCanvas: CGAffineTransform, stablePrefixCount requestedPrefixCount: Int? = nil) -> Raster? {
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, scale].allSatisfy(\.isFinite),
              bounds.width > 0, bounds.height > 0, scale > 0 else { return nil }
        let pixelWidth = ceil(bounds.width * scale), pixelHeight = ceil(bounds.height * scale)
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 4096, pixelHeight <= 4096 else { return nil }
        let width = Int(pixelWidth), height = Int(pixelHeight)
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 8_020_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        // The logical crop may end partway through its final pixel. Initialize
        // the complete bitmap so paper and multiply ink always have an opaque
        // destination, including those extra fractional-edge pixel samples.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY); context.concatenate(canonicalToCanvas)
        drawPaper(in: context)
        guard let paperImage = context.makeImage() else { return nil }
        for command in highlights { command.draw(in: context) }
        let prefixCount = requestedPrefixCount ?? max(0, objects.count - 4)
        guard (0...objects.count).contains(prefixCount) else { return nil }
        for command in objects.prefix(prefixCount) { command.draw(in: context) }
        let prefixImage = prefixCount > 0 ? context.makeImage() : nil
        for command in objects.dropFirst(prefixCount) { command.draw(in: context) }
        guard let image = context.makeImage() else { return nil }
        return Raster(paper: paperImage, prefix: prefixImage, image: image, scale: scale, prefixCount: prefixCount)
    }
}

@MainActor
final class NativePDFNavigationSnapshotBuilder {
    private var source: PDFPage?
    private var paper: NativePDFNavigationSnapshot.Paper?
    private struct PaperGeometry: Equatable {
        let crop: CGRect
        let media: CGRect
        let rotation: Int
        let displaysAnnotations: Bool
        init(_ page: PDFPage) {
            crop = page.bounds(for: .cropBox); media = page.bounds(for: .mediaBox)
            rotation = page.rotation; displaysAnnotations = page.displaysAnnotations
        }
    }
    private var paperGeometry: PaperGeometry?
    private struct Entry { let token: NativePDFCommittedVisualToken; let image: UIImage?; let command: NativePDFNavigationSnapshot.Command }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var lastSnapshot: NativePDFNavigationSnapshot?
    private var lastTokens: [NativePDFCommittedVisualToken]?
    private var lastImages: [UIImage?] = []
    private var lastHighlights: NativePDFCommittedVisualToken?
    private var revision: UInt64 = 0
    private(set) var preparedObjectCount = 0
    /// The owner invalidates when the recorded PDF contents change in place.
    /// Page identity, geometry and annotation visibility are checked below too.
    func invalidate() {
        source = nil; paper = nil; paperGeometry = nil; entries.removeAll()
        lastSnapshot = nil; lastTokens = nil; lastImages = []; lastHighlights = nil
    }

    func make(page: PDFPage, objects: [[String: Any]], tokens: [NativePDFCommittedVisualToken]?,
              highlights: [[String: Any]], image: ([String: Any]) -> UIImage?) -> NativePDFNavigationSnapshot? {
        let coordinates = NativePDFPageCoordinates(page: page)
        let size = CGSize(width: coordinates.width, height: coordinates.height)
        let mapper = InkCoordinateMapper.whiteboard(size: size)
        let pageBounds = CGRect(origin: .zero, size: size)
        let geometry = PaperGeometry(page)
        preparedObjectCount = 0
        if source !== page || paper == nil || paperGeometry != geometry {
            guard let transform = NativePDFBackdropRenderer.pdfToCanvas(page: page, mapper: mapper), let reference = page.pageRef else { return nil }
            let data = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { renderer in
                renderer.beginPage(); let context = renderer.cgContext
                context.concatenate(transform); context.clip(to: page.bounds(for: .cropBox))
                context.drawPDFPage(reference)
                if page.displaysAnnotations, !page.annotations.isEmpty,
                   let annotationSpace = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                       bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    page.transform(annotationSpace, for: .cropBox)
                    context.concatenate(annotationSpace.ctm.inverted())
                    for annotation in page.annotations where annotation.shouldDisplay {
                        context.saveGState(); annotation.draw(with: .cropBox, in: context); context.restoreGState()
                    }
                }
            }
            guard let captured = NativePDFNavigationSnapshot.Paper(data: data, size: size) else { return nil }
            source = page; paper = captured; paperGeometry = geometry; entries.removeAll()
        }
        guard let paper else { return nil }
        let validTokens = tokens?.count == objects.count ? tokens : nil
        let resolvedImages = objects.map { ["image", "clip"].contains($0["kind"] as? String ?? "") ? image($0) : nil }
        // Retain only the fields actually used to paint highlights. The token
        // freezes mutable JSON containers and preserves Boolean/number types.
        let highlightFields = highlights.map { value in
            value.filter { ["rects", "color", "nativeColor", "nativeOpacity"].contains($0.key) }
        }
        let highlightToken = NativePDFCommittedVisualToken(object: ["data": ["highlights": highlightFields]])
        if let previous = lastSnapshot, previous.paper === paper,
           let validTokens, let oldTokens = lastTokens, oldTokens.count == validTokens.count,
           zip(oldTokens, validTokens).allSatisfy({ $0.hasSameAppearance(as: $1) }),
           lastImages.count == resolvedImages.count, zip(lastImages, resolvedImages).allSatisfy({ $0 === $1 }),
           lastHighlights?.hasSameAppearance(as: highlightToken) == true {
            // ACK metadata may mint new row tokens with identical appearance.
            // Keep their commands reusable for the next actual appended stroke.
            var nextEntries: [ObjectIdentifier: Entry] = [:]
            for (old, new) in zip(oldTokens, validTokens) {
                if let entry = entries[ObjectIdentifier(old)] {
                    nextEntries[ObjectIdentifier(new)] = Entry(token: new, image: entry.image, command: entry.command)
                }
            }
            entries = nextEntries; lastTokens = validTokens; lastImages = resolvedImages; lastHighlights = highlightToken
            return previous
        }
        var nextEntries: [ObjectIdentifier: Entry] = [:]
        var commands: [NativePDFNavigationSnapshot.Command] = []
        for (index, object) in objects.enumerated() {
            let token = validTokens?[index]
            let resolvedImage = resolvedImages[index]
            if let token, let previous = entries[ObjectIdentifier(token)], previous.image === resolvedImage {
                commands.append(previous.command); nextEntries[ObjectIdentifier(token)] = previous; continue
            }
            let command: NativePDFNavigationSnapshot.Command
            let style = object["style"] as? [String: Any] ?? [:]
            // Only rows carrying an internal visual token may use their already
            // validated immutable path directly. Ordinary dictionaries validate.
            let aspect = size.height / size.width
            let candidate = token != nil ? object["_nativeInk"] as? NativePDFPreparedInk : nil
            let prepared = candidate?.aspect == aspect ? candidate : nil
            if let prepared = prepared ?? NativePDFObjectRenderer.prepareInk(object, aspect: aspect) {
                var transform = CGAffineTransform(scaleX: size.width, y: size.height)
                guard let path = prepared.path.copy(using: &transform) else { return nil }
                let opacity = (style["opacity"] as? NSNumber).flatMap { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite ? $0.doubleValue : nil } ?? 1
                command = .init(bounds: path.boundingBoxOfPath.insetBy(dx: -1, dy: -1), content: .path(path,
                    NativePDFObjectRenderer.color(style["color"] as? String ?? "ink").cgColor,
                    min(1, max(0, opacity)), object["kind"] as? String == "highlighter"))
            } else {
                let data = UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { renderer in
                    renderer.beginPage(); NativePDFObjectRenderer.draw(object, in: renderer.cgContext, mapper: mapper, image: resolvedImage)
                }
                guard let recording = NativePDFNavigationSnapshot.Paper(data: data, size: size) else { return nil }
                command = .init(bounds: NativePDFObjectRenderer.hitBounds(object, mapper: mapper)?.insetBy(dx: -2, dy: -2) ?? pageBounds, content: .pdf(recording))
            }
            preparedObjectCount += 1; commands.append(command)
            if let token { nextEntries[ObjectIdentifier(token)] = Entry(token: token, image: resolvedImage, command: command) }
        }
        entries = nextEntries
        let highlightCommands = highlights.flatMap { value -> [NativePDFNavigationSnapshot.Command] in
            let rgba = value["nativeColor"] as? [Double]
            let fallback: UIColor = value["color"] as? String == "pink" ? UIColor(red: 0.99, green: 0.70, blue: 0.84, alpha: 1) : NativePDFInkSurface.color(value["color"] as? String ?? "yellow")
            let color = rgba?.count == 4 && rgba!.allSatisfy({ $0.isFinite && (0...1).contains($0) })
                ? UIColor(red: rgba![0], green: rgba![1], blue: rgba![2], alpha: rgba![3]) : fallback
            let opacity = min(1, max(0, value["nativeOpacity"] as? Double ?? 0.42))
            return (value["rects"] as? [[String: Double]] ?? []).compactMap { box in
                guard let x = box["x"], let y = box["y"], let w = box["width"], let h = box["height"], [x,y,w,h].allSatisfy(\.isFinite) else { return nil }
                let rect = CGRect(x: x*size.width, y: y*size.height, width: w*size.width, height: h*size.height)
                return .init(bounds: rect, content: .path(CGPath(rect: rect, transform: nil), color.withAlphaComponent(opacity).cgColor, 1, true))
            }
        }
        revision &+= 1
        let snapshot = NativePDFNavigationSnapshot(paper: paper, highlights: highlightCommands, objects: commands, revision: revision)
        lastSnapshot = snapshot; lastTokens = validTokens; lastImages = resolvedImages; lastHighlights = highlightToken
        return snapshot
    }
}
