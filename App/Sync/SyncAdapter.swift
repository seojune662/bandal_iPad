import Foundation

/// SyncAdapter mappings between local rows and spec v2.1 values, mirroring the
/// desktop's `src/main/features/sync/adapter.ts`. Pure: the engine supplies
/// timestamps, asset hashes and image paths.
enum SyncAdapter {
    private typealias V = NativePDFRepositoryValidation

    /// The `pdf_drawings` columns the spec carries.
    struct DrawingRow {
        let id: String, kind: String, page: Int
        let dataJSON: String, styleJSON: String
        let createdAt: String, updatedAt: String, deletedAt: String?
    }

    struct AssetRef { let sha256: String; let ext: String }

    /// What applying one merged drawing should do to the local row.
    enum DrawingImport {
        case upsert(kind: String, page: Int, data: [String: Any], style: [String: Any], createdAt: String, updatedAt: String)
        case delete(deletedAt: String)
        /// Kept in sync state only: a kind this version cannot draw, or an image with no local file yet.
        case hold(Hold)
    }
    enum Hold { case unknownKind, needsAsset }

    /// Spec rounding: nearest, ties away from zero, on the binary64 value scaled by 10^digits,
    /// so the result is bit-identical to the desktop's. −0 comes out as 0, which is how
    /// `JSON.stringify` writes it; Foundation would write "-0".
    static func round(_ value: Double, digits: Int) -> Double {
        let scale = (0..<digits).reduce(1.0) { result, _ in result * 10 }
        let rounded = (abs(value) * scale).rounded(.toNearestOrAwayFromZero) / scale
        return value < 0 && rounded != 0 ? -rounded : rounded
    }

    /// The iPad keeps its own course colour tokens; spec v2.1 (gold green blue pink violet
    /// orange red) names two of them differently. Anything else passes through.
    static func specCourseColor(_ local: String) -> String { ["purple": "violet", "yellow": "gold"][local] ?? local }
    static func localCourseColor(_ spec: String) -> String { ["violet": "purple", "gold": "yellow"][spec] ?? spec }

    /// Course row → `course.upsert` fields.
    static func courseFields(name: String, sortOrder: Int, color: String, archived: Bool) -> [String: Any] {
        ["name": name, "sort": sortOrder, "color": specCourseColor(color), "archived": archived]
    }

    /// Course-relative material path → the spec's folder and file name, both NFC.
    static func docLocation(_ relPath: String) -> (relPath: String, name: String) {
        let path = relPath.precomposedStringWithCanonicalMapping, scalars = path.unicodeScalars
        guard let slash = scalars.lastIndex(of: "/") else { return ("", path) }
        return (String(scalars[..<slash]), String(scalars[scalars.index(after: slash)...]))
    }

    /// `pdf_drawings` row → spec object, or nil when it cannot be exported: a board clip
    /// (local in v1) or an image whose asset hash is not given. A deleted row becomes a
    /// minimal tombstone. Coordinates round to 5 digits and pressure to 3; the stored row
    /// is untouched.
    static func inkObject(_ row: DrawingRow, t: Int64, image: AssetRef? = nil) throws -> [String: Any]? {
        if row.kind == "clip" { return nil }
        if let deleted = row.deletedAt, !deleted.isEmpty { return ["id": row.id, "page": row.page, "t": t, "del": true] }
        guard let parsed = try V.parse(row.dataJSON) as? [String: Any], let style = try V.parse(row.styleJSON) as? [String: Any] else { throw V.error("Invalid stored drawing") }
        var data = mapGeometry(parsed, point: { point in
            rounding(point, ["x": 5, "y": 5, "p": 3])
        }, box: { box in
            rounding(box, ["x": 5, "y": 5, "width": 5, "height": 5])
        })
        if row.kind == "image" {
            guard let image else { return nil }
            let source = parsed["image"] as? [String: Any] ?? [:]
            var value: [String: Any] = ["sha256": image.sha256, "ext": image.ext]
            value["label"] = source["label"]
            if let width = source["widthPx"] { value["widthPx"] = width; value["heightPx"] = source["heightPx"] }
            data["image"] = value
        }
        return ["id": row.id, "kind": row.kind, "page": row.page, "t": t, "created": try milliseconds(row.createdAt), "data": data, "style": style]
    }

    /// Merged spec object → local change. Clamps geometry into the page, then validates
    /// like a local save; content that still fails throws a validation error.
    static func importInkObject(_ object: SyncFormat.InkObject, imagePath: (AssetRef) -> String? = { _ in nil }) throws -> DrawingImport {
        let value = object.value
        if value["del"] != nil { return .delete(deletedAt: iso(object.t)) }
        guard let kind = value["kind"] as? String, V.kinds.contains(kind) else { return .hold(.unknownKind) }
        var data = mapGeometry(value["data"] as? [String: Any] ?? [:], point: importPoint, box: importBox)
        // Only strokes carry a renderer version; the local contract rejects it elsewhere.
        if kind != "ink", kind != "highlighter" { data["inkVersion"] = nil }
        if kind == "image" {
            guard var image = data["image"] as? [String: Any], let sha = SyncFormat.sha(image["sha256"]), let ext = SyncFormat.ext(image["ext"]) else {
                throw V.error("data.image needs a sha256 and ext")
            }
            guard let relPath = imagePath(AssetRef(sha256: sha, ext: ext)) else { return .hold(.needsAsset) }
            image["sha256"] = nil; image["ext"] = nil
            if (image["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { image["label"] = "\(sha.prefix(8)).\(ext)" }
            image["relPath"] = relPath
            data["image"] = image
        }
        let created = (value["created"] as? NSNumber).map { Int64($0.doubleValue) } ?? object.t
        return .upsert(kind: kind, page: object.page, data: try V.data(data, kind: kind), style: try V.style(value["style"]),
                       createdAt: iso(created), updatedAt: iso(object.t))
    }

    /// `2026-10-30T00:00:02.001Z` from whole milliseconds, the shape of `Date#toISOString`.
    /// Built from integers because a fractional `Date` can print one millisecond short.
    static func iso(_ milliseconds: Int64) -> String {
        let seconds = whole.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds / 1000)))
        return String(seconds.dropLast()) + String(format: ".%03dZ", Int(milliseconds % 1000))
    }

    static func milliseconds(_ iso: String) throws -> Int64 {
        guard let date = fractional.date(from: iso) ?? whole.date(from: iso) else { throw V.error("Invalid stored timestamp") }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static let whole = ISO8601DateFormatter()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()

    /// Applies `point` and `box` to well-formed entries only; anything else is left for validation to reject.
    private static func mapGeometry(_ data: [String: Any], point: ([String: Any]) -> [String: Any], box: ([String: Any]) -> [String: Any]) -> [String: Any] {
        var result = data
        if let points = data["points"] as? [Any] { result["points"] = points.map { ($0 as? [String: Any]).map(point) ?? $0 } }
        if let value = data["box"] as? [String: Any] { result["box"] = box(value) }
        return result
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    /// Non-numbers pass through untouched so validation rejects them instead of reading them as 0.
    private static func rounding(_ value: [String: Any], _ digits: [String: Int]) -> [String: Any] {
        var result = value
        for (key, places) in digits { if let number = number(value[key]) { result[key] = round(number, digits: places) } }
        return result
    }

    private static func clamp(_ value: Any?) -> Any? { number(value).map { min(1, max(0, $0)) } ?? value }

    /// Optional pen samples outside the local ranges are dropped rather than failing the stroke.
    private static func importPoint(_ point: [String: Any]) -> [String: Any] {
        var result = point
        for key in ["x", "y", "p"] { result[key] = clamp(point[key]) }
        for (key, range) in [("t", 0.0...86_400_000), ("tiltX", -90...90), ("tiltY", -90...90)] where point[key] != nil {
            if !(number(point[key]).map(range.contains) ?? false) { result[key] = nil }
        }
        return result
    }

    private static func importBox(_ box: [String: Any]) -> [String: Any] {
        var result = box
        let left = clamp(box["x"]), top = clamp(box["y"])
        func fit(_ size: Any?, _ start: Any?) -> Any? {
            guard let size = number(size), let start = number(start) else { return size }
            return min(max(0, size), 1 - start)
        }
        result["x"] = left; result["y"] = top
        result["width"] = fit(box["width"], left); result["height"] = fit(box["height"], top)
        return result
    }
}
