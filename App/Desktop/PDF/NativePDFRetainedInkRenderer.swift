import Foundation
import CoreGraphics
import Metal

/// An ordered retained ink scene. Immutable meshes survive presentation,
/// deletion and viewport changes; only uniforms and the draw list change.
/// Each convex-union stroke writes a per-sample stencil mask, composites its
/// color once, then clears its mask, all inside one render encoder.
@MainActor
final class NativePDFRetainedInkRenderer {
    final class Mesh {
        let buffer: MTLBuffer
        let vertexCount: Int
        let bounds: CGRect
        init(buffer: MTLBuffer, vertexCount: Int, bounds: CGRect) {
            self.buffer = buffer; self.vertexCount = vertexCount; self.bounds = bounds
        }
    }
    /// The pixels are premultiplied BGRA8. This immutable resource is prepared
    /// outside encode and retained by the submitted Metal command while in use.
    final class Texture {
        let texture: MTLTexture
        let byteCount: Int
        fileprivate init(texture: MTLTexture, byteCount: Int) {
            self.texture = texture; self.byteCount = byteCount
        }
    }
    struct Item {
        enum Content { case mesh(Mesh); case texture(Texture) }
        let content: Content
        var mesh: Mesh? { if case let .mesh(value) = content { return value }; return nil }
        var texture: Texture? { if case let .texture(value) = content { return value }; return nil }
        /// Premultiplied RGBA for a mesh only. Texture pixels already include
        /// object opacity and are never multiplied by this color a second time.
        var color: SIMD4<Float>
        /// Mesh coordinates -> viewport, or texture UV [0,1] -> viewport.
        var transform: CGAffineTransform
        var multiply: Bool
        init(mesh: Mesh, color: SIMD4<Float>, transform: CGAffineTransform = .identity, multiply: Bool = false) {
            content = .mesh(mesh); self.color = color; self.transform = transform; self.multiply = multiply
        }
        init(texture: Texture, transform: CGAffineTransform, multiply: Bool = false) {
            content = .texture(texture); color = SIMD4(repeating: 1)
            self.transform = transform; self.multiply = multiply
        }
    }
    private struct Projection { var x: SIMD4<Float>; var y: SIMD4<Float> }
    private struct Pipelines {
        let mask: MTLRenderPipelineState
        let color: MTLRenderPipelineState
        let multiply: MTLRenderPipelineState
        let paper: MTLRenderPipelineState
        let texture: MTLRenderPipelineState
        let textureMultiply: MTLRenderPipelineState
    }
    private let device: MTLDevice
    private let pipelines: [Int: Pipelines]
    private let writeMask: MTLDepthStencilState
    private let consumeMask: MTLDepthStencilState
    private let ignoreMask: MTLDepthStencilState
    private var multisampleColor: MTLTexture?
    private var stencil: MTLTexture?
    private var samples = 1
    private var encodingQueue: MTLCommandQueue?
    static let maximumMeshBytes = 64 * 1024 * 1024
    static let maximumTextureBytes = 32 * 1024 * 1024
    static let maximumTextureDimension = 4096
    private(set) var meshUploadCount = 0
    private(set) var textureUploadCount = 0
    private(set) var encodedPassCount = 0
    private(set) var lastItemCount = 0

    init?(device: MTLDevice) {
        self.device = device
        let source = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        struct Projection { float4 x; float4 y; };
        constant float2 corners[6] = {float2(0,0),float2(0,1),float2(1,0),
                                     float2(1,0),float2(0,1),float2(1,1)};
        Out project(float2 point, constant Projection& p) {
            Out o; o.position=float4(dot(p.x.xyz,float3(point,1)),dot(p.y.xyz,float3(point,1)),0,1);
            o.uv=float2(0); return o;
        }
        vertex Out meshVertex(uint i [[vertex_id]], const device float2* points [[buffer(0)]],
                              constant Projection& p [[buffer(1)]]) { return project(points[i],p); }
        vertex Out boundsVertex(uint i [[vertex_id]], constant Projection& p [[buffer(1)]],
                                constant float4& rect [[buffer(2)]]) {
            return project(mix(rect.xy,rect.zw,corners[i]),p);
        }
        vertex Out paperVertex(uint i [[vertex_id]], constant Projection& p [[buffer(1)]]) {
            Out o=project(corners[i],p); o.uv=corners[i]; return o;
        }
        fragment float4 inkColor(constant float4& color [[buffer(0)]]) { return color; }
        fragment float4 paperColor(Out in [[stage_in]], texture2d<float> paper [[texture(0)]]) {
            constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge);
            return paper.sample(s,in.uv);
        }
        """#
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            var values: [Int: Pipelines] = [:]
            for count in [4, 2, 1] where device.supportsTextureSampleCount(count) {
                func pipeline(vertex: String, fragment: String?, colorWrites: Bool = true,
                              blend: Bool = false, multiply: Bool = false) throws -> MTLRenderPipelineState {
                    let d = MTLRenderPipelineDescriptor()
                    d.vertexFunction = library.makeFunction(name: vertex)
                    d.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
                    d.rasterSampleCount = count; d.stencilAttachmentPixelFormat = .stencil8
                    let a = d.colorAttachments[0]!
                    a.pixelFormat = .bgra8Unorm; a.writeMask = colorWrites ? .all : []
                    a.isBlendingEnabled = blend
                    a.sourceRGBBlendFactor = multiply ? .destinationColor : .one
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                    return try device.makeRenderPipelineState(descriptor: d)
                }
                if let mask = try? pipeline(vertex: "meshVertex", fragment: nil, colorWrites: false),
                   let color = try? pipeline(vertex: "boundsVertex", fragment: "inkColor", blend: true),
                   let multiply = try? pipeline(vertex: "boundsVertex", fragment: "inkColor", blend: true, multiply: true),
                   let paper = try? pipeline(vertex: "paperVertex", fragment: "paperColor"),
                   let texture = try? pipeline(vertex: "paperVertex", fragment: "paperColor", blend: true),
                   let textureMultiply = try? pipeline(vertex: "paperVertex", fragment: "paperColor", blend: true, multiply: true) {
                    values[count] = Pipelines(mask: mask, color: color, multiply: multiply, paper: paper,
                        texture: texture, textureMultiply: textureMultiply)
                }
            }
            guard values[1] != nil else { return nil }
            pipelines = values
            func state(compare: MTLCompareFunction, pass: MTLStencilOperation, writes: Bool) -> MTLDepthStencilState? {
                let d = MTLDepthStencilDescriptor()
                d.depthCompareFunction = .always; d.isDepthWriteEnabled = false
                let s = MTLStencilDescriptor()
                s.stencilCompareFunction = compare; s.stencilFailureOperation = .keep
                s.depthFailureOperation = .keep; s.depthStencilPassOperation = pass
                s.readMask = 0xff; s.writeMask = writes ? 0xff : 0
                d.frontFaceStencil = s; d.backFaceStencil = s
                return device.makeDepthStencilState(descriptor: d)
            }
            guard let write = state(compare: .always, pass: .replace, writes: true),
                  let consume = state(compare: .equal, pass: .zero, writes: true),
                  let ignore = state(compare: .always, pass: .keep, writes: false) else { return nil }
            writeMask = write; consumeMask = consume; ignoreMask = ignore
        } catch { return nil }
    }

    /// Only the versioned native ink's convex union is accepted here. General
    /// SVG/CGPath contours require a different tessellation or texture command.
    func makeMesh(convexPolygons: [[CGPoint]]) -> Mesh? {
        var count = 0
        for polygon in convexPolygons where polygon.count >= 3 {
            let (next, overflow) = count.addingReportingOverflow(polygon.count - 2)
            guard !overflow, next <= min(Self.maximumMeshBytes, device.maxBufferLength) / (3 * MemoryLayout<SIMD2<Float>>.stride) else { return nil }
            count = next
        }
        guard convexPolygons.allSatisfy({ $0.allSatisfy { Float($0.x).isFinite && Float($0.y).isFinite } }) else { return nil }
        let cache = NativePDFInkVertexCache()
        cache.update(convexPolygons)
        guard !cache.vertices.isEmpty else { return nil }
        let length = cache.vertices.count * MemoryLayout<SIMD2<Float>>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        cache.vertices.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: length)
        }
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in cache.vertices {
            low = SIMD2(min(low.x,p.x),min(low.y,p.y)); high = SIMD2(max(high.x,p.x),max(high.y,p.y))
        }
        let bounds = CGRect(x: CGFloat(low.x), y: CGFloat(low.y), width: CGFloat(high.x-low.x), height: CGFloat(high.y-low.y))
        guard !bounds.isEmpty, [bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy(\.isFinite) else { return nil }
        meshUploadCount += 1
        return Mesh(buffer: buffer, vertexCount: cache.vertices.count, bounds: bounds)
    }

    /// Caller supplies already-premultiplied, top-to-bottom BGRA8 pixels in
    /// the same non-sRGB Metal working format as the existing mesh pipeline.
    /// Row padding is allowed; input storage and GPU payload each stay bounded.
    /// No per-pixel Swift scan or opacity conversion occurs on this upload path.
    func makeTexture(premultipliedBGRA8 data: Data, width: Int, height: Int, bytesPerRow: Int) -> Texture? {
        guard width > 0, height > 0,
              width <= Self.maximumTextureDimension, height <= Self.maximumTextureDimension,
              bytesPerRow > 0, bytesPerRow <= Self.maximumTextureBytes, bytesPerRow % 4 == 0,
              data.count <= Self.maximumTextureBytes else { return nil }
        let row = width.multipliedReportingOverflow(by: 4)
        guard !row.overflow, bytesPerRow >= row.partialValue else { return nil }
        let payload = row.partialValue.multipliedReportingOverflow(by: height)
        let precedingRows = bytesPerRow.multipliedReportingOverflow(by: height - 1)
        let required = precedingRows.partialValue.addingReportingOverflow(row.partialValue)
        guard !payload.overflow, !precedingRows.overflow, !required.overflow,
              payload.partialValue <= Self.maximumTextureBytes,
              required.partialValue <= data.count else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), texture.device === device else { return nil }
        data.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow)
        }
        textureUploadCount += 1
        return Texture(texture: texture, byteCount: payload.partialValue)
    }

    /// A texture view aliases its parent even when the Metal wrapper differs.
    private func sameStorage(_ first: MTLTexture, _ second: MTLTexture) -> Bool {
        func root(_ texture: MTLTexture) -> MTLTexture {
            var result = texture
            while let parent = result.parent { result = parent }
            return result
        }
        return root(first) === root(second)
    }

    /// Failure leaves the caller's command unsubmitted. No CPU raster, readback,
    /// bitmap copy, resource upload, or drawable acquisition occurs here.
    func encode(items: [Item], backdrop: MTLTexture?, into target: MTLTexture,
                command: MTLCommandBuffer, logicalSize: CGSize,
                backdropTransform: CGAffineTransform? = nil) -> Bool {
        guard target.pixelFormat == .bgra8Unorm, target.sampleCount == 1,
              target.device === device, command.device === device,
              backdrop == nil || (backdrop?.device === device && !sameStorage(backdrop!, target)),
              logicalSize.width.isFinite, logicalSize.height.isFinite,
              logicalSize.width > 0, logicalSize.height > 0,
              !items.contains(where: { $0.multiply }) || backdrop != nil else { return false }
        var paperProjection: Projection?
        if backdrop != nil {
            let t = backdropTransform ?? CGAffineTransform(scaleX: logicalSize.width, y: logicalSize.height)
            guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite) else { return false }
            let sx = 2/logicalSize.width, sy = -2/logicalSize.height
            let p = Projection(x: SIMD4(Float(t.a*sx),Float(t.c*sx),Float(t.tx*sx-1),0),
                               y: SIMD4(Float(t.b*sy),Float(t.d*sy),Float(t.ty*sy+1),0))
            guard [p.x.x,p.x.y,p.x.z,p.y.x,p.y.y,p.y.z].allSatisfy(\.isFinite) else { return false }
            paperProjection = p
        } else if let t = backdropTransform,
                  ![t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite) { return false }
        // Reused scratch attachments rely on submission order on this queue.
        // MainActor serialization alone cannot order independent GPU queues.
        if let encodingQueue, encodingQueue !== command.commandQueue { return false }
        var uniforms: [(Projection, SIMD4<Float>)] = []; uniforms.reserveCapacity(items.count)
        for item in items {
            let t = item.transform
            guard [t.a,t.b,t.c,t.d,t.tx,t.ty].allSatisfy(\.isFinite) else { return false }
            let sx = 2/logicalSize.width, sy = -2/logicalSize.height
            let p = Projection(x: SIMD4(Float(t.a*sx),Float(t.c*sx),Float(t.tx*sx-1),0),
                               y: SIMD4(Float(t.b*sy),Float(t.d*sy),Float(t.ty*sy+1),0))
            guard [p.x.x,p.x.y,p.x.z,p.y.x,p.y.y,p.y.z].allSatisfy(\.isFinite) else { return false }
            let rect: SIMD4<Float>
            switch item.content {
            case let .mesh(mesh):
                let c = item.color
                guard mesh.buffer.device === device,
                      [c.x,c.y,c.z,c.w].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                      c.x <= c.w, c.y <= c.w, c.z <= c.w else { return false }
                let b = mesh.bounds
                // Both draws use the same projection. Slightly expand the cover
                // quad so float rounding cannot leave a covered stencil sample
                // uncleared at a mesh boundary and leak it into a later stroke.
                let padding = ([1,abs(b.minX),abs(b.minY),abs(b.maxX),abs(b.maxY)].max() ?? 1) * CGFloat(Float.ulpOfOne) * 8
                rect = SIMD4(Float(b.minX-padding),Float(b.minY-padding),Float(b.maxX+padding),Float(b.maxY+padding))
                guard [rect.x,rect.y,rect.z,rect.w].allSatisfy(\.isFinite) else { return false }
            case let .texture(resource):
                let texture = resource.texture
                guard texture.device === device, !sameStorage(texture, target),
                      texture.textureType == .type2D, texture.pixelFormat == .bgra8Unorm,
                      texture.sampleCount == 1, texture.usage.contains(.shaderRead),
                      texture.width > 0, texture.height > 0 else { return false }
                rect = .zero // Textured quad vertex shader uses UV corners.
            }
            uniforms.append((p,rect))
        }
        guard prepareAttachments(width: target.width, height: target.height),
              let stencil, let pipeline = pipelines[samples] else { return false }
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = multisampleColor ?? target; color.loadAction = .clear
        color.clearColor = backdrop == nil ? MTLClearColorMake(0,0,0,0) : MTLClearColorMake(1,1,1,1)
        if samples > 1 { color.resolveTexture = target; color.storeAction = .multisampleResolve }
        else { color.storeAction = .store }
        pass.stencilAttachment.texture = stencil; pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0; pass.stencilAttachment.storeAction = .dontCare
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encodingQueue = command.commandQueue
        encoder.setCullMode(.none); encoder.setStencilReferenceValue(1)
        if let backdrop, var projection = paperProjection {
            encoder.setVertexBytes(&projection, length: MemoryLayout<Projection>.stride, index: 1)
            encoder.setDepthStencilState(ignoreMask); encoder.setRenderPipelineState(pipeline.paper)
            encoder.setFragmentTexture(backdrop, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        for (index,item) in items.enumerated() {
            var (projection,rect) = uniforms[index]
            encoder.setVertexBytes(&projection, length: MemoryLayout<Projection>.stride, index: 1)
            switch item.content {
            case let .mesh(mesh):
                var ink = item.color
                encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
                encoder.setRenderPipelineState(pipeline.mask); encoder.setDepthStencilState(writeMask)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertexCount)
                encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                encoder.setFragmentBytes(&ink, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setRenderPipelineState(item.multiply ? pipeline.multiply : pipeline.color)
                encoder.setDepthStencilState(consumeMask)
            case let .texture(resource):
                encoder.setFragmentTexture(resource.texture, index: 0)
                encoder.setRenderPipelineState(item.multiply ? pipeline.textureMultiply : pipeline.texture)
                encoder.setDepthStencilState(ignoreMask)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        encoder.endEncoding(); encodedPassCount += 1; lastItemCount = items.count
        return true
    }

    private func prepareAttachments(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width*height <= 8_020_000 else { return false }
        if stencil?.width == width, stencil?.height == height { return true }
        for count in [4,2,1] where pipelines[count] != nil {
            func texture(_ format: MTLPixelFormat) -> MTLTexture? {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
                d.usage = .renderTarget; d.sampleCount = count
                if count > 1 { d.textureType = .type2DMultisample }
                #if targetEnvironment(simulator)
                d.storageMode = .private
                #else
                d.storageMode = .memoryless
                #endif
                return device.makeTexture(descriptor: d)
            }
            guard let nextStencil = texture(.stencil8) else { continue }
            let nextColor = count > 1 ? texture(.bgra8Unorm) : nil
            guard count == 1 || nextColor != nil else { continue }
            stencil = nextStencil; multisampleColor = nextColor; samples = count
            return true
        }
        return false
    }
}
