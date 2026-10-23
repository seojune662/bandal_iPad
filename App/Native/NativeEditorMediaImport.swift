import UIKit
import UniformTypeIdentifiers
import ImageIO

struct NativeDroppedMedia: Sendable {
    let data: Data
    let name: String
    let type: UTType
    let image: UIImage?
}

struct NativeImportedImage {
    let relativePath: String
    let pixelSize: CGSize
    let name: String
}

/// Shared by the PDF canvas and each Markdown page. Provider-owned URLs are read
/// inside their completion callback, before the provider can revoke the lease.
enum NativeEditorMediaImport {
    static let maximumBytes = 50 * 1024 * 1024
    static let maximumItems = 20

    static func supports(_ provider: NSItemProvider, imagesOnly: Bool) -> Bool {
        if provider.canLoadObject(ofClass: UIImage.self) { return true }
        return provider.registeredTypeIdentifiers.contains { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .fileURL)
                || (!imagesOnly && type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url))
        }
    }

    /// Reserving before reads/decodes bounds the whole multi-item drop, including
    /// providers that finish concurrently. A failed drop discards the budget.
    final class Budget: @unchecked Sendable {
        static let maximumTotalBytes = 100 * 1024 * 1024
        static let maximumDecodedPixels = 32_000_000
        private let lock = NSLock()
        private var bytes = 0
        private var pixels = 0
        func reserve(bytes newBytes: Int = 0, pixels newPixels: Int = 0) throws {
            lock.lock(); defer { lock.unlock() }
            guard newBytes >= 0, newPixels >= 0,
                  newBytes <= Self.maximumTotalBytes - bytes,
                  newPixels <= Self.maximumDecodedPixels - pixels else {
                throw DesktopRuntimeError("한 번에 가져오는 자료가 너무 큽니다. 사진이나 파일을 나누어 놓아 주세요.")
            }
            bytes += newBytes; pixels += newPixels
        }
    }

    static func load(_ provider: NSItemProvider, imagesOnly: Bool) async throws -> NativeDroppedMedia {
        for try await item in request(provider, imagesOnly: imagesOnly, budget: Budget()) { return item }
        throw DesktopRuntimeError("자료 제공자가 파일을 전달하지 못했습니다.")
    }

    /// AsyncThrowingStream's builder executes synchronously. performDrop invokes
    /// this method for every provider before returning to UIKit, then awaits the
    /// results. File representations are read before their callback returns.
    static func request(_ provider: NSItemProvider, imagesOnly: Bool, budget: Budget) -> AsyncThrowingStream<NativeDroppedMedia, Error> {
        let identifiers = provider.registeredTypeIdentifiers
        let suggestedName = provider.suggestedName
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let imageIdentifier = identifiers.first { UTType($0)?.conforms(to: .image) == true }
            let dataIdentifier = identifiers.first { id in
                guard let type = UTType(id) else { return false }
                return !imagesOnly && type.conforms(to: .data) && !type.conforms(to: .url) && !type.conforms(to: .text)
            }
            if let identifier = imageIdentifier ?? dataIdentifier {
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                    finish(continuation) {
                        guard let url else { throw error ?? DesktopRuntimeError("공유된 파일을 읽지 못했습니다.") }
                        return try readFile(url, imagesOnly: imagesOnly, type: UTType(identifier), name: suggestedName, budget: budget)
                    }
                }
            } else if identifiers.contains(where: { UTType($0)?.conforms(to: .fileURL) == true }) {
                if provider.canLoadObject(ofClass: NSURL.self) {
                    _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                        finish(continuation) {
                            guard let url = object as? NSURL, url.isFileURL else { throw error ?? DesktopRuntimeError("파일 주소를 읽지 못했습니다.") }
                            return try readFile(url as URL, imagesOnly: imagesOnly, budget: budget)
                        }
                    }
                } else {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                        finish(continuation) {
                            let url = fileURL(from: value)
                            guard let url else { throw error ?? DesktopRuntimeError("파일 주소를 읽지 못했습니다.") }
                            return try readFile(url, imagesOnly: imagesOnly, budget: budget)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                _ = provider.loadObject(ofClass: UIImage.self) { object, error in
                    finish(continuation) {
                        guard let image = object as? UIImage else { throw error ?? DesktopRuntimeError("사진을 읽지 못했습니다.") }
                        let ratio = min(1, 4096 / max(1, max(image.size.width, image.size.height)))
                        try budget.reserve(pixels: Int(ceil(image.size.width * ratio)) * Int(ceil(image.size.height * ratio)))
                        let bytes = try imageBytes(image)
                        return try decoded(bytes, name: suggestedName ?? "사진.png", type: .png, imagesOnly: true,
                                           budget: budget, pixelsReserved: true)
                    }
                }
            } else {
                continuation.finish(throwing: DesktopRuntimeError(imagesOnly ? "PDF 위에는 이미지 파일을 놓아 주세요." : "이 자료는 파일로 가져올 수 없습니다."))
            }
        }
    }

    private static func finish(_ continuation: AsyncThrowingStream<NativeDroppedMedia, Error>.Continuation,
                               _ operation: () throws -> NativeDroppedMedia) {
        do { continuation.yield(try operation()); continuation.finish() }
        catch { continuation.finish(throwing: error) }
    }

    static func fileURL(from value: NSSecureCoding?) -> URL? {
        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
        return url?.isFileURL == true ? url : nil
    }

    static func readFile(_ url: URL, imagesOnly: Bool, type: UTType? = nil, name: String? = nil, budget: Budget = Budget()) throws -> NativeDroppedMedia {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<NativeDroppedMedia, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let values = try readable.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumBytes else {
                    throw DesktopRuntimeError("50MB 이하의 파일을 선택해 주세요.")
                }
                try budget.reserve(bytes: size)
                let bytes = try Data(contentsOf: readable)
                guard bytes.count == size else { throw DesktopRuntimeError("읽는 동안 파일 크기가 바뀌었습니다. 다시 놓아 주세요.") }
                return try decoded(bytes, name: name ?? url.lastPathComponent,
                    type: type ?? UTType(filenameExtension: url.pathExtension) ?? .data, imagesOnly: imagesOnly,
                    budget: budget, bytesReserved: true)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DesktopRuntimeError("파일 제공자가 읽기를 완료하지 못했습니다.") }
        return try result.get()
    }

    static func decoded(_ bytes: Data, name: String, type: UTType, imagesOnly: Bool,
                        budget: Budget = Budget(), bytesReserved: Bool = false, pixelsReserved: Bool = false) throws -> NativeDroppedMedia {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw DesktopRuntimeError("50MB 이하의 파일을 선택해 주세요.") }
        if !bytesReserved { try budget.reserve(bytes: bytes.count) }
        var image: UIImage?
        if let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0 {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue.isFinite, height.doubleValue.isFinite else {
                throw DesktopRuntimeError("이미지 크기를 읽지 못했습니다.")
            }
            let dimension = min(4096, max(width.doubleValue, height.doubleValue))
            if !pixelsReserved {
                let ratio = min(1, dimension / max(width.doubleValue, height.doubleValue))
                try budget.reserve(pixels: Int(ceil(width.doubleValue * ratio)) * Int(ceil(height.doubleValue * ratio)))
            }
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
            ] as CFDictionary) { image = UIImage(cgImage: thumbnail) }
        }
        if imagesOnly && image == nil { throw DesktopRuntimeError("PDF 위에는 이미지 파일을 놓아 주세요. 다른 자료는 자료실로 가져올 수 있어요.") }
        return .init(data: bytes, name: (name as NSString).lastPathComponent, type: type, image: image)
    }

    static func imageBytes(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else { throw DesktopRuntimeError("빈 이미지입니다.") }
        let longest = max(image.size.width, image.size.height)
        let ratio = min(1, 4096 / longest)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let bytes = normalized.pngData(), bytes.count <= maximumBytes else { throw DesktopRuntimeError("이미지를 저장하기에는 크기가 너무 큽니다.") }
        return bytes
    }

    private static let previewQueue = NativeThumbnailWorkQueue(name: "app.bandal.markdown-image-preview", concurrency: 2)

    /// The worker owns file reads and ImageIO objects. Cancelling a waiting
    /// editor drops its result and prevents queued images from being decoded.
    static func previewImage(data: Data) async -> UIImage? {
        guard data.count <= maximumBytes else { return nil }
        return await previewQueue.image { preview(data) }?.image
    }
    static func previewImage(fileURL: URL) async -> UIImage? {
        await previewQueue.image {
            guard let before = try? NativeRepositoryContext.identity(fileURL),
                  let data = try? unchangedFileBytes(fileURL), let image = preview(data),
                  let after = try? NativeRepositoryContext.identity(fileURL),
                  NativeRepositoryContext.sameIdentity(before, after) else { return nil }
            return image
        }?.image
    }
    private static func preview(_ data: Data) -> UIImage? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
    static func base64(_ data: Data) async throws -> String {
        try await prepare { data.base64EncodedString() }
    }
    static func fileBase64(_ url: URL) async throws -> String {
        try await prepare {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?, result: Result<String, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                result = Result { try unchangedFileBytes(readable).base64EncodedString() }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw DesktopRuntimeError("파일 제공자가 읽기를 완료하지 못했습니다.") }
            return try result.get()
        }
    }
    private static func unchangedFileBytes(_ url: URL) throws -> Data {
        let before = try NativeRepositoryContext.identity(url)
        guard before["directory"] as? Bool == false, let rawSize = before["size"] as? String,
              let size = Int(rawSize), size > 0, size <= maximumBytes else {
            throw DesktopRuntimeError("50MB 이하의 파일을 선택해 주세요.")
        }
        let data = try Data(contentsOf: url)
        guard data.count == size, NativeRepositoryContext.sameIdentity(before, try NativeRepositoryContext.identity(url)) else {
            throw DesktopRuntimeError("읽는 동안 파일이 바뀌었습니다. 다시 선택해 주세요.")
        }
        return data
    }
    private static func prepare<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try work()
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: { worker.cancel() }
    }

    @MainActor static func saveImage(_ image: UIImage, courseID: String, store: NativeWorkspaceStore) async throws -> NativeImportedImage {
        let bytes = try await prepare { try imageBytes(image) }
        let name = "이미지-" + UUID().uuidString + ".png"
        let path = try await save(bytes: bytes, name: name, courseID: courseID, store: store)
        return .init(relativePath: path, pixelSize: image.size, name: name)
    }

    @MainActor static func markdown(_ items: [NativeDroppedMedia], courseID: String, store: NativeWorkspaceStore) async throws -> String {
        var fragments: [String] = []
        for item in items {
            let path: String
            if let image = item.image { path = try await saveImage(image, courseID: courseID, store: store).relativePath }
            else {
                let ext = (item.name as NSString).pathExtension
                let name = "첨부-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
                path = try await save(bytes: item.data, name: name, courseID: courseID, store: store)
            }
            fragments.append(markdownLink(name: item.name, path: path, image: item.image != nil))
        }
        return "\n" + fragments.joined(separator: "\n\n") + "\n"
    }

    static func markdownLink(name: String, path: String, image: Bool) -> String {
        let label = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()#?%"))) ?? path
        return (image ? "!" : "") + "[" + label + "](" + encoded + ")"
    }

    @MainActor private static func save(bytes: Data, name: String, courseID: String, store: NativeWorkspaceStore) async throws -> String {
        let encoded = try await base64(bytes)
        try Task.checkCancellation()
        let value = try await store.invoke("materials:writeFile", ["courseId": courseID, "dirRelPath": "assets", "createDirIfMissing": true,
            "fileName": name, "encoding": "base64", "data": encoded])
        guard let path = (value as? [String: Any])?["relPath"] as? String else { throw DesktopRuntimeError("첨부 파일의 저장 결과를 확인하지 못했습니다.") }
        return path
    }
}

@MainActor
final class NativeEditorDropInteraction: NSObject, UIDropInteractionDelegate {
    private let imagesOnly: Bool
    private let receive: ([NativeDroppedMedia], CGPoint) -> Void
    var onBegin: ((CGPoint) -> Void)?
    var onError: ((Error) -> Void)?
    var isEnabled: () -> Bool = { true }
    private var loading = false
    init(view: UIView, imagesOnly: Bool, receive: @escaping ([NativeDroppedMedia], CGPoint) -> Void) {
        self.imagesOnly = imagesOnly; self.receive = receive
        super.init()
        view.addInteraction(UIDropInteraction(delegate: self))
    }
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        isEnabled() && !loading && !session.items.isEmpty && session.items.count <= NativeEditorMediaImport.maximumItems
            && session.items.allSatisfy { NativeEditorMediaImport.supports($0.itemProvider, imagesOnly: imagesOnly) }
    }
    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: dropInteraction(interaction, canHandle: session) ? .copy : .forbidden)
    }
    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        guard let view = interaction.view, dropInteraction(interaction, canHandle: session) else { return }
        let point = session.location(in: view), providers = session.items.map(\.itemProvider)
        onBegin?(point); loading = true
        let budget = NativeEditorMediaImport.Budget()
        let requests = providers.map { NativeEditorMediaImport.request($0, imagesOnly: imagesOnly, budget: budget) }
        Task { @MainActor in
            defer { loading = false }
            do {
                var items: [NativeDroppedMedia] = []
                for request in requests {
                    var received = false
                    for try await item in request { items.append(item); received = true }
                    guard received else { throw DesktopRuntimeError("자료 제공자가 파일을 전달하지 못했습니다.") }
                }
                guard isEnabled() else { throw DesktopRuntimeError("문서가 변경되어 파일을 넣지 않았습니다. 다시 시도해 주세요.") }
                receive(items, point)
            } catch { onError?(error) }
        }
    }
}
