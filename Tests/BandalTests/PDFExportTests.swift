import XCTest
import PDFKit
import UIKit
@testable import Bandal

@MainActor
final class PDFExportTests: XCTestCase {
    func testImageExportRetainsTextCropBoxRotationAndImagePixels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("source.pdf")
        let imageURL = directory.appendingPathComponent("asset.png")
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
            context.beginPage()
            "Preserved PDF text".draw(at: CGPoint(x: 70, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        let source = try XCTUnwrap(PDFDocument(data: pdf))
        source.page(at: 0)?.rotation = 90
        source.page(at: 0)?.setBounds(CGRect(x: 20, y: 30, width: 560, height: 740), for: .cropBox)
        XCTAssertTrue(source.write(to: original))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let png = try XCTUnwrap(image.pngData())
        var records: [Int: Data] = [:]
        var exportedURL: URL?
        let controller = PDFWorkspaceController(documentURL: original, materialID: "material", revision: "revision",
            loadPage: { records[$0] }, savePage: { records[$0] = $1 }, onExport: { exportedURL = $0 },
            resolveImage: { _ in imageURL }, saveImage: { data in
                try? data.write(to: imageURL)
                return InkImageSource(relPath: "asset.png", label: "Image", assetId: "asset")
            })
        controller.insertImage(png)
        XCTAssertNil(controller.warning)
        let stored = try JSONDecoder().decode(PortableInkPageRecord.self, from: XCTUnwrap(records[1]))
        XCTAssertEqual(stored.objects.first?.data.image?.assetId, "asset")
        controller.exportPDF()
        XCTAssertNil(controller.warning)
        let outputURL = try XCTUnwrap(exportedURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try XCTUnwrap(PDFDocument(url: outputURL))
        XCTAssertTrue(output.string?.contains("Preserved PDF text") == true)
        let page = try XCTUnwrap(output.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 740, accuracy: 0.1)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 560, accuracy: 0.1)
        let thumbnail = try XCTUnwrap(page.thumbnail(of: CGSize(width: 200, height: 200), for: .mediaBox).cgImage)
        var pixels = [UInt8](repeating: 0, count: thumbnail.width * thumbnail.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: thumbnail.width, height: thumbnail.height,
            bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
        let center = ((thumbnail.height / 2) * thumbnail.width + thumbnail.width / 2) * 4
        XCTAssertGreaterThan(pixels[center], 200)
        XCTAssertLessThan(pixels[center + 1], 80)
        XCTAssertLessThan(pixels[center + 2], 80)
    }
}
