import UIKit
import Combine

struct NativePDFTextStyle: Codable, Equatable {
    static let colors = ["ink", "red", "orange", "yellow", "green", "blue", "violet"]
    static let labels = ["검정", "빨강", "주황", "노랑", "초록", "파랑", "보라"]
    static let sizes: [Double] = [6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72, 96]
    static let defaultsKey = "native.pdf.text-style.v1"
    var color = "ink"
    var fontSizePt = 14.0
    var bold = false, italic = false, underline = false, strike = false
    var align = "left"
    var fill: String?
    var opacity = 1.0

    init(_ value: [String: Any] = [:], pageWidth: Double = 595.28) {
        if let color = value["color"] as? String, Self.colors.contains(color) { self.color = color }
        let explicit = Self.number(value["fontSizePt"])
        let legacy = Self.number(value["fontScale"]).map { pageWidth * 0.026 * $0 }
        if let size = explicit ?? legacy, size > 0 { fontSizePt = size }
        bold = value["bold"] as? Bool == true; italic = value["italic"] as? Bool == true
        underline = value["underline"] as? Bool == true; strike = value["strike"] as? Bool == true
        if let align = value["align"] as? String, ["left", "center", "right"].contains(align) { self.align = align }
        if let fill = value["fill"] as? String, Self.colors.contains(fill) { self.fill = fill }
        if let opacity = Self.number(value["opacity"]) { self.opacity = min(1, max(0, opacity)) }
    }
    var dictionary: [String: Any] {
        var value: [String: Any] = ["color": color, "fontSizePt": fontSizePt, "bold": bold, "italic": italic,
            "underline": underline, "strike": strike, "align": align, "opacity": opacity, "width": 0.002]
        if let fill { value["fill"] = fill }
        return value
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    static func committedSize(_ input: String, fallback: Double) -> Double {
        guard let value = Double(input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), value.isFinite else { return fallback }
        return min(96, max(6, value.rounded()))
    }
    static func steppedSize(_ value: Double, direction: Int) -> Double {
        let nearest = sizes.indices.min { abs(sizes[$0] - value) < abs(sizes[$1] - value) } ?? 7
        return sizes[min(sizes.count - 1, max(0, nearest + direction))]
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey), let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        var clean = Self(decoded.dictionary)
        clean.fontSizePt = min(96, max(6, clean.fontSizePt)); clean.opacity = max(0.1, clean.opacity)
        return clean
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

/// Each pane owns its draft. No formatting target or active selection is global.
/// The custom attributed key keeps canonical UTF-16 runs while UIKit edits text.
@MainActor
final class NativePDFTextDraft: ObservableObject {
    static let inlineKey = NSAttributedString.Key("app.bandal.pdf.text.inline")
    static let inlineFields: Set<String> = ["color", "fontSizePt", "bold", "italic", "underline", "strike"]
    let original: [String: Any]
    let pageSize: CGSize
    let existing: Bool
    private let defaults: UserDefaults
    private let onChange: () -> Void
    private var data: [String: Any], base: [String: Any]
    private var richText: NSAttributedString
    private var caretOverrides: [String: Any]?
    @Published private(set) var revision = 0
    @Published private(set) var selection = NSRange(location: 0, length: 0)
    @Published private(set) var isComposing = false
    @Published private(set) var savedDefaults = false
    @Published var pointDraft = "14"
    var editingPoint = false
    var finishPendingInput: (() -> Void)?
    var finishPendingPointInput: (() -> Void)?

    init(object: [String: Any], pageSize: CGSize, existing: Bool, defaults: UserDefaults = .standard, onChange: @escaping () -> Void = {}) {
        self.original = object; self.existing = existing; self.defaults = defaults; self.onChange = onChange
        self.pageSize = CGSize(width: max(1, pageSize.width), height: max(1, pageSize.height))
        data = object["data"] as? [String: Any] ?? [:]
        base = object["style"] as? [String: Any] ?? NativePDFTextStyle.load(defaults: defaults).dictionary
        richText = Self.makeRichText(data: data, style: base, pageWidth: max(1, pageSize.width))
        pointDraft = Self.pointLabel(NativePDFTextStyle(base, pageWidth: max(1, pageSize.width)).fontSizePt)
    }
    var text: String { richText.string }
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var widthFraction: Double { NativePDFTextStyle.number((data["box"] as? [String: Any])?["width"]) ?? 0.26 }
    var physicalWidth: CGFloat { max(1, widthFraction * pageSize.width) }
    var style: NativePDFTextStyle {
        NativePDFTextStyle(base.merging(effectiveInline) { _, next in next }, pageWidth: pageSize.width)
    }
    var boxStyle: NativePDFTextStyle { NativePDFTextStyle(base, pageWidth: pageSize.width) }
    private var effectiveInline: [String: Any] {
        if let caretOverrides, selection.length == 0 { return caretOverrides }
        guard richText.length > 0 else { return [:] }
        let offset = min(richText.length - 1, selection.length == 0 ? max(0, selection.location - 1) : selection.location)
        return richText.attribute(Self.inlineKey, at: offset, effectiveRange: nil) as? [String: Any] ?? [:]
    }
    static func pointLabel(_ value: Double) -> String { String(format: value.rounded() == value ? "%.0f" : "%.1f", value) }

    func finishComposition() { finishPendingPointInput?(); finishPendingInput?(); commitPointInput() }
    func commitPointInput() {
        guard editingPoint else { return }
        editingPoint = false
        let value = NativePDFTextStyle.committedSize(pointDraft, fallback: style.fontSizePt)
        pointDraft = Self.pointLabel(value); apply(["fontSizePt": value], inline: true)
    }
    func cancelPointInput() { editingPoint = false; pointDraft = Self.pointLabel(style.fontSizePt) }
    func stepSize(_ direction: Int) {
        commitPointInput(); apply(["fontSizePt": NativePDFTextStyle.steppedSize(style.fontSizePt, direction: direction)], inline: true)
    }
    func toggle(_ key: String) {
        guard ["bold", "italic", "underline", "strike"].contains(key) else { return }
        apply([key: !(style.dictionary[key] as? Bool ?? false)], inline: true)
    }
    func preset(size: Double, bold: Bool) {
        commitPointInput()
        apply(["fontSizePt": size, "bold": bold, "italic": false, "underline": false, "strike": false], inline: true)
    }
    func apply(_ patch: [String: Any], inline: Bool = false) {
        finishPendingInput?()
        if inline, richText.length > 0 {
            let patch = patch.filter { Self.inlineFields.contains($0.key) }
            if selection.length == 0 {
                caretOverrides = effectiveInline.merging(patch) { _, new in new }
            } else {
                let changed = NSMutableAttributedString(attributedString: richText)
                changed.enumerateAttribute(Self.inlineKey, in: selection) { value, range, _ in
                    var next = value as? [String: Any] ?? [:]
                    next.merge(patch) { _, new in new }
                    changed.addAttribute(Self.inlineKey, value: next, range: range)
                }
                richText = changed
            }
        } else {
            for (key, value) in patch {
                if value is NSNull { base.removeValue(forKey: key) } else { base[key] = value }
            }
            if patch["fontSizePt"] != nil { base.removeValue(forKey: "fontScale") }
        }
        normalizeAndRebuild(); changed()
    }
    func setWidth(_ fraction: Double) {
        finishPendingInput?()
        guard var box = data["box"] as? [String: Any] else { return }
        let x = NativePDFTextStyle.number(box["x"]) ?? 0
        box["width"] = min(max(0.02, fraction), 1 - x); data["box"] = box
        changed()
    }
    func saveDefaults() {
        finishComposition(); style.save(defaults: defaults); savedDefaults = true
    }
    func setSelection(_ value: NSRange, composing: Bool = false) {
        let next = NSRange(location: min(max(0, value.location), richText.length),
            length: min(max(0, value.length), max(0, richText.length - min(max(0, value.location), richText.length))))
        if next != selection { selection = next; caretOverrides = nil }
        isComposing = composing
        if !editingPoint { pointDraft = Self.pointLabel(style.fontSizePt) }
    }
    func acceptEditorText(_ value: NSAttributedString, selection: NSRange, composing: Bool) {
        let previous = data
        richText = NSAttributedString(attributedString: value)
        setSelection(selection, composing: composing)
        updateData()
        if !NSDictionary(dictionary: previous).isEqual(to: data) { caretOverrides = nil; changed() }
    }
    func attributedText(scale: CGFloat) -> NSAttributedString {
        Self.scaled(Self.makeRichText(data: data, style: base, pageWidth: pageSize.width), by: scale)
    }
    func typingAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let merged = base.merging(effectiveInline) { _, new in new }
        let sample = NativePDFObjectRenderer.attributedText(data: ["text": " "], style: merged, surfaceWidth: pageSize.width)
        var value = Self.scaled(sample, by: scale).attributes(at: 0, effectiveRange: nil)
        value[Self.inlineKey] = effectiveInline
        return value
    }
    func objectForSave() -> [String: Any]? {
        finishComposition()
        guard hasText else { return nil }
        updateData()
        var row = original; row["data"] = data; row["style"] = base; row.removeValue(forKey: "nativePath")
        return Self.fittedObject(row, pageSize: pageSize)
    }
    private func changed() {
        revision += 1; savedDefaults = false
        if !editingPoint { pointDraft = Self.pointLabel(style.fontSizePt) }
        onChange()
    }
    private func normalizeAndRebuild() {
        updateData(); richText = Self.makeRichText(data: data, style: base, pageWidth: pageSize.width)
    }
    private func updateData() {
        data["text"] = richText.string
        var runs: [[String: Any]] = []
        richText.enumerateAttribute(Self.inlineKey, in: NSRange(location: 0, length: richText.length)) { value, range, _ in
            let clean = (value as? [String: Any] ?? [:]).filter { Self.inlineFields.contains($0.key) }
            guard !clean.isEmpty, range.length > 0 else { return }
            if let previous = runs.last, previous["to"] as? Int == range.location,
               let previousStyle = previous["style"] as? [String: Any], NSDictionary(dictionary: previousStyle).isEqual(to: clean) {
                runs[runs.count - 1]["to"] = NSMaxRange(range)
            } else { runs.append(["from": range.location, "to": NSMaxRange(range), "style": clean]) }
        }
        if runs.isEmpty { data.removeValue(forKey: "textRuns") } else { data["textRuns"] = runs }
    }
    private static func makeRichText(data: [String: Any], style: [String: Any], pageWidth: CGFloat) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: NativePDFObjectRenderer.attributedText(data: data, style: style, surfaceWidth: pageWidth))
        let length = value.length
        value.addAttribute(inlineKey, value: [String: Any](), range: NSRange(location: 0, length: length))
        var last = 0
        let runs = (data["textRuns"] as? [[String: Any]] ?? []).sorted { ($0["from"] as? Int ?? 0) < ($1["from"] as? Int ?? 0) }
        for run in runs {
            guard let start = run["from"] as? Int, let end = run["to"] as? Int, start >= 0, start < length,
                  let style = run["style"] as? [String: Any] else { continue }
            let from = max(last, start), to = min(length, end)
            guard to > from else { continue }
            value.addAttribute(inlineKey, value: style.filter { inlineFields.contains($0.key) }, range: NSRange(location: from, length: to - from)); last = to
        }
        return value
    }
    private static func scaled(_ source: NSAttributedString, by scale: CGFloat) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: source)
        copy.enumerateAttribute(.font, in: NSRange(location: 0, length: copy.length)) { value, range, _ in
            if let font = value as? UIFont { copy.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: range) }
        }
        return copy
    }
    static func newObject(at point: CGPoint, page: Int, pageSize: CGSize, defaults: UserDefaults = .standard) -> [String: Any] {
        let style = NativePDFTextStyle.load(defaults: defaults), width = max(1, pageSize.width), height = max(1, pageSize.height)
        let inset = style.fontSizePt * 0.36
        let x = min(0.98, max(0, point.x - inset / width))
        let boxWidth = max(0.02, min(1 - x, max(0.26, min(0.72, 10 * style.fontSizePt / width))))
        let boxHeight = min(1, (style.fontSizePt * 1.35 + inset * 2) / height)
        let y = max(0, min(1 - boxHeight, point.y - (inset + style.fontSizePt * 1.35 / 2) / height))
        return ["page": page, "kind": "textbox", "data": ["text": "", "box": ["x": Double(x), "y": Double(y), "width": Double(boxWidth), "height": Double(boxHeight)]], "style": style.dictionary]
    }
    static func fittedObject(_ object: [String: Any], pageSize: CGSize) -> [String: Any] {
        guard object["kind"] as? String == "textbox", var data = object["data"] as? [String: Any],
              var box = data["box"] as? [String: Any], let width = NativePDFTextStyle.number(box["width"]),
              let y = NativePDFTextStyle.number(box["y"]), let style = object["style"] as? [String: Any],
              pageSize.width > 0, pageSize.height > 0 else { return object }
        let padding = NativePDFObjectRenderer.baseFontSize(style, surfaceWidth: pageSize.width) * 0.36
        let layout = NativePDFObjectRenderer.textLayout(data: data, style: style, surfaceWidth: pageSize.width,
            contentWidth: max(1, width * pageSize.width - 2 * padding))
        let height = min(1, (ceil(layout.height * 1_000) / 1_000 + 2 * padding) / pageSize.height)
        box["height"] = Double(height); box["y"] = Double(max(0, min(y, 1 - height))); data["box"] = box
        var result = object; result["data"] = data; return result
    }
}
