import Foundation
import CoreGraphics

/// Pure edits of canonical normalized geometry. Pressure, time, tilt, version,
/// text runs, styles and unknown preserved fields are never regenerated.
enum NativePDFEditingGeometry {
    static func bounds(_ row: [String: Any], aspect: Double = 1) -> CGRect? {
        guard let data = row["data"] as? [String: Any] else { return nil }
        if let box = data["box"] as? [String: Any], let x = number(box["x"]), let y = number(box["y"]),
           let width = number(box["width"]), let height = number(box["height"]) { return CGRect(x: x, y: y, width: width, height: height) }
        guard let samples = data["points"] as? [[String: Any]] else { return nil }
        let points = samples.compactMap(point)
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y), minX = xs.min()!, minY = ys.min()!
        let width = number((row["style"] as? [String: Any])?["width"]) ?? 0
        return CGRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
            .insetBy(dx: -width / 2, dy: -width / (2 * max(aspect, 0.001)))
    }
    static func union(_ rows: [[String: Any]], aspect: Double = 1) -> CGRect? {
        let boxes = rows.compactMap { bounds($0, aspect: aspect) }
        guard let first = boxes.first else { return nil }; return boxes.dropFirst().reduce(first) { $0.union($1) }
    }
    static func hit(_ point: CGPoint, rows: [[String: Any]], aspect: Double) -> String? {
        rows.reversed().first { row in
            guard let box = bounds(row, aspect: aspect) else { return false }
            guard box.insetBy(dx: -0.012, dy: -0.012 / aspect).contains(point) else { return false }
            if let points = ((row["data"] as? [String: Any])?["points"] as? [[String: Any]])?.compactMap(Self.point), !points.isEmpty {
                let tolerance = max(0.012, (number((row["style"] as? [String: Any])?["width"]) ?? 0) / 2)
                let p = CGPoint(x: point.x, y: point.y * aspect), scaled = points.map { CGPoint(x: $0.x, y: $0.y * aspect) }
                if scaled.count == 1 { return hypot(p.x - scaled[0].x, p.y - scaled[0].y) <= tolerance }
                return zip(scaled, scaled.dropFirst()).contains { distance(p, to: $0.0, $0.1) <= tolerance }
            }
            return true
        }?["id"] as? String
    }
    static func lasso(_ polygon: [CGPoint], rows: [[String: Any]], aspect: Double) -> Set<String> {
        guard polygon.count >= 3 else { return [] }
        return Set(rows.compactMap { row in
            guard let id = row["id"] as? String, let box = bounds(row, aspect: aspect) else { return nil }
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            if let points = ((row["data"] as? [String: Any])?["points"] as? [[String: Any]])?.compactMap(point) {
                if points.contains(where: { contains($0, polygon: polygon) }) { return id }
                for pair in zip(points, points.dropFirst()) {
                    for edge in zip(polygon, Array(polygon.dropFirst()) + [polygon[0]]) where intersects(pair.0, pair.1, edge.0, edge.1) { return id }
                }
            } else if corners.contains(where: { contains($0, polygon: polygon) }) || contains(CGPoint(x: box.midX, y: box.midY), polygon: polygon) || polygon.contains(where: box.contains) { return id }
            return nil
        })
    }
    static func translated(_ rows: [[String: Any]], dx: Double, dy: Double, aspect: Double) -> [[String: Any]] {
        guard let box = union(rows, aspect: aspect) else { return rows }
        let dx = min(max(dx, -box.minX), 1 - box.maxX), dy = min(max(dy, -box.minY), 1 - box.maxY)
        return rows.map { transform($0) { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
    }
    static func resized(_ rows: [[String: Any]], original: CGRect, corner: String, to point: CGPoint) -> [[String: Any]] {
        let west = corner.contains("w"), north = corner.contains("n")
        if rows.count == 1, rows.first?["kind"] as? String == "textbox" {
            // Text font sizes remain physical points; handles change only the
            // wrap width. The caller measures its new height with textLayout.
            let anchor = west ? original.maxX : original.minX
            let x = min(1, max(0, west ? min(point.x, anchor - 0.02) : max(point.x, anchor + 0.02)))
            return rows.map { transform($0) { value in
                let ratio = original.width > 0 ? (value.x - original.minX) / original.width : 0
                return CGPoint(x: min(anchor, x) + ratio * abs(anchor - x), y: value.y)
            } }
        }
        let anchor = CGPoint(x: west ? original.maxX : original.minX, y: north ? original.maxY : original.minY)
        let x = min(1, max(0, west ? min(point.x, anchor.x - 0.005) : max(point.x, anchor.x + 0.005)))
        let y = min(1, max(0, north ? min(point.y, anchor.y - 0.005) : max(point.y, anchor.y + 0.005)))
        let old = CGPoint(x: west ? original.minX : original.maxX, y: north ? original.minY : original.maxY)
        let sx = abs(old.x - anchor.x) > 1e-9 ? (x - anchor.x) / (old.x - anchor.x) : 1
        let sy = abs(old.y - anchor.y) > 1e-9 ? (y - anchor.y) / (old.y - anchor.y) : 1
        return rows.map { transform($0) { CGPoint(x: anchor.x + ($0.x - anchor.x) * sx, y: anchor.y + ($0.y - anchor.y) * sy) } }
    }
    static func corner(at point: CGPoint, box: CGRect, aspect: Double) -> String? {
        let values: [(String, CGPoint)] = [("nw", CGPoint(x: box.minX, y: box.minY)), ("ne", CGPoint(x: box.maxX, y: box.minY)), ("sw", CGPoint(x: box.minX, y: box.maxY)), ("se", CGPoint(x: box.maxX, y: box.maxY))]
        return values.first { hypot(point.x - $0.1.x, (point.y - $0.1.y) * aspect) < 0.018 }?.0
    }
    /// Clipboard form: page/kind/data/style only. Images reference course
    /// assets that may not exist in the destination, so they do not travel.
    static func portable(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.compactMap { row in
            guard let kind = row["kind"] as? String, kind != "image", let data = row["data"], let style = row["style"] else { return nil }
            return ["page": row["page"] ?? 1, "kind": kind, "data": data, "style": style]
        }
    }
    /// Restyle keeps every unknown style field. Text boxes only take a colour;
    /// highlighters keep their effective width and opacity rules.
    static func restyled(_ rows: [[String: Any]], color: String?, width: Double?, opacity: Double?) -> [[String: Any]] {
        rows.map { row in
            var row = row; var style = row["style"] as? [String: Any] ?? [:]
            let kind = row["kind"] as? String ?? ""
            if let color { style["color"] = color }
            if kind != "textbox" {
                if let width { style["width"] = kind == "highlighter" ? max(0.014, width * 4) : width }
                if let opacity { style["opacity"] = kind == "highlighter" ? min(opacity, 0.34) : opacity }
            }
            row["style"] = style; row.removeValue(forKey: "nativePath"); row.removeValue(forKey: "_nativeInk"); return row
        }
    }
    static func dictionary(_ rect: CGRect) -> [String: Double] { ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)] }
    static func point(_ value: [String: Any]) -> CGPoint? {
        guard let x = number(value["x"]), let y = number(value["y"]) else { return nil }; return CGPoint(x: x, y: y)
    }
    private static func number(_ raw: Any?) -> Double? { guard let value = raw as? NSNumber, value.doubleValue.isFinite else { return nil }; return value.doubleValue }
    private static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
    private static func transform(_ source: [String: Any], _ body: (CGPoint) -> CGPoint) -> [String: Any] {
        var row = source; guard var data = row["data"] as? [String: Any] else { return row }
        if let points = data["points"] as? [[String: Any]] {
            data["points"] = points.map { value -> [String: Any] in
                guard let p = point(value) else { return value }; var value = value; let mapped = body(p)
                value["x"] = min(1, max(0, Double(mapped.x))); value["y"] = min(1, max(0, Double(mapped.y))); return value
            }
        }
        if var box = data["box"] as? [String: Any], let x = number(box["x"]), let y = number(box["y"]), let width = number(box["width"]), let height = number(box["height"]) {
            let a = body(CGPoint(x: x, y: y)), b = body(CGPoint(x: x + width, y: y + height))
            let x = min(1, max(0, Double(min(a.x, b.x)))), y = min(1, max(0, Double(min(a.y, b.y))))
            box["x"] = x; box["y"] = y; box["width"] = min(1 - x, abs(Double(b.x - a.x))); box["height"] = min(1 - y, abs(Double(b.y - a.y)))
            data["box"] = box
        }
        row["data"] = data; row.removeValue(forKey: "nativePath"); return row
    }
    private static func contains(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
        var result = false, last = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index], b = polygon[last]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            last = index
        }
        return result
    }
    private static func intersects(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let x = cross(a, b, c), y = cross(a, b, d), z = cross(c, d, a), w = cross(c, d, b)
        return (x > 0) != (y > 0) && (z > 0) != (w > 0)
    }
}
