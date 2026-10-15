import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFRetainedInkSurfaceTests: XCTestCase {
    func testTwoHundredStrokesDeleteWithoutRasterOrReuploadAndStayRegisteredDuringViewportChanges() async throws {
        let ready = await NativePDFAsynchronousEditTests.poll(timeout: 3) {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        XCTAssertTrue(ready)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded()
        let size = window.bounds.size, bounds = CGRect(origin: .zero, size: size)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { $0.beginPage() }
        let pdf = try XCTUnwrap(PDFDocument(data: data)), page = try XCTUnwrap(pdf.page(at: 0))
        var cropRequests = 0, inputWrites = 0
        let surface = try XCTUnwrap(NativePDFInkSurface(nativeFrame: bounds, navigationRasterRequest: { _ in cropRequests += 1 }))
        let metal = try XCTUnwrap(surface.subviews.compactMap { $0 as? NativePDFMetalInk }.first)
        surface.retainedInkEnabled = true
        surface.pdfPage = page; surface.mapper = .whiteboard(size: size); surface.isLoading = false
        surface.tool = .init(name: "eraser", style: .init(color: "blue", width: 0.008, opacity: 1))
        surface.onStroke = { _ in inputWrites += 1 }
        surface.onCheckpoint = { _ in inputWrites += 1 }
        surface.onFailure = { XCTFail("Unexpected retained display failure: \($0)") }
        var rows: [[String: Any]] = (0..<200).map { index in
            let column = Double(index % 8), row = Double(index / 8)
            let points: [[String: Double]] = (0..<96).map { point in
                let t = Double(point)/95
                return ["x": 0.02 + column*0.12 + t*0.095,
                    "y": 0.035 + row*0.037 + sin(t*Double.pi*4)*0.008,
                    "p": 0.2 + t*0.6, "t": Double(point)*4]
            }
            let marker = index.isMultiple(of: 7)
            return ["id": "latency-\(index)", "clientMutationId": "latency-\(index)", "page": 1,
                "kind": marker ? "highlighter" : "ink", "data": ["inkVersion": 4, "points": points],
                "style": ["color": marker ? "yellow" : "blue", "width": marker ? 0.012 : 0.0025, "opacity": marker ? 0.24 : 0.45]]
        }
        for index in rows.indices { rows[index]["_nativeInk"] = try XCTUnwrap(NativePDFObjectRenderer.prepareInk(rows[index], aspect: size.height/size.width)) }
        var tokens = rows.map(NativePDFCommittedVisualToken.init)
        surface.applyObjects(objects: rows, visualTokens: tokens)
        window.rootViewController!.view.addSubview(surface); window.layoutIfNeeded(); surface.layoutIfNeeded()
        try await settled(surface)
        XCTAssertEqual(cropRequests, 0)
        XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, 0)
        XCTAssertEqual(surface.inputDiagnostics["retainedInkMeshes"] as? Int, 200)
        let renderer = try XCTUnwrap(metal.retainedRenderer), uploads = renderer.meshUploadCount
        let paperRasters = surface.inputDiagnostics["retainedPaperRasters"] as? Int
        XCTAssertEqual(paperRasters, 1)
        let original = try XCTUnwrap(metal.renderedPixels(width: 1024, height: 1024))
        var timings: [Double] = []
        for index in 84..<94 {
            let position = try XCTUnwrap(rows.firstIndex { $0["id"] as? String == "latency-\(index)" })
            rows.remove(at: position); tokens.remove(at: position)
            let count = metal.submittedFrameCount, start = CACurrentMediaTime()
            surface.applyObjects(objects: rows, visualTokens: tokens)
            let submitted = await NativePDFAsynchronousEditTests.poll(timeout: 3) { metal.submittedFrameCount > count }
            XCTAssertTrue(submitted)
            timings.append((CACurrentMediaTime() - start)*1000)
            XCTAssertEqual(renderer.meshUploadCount, uploads)
            XCTAssertEqual(cropRequests, 0)
            XCTAssertEqual(surface.inputDiagnostics["sceneFullRenders"] as? Int, 0)
            XCTAssertEqual(surface.inputDiagnostics["retainedPaperRasters"] as? Int, paperRasters)
        }
        try await settled(surface)
        XCTAssertEqual(metal.retainedItems?.count, 190)
        let after = try XCTUnwrap(metal.renderedPixels(width: 1024, height: 1024))
        // Stroke 84 is a wide yellow stroke on blank paper; its own interior
        // changes to opaque white, while the neighboring row remains intact.
        let px = Int((0.02 + 4*0.12 + 0.0475)*1024), py = Int((0.035 + 10*0.037)*1024)
        func pixel(_ bytes: Data, _ x: Int, _ y: Int) -> [UInt8] { Array(bytes[(y*1024+x)*4..<(y*1024+x+1)*4]) }
        XCTAssertNotEqual(pixel(original, px, py), [255,255,255,255])
        XCTAssertEqual(pixel(after, px, py), [255,255,255,255])
        XCTAssertEqual(pixel(original, px, Int((0.035+9*0.037)*1024)), pixel(after, px, Int((0.035+9*0.037)*1024)))
        let count = metal.submittedFrameCount
        surface.viewportProvider = { CGRect(x: 100, y: 90, width: size.width-200, height: size.height-180) }
        surface.refreshViewport()
        let moved = await NativePDFAsynchronousEditTests.poll(timeout: 3) { metal.submittedFrameCount > count }
        XCTAssertTrue(moved)
        XCTAssertEqual(renderer.meshUploadCount, uploads)
        XCTAssertEqual(cropRequests, 0)
        XCTAssertEqual(surface.inputDiagnostics["retainedPaperRasters"] as? Int, paperRasters)
        XCTAssertEqual(inputWrites, 0)
        let payload: [String: Any] = ["scope": "Native Surface row delivery to GPU submission; no JS or physical presentation timing", "rows": 200, "deletions": 10, "applyToSubmitMS": timings, "cropRequests": cropRequests, "meshUploads": uploads]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "RETAINED-ERASURE-LATENCY.json"; attachment.lifetime = .keepAlways; add(attachment)
        print("[RETAINED_ERASURE_LATENCY] \(String(decoding: json, as: UTF8.self))")
    }
    private func settled(_ surface: NativePDFInkSurface) async throws {
        let ready = await NativePDFAsynchronousEditTests.poll(timeout: 10) {
            (surface.inputDiagnostics["retainedInkInstalls"] as? Int ?? 0) > 0 && surface.inputDiagnostics["frameRequested"] as? Bool == false
        }
        XCTAssertTrue(ready)
        if !ready { throw NSError(domain: "RetainedSurfaceTimeout", code: 1) }
    }
}
