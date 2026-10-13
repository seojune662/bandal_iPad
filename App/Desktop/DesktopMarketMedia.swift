import ImageIO
import UIKit
import UniformTypeIdentifiers

enum DesktopMarketMedia {
    /// Decode a bounded source and flatten orientation/metadata into a new PNG.
    /// ImageIO thumbnails avoid allocating full camera-resolution bitmaps.
    static func preview(_ data: Data, pickedImage: Bool) throws -> Data {
        let maximum = pickedImage ? 10 * 1024 * 1024 : 4 * 1024 * 1024
        guard data.count <= maximum,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000 else {
            throw DesktopRuntimeError("미리보기 이미지를 읽지 못했습니다.")
        }
        if !pickedImage {
            guard CGImageSourceGetType(source) as String? == UTType.png.identifier, width <= 2048, height <= 2048 else {
                throw DesktopRuntimeError("미리보기는 가로·세로 2048픽셀 이하의 PNG여야 합니다.")
            }
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pickedImage ? 1600 : 2048, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = UIImage(cgImage: image).pngData(), png.count <= 4 * 1024 * 1024 else {
            throw DesktopRuntimeError("미리보기 이미지는 4MB까지 사용할 수 있습니다.")
        }
        return png
    }
}
