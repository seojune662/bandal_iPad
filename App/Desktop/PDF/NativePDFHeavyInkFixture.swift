#if DEBUG
import Foundation
import UIKit

@MainActor
enum NativePDFHeavyInkFixture {
    /// Uses the normal canonical writer inside the isolated UI-test document.
    /// Short strokes cover the full page so scrolling reveals previously
    /// offscreen ink rather than repeatedly testing an empty paper viewport.
    static func seed(runtime: DesktopRuntime, courseID: String, relativePath: String) async throws {
        for index in 0..<200 {
            let x = 0.035 + Double(index % 8) * 0.12
            let y = 0.075 + Double(index / 8) * 0.033
            let points = (0..<96).map { sample -> [String: Double] in
                let t = Double(sample) / 95
                return ["x": x + t * 0.085, "y": y + sin(t * .pi * 4) * 0.009,
                        "p": 0.25 + t * 0.6, "t": Double(sample) * 4]
            }
            let highlighter = index.isMultiple(of: 8)
            _ = try await runtime.invoke("drawings:create", request: [
                "courseId": courseID, "relPath": relativePath, "page": 1,
                "kind": highlighter ? "highlighter" : "ink",
                "data": ["inkVersion": 4, "points": points],
                "style": ["color": highlighter ? "yellow" : "blue",
                          "width": highlighter ? 0.009 : 0.0018,
                          "opacity": highlighter ? 0.4 : 1.0]])
        }
    }

    /// A separate launch-flag fixture: retain the original 200 modern strokes,
    /// then add four independently textured objects through canonical writers.
    /// The image is generated/imported inside the isolated UI-test library;
    /// it is a valid local material, not a network URL or user-owned document.
    static func seedMixed(runtime: DesktopRuntime, courseID: String, relativePath: String) async throws {
        try await seed(runtime: runtime, courseID: courseID, relativePath: relativePath)
        let folder = runtime.root.appendingPathComponent("Temporary/Imports/PDFMixedInkFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageURL = folder.appendingPathComponent("Mixed fixture image.png")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
            UIColor.systemYellow.setFill(); context.fill(CGRect(x: 8, y: 6, width: 16, height: 12))
        }
        guard let png = image.pngData() else { throw DesktopRuntimeError("혼합 필기 테스트 이미지를 생성하지 못했습니다.") }
        try png.write(to: imageURL, options: .atomic)
        let imported = try await runtime.invoke("materials:import", request: ["courseId": courseID, "paths": [imageURL.path]]) as? [String: Any]
        guard let imagePath = (imported?["imported"] as? [String])?.first else {
            throw DesktopRuntimeError("혼합 필기 테스트 이미지를 가져오지 못했습니다.")
        }
        let rows: [[String: Any]] = [
            ["kind": "textbox", "data": ["box": ["x": 0.2, "y": 0.25, "width": 0.6, "height": 0.45],
                 "text": "Mixed native eraser fixture"],
             "style": ["color": "red", "width": 0.004, "opacity": 0.8, "fontSizePt": 14]],
            ["kind": "rect", "data": ["box": ["x": 0.3, "y": 0.35, "width": 0.4, "height": 0.3]],
             "style": ["color": "violet", "width": 0.004, "opacity": 0.8]],
            // No inkVersion: exercise the historical SVG/nativePath texture,
            // its independent raw-polyline eraser geometry, and multiply order.
            ["kind": "highlighter", "data": ["points": [
                 ["x": 0.25, "y": 0.55, "p": 0.4], ["x": 0.5, "y": 0.55, "p": 0.6], ["x": 0.75, "y": 0.55, "p": 0.5]]],
             "style": ["color": "yellow", "width": 0.02, "opacity": 0.3]],
            ["kind": "image", "data": ["box": ["x": 0.77, "y": 0.12, "width": 0.16, "height": 0.12],
                 "image": ["relPath": imagePath, "label": "Mixed fixture image"]],
             "style": ["color": "ink", "width": 0.004, "opacity": 1.0]]
        ]
        for row in rows {
            var input = row
            input["courseId"] = courseID; input["relPath"] = relativePath; input["page"] = 1
            _ = try await runtime.invoke("drawings:create", request: input)
        }
    }
}
#endif
