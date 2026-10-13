import XCTest
import UIKit
@testable import Bandal

final class DesktopMarketMediaTests: XCTestCase {
    func testPickedCameraImageIsBoundedAndRasterizedToPNG() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 1800), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1800))
        }
        let result = try DesktopMarketMedia.preview(source.jpegData(compressionQuality: 0.8)!, pickedImage: true)
        XCTAssertEqual(Array(result.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let output = try XCTUnwrap(UIImage(data: result)?.cgImage)
        XCTAssertEqual(output.width, 1600); XCTAssertEqual(output.height, 900)
        XCTAssertLessThanOrEqual(result.count, 4 * 1024 * 1024)
        XCTAssertNoThrow(try DesktopMarketMedia.preview(result, pickedImage: false))
    }
    func testRenderedPreviewRejectsNonPNGAndOversizedDimensions() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2050, height: 1), format: format).image { $0.fill(CGRect(x: 0, y: 0, width: 2050, height: 1)) }
        XCTAssertThrowsError(try DesktopMarketMedia.preview(source.pngData()!, pickedImage: false))
        XCTAssertThrowsError(try DesktopMarketMedia.preview(source.jpegData(compressionQuality: 0.8)!, pickedImage: false))
        XCTAssertThrowsError(try DesktopMarketMedia.preview(Data("<svg onload='alert(1)'/>".utf8), pickedImage: true))
    }
}
