import UIKit
import WebKit

/// The shell contains both drawing surfaces and normal text fields. Prevent
/// nearby WebKit editors from stealing Pencil touches in the drawing regions.
@MainActor
final class DesktopScribblePolicy: NSObject, UIScribbleInteractionDelegate {
    private weak var view: WKWebView?
    private var revision = -1
    private var viewport = CGSize.zero
    private var protectedRegions: [CGRect] = []
    private var editors: [CGRect] = []
    private var controls: [CGRect] = []
    private var interactions: [UIScribbleInteraction] = []
    private var decisions = 0
    private var allowed = 0
    var onDiagnostic: (([String: Any]) -> Void)?

    var diagnostics: [String: Any] {
        let attached = interactions.compactMap(\.view)
        return ["attachedViews": attached.count, "textInputViews": attached.filter { $0 is UITextInput }.count,
                "regionRevision": revision, "protectedRegionCount": protectedRegions.count,
                "editorRegionCount": editors.count, "controlRegionCount": controls.count,
                "decisions": decisions, "allowed": allowed, "denied": decisions - allowed]
    }

    func attach(to view: WKWebView) {
        if self.view !== view {
            for interaction in interactions { interaction.view?.removeInteraction(interaction) }
            interactions.removeAll()
            reset()
        }
        self.view = view
        refreshAttachments()
    }

    /// WebKit owns an indirect Scribble interaction on its UITextInput content
    /// view. Add our public policy to that view as well as the shell. Do not
    /// remove WebKit interactions or depend on internal class names. A process
    /// replacement can recreate the content view, so every DOM layout refresh
    /// repeats this inexpensive, idempotent discovery.
    func refreshAttachments() {
        guard let view else { return }
        var candidates: [UIView] = [view], pending = view.subviews
        while let child = pending.popLast() {
            if child is UITextInput {
                candidates.append(child)
            }
            pending.append(contentsOf: child.subviews)
        }
        interactions.removeAll { interaction in
            guard let attached = interaction.view, candidates.contains(where: { $0 === attached }) else {
                interaction.view?.removeInteraction(interaction)
                return true
            }
            return false
        }
        for candidate in candidates where !interactions.contains(where: { $0.view === candidate }) {
            let interaction = UIScribbleInteraction(delegate: self)
            candidate.addInteraction(interaction)
            interactions.append(interaction)
        }
        onDiagnostic?(diagnostics)
    }

    func update(_ payload: [String: Any]) throws {
        guard let next = payload["revision"] as? Int, next > revision,
              let size = payload["viewport"] as? [String: Double],
              let width = size["width"], let height = size["height"],
              width.isFinite, height.isFinite, width > 0, height > 0, width < 20_000, height < 20_000,
              let blocked = payload["protected"] as? [[String: Double]], blocked.count <= 512,
              let allowed = payload["editors"] as? [[String: Double]], allowed.count <= 64 else { return }
        let buttons = payload["controls"] as? [[String: Double]] ?? []
        guard buttons.count <= 512 else { return }
        func rects(_ values: [[String: Double]]) throws -> [CGRect] {
            try values.map { value in
                guard let x = value["x"], let y = value["y"], let w = value["width"], let h = value["height"],
                      [x, y, w, h].allSatisfy(\.isFinite), x >= 0, y >= 0, w > 0, h > 0,
                      x + w <= width + 1, y + h <= height + 1 else { throw DesktopRuntimeError("Invalid Pencil input region") }
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        let newProtected = try rects(blocked), newEditors = try rects(allowed), newControls = try rects(buttons)
        revision = next; viewport = CGSize(width: width, height: height)
        protectedRegions = newProtected; editors = newEditors; controls = newControls
        refreshAttachments()
    }

    func reset() {
        revision = -1; viewport = .zero; protectedRegions = []; editors = []; controls = []
        refreshAttachments()
    }

    func permitsScribble(at location: CGPoint, in bounds: CGSize) -> Bool {
        guard revision >= 0, viewport.width > 0, bounds.width > 0 else { return false }
        // Resizing invalidates the published text exceptions. Fail closed until
        // the new DOM layout arrives, rather than write to the wrong editor.
        guard abs(bounds.width - viewport.width) < 2, abs(bounds.height - viewport.height) < 2 else { return false }
        // A projected text editor may overlap the floating style palette.
        // Tool controls always win over an editing exception beneath them.
        if controls.contains(where: { $0.contains(location) }) { return false }
        if protectedRegions.contains(where: { $0.contains(location) }) {
            return editors.contains(where: { $0.contains(location) })
        }
        return true
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        decisions += 1
        guard let view, let source = interaction.view, source === view || source.isDescendant(of: view) else {
            onDiagnostic?(diagnostics)
            return false
        }
        // UIKit reports points in the interaction's view, not the WKWebView.
        // Conversion includes the content view's scroll offset and transform.
        let point = source.convert(location, to: view)
        let result = permitsScribble(at: point, in: view.bounds.size)
        if result { allowed += 1 }
        onDiagnostic?(diagnostics)
        return result
    }
}
