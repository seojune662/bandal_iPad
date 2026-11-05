import Foundation
import CryptoKit

/// The width remains a PDF page-width fraction on disk. The palette shows it as
/// one of twelve steps; zoom never changes the stored stroke.
struct NativePDFPenPreset: Codable, Equatable {
    var color: String
    var width: Double
    var opacity: Double

    static let pen = Self(color: "ink", width: 0.004, opacity: 0.95)
    static let ballpoint = Self(color: "ink", width: 0.003, opacity: 1)
    static let highlighter = Self(color: "yellow", width: 0.006, opacity: 0.28)
    static let colors = ["ink", "red", "orange", "yellow", "green", "blue", "violet"]
    var isValid: Bool {
        Self.colors.contains(color) && width.isFinite && (0.001...0.04).contains(width) &&
            opacity.isFinite && (0.05...1).contains(opacity)
    }
    func validated(highlighter: Bool = false) -> Self {
        let fallback = highlighter ? Self.highlighter : .pen
        return Self(color: Self.colors.contains(color) ? color : fallback.color,
                    width: width.isFinite ? min(0.04, max(0.001, width)) : fallback.width,
                    opacity: opacity.isFinite ? min(highlighter ? 0.34 : 1, max(0.05, opacity)) : fallback.opacity)
    }
}

enum NativePDFPaletteStyle {
    /// Twelve thickness steps per tool, stored as the usual page-width fraction.
    /// Every earlier default and quick width is one of the steps.
    static let penSteps = [0.001, 0.0015, 0.002, 0.0025, 0.003, 0.004, 0.005, 0.006, 0.008, 0.010, 0.013, 0.017]
    /// Stored highlighter widths; the drawn width is `effectiveWidth`.
    static let highlighterSteps = [0.0035, 0.004, 0.0045, 0.005, 0.0055, 0.006, 0.007, 0.008, 0.009, 0.010, 0.0115, 0.013]
    /// Eraser radius; 0.005 (index 3) is the radius the eraser always had.
    static let eraserSteps = [0.002, 0.003, 0.004, 0.005, 0.007, 0.009, 0.012, 0.015, 0.020, 0.025, 0.032, 0.040]
    static let slotTools = ["pen", "ballpoint", "highlighter", "eraser"]
    static let defaultWidthSlots: [String: [Int]] = ["pen": [2, 5, 8], "ballpoint": [2, 4, 8], "highlighter": [0, 5, 9], "eraser": [1, 3, 6]]
    static let defaultColorSlots: [String: [String]] = ["pen": ["ink", "blue", "red", "green"], "ballpoint": ["ink", "blue", "red"], "highlighter": ["yellow", "green", "blue", "violet"]]
    static let eraserModes = ["stroke", "partial"]
    static func steps(for tool: String) -> [Double] {
        switch tool {
        case "highlighter": highlighterSteps
        case "eraser": eraserSteps
        default: penSteps
        }
    }
    /// The step closest to a stored width, so widths saved by the old slider still show a step.
    static func nearestStep(_ width: Double, tool: String) -> Int {
        let values = steps(for: tool)
        return values.indices.min { abs(values[$0] - width) < abs(values[$1] - width) } ?? 0
    }
    static func stepLabel(_ index: Int) -> String { "\(index + 1)단계" }
    static func effectiveWidth(_ width: Double, highlighter: Bool) -> Double {
        highlighter ? max(0.014, width * 4) : width
    }
    static func opacityRange(_ opacity: Double, highlighter: Bool) -> ClosedRange<Double> {
        min(opacity, 0.1)...(highlighter ? 0.34 : 1)
    }
}

/// Favorites and recent styles are workspace-wide; open panes keep their own
/// active style. Every mutation rereads the latest value to preserve edits made
/// in another PDF pane between two UI actions.
struct NativePDFPalettePreferences: Codable, Equatable {
    var version = 2
    var favorites = [NativePDFPenPreset.pen, .init(color: "blue", width: 0.004, opacity: 0.95), .init(color: "red", width: 0.004, opacity: 0.95)]
    var recentPen = NativePDFPenPreset.pen
    var recentHighlighter = NativePDFPenPreset.highlighter
    var recentBallpoint = NativePDFPenPreset.ballpoint
    var drawAndHold = true
    /// Per tool: up to seven colour names and three thickness steps (Notability-style slots).
    var colorSlots: [String: [String]] = [:]
    var widthSlots: [String: [Int]] = [:]
    var eraserMode = "stroke"
    var eraserRadius = 0.005
    func colors(for tool: String) -> [String] {
        var seen = Set<String>()
        let value = (colorSlots[tool] ?? []).filter { NativePDFPenPreset.colors.contains($0) && seen.insert($0).inserted }
        return value.isEmpty ? NativePDFPaletteStyle.defaultColorSlots[tool] ?? ["ink"] : value
    }
    func widths(for tool: String) -> [Int] {
        let value = widthSlots[tool] ?? []
        guard value.count == 3, value.allSatisfy(NativePDFPaletteStyle.steps(for: tool).indices.contains) else {
            return NativePDFPaletteStyle.defaultWidthSlots[tool] ?? [2, 5, 8]
        }
        return value
    }
    static let changed = Notification.Name("NativePDFPalettePreferences.changed")

    init() {}
    private enum CodingKeys: String, CodingKey { case version, favorites, presets, recentPen, recentHighlighter, recentBallpoint, drawAndHold, colorSlots, widthSlots, eraserMode, eraserRadius }
    private struct Candidate: Decodable {
        let value: NativePDFPenPreset?
        init(from decoder: Decoder) throws { value = try? NativePDFPenPreset(from: decoder) }
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 2
        guard version == 1 || version == 2 else { return }
        let old = version == 1
        let candidates = ((try? values.decode([Candidate].self, forKey: old ? .presets : .favorites)) ?? []).map(\.value)
        let previous = candidates.compactMap { $0 }.filter(\.isValid)
        let source = old ? previous.map(Optional.some) : candidates
        for index in favorites.indices where source.indices.contains(index) {
            if let preset = source[index], preset.isValid { favorites[index] = preset }
        }
        if let value = try? values.decode(NativePDFPenPreset.self, forKey: .recentPen), value.isValid { recentPen = value }
        else if old, let first = previous.first { recentPen = first }
        if let value = try? values.decode(NativePDFPenPreset.self, forKey: .recentHighlighter), value.isValid { recentHighlighter = value.validated(highlighter: true) }
        if let value = try? values.decode(NativePDFPenPreset.self, forKey: .recentBallpoint), value.isValid { recentBallpoint = value }
        drawAndHold = (try? values.decode(Bool.self, forKey: .drawAndHold)) ?? true
        // Added within version 2: older builds ignore these keys instead of resetting everything.
        colorSlots = (try? values.decode([String: [String]].self, forKey: .colorSlots)) ?? [:]
        widthSlots = (try? values.decode([String: [Int]].self, forKey: .widthSlots)) ?? [:]
        if let mode = try? values.decode(String.self, forKey: .eraserMode), NativePDFPaletteStyle.eraserModes.contains(mode) { eraserMode = mode }
        if let radius = try? values.decode(Double.self, forKey: .eraserRadius), radius.isFinite,
           (NativePDFPaletteStyle.eraserSteps.first!...NativePDFPaletteStyle.eraserSteps.last!).contains(radius) { eraserRadius = radius }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version); try values.encode(favorites, forKey: .favorites)
        try values.encode(recentPen, forKey: .recentPen); try values.encode(recentHighlighter, forKey: .recentHighlighter)
        try values.encode(recentBallpoint, forKey: .recentBallpoint)
        try values.encode(drawAndHold, forKey: .drawAndHold)
        try values.encode(colorSlots, forKey: .colorSlots); try values.encode(widthSlots, forKey: .widthSlots)
        try values.encode(eraserMode, forKey: .eraserMode); try values.encode(eraserRadius, forKey: .eraserRadius)
    }
    static func key(root: URL, documentsRoot: URL? = nil) -> String {
        key(rootIdentity: NativePDFPreferenceScope.identity(root: root, documentsRoot: documentsRoot))
    }
    private static func key(rootIdentity: String) -> String {
        "native-pdf.palette.v2." + SHA256.hash(data: Data(rootIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func load(root: URL, defaults: UserDefaults = .standard, documentsRoot: URL? = nil) -> Self {
        let data = NativePDFPreferenceScope.storedData(root: root, stableKey: key(root: root, documentsRoot: documentsRoot), documentsRoot: documentsRoot, defaults: defaults,
            legacyKeys: { path in let key = key(rootIdentity: path); return [key, key.replacingOccurrences(of: ".v2.", with: ".v1.")] },
            normalize: { data in
                guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return try? encoder.encode(value)
            })
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    @discardableResult
    static func update(root: URL, defaults: UserDefaults = .standard, documentsRoot: URL? = nil, _ change: (inout Self) -> Void) -> Self {
        var value = load(root: root, defaults: defaults, documentsRoot: documentsRoot); change(&value)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let key = key(root: root, documentsRoot: documentsRoot)
        if let data = try? encoder.encode(value), data != defaults.data(forKey: key) {
            defaults.set(data, forKey: key)
            NotificationCenter.default.post(name: changed, object: defaults, userInfo: ["key": key])
        }
        return value
    }
}
