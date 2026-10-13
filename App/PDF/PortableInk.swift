import Foundation
import CoreGraphics
import UIKit
import PencilKit

/// The wire geometry deliberately matches desktop drawing.ts: normalized,
/// unrotated CropBox coordinates, with the origin at the top left.
struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var p: Double
}

struct InkBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct InkStyle: Codable, Equatable {
    var color: String
    var width: Double
    var opacity: Double
    var fontScale: Double?
    var fontSizePt: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var align: String?
    var fill: String?
}

struct InkGeometry: Codable, Equatable {
    var points: [InkPoint]?
    var box: InkBox?
    var text: String?
    var textRuns: [InkTextRun]?
    var clip: InkClipSource?
    var image: InkImageSource?
}

struct InkInlineStyle: Codable, Equatable {
    var color: String?
    var fontSizePt: Double?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
}
struct InkTextRun: Codable, Equatable { var from: Int; var to: Int; var style: InkInlineStyle }
struct InkClipSource: Codable, Equatable {
    var relPath: String; var page: Int; var crop: InkBox?; var pageAspect: Double?; var label: String
}
struct InkImageSource: Codable, Equatable {
    var relPath: String; var label: String; var assetId: String?; var storage: String?; var widthPx: Double?; var heightPx: Double?
}

struct PortableInkObject: Codable, Identifiable, Equatable {
    var id: String
    var kind: String
    var data: InkGeometry
    var style: InkStyle
    var createdAt: String
    var updatedAt: String
    /// A local mapping hint, never used as the cross-device object identity.
    var nativeKey: String?
}

struct PortableTextHighlight: Codable, Identifiable, Equatable {
    var id: String
    var quote: String
    var rects: [InkBox]
    var color: String
    var createdAt: String
    var prefix: String?
    var suffix: String?
    var comment: String?
    var updatedAt: String?
}

struct InkPageGeometry: Codable, Equatable {
    var cropX: Double
    var cropY: Double
    var width: Double
    var height: Double
    var rotation: Int

    init(cropBox: CGRect, rotation: Int) {
        cropX = cropBox.minX; cropY = cropBox.minY
        width = cropBox.width; height = cropBox.height
        self.rotation = ((rotation % 360) + 360) % 360
    }

    var cropBox: CGRect { CGRect(x: cropX, y: cropY, width: width, height: height) }

    func normalize(_ point: CGPoint, pressure: Double = 0.5) -> InkPoint {
        InkPoint(x: (point.x - cropX) / max(width, 1),
                 y: (cropY + height - point.y) / max(height, 1), p: pressure)
    }

    func pdfPoint(_ point: InkPoint) -> CGPoint {
        CGPoint(x: cropX + point.x * width, y: cropY + height - point.y * height)
    }

    func normalize(_ rect: CGRect) -> InkBox {
        InkBox(x: (rect.minX - cropX) / max(width, 1),
               y: (cropY + height - rect.maxY) / max(height, 1),
               width: rect.width / max(width, 1), height: rect.height / max(height, 1))
    }

    func pdfRect(_ box: InkBox) -> CGRect {
        CGRect(x: cropX + box.x * width, y: cropY + height - (box.y + box.height) * height,
               width: box.width * width, height: box.height * height)
    }
}

struct NativeInkCache: Codable {
    var drawing: Data
    var canvasWidth: Double
    var canvasHeight: Double
    /// SHA-256 of the portable objects prevents an old cache masking synced edits.
    var portableDigest: String
}

struct PortableInkPageRecord: Codable {
    var schemaVersion = 1
    var materialID: String
    var documentRevision: String
    var page: Int
    var coordinateSpace = "unrotated-crop-box-top-left-normalized"
    var geometry: InkPageGeometry
    var objects: [PortableInkObject] = []
    var highlights: [PortableTextHighlight] = []
    var deletedObjectIDs: [String] = []
    var deletedHighlightIDs: [String] = []
    var nativeCache: NativeInkCache?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, materialID, documentRevision, page, coordinateSpace, geometry
        case objects, highlights, deletedObjectIDs, deletedHighlightIDs, nativeCache
    }

    static func empty(materialID: String, revision: String, page: Int, geometry: InkPageGeometry) -> Self {
        Self(materialID: materialID, documentRevision: revision, page: page, geometry: geometry)
    }

    func validate(materialID: String, revision: String, page: Int, geometry: InkPageGeometry) throws {
        guard schemaVersion == 1,
              coordinateSpace == "unrotated-crop-box-top-left-normalized" else { throw InkRecordError.unsupportedVersion }
        guard self.materialID == materialID, self.page == page else { throw InkRecordError.wrongDocument }
        guard documentRevision == revision, self.geometry == geometry else { throw InkRecordError.changedDocument }
        guard objects.allSatisfy({ object in
            object.style.width.isFinite && object.style.width >= 0 && object.style.opacity.isFinite &&
            (object.data.points ?? []).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.p.isFinite }
        }) else { throw InkRecordError.invalidGeometry }
    }
}

extension PortableInkPageRecord {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        materialID = try values.decode(String.self, forKey: .materialID)
        documentRevision = try values.decode(String.self, forKey: .documentRevision)
        page = try values.decode(Int.self, forKey: .page)
        coordinateSpace = try values.decode(String.self, forKey: .coordinateSpace)
        geometry = try values.decode(InkPageGeometry.self, forKey: .geometry)
        objects = try values.decodeIfPresent([PortableInkObject].self, forKey: .objects) ?? []
        highlights = try values.decodeIfPresent([PortableTextHighlight].self, forKey: .highlights) ?? []
        deletedObjectIDs = try values.decodeIfPresent([String].self, forKey: .deletedObjectIDs) ?? []
        deletedHighlightIDs = try values.decodeIfPresent([String].self, forKey: .deletedHighlightIDs) ?? []
        nativeCache = try values.decodeIfPresent(NativeInkCache.self, forKey: .nativeCache)
    }
}

enum PortableInkPersistence {
    /// The JSON is base64-encoded once more in the generic storage envelope.
    /// Leave ample room below that store's 4 MiB record limit.
    static let nativeCacheBudget = 2_500_000
    static let portableSyncBudget = 3_000_000

    static func encode(_ record: PortableInkPageRecord) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let complete = try encoder.encode(record)
        guard complete.count > nativeCacheBudget, record.nativeCache != nil else { return complete }
        var portable = record
        portable.nativeCache = nil
        // Never simplify or discard user strokes to meet a transfer limit. The
        // caller's local recovery journal retains oversized portable records.
        return try encoder.encode(portable)
    }
}

/// Reconciles an incoming sync snapshot with edits completed while it was in
/// flight. A three-way comparison distinguishes unchanged objects from edits;
/// simultaneous edits/deletes retain explicit new-ID copies of visible content.
enum PortableInkThreeWayMerge {
    struct Result { var record: PortableInkPageRecord; var preservedConflicts: Bool }
    static func merge(base: PortableInkPageRecord, local: PortableInkPageRecord,
                      remote: PortableInkPageRecord) throws -> Result {
        try remote.validate(materialID: local.materialID, revision: local.documentRevision,
                            page: local.page, geometry: local.geometry)
        var merged = local
        let objects = mergeObjects(base: base.objects, local: local.objects, remote: remote.objects,
            localDeleted: local.deletedObjectIDs + base.deletedObjectIDs,
            remoteDeleted: remote.deletedObjectIDs + base.deletedObjectIDs,
            equivalent: { $0.kind == $1.kind && $0.data == $1.data && $0.style == $1.style },
            copy: { original in var copy = original; copy.id = UUID().uuidString; copy.nativeKey = nil; return copy })
        let highlights = mergeObjects(base: base.highlights, local: local.highlights, remote: remote.highlights,
            localDeleted: local.deletedHighlightIDs + base.deletedHighlightIDs,
            remoteDeleted: remote.deletedHighlightIDs + base.deletedHighlightIDs,
            equivalent: { a, b in a.quote == b.quote && a.rects == b.rects && a.color == b.color &&
                a.prefix == b.prefix && a.suffix == b.suffix && a.comment == b.comment },
            copy: { original in var copy = original; copy.id = UUID().uuidString; return copy })
        merged.objects = objects.values.sorted { ($0.createdAt + $0.id) < ($1.createdAt + $1.id) }
        merged.highlights = highlights.values.sorted { ($0.createdAt + $0.id) < ($1.createdAt + $1.id) }
        merged.deletedObjectIDs = objects.deleted; merged.deletedHighlightIDs = highlights.deleted
        merged.nativeCache = nil
        return Result(record: merged, preservedConflicts: objects.conflicts || highlights.conflicts)
    }

    private static func mergeObjects<T: Identifiable>(base: [T], local: [T], remote: [T],
        localDeleted: [String], remoteDeleted: [String], equivalent: (T, T) -> Bool,
        copy: (T) -> T) -> (values: [T], deleted: [String], conflicts: Bool) where T.ID == String {
        let baseline = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let left = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let right = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let leftDeleted = Set(localDeleted), rightDeleted = Set(remoteDeleted)
        var deleted = leftDeleted.union(rightDeleted)
        let ids = Set(baseline.keys).union(left.keys).union(right.keys).union(deleted)
        var values: [T] = []
        var conflicts = false
        func same(_ a: T?, _ b: T?) -> Bool {
            switch (a, b) { case (nil, nil): true; case let (a?, b?): equivalent(a, b); default: false }
        }
        for id in ids.sorted() {
            let original = baseline[id]
            let local = leftDeleted.contains(id) ? nil : left[id]
            let remote = rightDeleted.contains(id) ? nil : right[id]
            let candidates: [T]
            if same(local, original) { candidates = remote.map { [$0] } ?? [] }
            else if same(remote, original) || same(local, remote) { candidates = local.map { [$0] } ?? [] }
            else {
                conflicts = true
                if local == nil || remote == nil { deleted.insert(id) }
                candidates = [local, remote].compactMap { $0 }
            }
            if candidates.isEmpty {
                if original != nil || deleted.contains(id) { deleted.insert(id) }
            } else {
                for (index, candidate) in candidates.enumerated() {
                    if deleted.contains(id) || index > 0 { values.append(copy(candidate)) }
                    else { values.append(candidate) }
                }
            }
        }
        return (values, deleted.sorted(), conflicts)
    }
}

enum InkRecordError: LocalizedError {
    case unsupportedVersion, wrongDocument, changedDocument, invalidGeometry
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "더 새로운 필기 형식입니다. 앱을 업데이트해 주세요. 기존 필기는 보존됩니다."
        case .wrongDocument: "이 자료와 일치하지 않는 필기입니다. 기존 필기는 보존됩니다."
        case .changedDocument: "원본 PDF가 변경되어 이전 필기를 적용하지 않았습니다. 기존 필기는 보존됩니다."
        case .invalidGeometry: "필기 좌표가 올바르지 않아 편집을 중지했습니다. 기존 필기는 보존됩니다."
        }
    }
}

enum InkPalette: String, CaseIterable, Identifiable {
    case ink, red, orange, yellow, green, blue, violet
    var id: String { rawValue }
    var label: String {
        switch self { case .ink: "검정"; case .red: "빨강"; case .orange: "주황"; case .yellow: "노랑"
        case .green: "초록"; case .blue: "파랑"; case .violet: "보라" }
    }
    var uiColor: UIColor {
        switch self { case .ink: UIColor(white: 0.12, alpha: 1); case .red: .systemRed
        case .orange: .systemOrange; case .yellow: .systemYellow; case .green: .systemGreen
        case .blue: .systemBlue; case .violet: .systemPurple }
    }
    static func nearest(_ color: UIColor) -> Self {
        func rgb(_ c: UIColor) -> [CGFloat] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [r, g, b]
        }
        let components = rgb(color)
        return allCases.min { a, b in
            zip(components, rgb(a.uiColor)).reduce(0) { $0 + pow($1.0 - $1.1, 2) } <
            zip(components, rgb(b.uiColor)).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
        } ?? .ink
    }
}

/// An affine map captured while the overlay is attached. It remains valid when
/// PDFKit removes an offscreen overlay, so the final save never needs a detached view conversion.
struct InkCoordinateMapper {
    var canvasToPDF: CGAffineTransform
    var geometry: InkPageGeometry
    var pdfToCanvas: CGAffineTransform { canvasToPDF.inverted() }
    var canvasUnitsPerPDFPoint: CGFloat {
        let transform = pdfToCanvas
        return max(hypot(transform.a, transform.b), 0.0001)
    }
    func normalized(_ point: CGPoint, pressure: Double) -> InkPoint {
        geometry.normalize(point.applying(canvasToPDF), pressure: pressure)
    }
    func canvasPoint(_ point: InkPoint) -> CGPoint { geometry.pdfPoint(point).applying(pdfToCanvas) }
    static func whiteboard(size: CGSize) -> Self {
        Self(canvasToPDF: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height),
             geometry: InkPageGeometry(cropBox: CGRect(origin: .zero, size: size), rotation: 0))
    }
}
