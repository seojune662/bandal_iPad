import Foundation
import CryptoKit

/// The width remains a PDF page-width fraction on disk. Only the presentation
/// converts it to physical millimetres; zoom never changes the stored stroke.
struct NativePDFPenPreset: Codable, Equatable {
    var color: String
    var width: Double
    var opacity: Double

    static let pen = Self(color: "ink", width: 0.004, opacity: 0.95)
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
    static let penWidths = [0.002, 0.004, 0.008]
    static let highlighterWidths = [0.0035, 0.006, 0.01]
    static func effectiveWidth(_ width: Double, highlighter: Bool) -> Double {
        highlighter ? max(0.014, width * 4) : width
    }
    static func millimetres(width: Double, highlighter: Bool, pageWidthPoints: Double?) -> Double? {
        guard let points = pageWidthPoints, points.isFinite, points > 0, width.isFinite else { return nil }
        return effectiveWidth(width, highlighter: highlighter) * points * 25.4 / 72
    }
    static func widthLabel(_ width: Double, highlighter: Bool, pageWidthPoints: Double?) -> String {
        guard let value = millimetres(width: width, highlighter: highlighter, pageWidthPoints: pageWidthPoints) else { return "— mm" }
        return String(format: "%.2f mm", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    static func widthRange(_ width: Double, highlighter: Bool) -> ClosedRange<Double> {
        // Existing values between steps or beyond the new quick choices remain
        // selectable without snapping on the first slider interaction.
        min(width, highlighter ? 0.0035 : 0.001)...max(width, highlighter ? 0.01 : 0.025)
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
    var drawAndHold = true
    static let changed = Notification.Name("NativePDFPalettePreferences.changed")

    init() {}
    private enum CodingKeys: String, CodingKey { case version, favorites, presets, recentPen, recentHighlighter, drawAndHold }
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
        drawAndHold = (try? values.decode(Bool.self, forKey: .drawAndHold)) ?? true
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version); try values.encode(favorites, forKey: .favorites)
        try values.encode(recentPen, forKey: .recentPen); try values.encode(recentHighlighter, forKey: .recentHighlighter)
        try values.encode(drawAndHold, forKey: .drawAndHold)
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
