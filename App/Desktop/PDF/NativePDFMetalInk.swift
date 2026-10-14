import UIKit
import MetalKit

/// A transparent, event-free live-ink surface. Each stroke is first rendered
/// with blending disabled into a private texture, then composited once. This
/// preserves highlighter opacity at crossings within the same stroke.
@MainActor
final class NativePDFMetalInk: MTKView, MTKViewDelegate {
    struct Stroke {
        var polygons: [[CGPoint]]
        var color: UIColor
        var opacity: Float
        var multiply = false
        /// Polygon space -> this cropped Metal view's local points. Native
        /// geometry can stay normalized until the GPU vertex stage.
        var transform: CGAffineTransform = .identity
    }
    var strokes: [Stroke] = [] { didSet { setNeedsDisplay() } }
    /// Transparent Metal cannot multiply UIKit layers below it. This bounded
    /// PDF + committed-object raster is rebuilt only when that scene changes.
    var backdrop: CGImage? {
        didSet {
            guard oldValue !== backdrop else { return }
            backdropTexture = nil
            if let backdrop, let device {
                backdropTexture = try? MTKTextureLoader(device: device).newTexture(cgImage: backdrop, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft.rawValue])
            }
            setNeedsDisplay()
        }
    }
    var receivedAt: CFTimeInterval?
    var onSubmission: ((Double) -> Void)?
    private let commands: MTLCommandQueue
    private let fillPipelines: [Int: MTLRenderPipelineState]
    private let compositePipeline: MTLRenderPipelineState
    private let multiplyPipeline: MTLRenderPipelineState
    private var backdropTexture: MTLTexture?
    private var scratch: MTLTexture?
    private var multisampleScratch: MTLTexture?
    private(set) var rasterSampleCount = 1
    private struct InkProjection {
        var x: SIMD4<Float>
        var y: SIMD4<Float>
    }

    init?(renderer: Void = ()) {
        guard let gpu = MTLCreateSystemDefaultDevice(), let commands = gpu.makeCommandQueue() else { return nil }
        self.commands = commands
        let source = #"""
        #include <metal_stdlib>
        using namespace metal;
        struct Out { float4 position [[position]]; float2 uv; };
        struct InkProjection { float4 x; float4 y; };
        vertex Out inkVertex(uint i [[vertex_id]], const device float2* points [[buffer(0)]],
                             constant InkProjection& projection [[buffer(1)]]) {
            const float3 point=float3(points[i],1);
            Out o; o.position=float4(dot(projection.x.xyz,point),dot(projection.y.xyz,point),0,1);
            o.uv=float2(0); return o;
        }
        fragment float4 inkColor(constant float4& color [[buffer(0)]]) { return color; }
        vertex Out quadVertex(uint i [[vertex_id]]) {
            const float2 p[6]={float2(-1,1),float2(-1,-1),float2(1,1),float2(1,1),float2(-1,-1),float2(1,-1)};
            Out o; o.position=float4(p[i],0,1); o.uv=float2((p[i].x+1)*.5,(1-p[i].y)*.5); return o;
        }
        fragment float4 composite(Out in [[stage_in]], texture2d<float> ink [[texture(0)]]) {
            constexpr sampler s(coord::normalized,filter::linear,address::clamp_to_edge);
            return ink.sample(s,in.uv);
        }
        """#
        do {
            let library = try gpu.makeLibrary(source: source, options: nil)
            let fill = MTLRenderPipelineDescriptor()
            fill.vertexFunction = library.makeFunction(name: "inkVertex")
            fill.fragmentFunction = library.makeFunction(name: "inkColor")
            fill.colorAttachments[0].pixelFormat = .bgra8Unorm
            fill.colorAttachments[0].isBlendingEnabled = false
            var pipelines: [Int: MTLRenderPipelineState] = [:]
            for samples in [4, 2, 1] where gpu.supportsTextureSampleCount(samples) {
                fill.rasterSampleCount = samples
                if let pipeline = try? gpu.makeRenderPipelineState(descriptor: fill) { pipelines[samples] = pipeline }
            }
            guard pipelines[1] != nil else { return nil }
            fillPipelines = pipelines
            let composition = MTLRenderPipelineDescriptor()
            composition.vertexFunction = library.makeFunction(name: "quadVertex")
            composition.fragmentFunction = library.makeFunction(name: "composite")
            let attachment = composition.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm; attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try gpu.makeRenderPipelineState(descriptor: composition)
            // alpha * source * destination + (1-alpha) * destination.
            // The union texture prevents extra darkening at self-crossings.
            attachment.sourceRGBBlendFactor = .destinationColor
            multiplyPipeline = try gpu.makeRenderPipelineState(descriptor: composition)
        } catch { return nil }
        super.init(frame: .zero, device: gpu)
        delegate = self; isPaused = true; enableSetNeedsDisplay = true
        framebufferOnly = true; colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        layer.isOpaque = false
        accessibilityElementsHidden = true
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scratch = nil; multisampleScratch = nil
    }
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let command = commands.makeCommandBuffer() else { return }
        encode(into: drawable.texture, command: command)
        command.present(drawable); command.commit()
        if !strokes.isEmpty, let receivedAt {
            onSubmission?(max(0, (CACurrentMediaTime() - receivedAt) * 1_000))
            self.receivedAt = nil
        }
    }
    private func encode(into target: MTLTexture, command: MTLCommandBuffer) {
        guard let gpu = device else { return }
        let width = target.width, height = target.height
        if scratch?.width != width || scratch?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
            scratch = gpu.makeTexture(descriptor: descriptor)
            multisampleScratch = nil; rasterSampleCount = 1
            // Rasterize the union per sample, then resolve exactly once. A
            // separate AA pass per polygon would repeatedly blend overlaps
            // and make translucent ink darker at joins/self-crossings.
            // Memoryless MSAA stays in the iPad GPU's tile memory; the resolved
            // single-sample texture is the only persistent ink allocation.
            for samples in [4, 2] where fillPipelines[samples] != nil {
                let multisample = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                multisample.textureType = .type2DMultisample; multisample.sampleCount = samples
                multisample.usage = [.renderTarget]; multisample.storageMode = .memoryless
                if let texture = gpu.makeTexture(descriptor: multisample) {
                    multisampleScratch = texture; rasterSampleCount = samples; break
                }
            }
        }
        guard let scratch, let fillPipeline = fillPipelines[rasterSampleCount] else { return }
        var first = true
        if !strokes.isEmpty, let backdropTexture {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clearColor
            if let encoder = command.makeRenderCommandEncoder(descriptor: pass) {
                encoder.setRenderPipelineState(compositePipeline); encoder.setFragmentTexture(backdropTexture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding(); first = false
            }
        }
        for stroke in strokes {
            var vertices: [SIMD2<Float>] = []
            vertices.reserveCapacity(stroke.polygons.reduce(0) { $0 + max(0, $1.count - 2) * 3 })
            func vertex(_ point: CGPoint) -> SIMD2<Float> { SIMD2(Float(point.x), Float(point.y)) }
            for polygon in stroke.polygons where polygon.count >= 3 {
                let first = vertex(polygon[0])
                for index in 1..<(polygon.count - 1) {
                    vertices.append(first); vertices.append(vertex(polygon[index])); vertices.append(vertex(polygon[index + 1]))
                }
            }
            guard !vertices.isEmpty, let buffer = gpu.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared) else { continue }
            let union = MTLRenderPassDescriptor()
            union.colorAttachments[0].texture = multisampleScratch ?? scratch
            union.colorAttachments[0].loadAction = .clear
            union.colorAttachments[0].clearColor = clearColor
            if multisampleScratch != nil {
                union.colorAttachments[0].resolveTexture = scratch
                union.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                union.colorAttachments[0].storeAction = .store
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: union) else { continue }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            stroke.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let alpha = stroke.opacity * Float(a)
            var color = SIMD4(Float(r) * alpha, Float(g) * alpha, Float(b) * alpha, alpha)
            // Compose the affine and viewport projection once per stroke,
            // not for every point of every triangle on the CPU.
            let affine = stroke.transform, sx = 2 / max(bounds.width, 1), sy = -2 / max(bounds.height, 1)
            var projection = InkProjection(
                x: SIMD4(Float(affine.a * sx), Float(affine.c * sx), Float(affine.tx * sx - 1), 0),
                y: SIMD4(Float(affine.b * sy), Float(affine.d * sy), Float(affine.ty * sy + 1), 0))
            encoder.setRenderPipelineState(fillPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&projection, length: MemoryLayout<InkProjection>.stride, index: 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = first ? .clear : .load
            pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = clearColor
            guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { continue }
            composite.setRenderPipelineState(stroke.multiply && backdropTexture != nil ? multiplyPipeline : compositePipeline)
            composite.setFragmentTexture(scratch, index: 0)
            composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            composite.endEncoding(); first = false
        }
        if first {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = clearColor
            command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    /// Same GPU encoders as a displayed frame, with deterministic readback for
    /// checking blend modes and union opacity without screenshot conversions.
    func renderedPixels(width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= 4096, height <= 4096, let device,
              let command = commands.makeCommandBuffer() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]; descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor) else { return nil }
        encode(into: output, command: command); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { output.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        }
        return bytes
    }
}
