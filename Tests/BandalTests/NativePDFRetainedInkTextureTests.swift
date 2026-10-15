import XCTest
import UIKit
import Metal
@testable import Bandal

/// Offscreen actual GPU pixels. These tests do not measure compositor cadence,
/// physical Pencil latency, or Core Graphics object-recording fidelity.
@MainActor
final class NativePDFRetainedInkTextureTests: XCTestCase {
    private typealias Renderer = NativePDFRetainedInkRenderer
    private let fullUV = CGAffineTransform(scaleX: 64, y: 64)

    func testOrderedMeshTextureHighlighterMeshPreservesPremultiplicationAndReusesResources() throws {
        let f = try Fixture()
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(8, 8, 48, 48)]))
        let bytes = image(width: 64, height: 64) { x, y in
            (12..<52).contains(x) && (12..<52).contains(y) ? [0, 96, 0, 96] : [0, 0, 0, 0]
        }
        let texture = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: bytes, width: 64, height: 64, bytesPerRow: 256))
        let paperRGBA: [UInt8] = [48, 96, 160, 255]
        let paper = try f.paper(paperRGBA)
        let red = SIMD4<Float>(0.4, 0, 0, 0.4)
        let magenta = SIMD4<Float>(0.4, 0, 0.4, 0.4)
        let blue = SIMD4<Float>(0, 0, 0.25, 0.25)
        let a = Renderer.Item(mesh: mesh, color: red)
        var b = Renderer.Item(texture: texture, transform: fullUV)
        b.color = .zero // Texture alpha/color is already baked; this must be ignored.
        let h = Renderer.Item(mesh: mesh, color: magenta, multiply: true)
        let z = Renderer.Item(mesh: mesh, color: blue)
        XCTAssertNil(b.mesh); XCTAssertTrue(b.texture === texture)
        XCTAssertTrue(a.mesh === mesh); XCTAssertNil(a.texture)
        let ordered = try f.render([a, b, h, z], backdrop: paper)
        let green = [0.0, 96.0 / 255, 0, 96.0 / 255]
        let base = paperRGBA.map { Double($0) / 255 }
        let expected = over(rgba(blue), multiply(rgba(magenta), over(green, over(rgba(red), base))))
        assertPixel(ordered, 32, 32, expected: expected)
        assertPixel(ordered, 3, 3, expected: base, tolerance: 0)
        assertPixel(ordered, 10, 32, expected: over(rgba(blue), multiply(rgba(magenta), over(rgba(red), base))))
        let reordered = try f.render([a, h, b, z], backdrop: paper)
        assertPixel(reordered, 32, 32, expected: over(rgba(blue), over(green, multiply(rgba(magenta), over(rgba(red), base)))))
        XCTAssertNotEqual(pixel(ordered, 32, 32), pixel(reordered, 32, 32), "The oracle must distinguish the actual z order")
        let deleted = try f.render([a, h, z], backdrop: paper)
        assertPixel(deleted, 32, 32, expected: over(rgba(blue), multiply(rgba(magenta), over(rgba(red), base))))
        let restored = try f.render([a, b, h, z], backdrop: paper)
        XCTAssertTrue(restored == ordered)
        XCTAssertEqual(f.renderer.meshUploadCount, 1)
        XCTAssertEqual(f.renderer.textureUploadCount, 1)
        XCTAssertEqual(f.renderer.encodedPassCount, 4)
        XCTAssertEqual(f.renderer.lastItemCount, 4)
    }

    func testLegacyMultiplyTextureUsesCurrentOpaqueDestinationAndAlphaExactlyOnce() throws {
        let f = try Fixture()
        let sourceRGBA: [UInt8] = [0, 102, 102, 102]
        let bytes = image(width: 64, height: 64) { x, y in
            (8..<56).contains(x) && (8..<56).contains(y) ? sourceRGBA : [0, 0, 0, 0]
        }
        let texture = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: bytes, width: 64, height: 64, bytesPerRow: 256))
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(16, 16, 32, 32)]))
        let penColor = SIMD4<Float>(0.5, 0.1, 0, 0.5)
        let pen = Renderer.Item(mesh: mesh, color: penColor)
        let h = Renderer.Item(texture: texture, transform: fullUV, multiply: true)
        let baseRGBA: [UInt8] = [100, 140, 200, 255]
        let paper = try f.paper(baseRGBA)
        let base = baseRGBA.map { Double($0) / 255 }, source = sourceRGBA.map { Double($0) / 255 }
        let once = try f.render([pen, h], backdrop: paper)
        assertPixel(once, 32, 32, expected: multiply(source, over(rgba(penColor), base)))
        assertPixel(once, 10, 32, expected: multiply(source, base))
        assertPixel(once, 3, 3, expected: base, tolerance: 0)
        let twice = try f.render([pen, h, h], backdrop: paper)
        assertPixel(twice, 32, 32, expected: multiply(source, multiply(source, over(rgba(penColor), base))))
        XCTAssertNotEqual(pixel(once, 32, 32), pixel(twice, 32, 32))
        XCTAssertEqual(f.renderer.textureUploadCount, 1)
    }

    func testTextureIgnoresStencilThenFollowingMeshRestoresItsOwnUnionMask() throws {
        let f = try Fixture()
        let left = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(2, 2, 14, 14)]))
        let right = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(46, 46, 14, 14)]))
        let texture = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: image(width: 1, height: 1) { _, _ in [0, 128, 0, 128] },
            width: 1, height: 1, bytesPerRow: 4))
        let items: [Renderer.Item] = [
            .init(mesh: left, color: SIMD4<Float>(1, 0, 0, 1)),
            .init(texture: texture, transform: fullUV),
            .init(mesh: right, color: SIMD4<Float>(0, 0, 1, 1))
        ]
        let result = try f.render(items)
        assertPixel(result, 8, 8, expected: over([0, 128.0 / 255, 0, 128.0 / 255], [1, 0, 0, 1]))
        assertPixel(result, 32, 32, expected: [0, 128.0 / 255, 0, 128.0 / 255], tolerance: 0)
        assertPixel(result, 52, 52, expected: [0, 0, 1, 1], tolerance: 0)
        assertPixel(result, 40, 52, expected: [0, 128.0 / 255, 0, 128.0 / 255], tolerance: 0)
        XCTAssertEqual(f.renderer.encodedPassCount, 1)
    }

    func testTextureUVOrientationAffinePanAndRotationNeedNoUpload() throws {
        let f = try Fixture()
        let data = image(width: 4, height: 4) { x, y in
            if y < 2 { return x < 2 ? [255, 0, 0, 255] : [0, 255, 0, 255] }
            return x < 2 ? [0, 0, 255, 255] : [255, 255, 0, 255]
        }
        let texture = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: data, width: 4, height: 4, bytesPerRow: 16))
        let plain = CGAffineTransform(a: 32, b: 0, c: 0, d: 32, tx: 8, ty: 8)
        let initial = try f.render([.init(texture: texture, transform: plain)])
        assertPixel(initial, 16, 16, expected: [1, 0, 0, 1], tolerance: 0)
        assertPixel(initial, 32, 16, expected: [0, 1, 0, 1], tolerance: 0)
        assertPixel(initial, 16, 32, expected: [0, 0, 1, 1], tolerance: 0)
        assertPixel(initial, 32, 32, expected: [1, 1, 0, 1], tolerance: 0)
        let rotated = CGAffineTransform(a: 0, b: 32, c: -32, d: 0, tx: 48, ty: 8)
        let changed = try f.render([.init(texture: texture, transform: rotated)])
        assertPixel(changed, 40, 16, expected: [1, 0, 0, 1], tolerance: 0)
        assertPixel(changed, 40, 32, expected: [0, 1, 0, 1], tolerance: 0)
        assertPixel(changed, 24, 16, expected: [0, 0, 1, 1], tolerance: 0)
        assertPixel(changed, 24, 32, expected: [1, 1, 0, 1], tolerance: 0)
        assertPixel(changed, 8, 8, expected: [0, 0, 0, 0], tolerance: 0)
        XCTAssertTrue(try f.render([.init(texture: texture, transform: plain)]) == initial)
        XCTAssertEqual(f.renderer.textureUploadCount, 1)
        XCTAssertEqual(f.renderer.meshUploadCount, 0)
    }

    func testUploadPreflightRejectsInvalidExtentStrideAndBudgetAndHonorsPaddedRows() throws {
        let f = try Fixture(), data = Data(repeating: 0, count: 16)
        let invalid: [(Int, Int, Int)] = [
            (0, 1, 4), (-1, 1, 4), (1, 0, 4), (1, -1, 4), (Int.max, 1, 4),
            (1, Int.max, 4), (4097, 1, 16388), (4096, 4096, 16384),
            (1, 2, Int.max), (2, 2, 4), (2, 2, 9), (2, 3, 8), (1, 1, 0)
        ]
        for (width, height, stride) in invalid {
            XCTAssertNil(f.renderer.makeTexture(premultipliedBGRA8: data, width: width, height: height, bytesPerRow: stride))
        }
        XCTAssertEqual(Renderer.maximumTextureBytes, 32 * 1024 * 1024)
        XCTAssertEqual(f.renderer.textureUploadCount, 0)
        // Padding is not a pixel, and the final row need not include padding.
        let padded = Data([0, 0, 255, 255, 0, 255, 0, 255, 17, 23, 31, 43,
                           255, 0, 0, 255, 0, 255, 255, 255])
        let resource = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: padded, width: 2, height: 2, bytesPerRow: 12))
        XCTAssertEqual(resource.byteCount, 16)
        let result = try f.render([.init(texture: resource, transform: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 8, ty: 8))])
        assertPixel(result, 8, 8, expected: [1, 0, 0, 1], tolerance: 0)
        assertPixel(result, 9, 8, expected: [0, 1, 0, 1], tolerance: 0)
        assertPixel(result, 8, 9, expected: [0, 0, 1, 1], tolerance: 0)
        assertPixel(result, 9, 9, expected: [1, 1, 0, 1], tolerance: 0)
        XCTAssertEqual(f.renderer.textureUploadCount, 1)
    }

    func testInvalidLaterTextureAndTargetAliasRejectBeforeChangingAnyTargetPixel() throws {
        let f = try Fixture()
        let mesh = try XCTUnwrap(f.renderer.makeMesh(convexPolygons: [rectangle(0, 0, 64, 64)]))
        let valid = Renderer.Item(mesh: mesh, color: SIMD4<Float>(0, 0, 1, 1))
        let baseline = try f.render([valid])
        let resource = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: image(width: 64, height: 64) { _, _ in [128, 0, 0, 128] },
            width: 64, height: 64, bytesPerRow: 256))
        let invalid = Renderer.Item(texture: resource, transform: CGAffineTransform(a: CGFloat.nan, b: 0, c: 0, d: 1, tx: 0, ty: 0))
        let badCommand = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertFalse(f.renderer.encode(items: [valid, invalid], backdrop: nil, into: f.target,
            command: badCommand, logicalSize: CGSize(width: 64, height: 64)))
        XCTAssertEqual(badCommand.status, .notEnqueued)
        badCommand.commit(); badCommand.waitUntilCompleted()
        XCTAssertEqual(badCommand.status, .completed)
        XCTAssertTrue(f.read(f.target) == baseline)
        let multiplyCommand = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertFalse(f.renderer.encode(items: [.init(texture: resource, transform: fullUV, multiply: true)],
            backdrop: nil, into: f.target, command: multiplyCommand, logicalSize: CGSize(width: 64, height: 64)))
        let aliasBefore = f.read(resource.texture)
        let aliasCommand = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertFalse(f.renderer.encode(items: [.init(texture: resource, transform: fullUV)], backdrop: nil,
            into: resource.texture, command: aliasCommand, logicalSize: CGSize(width: 64, height: 64)))
        aliasCommand.commit(); aliasCommand.waitUntilCompleted()
        XCTAssertEqual(aliasCommand.status, .completed)
        XCTAssertTrue(f.read(resource.texture) == aliasBefore)
        XCTAssertEqual(f.renderer.encodedPassCount, 1)
        XCTAssertEqual(f.renderer.lastItemCount, 1)
        XCTAssertEqual(f.renderer.textureUploadCount, 1)
    }

    func testUploadedPixelsAndSubmittedResourceSurviveCallerDataAndWrapperRelease() throws {
        let f = try Fixture()
        var data = image(width: 4, height: 4) { _, _ in [0, 128, 0, 128] }
        weak var releasedWrapper: Renderer.Texture?
        let command = try XCTUnwrap(f.queue.makeCommandBuffer())
        try autoreleasepool {
            let resource = try XCTUnwrap(f.renderer.makeTexture(premultipliedBGRA8: data, width: 4, height: 4, bytesPerRow: 16))
            releasedWrapper = resource
            data.resetBytes(in: 0..<data.count)
            XCTAssertTrue(f.renderer.encode(items: [.init(texture: resource, transform: fullUV)], backdrop: nil,
                into: f.target, command: command, logicalSize: CGSize(width: 64, height: 64)))
        }
        XCTAssertNil(releasedWrapper, "Only the Metal resource, not a scene wrapper, needs to outlive submission")
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        assertPixel(f.read(f.target), 32, 32, expected: [0, 128.0 / 255, 0, 128.0 / 255], tolerance: 0)
        XCTAssertEqual(f.renderer.textureUploadCount, 1)
    }

    private func rectangle(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }
    private func image(width: Int, height: Int, rgba: (Int, Int) -> [UInt8]) -> Data {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let c = rgba(x, y); bytes.append(contentsOf: [c[2], c[1], c[0], c[3]])
        } }
        return Data(bytes)
    }
    private func rgba(_ color: SIMD4<Float>) -> [Double] {
        [Double(color.x), Double(color.y), Double(color.z), Double(color.w)]
    }
    private func quantize(_ value: Double) -> Double { max(0, min(255, (value * 255).rounded())) / 255 }
    private func over(_ s: [Double], _ d: [Double]) -> [Double] {
        (0..<4).map { quantize(s[$0] + d[$0] * (1 - s[3])) }
    }
    private func multiply(_ s: [Double], _ d: [Double]) -> [Double] {
        (0..<3).map { quantize(d[$0] * (1 - s[3] + s[$0])) } + [1]
    }
    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * 64 + x) * 4
        return [bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3]]
    }
    private func assertPixel(_ actual: [UInt8], _ x: Int, _ y: Int, expected: [Double], tolerance: Int = 1,
                             file: StaticString = #filePath, line: UInt = #line) {
        let a = pixel(actual, x, y), e = expected.map { Int(($0 * 255).rounded()) }
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(a[channel]) - e[channel]), tolerance,
                "RGBA (\(x),\(y)): \(a) vs \(e)", file: file, line: line)
        }
    }

    @MainActor
    private final class Fixture {
        let device: MTLDevice, queue: MTLCommandQueue, target: MTLTexture
        let renderer: Renderer
        init() throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal is unavailable") }
            self.device = device; queue = try XCTUnwrap(device.makeCommandQueue())
            renderer = try XCTUnwrap(Renderer(device: device))
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
            target = try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        func paper(_ rgba: [UInt8]) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
            d.storageMode = .shared; d.usage = [.shaderRead]
            let t = try XCTUnwrap(device.makeTexture(descriptor: d))
            [rgba[2], rgba[1], rgba[0], rgba[3]].withUnsafeBytes { b in
                t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: b.baseAddress!, bytesPerRow: 4)
            }
            return t
        }
        func render(_ items: [Renderer.Item], backdrop: MTLTexture? = nil) throws -> [UInt8] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encode(items: items, backdrop: backdrop, into: target, command: command,
                logicalSize: CGSize(width: 64, height: 64)))
            command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
            return read(target)
        }
        func read(_ texture: MTLTexture) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            bytes.withUnsafeMutableBytes { b in
                texture.getBytes(b.baseAddress!, bytesPerRow: texture.width * 4,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            return bytes
        }
    }
}
