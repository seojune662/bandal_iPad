#if DEBUG
import CoreText
import UIKit

/// Test ink: the outlines of typeset text as pen strokes. It stands in for handwriting in unit tests
/// and UI-test fixtures only; real recognition quality is measured on real notes.
enum NativeHandwritingFixture {
    /// `drawings:create` data/style pairs writing `text` with its baseline starting at `origin` (page points, top-left origin).
    static func strokes(_ text: String, at origin: CGPoint, fontSize: CGFloat, pageSize: CGSize, color: String = "ink") -> [[String: Any]] {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var result: [[String: Any]] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                for outline in polylines(path) {
                    let points = outline.map { point -> [String: Any] in
                        ["x": min(1, max(0, (origin.x + position.x + point.x) / pageSize.width)),
                         "y": min(1, max(0, (origin.y - position.y - point.y) / pageSize.height)), "p": 0.5]
                    }
                    guard points.count > 1 else { continue }
                    result.append(["data": ["inkVersion": 5, "points": points], "style": ["color": color, "width": 0.0025, "opacity": 1.0]])
                }
            }
        }
        return result
    }

    private static func polylines(_ path: CGPath) -> [[CGPoint]] {
        var lines: [[CGPoint]] = [], current: [CGPoint] = []
        func curve(_ from: CGPoint, _ controls: [CGPoint], _ to: CGPoint) {
            for step in 1...6 {
                let t = CGFloat(step) / 6, u = 1 - t
                if controls.count == 1 {
                    current.append(CGPoint(x: u * u * from.x + 2 * u * t * controls[0].x + t * t * to.x, y: u * u * from.y + 2 * u * t * controls[0].y + t * t * to.y))
                } else {
                    current.append(CGPoint(x: u * u * u * from.x + 3 * u * u * t * controls[0].x + 3 * u * t * t * controls[1].x + t * t * t * to.x,
                                           y: u * u * u * from.y + 3 * u * u * t * controls[0].y + 3 * u * t * t * controls[1].y + t * t * t * to.y))
                }
            }
        }
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: if current.count > 1 { lines.append(current) }; current = [points[0]]
            case .addLineToPoint: current.append(points[0])
            case .addQuadCurveToPoint: curve(current.last ?? points[0], [points[0]], points[1])
            case .addCurveToPoint: curve(current.last ?? points[0], [points[0], points[1]], points[2])
            case .closeSubpath: if let first = current.first { current.append(first) }; lines.append(current); current = []
            @unknown default: break
            }
        }
        if current.count > 1 { lines.append(current) }
        return lines
    }
}
#endif
