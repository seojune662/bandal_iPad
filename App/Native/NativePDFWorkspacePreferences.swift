import Foundation
import CryptoKit

/// Local presentation state belongs to a document in one workspace. It never
/// participates in PDF identity, ink geometry, or cross-device material sync.
struct NativePDFWorkspacePreferences: Codable, Equatable {
    var tool = "pen"
    var color = "ink"
    var width = NativePDFPenPreset.pen.width
    var opacity = NativePDFPenPreset.pen.opacity
    var previousTool = "pen"
    var penColor = "ink"
    var highlighterColor = "yellow"
    var penStyle = NativePDFPenPreset.pen
    var highlighterStyle = NativePDFPenPreset.highlighter
    var ballpointStyle = NativePDFPenPreset.ballpoint
    var lassoMode = "freeform"
    var shapeRecognitionEnabled = true
    var toolsExpanded = true
    var showPages = false
    var showAnnotations = false
    var viewport: Viewport?

    init() {}
    private enum CodingKeys: String, CodingKey {
        case tool, color, width, opacity, previousTool, penColor, highlighterColor, penStyle, highlighterStyle
        case toolsExpanded, showPages, showAnnotations, viewport, shapeRecognitionEnabled, ballpointStyle, lassoMode
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tool = try values.decodeIfPresent(String.self, forKey: .tool) ?? tool
        color = try values.decodeIfPresent(String.self, forKey: .color) ?? color
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? width
        opacity = try values.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        previousTool = try values.decodeIfPresent(String.self, forKey: .previousTool) ?? previousTool
        penColor = try values.decodeIfPresent(String.self, forKey: .penColor) ?? (tool == "pen" ? color : penColor)
        highlighterColor = try values.decodeIfPresent(String.self, forKey: .highlighterColor) ?? (tool == "highlighter" ? color : highlighterColor)
        // Native v1 stored only a shared width/opacity. Preserve those values in
        // both styles during the one-time migration instead of resetting ink.
        penStyle = try values.decodeIfPresent(NativePDFPenPreset.self, forKey: .penStyle) ?? .init(color: penColor, width: width, opacity: opacity)
        highlighterStyle = try values.decodeIfPresent(NativePDFPenPreset.self, forKey: .highlighterStyle) ?? .init(color: highlighterColor, width: width, opacity: opacity)
        shapeRecognitionEnabled = try values.decodeIfPresent(Bool.self, forKey: .shapeRecognitionEnabled) ?? true
        ballpointStyle = try values.decodeIfPresent(NativePDFPenPreset.self, forKey: .ballpointStyle) ?? ballpointStyle
        lassoMode = try values.decodeIfPresent(String.self, forKey: .lassoMode) ?? lassoMode
        toolsExpanded = try values.decodeIfPresent(Bool.self, forKey: .toolsExpanded) ?? toolsExpanded
        showPages = try values.decodeIfPresent(Bool.self, forKey: .showPages) ?? showPages
        showAnnotations = try values.decodeIfPresent(Bool.self, forKey: .showAnnotations) ?? showAnnotations
        viewport = try values.decodeIfPresent(Viewport.self, forKey: .viewport)
    }

    struct Viewport: Codable, Equatable {
        var revision: String
        var page: Int
        var zoom: Double
        var progress: Double
        var horizontalProgress: Double

        init?(revision: String, values: [String: Any]) {
            guard !revision.isEmpty, let page = values["page"] as? Int, page > 0,
                  let zoom = values["zoom"] as? Double, zoom.isFinite, (0.4...4).contains(zoom),
                  let progress = values["progress"] as? Double, progress.isFinite,
                  let horizontal = values["horizontalProgress"] as? Double, horizontal.isFinite else { return nil }
            self.revision = revision; self.page = page; self.zoom = zoom
            self.progress = min(1, max(0, progress)); horizontalProgress = min(1, max(0, horizontal))
        }
        func restoring(_ canonical: [String: Any], revision: String, independent: Bool = false) -> [String: Any] {
            if independent, self.revision == revision {
                return canonical.merging(["page": page, "zoom": zoom, "progress": progress, "horizontalProgress": horizontalProgress]) { _, value in value }
            }
            // A remote view-state update or a replaced PDF takes precedence.
            guard self.revision == revision, canonical["page"] as? Int == page,
                  let canonicalZoom = canonical["zoom"] as? Double, abs(canonicalZoom - zoom) < 0.00001 else { return canonical }
            return canonical.merging(["progress": progress, "horizontalProgress": horizontalProgress]) { _, value in value }
        }
    }

    static let tools = Set(["select", "lasso", "pen", "ballpoint", "highlighter", "eraser", "text"])
    static let lassoModes = Set(["freeform", "box"])
    static let colors = Set(["ink", "red", "orange", "yellow", "green", "blue", "violet"])
    static func key(root: URL, documentID: String, documentsRoot: URL? = nil) -> String {
        key(rootIdentity: NativePDFPreferenceScope.identity(root: root, documentsRoot: documentsRoot), documentID: documentID)
    }
    private static func key(rootIdentity: String, documentID: String) -> String {
        let identity = rootIdentity + "\u{0}" + documentID
        return "native-pdf.document.v1." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func storedData(root: URL, documentID: String, defaults: UserDefaults, documentsRoot: URL?) -> Data? {
        NativePDFPreferenceScope.storedData(root: root, stableKey: key(root: root, documentID: documentID, documentsRoot: documentsRoot), documentsRoot: documentsRoot, defaults: defaults,
            legacyKeys: { [key(rootIdentity: $0, documentID: documentID)] }, normalize: { data in
                guard let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return try? encoder.encode(value.validated())
            })
    }
    static func hasStored(root: URL, documentID: String, defaults: UserDefaults = .standard, documentsRoot: URL? = nil) -> Bool {
        storedData(root: root, documentID: documentID, defaults: defaults, documentsRoot: documentsRoot) != nil
    }
    static func load(root: URL, documentID: String, defaults: UserDefaults = .standard, documentsRoot: URL? = nil) -> Self {
        guard let data = storedData(root: root, documentID: documentID, defaults: defaults, documentsRoot: documentsRoot),
              let stored = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return stored.validated()
    }
    func save(root: URL, documentID: String, defaults: UserDefaults = .standard, documentsRoot: URL? = nil) {
        let key = Self.key(root: root, documentID: documentID, documentsRoot: documentsRoot)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(validated()), defaults.data(forKey: key) != data else { return }
        defaults.set(data, forKey: key)
    }
    func validated() -> Self {
        var value = self
        if !Self.tools.contains(tool) { value.tool = "pen" }
        if !Self.tools.contains(previousTool) { value.previousTool = "pen" }
        if !Self.colors.contains(color) { value.color = "ink" }
        if !Self.colors.contains(penColor) { value.penColor = "ink" }
        if !Self.colors.contains(highlighterColor) { value.highlighterColor = "yellow" }
        value.penStyle = penStyle.validated()
        value.highlighterStyle = highlighterStyle.validated(highlighter: true)
        value.ballpointStyle = ballpointStyle.validated()
        if !Self.lassoModes.contains(lassoMode) { value.lassoMode = "freeform" }
        let style = NativePDFPenPreset(color: value.color, width: width, opacity: opacity).validated(highlighter: value.tool == "highlighter")
        value.width = style.width; value.opacity = style.opacity
        if let viewport, !viewport.zoom.isFinite || !(0.4...4).contains(viewport.zoom) || viewport.page < 1 ||
            !viewport.progress.isFinite || !(0...1).contains(viewport.progress) ||
            !viewport.horizontalProgress.isFinite || !(0...1).contains(viewport.horizontalProgress) { value.viewport = nil }
        return value
    }
    var drawingStyle: [String: Any] {
        var style: [String: Any] = ["color": color, "width": tool == "highlighter" ? max(0.014, width * 4) : width,
                                    "opacity": tool == "highlighter" ? min(opacity, 0.34) : opacity]
        if tool == "ballpoint" { style["fixedWidth"] = true }
        return style
    }
}
