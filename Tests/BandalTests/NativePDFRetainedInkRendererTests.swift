import XCTest
import UIKit
import Metal
@testable import Bandal

/// Offscreen GPU correctness only. Command completion/readback does not establish
/// an onscreen presentation deadline or physical Apple Pencil latency.
@MainActor
final class NativePDFRetainedInkRendererTests: XCTestCase {
    private typealias Renderer = NativePDFRetainedInkRenderer
    private let size = CGSize(width: 64, height: 64)

    func testOneStrokeUnionsCrossingAndRepeatedPolygonsBeforeApplyingOpacity() throws {
        let f = try Fixture()
        let horizontal = rectangle(8, 24, 48, 16)
        let vertical = rectangle(24, 8, 16, 48)
        // More than 255 writes to the same stencil sample must still represent
        // one stroke's union, never winding accumulation or wrapping.
        let polygons = Array(repeating: horizontal, count: 300) + [vertical]
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: polygons))
        let color = SIMD4<Float>(0, 0, 0.5, 0.5) // Premultiplied blue, alpha 1/2.
        let pixels = try f.render([.init(mesh: mesh, color: color)], logicalSize: size)
        assertPixel(pixels, x: 12, y: 30, rgba: [0, 0, 128, 128])
        assertPixel(pixels, x: 30, y: 12, rgba: [0, 0, 128, 128])
        assertPixel(pixels, x: 30, y: 30, rgba: [0, 0, 128, 128])
        assertPixel(pixels, x: 12, y: 12, rgba: [0, 0, 0, 0], tolerance: 0)
        XCTAssertEqual(f.renderer.meshUploadCount, 1)
        XCTAssertEqual(f.renderer.encodedPassCount, 1)
        XCTAssertEqual(f.renderer.lastItemCount, 1)
    }

    func testOrderedSourceOverAndHighlighterMultiplyAgainstNonwhitePaper() throws {
        let f = try Fixture()
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(8, 8, 48, 48)]))
        let paperBytes: [UInt8] = [60, 120, 180, 255] // RGBA, deliberately nonwhite.
        let paper = try f.solidTexture(rgba: paperBytes)
        let paperColor = paperBytes.map { Double($0) / 255 }
        let red = SIMD4<Float>(0.5, 0, 0, 0.5)
        let blue = SIMD4<Float>(0, 0, 0.5, 0.5)
        let cyan = SIMD4<Float>(0, 0.4, 0.4, 0.4)
        let redItem = Renderer.Item(mesh: mesh, color: red)
        let blueItem = Renderer.Item(mesh: mesh, color: blue)
        let cyanItem = Renderer.Item(mesh: mesh, color: cyan, multiply: true)

        let normal = try f.render([redItem, blueItem], backdrop: paper, logicalSize: size)
        assertPixel(normal, x: 32, y: 32, rgba: bytes(over(blue, over(red, paperColor))))
        assertPixel(normal, x: 2, y: 2, rgba: paperBytes, tolerance: 0)
        let highlighted = try f.render([redItem, cyanItem, blueItem], backdrop: paper, logicalSize: size)
        assertPixel(highlighted, x: 32, y: 32,
                    rgba: bytes(over(blue, multiply(cyan, over(red, paperColor)))))
        let reordered = try f.render([cyanItem, redItem, blueItem], backdrop: paper, logicalSize: size)
        assertPixel(reordered, x: 32, y: 32,
                    rgba: bytes(over(blue, over(red, multiply(cyan, paperColor)))))
        XCTAssertNotEqual(pixel(highlighted, x: 32, y: 32), pixel(reordered, x: 32, y: 32),
                          "The reference must distinguish changing the highlighter's z order")
        XCTAssertEqual(f.renderer.meshUploadCount, 1)
        XCTAssertEqual(f.renderer.encodedPassCount, 3, "One render pass per encode, independent of item count")
        XCTAssertEqual(f.renderer.lastItemCount, 3)
    }

    func testMoreThanThreeHundredOverlappingStrokesDoNotWrapOrLeakStencil() throws {
        let f = try Fixture()
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(8, 8, 48, 48)]))
        let red = SIMD4<Float>(0.25, 0, 0, 0.25)
        var items = Array(repeating: Renderer.Item(mesh: mesh, color: red), count: 320)
        let blue = SIMD4<Float>(0, 0, 0.5, 0.5)
        items.append(.init(mesh: mesh, color: blue))
        let image = try f.render(items, logicalSize: size)
        assertPixel(image, x: 32, y: 32, rgba: [128, 0, 128, 255])
        assertPixel(image, x: 2, y: 2, rgba: [0, 0, 0, 0], tolerance: 0)
        XCTAssertEqual(f.renderer.lastItemCount, 321)
        XCTAssertEqual(f.renderer.encodedPassCount, 1)
        XCTAssertEqual(f.renderer.meshUploadCount, 1)

        // Reusing the target for an empty scene must not retain old color/stencil.
        let cleared = try f.render([], logicalSize: size)
        XCTAssertTrue(cleared.allSatisfy { $0 == 0 })
        XCTAssertEqual(f.renderer.lastItemCount, 0)
        XCTAssertEqual(f.renderer.meshUploadCount, 1)
    }

    func testRemovingAndReorderingItemsChangesPixelsWithoutUploadingMeshesAgain() throws {
        let f = try Fixture()
        let a = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(8, 8, 32, 32)]))
        let b = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(24, 24, 32, 32)]))
        let red = Renderer.Item(mesh: a, color: SIMD4<Float>(0.5, 0, 0, 0.5))
        let blue = Renderer.Item(mesh: b, color: SIMD4<Float>(0, 0, 0.5, 0.5))
        let uploaded = f.renderer.meshUploadCount
        XCTAssertEqual(uploaded, 2)
        let ab = try f.render([red, blue], logicalSize: size)
        assertPixel(ab, x: 30, y: 30, rgba: [64, 0, 128, 191])
        let ba = try f.render([blue, red], logicalSize: size)
        assertPixel(ba, x: 30, y: 30, rgba: [128, 0, 64, 191])
        let onlyB = try f.render([blue], logicalSize: size)
        assertPixel(onlyB, x: 12, y: 12, rgba: [0, 0, 0, 0], tolerance: 0)
        assertPixel(onlyB, x: 30, y: 30, rgba: [0, 0, 128, 128])
        let restored = try f.render([red, blue], logicalSize: size)
        XCTAssertEqual(restored, ab, "Restoring the original ordered immutable meshes restores every target byte")
        XCTAssertEqual(f.renderer.meshUploadCount, uploaded)
        XCTAssertEqual(f.renderer.encodedPassCount, 4)
    }

    func testPanAndScaleChangeOnlyUniformsWithAnalyticInteriorCoverage() throws {
        let f = try Fixture()
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(4, 4, 8, 8)]))
        let color = SIMD4<Float>(0, 1, 0, 1)
        let original = try f.render([.init(mesh: mesh, color: color)], logicalSize: size)
        assertPixel(original, x: 8, y: 8, rgba: [0, 255, 0, 255], tolerance: 0)
        let pan = CGAffineTransform(translationX: 20, y: 12)
        let moved = try f.render([.init(mesh: mesh, color: color, transform: pan)], logicalSize: size)
        assertPixel(moved, x: 28, y: 20, rgba: [0, 255, 0, 255], tolerance: 0)
        assertPixel(moved, x: 8, y: 8, rgba: [0, 0, 0, 0], tolerance: 0)
        let scale = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 16, ty: 8)
        let zoomed = try f.render([.init(mesh: mesh, color: color, transform: scale)], logicalSize: size)
        assertPixel(zoomed, x: 26, y: 18, rgba: [0, 255, 0, 255], tolerance: 0)
        assertPixel(zoomed, x: 38, y: 30, rgba: [0, 255, 0, 255], tolerance: 0)
        assertPixel(zoomed, x: 42, y: 30, rgba: [0, 0, 0, 0], tolerance: 0)
        let restored = try f.render([.init(mesh: mesh, color: color)], logicalSize: size)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(f.renderer.meshUploadCount, 1)
    }

    func testGeometryOutsideViewportProducesNoPixelsAndPartiallyVisibleGeometryClips() throws {
        let f = try Fixture()
        let outside = try XCTUnwrap(f.renderer.makeMesh(convexPolygons:
            [rectangle(-30, -30, 10, 10), rectangle(90, 90, 10, 10)]))
        let color = SIMD4<Float>(1, 0, 0, 1)
        let empty = try f.render([.init(mesh: outside, color: color)], logicalSize: size)
        XCTAssertTrue(empty.allSatisfy { $0 == 0 })
        let partial = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(-8, 16, 24, 24)]))
        let clipped = try f.render([.init(mesh: partial, color: color)], logicalSize: size)
        assertPixel(clipped, x: 2, y: 24, rgba: [255, 0, 0, 255], tolerance: 0)
        assertPixel(clipped, x: 20, y: 24, rgba: [0, 0, 0, 0], tolerance: 0)
        XCTAssertEqual(f.renderer.meshUploadCount, 2)
    }

    private func rectangle(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
         CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
    }
    private func over(_ source: SIMD4<Float>, _ destination: [Double]) -> [Double] {
        let a = Double(source.w), s = [Double(source.x), Double(source.y), Double(source.z)]
        return (0..<3).map { s[$0] + destination[$0] * (1 - a) } + [a + destination[3] * (1 - a)]
    }
    private func multiply(_ source: SIMD4<Float>, _ destination: [Double]) -> [Double] {
        let a = Double(source.w), s = [Double(source.x), Double(source.y), Double(source.z)]
        // This oracle intentionally covers an opaque destination: highlighter
        // color is premultiplied and multiply is D * (1 - alpha + S).
        return (0..<3).map { destination[$0] * (1 - a + s[$0]) } + [1]
    }
    private func bytes(_ rgba: [Double]) -> [UInt8] {
        rgba.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
    }
    private func pixel(_ bgra: [UInt8], x: Int, y: Int) -> [UInt8] {
        let offset = (y * 64 + x) * 4
        return [bgra[offset + 2], bgra[offset + 1], bgra[offset], bgra[offset + 3]]
    }
    private func assertPixel(_ image: [UInt8], x: Int, y: Int, rgba expected: [UInt8], tolerance: Int = 2,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = pixel(image, x: x, y: y)
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), tolerance,
                "Pixel (\(x),\(y)) RGBA channel \(channel): \(actual) vs \(expected)", file: file, line: line)
        }
    }

    @MainActor
    private final class Fixture {
        let device: MTLDevice
        let renderer: Renderer
        let queue: MTLCommandQueue
        let target: MTLTexture
        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
            self.device = device
            renderer = try XCTUnwrap(Renderer(device: device), "The retained renderer must initialize on a Metal device")
            queue = try XCTUnwrap(device.makeCommandQueue())
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 64, height: 64, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
            target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        func solidTexture(rgba: [UInt8]) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 64, height: 64, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let bgra = [rgba[2], rgba[1], rgba[0], rgba[3]]
            let bytes = Array(repeating: bgra, count: 64 * 64).flatMap { $0 }
            bytes.withUnsafeBytes { buffer in
                texture.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0,
                                withBytes: buffer.baseAddress!, bytesPerRow: 64 * 4)
            }
            return texture
        }
        func render(_ items: [Renderer.Item], backdrop: MTLTexture? = nil, logicalSize: CGSize) throws -> [UInt8] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encode(items: items, backdrop: backdrop, into: target,
                                           command: command, logicalSize: logicalSize))
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "GPU command failed: \(String(describing: command.error))")
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            bytes.withUnsafeMutableBytes { buffer in
                target.getBytes(buffer.baseAddress!, bytesPerRow: 64 * 4,
                                from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            }
            return bytes
        }
    }
}
