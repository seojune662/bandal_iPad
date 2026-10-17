import Foundation
import CoreFoundation

/// The existing desktop drawing contract, normalized without interpreting or
/// resampling its measured points. Unknown presentation fields never enter a
/// receipt; raw storage rows remain untouched when they are read.
enum NativePDFRepositoryValidation {
    static let kinds = ["ink", "highlighter", "rect", "ellipse", "arrow", "line", "textbox", "image"]
    static let colors = ["ink", "red", "orange", "yellow", "green", "blue", "violet"]
    static let flags = ["bold", "italic", "underline", "strike"]
    static func error(_ message: String) -> DesktopRuntimeError { DesktopRuntimeError(message, code: "VALIDATION_ERROR") }
    static func string(_ value: Any?, _ name: String) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw error("\(name) must be a non-empty string") }
        return value
    }
    static func id(_ value: Any?, _ name: String = "id") throws -> String {
        let value = try string(value, name)
        guard !value.unicodeScalars.contains(where: { $0.value < 32 }) else { throw error("\(name) contains control characters") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func uuid(_ value: Any?, _ name: String) throws -> String {
        let value = try string(value, name)
        guard UUID(uuidString: value) != nil else { throw error("\(name) must be a UUID") }; return value
    }
    static func path(_ value: Any?) throws -> String {
        let value = try string(value, "relPath")
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.unicodeScalars.contains(where: { $0.value < 32 }),
              !value.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw error("Invalid PDF relative path") }
        return value
    }
    static func number(_ value: Any?, _ name: String, min: Double = -.infinity, max: Double = .infinity, positive: Bool = false) throws -> Double {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw error("\(name) must be numeric") }
        let number = value.doubleValue
        guard number.isFinite, number >= min, number <= max, !positive || number > 0 else { throw error("\(name) is outside its valid range") }
        return number == 0 ? 0 : number
    }
    static func integer(_ value: Any?, _ name: String, min: Int = 1) throws -> Int {
        let value = try number(value, name, min: Double(min), max: Double(Int.max))
        guard value.rounded() == value, value < Double(Int.max) else { throw error("\(name) must be an integer") }
        return Int(value)
    }
    static func digest(_ value: Any?) throws -> String {
        guard let value = value as? String, value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw error("documentRevision must be a SHA-256 digest") }
        return value
    }
    static func object(_ value: Any?, _ name: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw error("\(name) must be an object") }; return value
    }
    static func kind(_ value: Any?) throws -> String {
        guard let value = value as? String, kinds.contains(value) else { throw error("Unsupported PDF drawing kind") }; return value
    }
    static func box(_ value: Any?, _ name: String) throws -> [String: Any] {
        let source = try object(value, name)
        var result: [String: Any] = [:]
        for key in ["x", "y", "width", "height"] { result[key] = try number(source[key], name + "." + key, min: 0, max: 1) }
        guard (result["x"] as! Double) + (result["width"] as! Double) <= 1,
              (result["y"] as! Double) + (result["height"] as! Double) <= 1 else { throw error("\(name) must stay inside the normalized page") }
        return result
    }
    static func data(_ value: Any?, kind: String) throws -> [String: Any] {
        let source = try object(value, "data")
        var result: [String: Any] = [:]
        if let version = source["inkVersion"] {
            let version = try integer(version, "inkVersion")
            guard [2, 3, 4, 5].contains(version), ["ink", "highlighter"].contains(kind) else { throw error("Unsupported ink renderer version") }
            result["inkVersion"] = version
        }
        if let raw = source["points"] {
            guard let points = raw as? [[String: Any]] else { throw error("data.points must be an array") }
            result["points"] = try points.map { point -> [String: Any] in
                var value: [String: Any] = [:]
                for key in ["x", "y", "p"] { value[key] = try number(point[key], "point." + key, min: 0, max: 1) }
                for key in ["t", "tiltX", "tiltY"] where point[key] != nil {
                    value[key] = try number(point[key], "point." + key, min: key == "t" ? 0 : -90, max: key == "t" ? 86_400_000 : 90)
                }
                return value
            }
        }
        if source["box"] != nil { result["box"] = try box(source["box"], "data.box") }
        if let text = source["text"] {
            guard let text = text as? String else { throw error("data.text must be a string") }; result["text"] = text
        }
        if let runs = source["textRuns"] {
            guard let text = result["text"] as? String, let runs = runs as? [[String: Any]] else { throw error("data.textRuns needs textbox text and an array") }
            var normalized: [[String: Any]] = []
            for run in runs {
                let from = try integer(run["from"], "run.from", min: 0), to = try integer(run["to"], "run.to")
                guard from < to, to <= text.utf16.count else { throw error("Invalid text run range") }
                let style = try inlineStyle(run["style"])
                normalized.append(["from": from, "to": to, "style": style])
            }
            normalized.sort { ($0["from"] as! Int, $0["to"] as! Int) < ($1["from"] as! Int, $1["to"] as! Int) }
            var previousEnd = 0, previousStyle: [String: Any]?
            for index in normalized.indices {
                let from = max(previousEnd, normalized[index]["from"] as! Int), to = normalized[index]["to"] as! Int
                let style = normalized[index]["style"] as! [String: Any]
                guard to > from, !style.isEmpty,
                      !(previousEnd == from && previousStyle != nil && NSDictionary(dictionary: previousStyle!).isEqual(to: style)) else { throw error("data.textRuns must be ordered, non-overlapping ranges") }
                normalized[index]["from"] = from; previousEnd = to; previousStyle = style
            }
            if !normalized.isEmpty { result["textRuns"] = normalized }
        }
        if let image = source["image"] {
            let image = try object(image, "data.image")
            var value: [String: Any] = ["relPath": try string(image["relPath"], "image.relPath"), "label": try string(image["label"], "image.label")]
            if image["storage"] != nil || image["assetId"] != nil {
                guard image["storage"] as? String == "shared" else { throw error("Invalid shared image storage") }
                value["storage"] = "shared"; value["assetId"] = try string(image["assetId"], "image.assetId")
                value["widthPx"] = try integer(image["widthPx"], "image.widthPx"); value["heightPx"] = try integer(image["heightPx"], "image.heightPx")
            }
            result["image"] = value
        }
        let count = (result["points"] as? [[String: Any]])?.count ?? 0
        if ["ink", "highlighter"].contains(kind), count == 0 { throw error("Ink data needs at least one point") }
        if ["rect", "ellipse", "textbox", "image"].contains(kind), result["box"] == nil { throw error("\(kind) needs a box") }
        if ["line", "arrow"].contains(kind), result["box"] == nil, count < 2 { throw error("\(kind) needs a box or two points") }
        if kind == "textbox", result["text"] == nil { throw error("textbox needs text") }
        if kind == "image", result["image"] == nil { throw error("image needs a source") }
        return result
    }
    private static func inlineStyle(_ raw: Any?) throws -> [String: Any] {
        let source = try object(raw, "text style"); var result: [String: Any] = [:]
        if let color = source["color"] {
            guard let color = color as? String, colors.contains(color) else { throw error("Invalid text color") }; result["color"] = color
        }
        if let size = source["fontSizePt"] { result["fontSizePt"] = try number(size, "fontSizePt", max: 96, positive: true) }
        for key in flags where source[key] != nil {
            guard let value = source[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw error("\(key) must be boolean") }
            result[key] = value.boolValue
        }
        return result
    }
    static func style(_ raw: Any?) throws -> [String: Any] {
        let source = try object(raw, "style")
        guard let color = source["color"] as? String, colors.contains(color) else { throw error("Invalid drawing color") }
        var result = try inlineStyle(source)
        result["color"] = color; result["width"] = try number(source["width"], "style.width", max: 1, positive: true)
        result["opacity"] = try number(source["opacity"], "style.opacity", min: 0, max: 1)
        if let scale = source["fontScale"] { result["fontScale"] = try number(scale, "fontScale", max: 10, positive: true) }
        if let align = source["align"] {
            guard let align = align as? String, ["left", "center", "right"].contains(align) else { throw error("Invalid text alignment") }; result["align"] = align
        }
        if let fill = source["fill"] {
            guard let fill = fill as? String, colors.contains(fill) else { throw error("Invalid drawing fill") }; result["fill"] = fill
        }
        return result
    }
    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
    }
    static func parse(_ value: Any?) throws -> Any {
        guard let value = value as? String else { throw error("Missing stored JSON") }
        return try DesktopJSON.decode(Data(value.utf8), options: [.fragmentsAllowed])
    }
    /// Prior receipts use JSON.stringify field order. Equality is structural so
    /// Swift's JSON number spelling cannot reject a genuine historical receipt.
    static func receiptMatches(_ stored: Any?, _ expected: [String: Any]) throws -> Bool {
        guard let old = try parse(stored) as? [String: Any] else { throw error("Invalid drawing receipt") }
        return NSDictionary(dictionary: old).isEqual(to: expected)
    }
}
