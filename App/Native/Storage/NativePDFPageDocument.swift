import Foundation
import CryptoKit
import PDFKit
import CoreGraphics

/// Page edits retain PDFKit's original document/catalog. Rebuilding a new PDF
/// from copied pages would discard forms, outlines, and other document data.
enum NativePDFPageDocument {
    private typealias C = NativeRepositoryContext
    private typealias F = NativeSyncFormat
    static func open(_ bytes: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: bytes), !document.isLocked, !document.isEncrypted,
              document.pageCount > 0, document.pageCount <= 20_000 else { throw C.validation("암호화되었거나 손상된 PDF의 페이지는 변경할 수 없습니다.") }
        if let catalog = document.documentRef?.catalog {
            func has(_ dictionary: CGPDFDictionaryRef, _ name: String) -> Bool { var object: CGPDFObjectRef?; return CGPDFDictionaryGetObject(dictionary, name, &object) }
            var form: CGPDFDictionaryRef?, names: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form {
                var signatureFlags: CGPDFInteger = 0
                if has(form, "XFA") || CGPDFDictionaryGetInteger(form, "SigFlags", &signatureFlags) && signatureFlags != 0 { throw C.validation("동적 양식 또는 서명 정보가 있는 PDF는 원본 보존을 위해 페이지 편집을 지원하지 않습니다.") }
            }
            if has(catalog, "Collection") || (CGPDFDictionaryGetDictionary(catalog, "Names", &names) && names.map { has($0, "EmbeddedFiles") || has($0, "JavaScript") } == true) { throw C.validation("첨부 파일 또는 문서 스크립트가 있는 PDF는 원본 보존을 위해 페이지 편집을 지원하지 않습니다.") }
        }
        // A page rewrite invalidates signatures. Keep the signed source intact.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { throw C.validation("PDF 페이지를 읽지 못했습니다.") }
            for annotation in page.annotations {
                if annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "FT")) as? String == "Sig" { throw C.validation("서명된 PDF의 페이지는 변경할 수 없습니다.") }
            }
        }
        return document
    }
    static func recipe(_ value: Any?, count: Int) throws -> [Int] {
        guard let raw = value as? [Any], !raw.isEmpty, raw.count <= count + 200 else { throw C.validation("하나 이상의 기존 페이지를 남겨 주세요.") }
        // 0 (desktop: `source: null`) inserts a new page: a copy of the preceding
        // entry's page template without any drawings.
        let pages = try raw.map { value -> Int in
            let object = value as? [String: Any]
            if let rotate = object?["rotate"] { guard let n = rotate as? NSNumber, n.intValue == 0, n.doubleValue == 0 else { throw C.validation("현재 페이지 편집은 재배열과 삭제를 지원합니다.") } }
            let source = object?["source"] ?? value
            if source is NSNull { return 0 }
            guard let n = source as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue), (0...count).contains(n.intValue) else { throw C.validation("PDF 페이지 번호가 올바르지 않습니다.") }
            return n.intValue
        }
        let kept = pages.filter { $0 != 0 }
        guard !kept.isEmpty, kept.count <= count else { throw C.validation("하나 이상의 기존 페이지를 남겨 주세요.") }
        guard Set(kept).count == kept.count else { throw C.validation("같은 페이지를 두 번 넣을 수 없습니다.") }
        return pages
    }
    static func map(_ pages: [Int], count: Int) -> [[Int]] { (1...count).map { old in pages.firstIndex(of: old).map { [$0 + 1] } ?? [] } }
    /// The page whose template a `0` entry copies: the nearest earlier source, else the first one.
    static func template(_ pages: [Int], at index: Int) -> Int {
        pages[...index].last { $0 != 0 } ?? pages.first { $0 != 0 } ?? 1
    }
    static func rewrite(_ bytes: Data, pages recipe: [Int]) throws -> Data {
        let pages = recipe.filter { $0 != 0 }
        let document = try open(bytes), keep = Set(pages)
        let originalPages = (0..<document.pageCount).map { document.page(at: $0)! }
        // PDFKit otherwise silently retargets destinations to a removed page.
        func prune(_ parent: PDFOutline) {
            for index in (0..<parent.numberOfChildren).reversed() {
                guard let child = parent.child(at: index) else { continue }; prune(child)
                if let page = child.destination?.page, !keep.contains(document.index(for: page) + 1) {
                    if child.numberOfChildren == 0 { child.removeFromParent() } else { child.destination = nil; child.action = nil }
                }
            }
        }
        if let outline = document.outlineRoot { prune(outline) }
        for source in pages {
            for annotation in originalPages[source - 1].annotations {
                if let action = annotation.action as? PDFActionGoTo, let page = action.destination.page, !keep.contains(document.index(for: page) + 1) { originalPages[source - 1].removeAnnotation(annotation) }
            }
        }
        for (destination, source) in pages.enumerated() {
            let index = document.index(for: originalPages[source - 1])
            if destination != index { document.exchangePage(at: destination, withPageAt: index) }
        }
        while document.pageCount > pages.count { document.removePage(at: document.pageCount - 1) }
        for (index, entry) in recipe.enumerated() where entry == 0 {
            guard let copy = originalPages[template(recipe, at: index) - 1].copy() as? PDFPage else { throw C.validation("새 페이지를 만들지 못했습니다.") }
            for annotation in copy.annotations { copy.removeAnnotation(annotation) }
            document.insert(copy, at: index)
        }
        guard let output = document.dataRepresentation(), !output.isEmpty else { throw C.validation("변경한 PDF를 저장하지 못했습니다.") }
        try validate(source: bytes, target: output, pages: recipe)
        return output
    }
    /// Verify actual target pages rather than trusting a remotely supplied
    /// revision/recipe. Form values, geometry, searchable text, and pixels must
    /// match; this also rejects accidental flattening or rotated ink surfaces.
    static func validate(source: Data, target: Data, pages recipe: [Int]) throws {
        let before = try open(source), after = try open(target), pages = recipe.filter { $0 != 0 }
        guard after.pageCount == recipe.count, Set(pages).count == pages.count, pages.allSatisfy({ (1...before.pageCount).contains($0) }) else { throw C.conflict("PDF 페이지 변경 이력이 원본과 다릅니다.") }
        for (index, old) in recipe.enumerated() {
            guard let b = after.page(at: index) else { throw C.conflict("PDF 페이지 변경 이력이 원본과 다릅니다.") }
            if old == 0 {
                // A new page is a template copy: same geometry and pixels as its source, no annotations.
                guard let a = before.page(at: template(recipe, at: index) - 1), try matches(fingerprint(a, annotations: false), fingerprint(b)), b.annotations.isEmpty else { throw C.conflict("새 페이지를 원본 양식대로 만들지 못했습니다. 원본은 변경하지 않았습니다.") }
                continue
            }
            // Destinations map through the full recipe: inserted pages shift later numbers.
            guard let a = before.page(at: old - 1), try matches(fingerprint(a), fingerprint(b)), try links(before, page: a, pages: recipe) == links(after, page: b, pages: Array(1...after.pageCount)) else { throw C.conflict("PDF 내용·양식 또는 페이지 크기를 그대로 보존하지 못했습니다. 원본은 변경하지 않았습니다.") }
        }
        guard try outlines(before, pages: recipe) == outlines(after, pages: Array(1...after.pageCount)) else { throw C.conflict("PDF 책갈피의 대상을 그대로 보존하지 못했습니다. 원본은 변경하지 않았습니다.") }
        for key in [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute] {
            if let expected = before.documentAttributes?[key] as? NSObject, (after.documentAttributes?[key] as? NSObject).map({ expected.isEqual($0) }) != true { throw C.conflict("PDF 문서 정보를 그대로 보존하지 못했습니다.") }
        }
    }
    struct Fingerprint { let meta: String; let pixels: [UInt8] }
    static func signature(_ page: PDFPage, annotations includeAnnotations: Bool = true) throws -> String {
        let value = try fingerprint(page, annotations: includeAnnotations)
        return try F.digest(["meta": value.meta, "pixels": F.hash(Data(value.pixels))])
    }
    /// PDFKit re-serialises content streams on every save, which moves thin
    /// paper lines by a hair of anti-aliasing (a few bytes, ±2/255). Tolerate
    /// that; real content, rotation or flattening changes far more.
    static func matches(_ a: Fingerprint, _ b: Fingerprint) -> Bool {
        guard a.meta == b.meta, a.pixels.count == b.pixels.count else { return false }
        var differing = 0
        for (x, y) in zip(a.pixels, b.pixels) where x != y {
            if abs(Int(x) - Int(y)) > 8 { return false }
            differing += 1
        }
        return differing * 500 <= a.pixels.count
    }
    static func fingerprint(_ page: PDFPage, annotations includeAnnotations: Bool = true) throws -> Fingerprint {
        func rect(_ box: CGRect) -> [Double] { [box.origin.x, box.origin.y, box.width, box.height].map(Double.init) }
        let crop = page.bounds(for: .cropBox)
        guard crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else { throw C.validation("Invalid PDF page geometry") }
        let scale = min(1.5, 1800 / max(crop.width, crop.height)), width = max(1, Int(ceil(crop.width * scale))), height = max(1, Int(ceil(crop.height * scale)))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw C.validation("PDF 페이지 검증 이미지를 만들지 못했습니다.") }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height)); bitmap.scaleBy(x: scale, y: scale); bitmap.translateBy(x: -crop.minX, y: -crop.minY)
        // The CG page excludes link hit areas, which are intentionally detached
        // when their destination is removed. Fields are compared separately.
        if let reference = page.pageRef { bitmap.drawPDFPage(reference) }
        let annotations: [[String: Any]] = (includeAnnotations ? page.annotations : []).filter { $0.type != "Link" }.map { annotation in
            ["type": annotation.type ?? "", "bounds": rect(annotation.bounds), "contents": annotation.contents ?? "", "field": annotation.fieldName ?? "", "value": annotation.widgetStringValue ?? "", "state": annotation.buttonWidgetState.rawValue]
        }
        return Fingerprint(meta: try F.digest(["media": rect(page.bounds(for: .mediaBox)), "crop": rect(crop), "rotation": page.rotation, "text": page.string ?? "", "annotations": annotations]), pixels: pixels)
    }
    private static func outlines(_ document: PDFDocument, pages: [Int]) throws -> String {
        func children(_ parent: PDFOutline) -> [[String: Any]] {
            (0..<parent.numberOfChildren).compactMap { index in
                guard let item = parent.child(at: index) else { return nil }; let nested = children(item)
                var value: [String: Any] = ["label": item.label ?? "", "children": nested]
                if let target = item.destination?.page {
                    guard let targetIndex = pages.firstIndex(of: document.index(for: target) + 1) else { return nested.isEmpty ? nil : value }
                    value["page"] = targetIndex + 1
                    if let point = item.destination?.point { value["point"] = [Double(point.x), Double(point.y)] }
                } else if let action = item.action as? PDFActionURL { value["url"] = action.url?.absoluteString ?? "" }
                return value
            }
        }
        return try F.canonical(document.outlineRoot.map(children) ?? [])
    }
    private static func links(_ document: PDFDocument, page: PDFPage, pages: [Int]) throws -> String {
        let values: [[String: Any]] = page.annotations.filter { $0.type == "Link" }.compactMap { annotation in
            var value: [String: Any] = ["bounds": [Double(annotation.bounds.minX), Double(annotation.bounds.minY), Double(annotation.bounds.width), Double(annotation.bounds.height)]]
            if let action = annotation.action as? PDFActionGoTo, let destination = action.destination.page {
                guard let index = pages.firstIndex(of: document.index(for: destination) + 1) else { return nil }
                value["page"] = index + 1; value["point"] = [Double(action.destination.point.x), Double(action.destination.point.y)]
            } else if let action = annotation.action as? PDFActionURL { value["url"] = action.url?.absoluteString ?? "" }
            else { value["type"] = annotation.action?.type ?? "" }
            return value
        }
        return try F.canonical(values)
    }
    static func fingerprint(_ data: Data) -> String {
        if let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider), let ids = document.fileIdentifier {
            var value: CGPDFStringRef?
            if CGPDFArrayGetString(ids, 0, &value), let value, CGPDFStringGetLength(value) == 16, let bytes = CGPDFStringGetBytePtr(value), (0..<16).contains(where: { bytes[$0] != 0 }) { return (0..<16).map { String(format: "%02x", bytes[$0]) }.joined() }
        }
        // This is PDF.js's persisted document fingerprint contract, not a
        // security digest. SHA-256 remains the binding/recovery identity.
        return Insecure.MD5.hash(data: data.prefix(1024)).map { String(format: "%02x", $0) }.joined()
    }
    static func sizes(_ document: PDFDocument) -> [[String: Double]] {
        (0..<document.pageCount).map { index in let page = document.page(at: index)!, box = page.bounds(for: .cropBox), rotated = ((page.rotation % 180) + 180) % 180 != 0; return ["width": Double(rotated ? box.height : box.width), "height": Double(rotated ? box.width : box.height)] }
    }
}
