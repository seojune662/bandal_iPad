import Foundation
import PDFKit

/// The portable envelope uses unrotated CropBox coordinates. Storage keeps
/// displayed coordinates, including every measured pressure/time/tilt sample.
enum NativeSyncInkGeometry {
    private typealias V = NativePDFRepositoryValidation
    static func validate(_ raw: Any?) throws -> [String: Any] {
        let value = try V.object(raw, "ink geometry")
        let rotation = try V.integer(value["rotation"], "rotation", min: 0)
        guard [0, 90, 180, 270].contains(rotation) else { throw V.error("Unsupported ink rotation") }
        return ["cropX": try V.number(value["cropX"], "cropX"), "cropY": try V.number(value["cropY"], "cropY"),
                "width": try V.number(value["width"], "page width", positive: true),
                "height": try V.number(value["height"], "page height", positive: true), "rotation": rotation]
    }
    static func pages(_ url: URL) throws -> [[String: Any]] {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw V.error("Sync PDF is unavailable or locked") }
        return try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { throw V.error("Sync PDF page is unavailable") }
            let box = page.bounds(for: .cropBox)
            return try validate(["cropX": Double(box.minX), "cropY": Double(box.minY), "width": Double(box.width), "height": Double(box.height), "rotation": (page.rotation % 360 + 360) % 360])
        }
    }
    static func matches(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        (left["rotation"] as? NSNumber)?.intValue == (right["rotation"] as? NSNumber)?.intValue &&
        ["cropX", "cropY", "width", "height"].allSatisfy {
            guard let a = left[$0] as? NSNumber, let b = right[$0] as? NSNumber else { return false }
            return abs(a.doubleValue - b.doubleValue) <= 0.001
        }
    }
    static func rotate(_ x: Double, _ y: Double, _ rotation: Int, inverse: Bool = false) throws -> (Double, Double) {
        switch ((inverse ? -rotation : rotation) + 360) % 360 {
        case 0: return (x, y)
        case 90: return (y, 1 - x)
        case 180: return (1 - x, 1 - y)
        case 270: return (1 - y, x)
        default: throw V.error("Unsupported ink rotation")
        }
    }
    static func box(_ raw: Any?, rotation: Int, inverse: Bool = false) throws -> [String: Any] {
        let value = try V.box(raw, "ink box")
        let x = value["x"] as! Double, y = value["y"] as! Double, w = value["width"] as! Double, h = value["height"] as! Double
        let a = try rotate(x, y, rotation, inverse: inverse), b = try rotate(x + w, y + h, rotation, inverse: inverse)
        return ["x": min(a.0, b.0), "y": min(a.1, b.1), "width": abs(a.0 - b.0), "height": abs(a.1 - b.1)]
    }
    static func shape(_ raw: [String: Any], geometry: [String: Any], inverse: Bool = false) throws -> [String: Any] {
        var result = raw, data = try V.object(raw["data"], "ink data"), style = try V.object(raw["style"], "ink style")
        let rotation = try V.integer(geometry["rotation"], "rotation", min: 0)
        if let rawPoints = data["points"] {
            guard let points = rawPoints as? [[String: Any]] else { throw V.error("Invalid measured ink points") }
            data["points"] = try points.map { point in
                var point = point
                let (x, y) = try rotate(V.number(point["x"], "point.x", min: 0, max: 1), V.number(point["y"], "point.y", min: 0, max: 1), rotation, inverse: inverse)
                point["x"] = x; point["y"] = y; return point
            }
        }
        if data["box"] != nil { data["box"] = try box(data["box"], rotation: rotation, inverse: inverse) }
        if rotation == 90 || rotation == 270 {
            let width = try V.number(geometry["width"], "page width", positive: true), height = try V.number(geometry["height"], "page height", positive: true)
            style["width"] = try V.number(style["width"], "ink width", positive: true) * (inverse ? width / height : height / width)
        }
        result["data"] = data; result["style"] = style; return result
    }
    /// Validate without normalizing away fields a newer app may understand.
    static func validateShape(_ shape: [String: Any]) throws {
        let kind = try V.string(shape["kind"], "kind"), data = try V.object(shape["data"], "data")
        if kind == "clip" {
            _ = try V.box(data["box"], "clip box")
            let clip = try V.object(data["clip"], "clip")
            _ = try V.path(clip["relPath"]); _ = try V.string(clip["label"], "clip label"); _ = try V.integer(clip["page"], "clip page")
            if clip["crop"] != nil { _ = try V.box(clip["crop"], "clip crop") }
        } else { _ = try V.data(data, kind: V.kind(kind)) }
        _ = try V.style(shape["style"])
    }
}
