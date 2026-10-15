import UIKit

/// Draws the desktop drawing contract without converting objects to PDF
/// annotations. Geometry belongs to the canonical plane supplied by the host
/// (legacy desktop display coordinates). The mapper owns PDF CropBox/rotation
/// conversion; text and images follow its whole-object affine transform.
@MainActor
enum NativePDFObjectRenderer {
    private static let inkPaths = NativePDFInkPathCache()
    static func prepareInk(_ input: NativePDFStrokeInput, aspect: Double, reusing: NativePDFPreparedInk? = nil) -> NativePDFPreparedInk? { inkPaths.prepare(input, aspect: aspect, reusing: reusing) }
    static func prepareInk(_ object: [String: Any], aspect: Double, reusing: NativePDFPreparedInk? = nil) -> NativePDFPreparedInk? { inkPaths.prepare(object, aspect: aspect, reusing: reusing) }
    static func releaseInkPaths() { inkPaths.removeAll() }
    static func draw(_ object: [String: Any], in context: CGContext, mapper: InkCoordinateMapper, image: UIImage?, overrideBlend: Bool = false) {
        guard let data = object["data"] as? [String: Any], let style = object["style"] as? [String: Any],
              let transform = pageTransform(mapper) else { return }
        let width = mapper.geometry.width, height = mapper.geometry.height
        let ink = color(style["color"] as? String ?? "ink")
        let strokeWidth = max(0.0001, finite(style["width"], fallback: 0.003) * width)
        let opacity = min(1, max(0, finite(style["opacity"], fallback: 1)))
        context.saveGState(); defer { context.restoreGState() }
        context.concatenate(transform)
        // A retained transparent object texture carries multiply in its GPU
        // item. All existing callers retain the destination-aware CG behavior.
        if !overrideBlend, object["kind"] as? String == "highlighter" { context.setBlendMode(.multiply) }
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer() }
        context.setFillColor(ink.cgColor); context.setStrokeColor(ink.cgColor)
        context.setLineWidth(strokeWidth); context.setLineCap(.round); context.setLineJoin(.round)
        if let prepared = prepareInk(object, aspect: height / width) {
            context.scaleBy(x: width, y: height)
            context.addPath(prepared.path); context.fillPath(); return
        }
        if let encoded = object["nativePath"] as? String, let path = path(encoded, width: width, height: height) {
            context.addPath(path); context.fillPath(); return
        }
        let kind = object["kind"] as? String ?? ""
        if ["line", "arrow", "rect", "ellipse"].contains(kind) {
            let normalizedWidth = max(0, finite(style["width"], fallback: 0.003))
            guard let outline = shapeOutline(kind: kind, data: data, strokeWidth: normalizedWidth, aspect: height / width) else { return }
            // Desktop SVG uses viewBox="0 0 1 1", preserveAspectRatio="none"
            // and a normalized strokeWidth. Both the path AND its stroke must
            // stretch with the page; stroking in physical points makes a
            // portrait page's horizontal edges incorrectly thin.
            context.scaleBy(x: width, y: height)
            context.addPath(outline)
            context.fillPath(); return
        }
        guard let box = physicalBox(data, width: width, height: height), box.width > 0, box.height > 0 else { return }
        switch kind {
        case "image", "clip":
            UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
            if let image, image.size.width > 0, image.size.height > 0 {
                let ratio = image.size.height / image.size.width, boxRatio = box.height / box.width
                let imageRect: CGRect
                if abs(boxRatio - ratio) / ratio <= 0.01 { imageRect = box }
                else {
                    let scale = min(box.width / image.size.width, box.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    imageRect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
                }
                image.draw(in: imageRect)
            } else {
                context.saveGState(); defer { context.restoreGState() }
                context.setFillColor(UIColor(white: 0.96, alpha: 1).cgColor); context.fill(box)
                context.setStrokeColor(UIColor(white: 0.65, alpha: 1).cgColor); context.setLineWidth(0.6); context.setLineDash(phase: 0, lengths: [3, 3]); context.stroke(box)
                let source = data[kind] as? [String: Any]
                let label = source?["label"] as? String ?? (kind == "image" ? "이미지를 불러올 수 없습니다" : "원본 자료를 불러올 수 없습니다")
                (label as NSString).draw(with: box.insetBy(dx: 6, dy: 6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray], context: nil)
            }
        case "textbox":
            context.saveGState(); defer { context.restoreGState() }
            context.clip(to: box)
            if let fill = style["fill"] as? String { context.setFillColor(color(fill).withAlphaComponent(0.18).cgColor); context.fill(box) }
            let fontSize = baseFontSize(style, surfaceWidth: width)
            // The desktop transparent border occupies 0.06em before 0.3em
            // inner padding; preserve that offset even without a visible frame.
            let padding = fontSize * 0.36
            let content = box.insetBy(dx: padding, dy: padding)
            guard content.width > 0, content.height > 0 else { return }
            UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
            attributedText(data: data, style: style, surfaceWidth: width).draw(with: content, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        default: break
        }
    }

    static func hitBounds(_ object: [String: Any], mapper: InkCoordinateMapper) -> CGRect? {
        guard let data = object["data"] as? [String: Any], let transform = pageTransform(mapper) else { return nil }
        let width = mapper.geometry.width, height = mapper.geometry.height
        let style = object["style"] as? [String: Any] ?? [:]
        let margin = finite(style["width"], fallback: 0.003) * width / 2
        if let prepared = prepareInk(object, aspect: height / width) {
            return prepared.path.boundingBoxOfPath.applying(CGAffineTransform(scaleX: width, y: height)).applying(transform)
        }
        if let nativePath = object["nativePath"] as? String, let path = path(nativePath, width: width, height: height) {
            return path.boundingBoxOfPath.applying(transform)
        }
        let kind = object["kind"] as? String ?? ""
        if ["line", "arrow", "rect", "ellipse"].contains(kind) {
            let normalizedWidth = max(0, finite(style["width"], fallback: 0.003))
            guard let outline = shapeOutline(kind: kind, data: data, strokeWidth: normalizedWidth, aspect: height / width) else { return nil }
            return outline.boundingBoxOfPath.applying(CGAffineTransform(scaleX: width, y: height)).applying(transform)
        }
        return physicalBox(data, width: width, height: height)?.insetBy(dx: -margin, dy: -margin).applying(transform)
    }

    private static func shapeOutline(kind: String, data: [String: Any], strokeWidth: Double, aspect: Double) -> CGPath? {
        guard strokeWidth.isFinite, strokeWidth > 0,
              let path = shapePath(kind: kind, data: data, strokeWidth: strokeWidth, aspect: aspect) else { return nil }
        // CGPath's stroker uses absolute flatness. At normalized widths such as
        // 0.003 it silently drops round caps and curve detail. Form the outline
        // in a well-conditioned plane before returning to the SVG coordinates.
        let factor = min(1_000_000, max(1024, 32 / strokeWidth))
        var up = CGAffineTransform(scaleX: factor, y: factor), down = up.inverted()
        guard let enlarged = path.copy(using: &up) else { return nil }
        return enlarged.copy(strokingWithWidth: strokeWidth * factor,
            lineCap: kind == "line" || kind == "arrow" ? .round : .butt,
            lineJoin: kind == "rect" ? .miter : .round, miterLimit: 4).copy(using: &down)
    }

    private static func shapePath(kind: String, data: [String: Any], strokeWidth: Double, aspect: Double) -> CGPath? {
        let shape = CGMutablePath()
        if kind == "rect" || kind == "ellipse" {
            guard let box = physicalBox(data, width: 1, height: 1), box.width > 0, box.height > 0 else { return nil }
            if kind == "rect" { shape.addRect(box) } else { shape.addEllipse(in: box) }
        } else {
            guard let endpoints = endpoints(data, width: 1, height: 1), aspect.isFinite, aspect > 0,
                  hypot(endpoints.1.x - endpoints.0.x, (endpoints.1.y - endpoints.0.y) * aspect) > 0 else { return nil }
            shape.move(to: endpoints.0); shape.addLine(to: endpoints.1)
            if kind == "arrow" {
                // Match inkGeometry.arrowHeadPoints: head geometry is physical
                // (equal angles on screen), while its SVG stroke is normalized.
                let angle = atan2((endpoints.1.y - endpoints.0.y) * aspect, endpoints.1.x - endpoints.0.x)
                let size = max(strokeWidth * 4, 0.012)
                func wing(_ offset: Double) -> CGPoint {
                    CGPoint(x: endpoints.1.x - cos(angle + offset) * size, y: endpoints.1.y - sin(angle + offset) * size / aspect)
                }
                shape.move(to: wing(-.pi / 6)); shape.addLine(to: endpoints.1); shape.addLine(to: wing(.pi / 6))
            }
        }
        return shape
    }

    static func pageTransform(_ mapper: InkCoordinateMapper) -> CGAffineTransform? {
        let width = mapper.geometry.width, height = mapper.geometry.height
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let p0 = mapper.canvasPoint(InkPoint(x: 0, y: 0, p: 0.5)), px = mapper.canvasPoint(InkPoint(x: 1, y: 0, p: 0.5)), py = mapper.canvasPoint(InkPoint(x: 0, y: 1, p: 0.5))
        let transform = CGAffineTransform(a: (px.x - p0.x) / width, b: (px.y - p0.y) / width, c: (py.x - p0.x) / height, d: (py.y - p0.y) / height, tx: p0.x, ty: p0.y)
        return [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].allSatisfy(\.isFinite) ? transform : nil
    }

    static func attributedText(data: [String: Any], style: [String: Any], surfaceWidth: Double) -> NSAttributedString {
        let text = data["text"] as? String ?? "", length = (text as NSString).length
        let baseSize = baseFontSize(style, surfaceWidth: surfaceWidth)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style["align"] as? String == "center" ? .center : style["align"] as? String == "right" ? .right : .left
        paragraph.lineBreakMode = .byWordWrapping
        let baseFont = UIFont.systemFont(ofSize: baseSize)
        paragraph.lineHeightMultiple = 1.35 * baseSize / baseFont.lineHeight
        var attributes = textAttributes(style, fontSize: baseSize)
        attributes[.paragraphStyle] = paragraph
        let output = NSMutableAttributedString(string: text, attributes: attributes)
        // JavaScript ranges are UTF-16, exactly NSString/NSRange coordinates.
        // Match normalizeTextRuns: sort, clamp, trim overlaps, first run wins.
        let runs = (data["textRuns"] as? [[String: Any]] ?? []).compactMap { run -> (Int, Int, [String: Any])? in
            guard let from = run["from"] as? Int, let to = run["to"] as? Int, from >= 0, from < length, to > from, let overrides = run["style"] as? [String: Any], !overrides.isEmpty else { return nil }
            return (from, min(to, length), overrides)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var last = 0
        for (start, end, overrides) in runs {
            let from = max(last, start); guard end > from else { continue }
            let merged = style.merging(overrides) { _, right in right }
            let size = overrides["fontSizePt"] != nil ? baseFontSize(merged, surfaceWidth: surfaceWidth) : baseSize
            output.addAttributes(textAttributes(merged, fontSize: size), range: NSRange(location: from, length: end - from)); last = end
        }
        return output
    }
    private static func textAttributes(_ style: [String: Any], fontSize: Double) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: fontSize, weight: style["bold"] as? Bool == true ? .bold : .regular),
         .foregroundColor: color(style["color"] as? String ?? "ink"),
         .obliqueness: style["italic"] as? Bool == true ? tan(12 * Double.pi / 180) : 0,
         .underlineStyle: style["underline"] as? Bool == true ? NSUnderlineStyle.single.rawValue : 0,
         .strikethroughStyle: style["strike"] as? Bool == true ? NSUnderlineStyle.single.rawValue : 0]
    }
    private static func baseFontSize(_ style: [String: Any], surfaceWidth: Double) -> Double {
        let point = finite(style["fontSizePt"], fallback: 0)
        return point > 0 ? point : max(0.01, surfaceWidth * 0.026 * max(0.01, finite(style["fontScale"], fallback: 1)))
    }
    private static func finite(_ value: Any?, fallback: Double) -> Double {
        // Native tool dictionaries may contain Int while JSON supplies NSNumber.
        // Accept both numeric representations, but never treat true/false as 1/0.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return fallback }
        return number.doubleValue
    }
    private static func physicalBox(_ data: [String: Any], width: Double, height: Double) -> CGRect? {
        guard let box = data["box"] as? [String: Double], let x = box["x"], let y = box["y"], let w = box["width"], let h = box["height"], [x,y,w,h].allSatisfy(\.isFinite), w >= 0, h >= 0 else { return nil }
        return CGRect(x: x * width, y: y * height, width: w * width, height: h * height)
    }
    private static func endpoints(_ data: [String: Any], width: Double, height: Double) -> (CGPoint, CGPoint)? {
        if let points = data["points"] as? [[String: Double]], points.count >= 2,
           let first = points.first, let last = points.last, let x0 = first["x"], let y0 = first["y"], let x1 = last["x"], let y1 = last["y"], [x0,y0,x1,y1].allSatisfy(\.isFinite) {
            return (CGPoint(x: x0 * width, y: y0 * height), CGPoint(x: x1 * width, y: y1 * height))
        }
        return physicalBox(data, width: width, height: height).map { (CGPoint(x: $0.minX, y: $0.minY), CGPoint(x: $0.maxX, y: $0.maxY)) }
    }
    static func color(_ name: String) -> UIColor {
        let rgb: (CGFloat, CGFloat, CGFloat)
        switch name {
        case "red": rgb = (214,36,46)
        case "orange": rgb = (240,99,20)
        case "yellow": rgb = (245,184,10)
        case "green": rgb = (26,148,77)
        case "blue": rgb = (20,97,224)
        case "violet": rgb = (125,54,209)
        default: rgb = (20,23,31)
        }
        return UIColor(red: rgb.0/255, green: rgb.1/255, blue: rgb.2/255, alpha: 1)
    }
    static func path(_ source: String, width: Double, height: Double) -> CGPath? {
        guard source.count <= 8_000_000 else { return nil }
        let pattern = #"[MLQZ]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let string = source as NSString, range = NSRange(location: 0, length: string.length)
        let matches = regex.matches(in: source, range: range)
        // Reject rather than silently ignoring unsupported commands/garbage.
        let remainder = regex.stringByReplacingMatches(in: source, range: range, withTemplate: "")
        guard remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tokens = matches.map { string.substring(with: $0.range) }
        var offset = 0; let path = CGMutablePath()
        func point() -> CGPoint? {
            guard offset + 1 < tokens.count, let x = Double(tokens[offset]), let y = Double(tokens[offset+1]), x.isFinite, y.isFinite else { return nil }
            offset += 2; return CGPoint(x: x * width, y: y * height)
        }
        while offset < tokens.count {
            let command = tokens[offset]; offset += 1
            switch command {
            case "M": guard let p = point() else { return nil }; path.move(to: p)
            case "L": guard let p = point() else { return nil }; path.addLine(to: p)
            case "Q": guard let control = point(), let end = point() else { return nil }; path.addQuadCurve(to: end, control: control)
            case "Z": path.closeSubpath()
            default: return nil
            }
        }
        return path.isEmpty ? nil : path
    }
}
