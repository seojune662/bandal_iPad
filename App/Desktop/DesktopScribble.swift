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

    func attach(to view: WKWebView) {
        self.view = view
        view.addInteraction(UIScribbleInteraction(delegate: self))
    }

    func update(_ payload: [String: Any]) throws {
        guard let next = payload["revision"] as? Int, next > revision,
              let size = payload["viewport"] as? [String: Double],
              let width = size["width"], let height = size["height"],
              width.isFinite, height.isFinite, width > 0, height > 0, width < 20_000, height < 20_000,
              let blocked = payload["protected"] as? [[String: Double]], blocked.count <= 512,
              let allowed = payload["editors"] as? [[String: Double]], allowed.count <= 64 else { return }
        func rects(_ values: [[String: Double]]) throws -> [CGRect] {
            try values.map { value in
                guard let x = value["x"], let y = value["y"], let w = value["width"], let h = value["height"],
                      [x, y, w, h].allSatisfy(\.isFinite), x >= 0, y >= 0, w > 0, h > 0,
                      x + w <= width + 1, y + h <= height + 1 else { throw DesktopRuntimeError("Invalid Pencil input region") }
                return CGRect(x: x, y: y, width: w, height: h)
            }
        }
        let newProtected = try rects(blocked), newEditors = try rects(allowed)
        revision = next; viewport = CGSize(width: width, height: height)
        protectedRegions = newProtected; editors = newEditors
    }

    func reset() { revision = -1; viewport = .zero; protectedRegions = []; editors = [] }

    func permitsScribble(at location: CGPoint, in bounds: CGSize) -> Bool {
        guard revision >= 0, viewport.width > 0, bounds.width > 0 else { return false }
        // Resizing invalidates the published text exceptions. Fail closed until
        // the new DOM layout arrives, rather than write to the wrong editor.
        guard abs(bounds.width - viewport.width) < 2, abs(bounds.height - viewport.height) < 2 else { return false }
        if protectedRegions.contains(where: { $0.contains(location) }) {
            return editors.contains(where: { $0.contains(location) })
        }
        return true
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        guard let view else { return false }
        return permitsScribble(at: location, in: view.bounds.size)
    }
}
