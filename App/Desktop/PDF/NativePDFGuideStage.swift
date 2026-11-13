import PDFKit
import UIKit

/// 짚어주기 on the PDF host: finds a quoted passage's lines on its page, brings them into view and says where
/// they are on screen. It only moves the view: nothing is drawn into the page, selected, marked or saved.
/// Rectangles cross the host as `[x, y, width, height]`, normalised to the displayed page from the top left
/// (as search marks and handwriting boxes are), or in the PDF body's own points for `frames`.
@MainActor
enum NativePDFGuideStage {
    /// What stays clear at the top of the view: the floating palette and a margin under it.
    static let comfortTop = NativePDFFloatingPalette.top + NativePDFFloatingPalette.height + 16

    static func run(_ request: [String: Any], view: PDFView, scroll: UIScrollView?, document: PDFDocument) throws -> [String: Any] {
        // A page the document does not have is a step with nothing to point at (an empty answer), not a failure:
        // a thrown error tells the player the surface is gone.
        guard let number = request["page"] as? Int, number >= 1, let page = document.page(at: number - 1) else { return [:] }
        let coordinates = NativePDFPageCoordinates(page: page)
        switch request["action"] as? String {
        case "locate":
            // The page's own text; the caller tries recognised handwriting when this finds nothing.
            guard let text = page.string,
                  let range = NativePDFGuideResolver.pick(NativePDFGuideResolver.ranges(of: request["quote"] as? String ?? "", in: text), after: request["after"] as? Int),
                  let selection = page.selection(for: range) else { return ["rects": [[Double]]()] }
            let rects = selection.selectionsByLine().filter { $0.pages.contains(page) }.compactMap { line -> [Double]? in
                let rect = coordinates.normalizedRect(line.bounds(for: page))
                guard let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"], width > 0, height > 0 else { return nil }
                return [x, y, width, height]
            }
            return ["rects": rects, "location": range.location]
        case "show":
            guard let scroll else { return ["settle": 0.0] }
            let jumped = jumpIfFar(to: page, number: number, view: view, document: document)
            let comfort = comfortArea(view)
            let frames = viewRects(request["rects"], page: page, coordinates: coordinates, view: view)
            var delta = CGPoint.zero
            if let focus = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) {
                // Up into the top third, leaving room under it for the caption.
                let fits = focus.height <= comfort.height * 0.6
                if focus.minY < comfort.minY || focus.maxY > comfort.maxY || (fits && focus.maxY > comfort.minY + comfort.height * 0.72) {
                    delta.y = focus.minY - (fits ? comfort.minY + comfort.height * 0.28 : comfort.minY)
                }
                if focus.minX < comfort.minX || focus.maxX > comfort.maxX {
                    delta.x = focus.width <= comfort.width ? focus.midX - comfort.midX : focus.minX - comfort.minX
                }
            } else {
                // A passage that could not be found: the page itself, from its top, unless most of it is in view.
                let whole = view.convert(page.bounds(for: view.displayBox), from: page)
                if whole.intersection(comfort).height < comfort.height * 0.5 { delta.y = whole.minY - comfort.minY }
            }
            let settle = glide(scroll, by: delta, view: view)
            return ["settle": max(settle, jumped ? 0.06 : 0)]
        case "frames":
            let container = view.superview ?? view
            return ["frames": viewRects(request["rects"], page: page, coordinates: coordinates, view: view).map { rect in
                let frame = view.convert(rect, to: container)
                return [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            }]
        case "restore":
            // The saved viewport's meaning (`navigate`): that point of the page at the view's centre.
            guard let scroll else { return ["settle": 0.0] }
            let jumped = jumpIfFar(to: page, number: number, view: view, document: document)
            let x = min(1, max(0, request["horizontalProgress"] as? Double ?? 0.5)), y = min(1, max(0, request["progress"] as? Double ?? 0))
            let point = view.convert(coordinates.pdfPoint(CGPoint(x: x, y: y)), from: page)
            let settle = glide(scroll, by: CGPoint(x: point.x - view.bounds.midX, y: point.y - view.bounds.midY), view: view)
            return ["settle": max(settle, jumped ? 0.06 : 0)]
        default: throw NativePDFError.invalid("알 수 없는 짚어주기 작업입니다.")
        }
    }

    /// The view less the palette band and margins: where a passage reads comfortably.
    private static func comfortArea(_ view: PDFView) -> CGRect {
        view.bounds.inset(by: UIEdgeInsets(top: min(comfortTop, view.bounds.height * 0.3), left: 16, bottom: 24, right: 16))
    }

    /// A page more than one away is jumped to, so the glide after it stays short.
    private static func jumpIfFar(to page: PDFPage, number: Int, view: PDFView, document: PDFDocument) -> Bool {
        guard let current = view.page(for: CGPoint(x: view.bounds.midX, y: view.bounds.midY), nearest: true),
              abs(document.index(for: current) - (number - 1)) > 1 else { return false }
        view.go(to: page); view.layoutIfNeeded()
        return true
    }

    /// Scrolls by `delta` within the content (clamped as `navigate` clamps); animated unless it is far.
    /// Returns how long to wait before the view is where it is going.
    private static func glide(_ scroll: UIScrollView, by delta: CGPoint, view: PDFView) -> Double {
        let inset = scroll.adjustedContentInset, offset = scroll.contentOffset
        let minY = -inset.top, maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let minX = -inset.left, maxX = max(minX, scroll.contentSize.width - scroll.bounds.width + inset.right)
        let target = CGPoint(x: min(maxX, max(minX, offset.x + delta.x)), y: min(maxY, max(minY, offset.y + delta.y)))
        guard abs(target.x - offset.x) > 0.5 || abs(target.y - offset.y) > 0.5 else { return 0 }
        let animated = !UIAccessibility.isReduceMotionEnabled && abs(target.y - offset.y) < view.bounds.height * 2.5
        scroll.setContentOffset(target, animated: animated)
        return animated ? 0.38 : 0.06
    }

    private static func viewRects(_ raw: Any?, page: PDFPage, coordinates: NativePDFPageCoordinates, view: PDFView) -> [CGRect] {
        (raw as? [[Double]] ?? []).compactMap { value in
            guard value.count == 4, value.allSatisfy(\.isFinite), value[2] > 0, value[3] > 0 else { return nil }
            let a = coordinates.pdfPoint(CGPoint(x: value[0], y: value[1])), b = coordinates.pdfPoint(CGPoint(x: value[0] + value[2], y: value[1] + value[3]))
            return view.convert(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)), from: page)
        }
    }
}
