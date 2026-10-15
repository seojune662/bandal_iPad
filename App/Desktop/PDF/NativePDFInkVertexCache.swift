import Foundation
import CoreGraphics
import Metal

/// The live geometry cache preserves polygons, but expanding every retained
/// disk into 90 triangle vertices used to happen again on every display frame.
/// Retain that mesh too; prediction replacement invalidates only its suffix.
final class NativePDFInkVertexCache {
    private var polygons: [[CGPoint]] = []
    private var polygonEnds: [Int] = []
    private var cumulativeBounds: [CGRect] = []
    private var revision: UInt64?
    private(set) var vertices: [SIMD2<Float>] = []
    private(set) var rebuiltVertexCount = 0
    private(set) var retainedPrefixPolygonCount = 0
    private(set) var rebuiltBoundsPointCount = 0
    /// Bounds of the uploaded Float geometry, including degenerate contours.
    /// A retained polygon prefix also retains its cumulative bounds.
    var bounds: CGRect { cumulativeBounds.last ?? .null }

    /// Returns the first vertex that any reusable GPU buffer must re-upload.
    /// A prefix hint is valid only for consecutive geometry revisions: the
    /// surface may have advanced while a drawable was unavailable.
    @discardableResult
    func update(_ next: [[CGPoint]], retainedPrefix: Int? = nil, revision nextRevision: UInt64? = nil) -> Int {
        var prefix = 0
        if let retainedPrefix, let revision, let nextRevision,
           nextRevision == revision &+ 1, retainedPrefix >= 0,
           retainedPrefix <= min(polygons.count, next.count) {
            prefix = retainedPrefix
        } else {
            while prefix < min(polygons.count, next.count), polygons[prefix] == next[prefix] { prefix += 1 }
        }
        let firstChanged = prefix == 0 ? 0 : polygonEnds[prefix - 1]
        if prefix < polygons.count {
            vertices.removeSubrange(firstChanged...)
            polygonEnds.removeSubrange(prefix...)
            cumulativeBounds.removeSubrange(prefix...)
        }
        rebuiltBoundsPointCount = 0
        var currentBounds = cumulativeBounds.last ?? CGRect.null
        for polygon in next.dropFirst(prefix) {
            if polygon.count >= 3 {
                for point in polygon {
                    // Match GPU conversion exactly; CGFloat bounds could lie
                    // inside an outward-rounded Float vertex.
                    let x = CGFloat(Float(point.x)), y = CGFloat(Float(point.y))
                    if currentBounds.isNull { currentBounds = CGRect(x: x, y: y, width: 0, height: 0) }
                    else {
                        let minX = min(currentBounds.minX, x), minY = min(currentBounds.minY, y)
                        let maxX = max(currentBounds.maxX, x), maxY = max(currentBounds.maxY, y)
                        currentBounds = CGRect(x: minX, y: minY, width: maxX-minX, height: maxY-minY)
                    }
                    rebuiltBoundsPointCount += 1
                }
                let first = SIMD2(Float(polygon[0].x), Float(polygon[0].y))
                for index in 1..<(polygon.count - 1) {
                    vertices.append(first)
                    vertices.append(SIMD2(Float(polygon[index].x), Float(polygon[index].y)))
                    vertices.append(SIMD2(Float(polygon[index + 1].x), Float(polygon[index + 1].y)))
                }
            }
            polygonEnds.append(vertices.count)
            cumulativeBounds.append(currentBounds)
        }
        rebuiltVertexCount = vertices.count - firstChanged
        retainedPrefixPolygonCount = prefix
        polygons = next; revision = nextRevision
        return firstChanged
    }
}

/// A small pool of shared buffers. Each in-flight command owns a lease; no
/// CPU write can modify the storage used by an unfinished GPU frame. Busy
/// slots accumulate the earliest dirty vertex until they become available.
final class NativePDFInkVertexBufferPool: @unchecked Sendable {
    struct Lease {
        let buffer: MTLBuffer
        fileprivate let index: Int
        fileprivate let generation: UInt64
    }
    private struct Slot {
        var buffer: MTLBuffer
        var dirtyFrom = 0
        var busy = false
        var generation: UInt64 = 0
    }
    private let device: MTLDevice
    private let lock = NSLock()
    private var slots: [Slot] = []
    private let maximumBuffers: Int
    private(set) var allocationCount = 0
    private(set) var uploadedVertexCount = 0

    init(device: MTLDevice, maximumBuffers: Int = 3) {
        self.device = device; self.maximumBuffers = max(1, maximumBuffers)
    }

    func invalidate(from firstChanged: Int) {
        lock.lock(); defer { lock.unlock() }
        for index in slots.indices { slots[index].dirtyFrom = min(slots[index].dirtyFrom, firstChanged) }
    }

    func acquire(vertices: [SIMD2<Float>]) -> Lease? {
        guard !vertices.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        uploadedVertexCount = 0
        let bytes = vertices.count * MemoryLayout<SIMD2<Float>>.stride
        let index: Int
        if let available = slots.firstIndex(where: { !$0.busy }) { index = available }
        else {
            guard slots.count < maximumBuffers, let buffer = makeBuffer(minimumLength: bytes) else { return nil }
            slots.append(Slot(buffer: buffer)); index = slots.count - 1
        }
        if slots[index].buffer.length < bytes {
            guard let buffer = makeBuffer(minimumLength: bytes) else { return nil }
            slots[index].buffer = buffer; slots[index].dirtyFrom = 0
        }
        let first = min(vertices.count, max(0, slots[index].dirtyFrom))
        if first < vertices.count {
            vertices.withUnsafeBytes { source in
                let offset = first * MemoryLayout<SIMD2<Float>>.stride
                slots[index].buffer.contents().advanced(by: offset)
                    .copyMemory(from: source.baseAddress!.advanced(by: offset), byteCount: bytes - offset)
            }
        }
        uploadedVertexCount = vertices.count - first
        slots[index].dirtyFrom = vertices.count
        slots[index].busy = true; slots[index].generation &+= 1
        return Lease(buffer: slots[index].buffer, index: index, generation: slots[index].generation)
    }

    func release(_ lease: Lease) {
        lock.lock(); defer { lock.unlock() }
        guard slots.indices.contains(lease.index), slots[lease.index].generation == lease.generation else { return }
        slots[lease.index].busy = false
    }

    private func makeBuffer(minimumLength: Int) -> MTLBuffer? {
        var capacity = 4096
        while capacity < minimumLength { capacity *= 2 }
        guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else { return nil }
        allocationCount += 1
        return buffer
    }
}
