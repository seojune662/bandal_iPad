import Foundation
import UIKit

/// Coalesces consumers before any disk or drawing work. A disappearing cell
/// releases only its own subscription; the last consumer cancels the producer.
@MainActor
final class NativeThumbnailImageCache {
    private final class Request {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
    }
    private let images = NSCache<NSString, UIImage>()
    private var requests: [String: Request] = [:]
    private(set) var loadCount = 0
    var pendingCount: Int { requests.count }

    init(bytes: Int, count: Int) {
        images.totalCostLimit = bytes
        images.countLimit = count
    }

    func image(key: String, load: @escaping @MainActor () async -> UIImage?) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = images.object(forKey: key as NSString) { return image }
        let subscriber = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let request: Request
                if let current = requests[key] { request = current }
                else {
                    request = Request()
                    requests[key] = request
                    loadCount += 1
                    let id = request.id
                    request.task = Task(priority: .utility) { [weak self] in
                        let image = await load()
                        self?.complete(key: key, id: id, image: Task.isCancelled ? nil : image)
                    }
                }
                request.waiters[subscriber] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(key: key, subscriber: subscriber) }
        }
    }

    private func complete(key: String, id: UUID, image: UIImage?) {
        guard let request = requests[key], request.id == id else { return }
        requests[key] = nil
        if let image {
            let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            images.setObject(image, forKey: key as NSString, cost: cost)
        }
        for continuation in request.waiters.values { continuation.resume(returning: image) }
    }

    private func cancel(key: String, subscriber: UUID) {
        guard let request = requests[key], let continuation = request.waiters.removeValue(forKey: subscriber) else { return }
        continuation.resume(returning: nil)
        if request.waiters.isEmpty {
            requests[key] = nil
            request.task?.cancel()
        }
    }
}

/// PDFKit objects never leave their worker. Cancellation releases the waiting
/// cell immediately and prevents queued work from decoding an offscreen page.
final class NativeThumbnailWorkQueue: @unchecked Sendable {
    final class ImageBox: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ImageBox?, Never>?
        private var operation: Operation?
        private var finished = false
        var shouldRun: Bool { lock.lock(); defer { lock.unlock() }; return !finished }
        func install(_ continuation: CheckedContinuation<ImageBox?, Never>) {
            lock.lock()
            if finished { lock.unlock(); continuation.resume(returning: nil) }
            else { self.continuation = continuation; lock.unlock() }
        }
        func install(_ operation: Operation) {
            lock.lock()
            if finished { lock.unlock(); operation.cancel() }
            else { self.operation = operation; lock.unlock() }
        }
        func finish(_ result: ImageBox?) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation
            self.continuation = nil
            operation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
        func cancel() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation, operation = operation
            self.continuation = nil
            self.operation = nil
            lock.unlock()
            operation?.cancel()
            continuation?.resume(returning: nil)
        }
    }
    private let queue: OperationQueue
    init(name: String, concurrency: Int = 1) {
        queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = max(1, concurrency)
    }
    func image(_ render: @escaping @Sendable () -> UIImage?) async -> ImageBox? {
        let ticket = Ticket()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                ticket.install(continuation)
                let operation = BlockOperation {
                    guard ticket.shouldRun else { return }
                    let image = autoreleasepool { render() }
                    ticket.finish(image.map(ImageBox.init))
                }
                ticket.install(operation)
                queue.addOperation(operation)
            }
        } onCancel: { ticket.cancel() }
    }
}
