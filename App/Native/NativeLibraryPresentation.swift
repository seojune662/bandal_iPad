import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

/// Shared between the compact materials rail and its expanded presentation.
enum NativeLibraryDisplayMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery
    var id: String { rawValue }
    var title: String {
        switch self { case .icons: "아이콘"; case .list: "목록"; case .columns: "열"; case .gallery: "갤러리" }
    }
    var symbol: String {
        switch self { case .icons: "square.grid.2x2"; case .list: "list.bullet"; case .columns: "rectangle.split.3x1"; case .gallery: "rectangle.stack" }
    }
}

struct NativeLibraryColumn: Identifiable, Equatable {
    let path: String
    let title: String
    let materials: [NativeMaterial]
    var id: String { path }
}

enum NativeLibraryPresentation {
    static func sorted(_ items: [NativeMaterial]) -> [NativeMaterial] {
        items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    /// Only valid ancestors are included. A deleted folder cannot leave an empty
    /// inaccessible column selected after the library refreshes.
    static func columns(folder: String, materials: [NativeMaterial]) -> [NativeLibraryColumn] {
        var result = [NativeLibraryColumn(path: "", title: "전체 자료", materials: sorted(materials))]
        var children = materials
        var path = ""
        for component in folder.split(separator: "/") {
            path = path.isEmpty ? String(component) : path + "/" + component
            guard let directory = children.first(where: { $0.relPath == path && $0.isDirectory }) else { break }
            children = directory.children ?? []
            result.append(NativeLibraryColumn(path: path, title: directory.name, materials: sorted(children)))
        }
        return result
    }
    static func thumbnailKey(url: URL, revision: String) -> String { url.standardizedFileURL.path + ":" + revision }
}

/// PDFKit objects remain on a worker queue. Decoding the original image at a
/// bounded size keeps a sidebar of large scans from occupying the main thread.
@MainActor
final class NativeLibraryThumbnailCache {
    static let shared = NativeLibraryThumbnailCache()
    private let cache = NativeThumbnailImageCache(bytes: 24 * 1024 * 1024, count: 80)
    private let worker = NativeThumbnailWorkQueue(name: "bandal.library.thumbnails", concurrency: 2)
    func image(url: URL, revision: String) async -> UIImage? {
        let key = NativeLibraryPresentation.thumbnailKey(url: url, revision: revision)
        return await cache.image(key: key) { [worker] in
            await worker.image { Self.render(url: url) }?.image
        }
    }
    nonisolated private static func render(url: URL) -> UIImage? {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
            let coordinates = NativePDFPageCoordinates(page: page)
            let scale = min(420 / max(1, coordinates.width), 540 / max(1, coordinates.height))
            return page.thumbnail(of: CGSize(width: coordinates.width * scale, height: coordinates.height * scale), for: .cropBox)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 540,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct NativeLibraryThumbnail: View {
    let url: URL?
    let symbol: String
    var revision = ""
    var isDirectory = false
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(NativeDesktopTheme.raised)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(3)
            } else {
                Image(systemName: symbol).font(.system(size: isDirectory ? 34 : 30, weight: .light))
                    .foregroundStyle(isDirectory ? Color.accentColor : NativeDesktopTheme.muted)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
        .task(id: (url?.path ?? "") + ":" + revision) {
            image = nil
            guard let url, !isDirectory else { return }
            let next = await NativeLibraryThumbnailCache.shared.image(url: url, revision: revision)
            guard !Task.isCancelled else { return }
            image = next
        }
    }
}

enum NativeLibraryMaterialAccess {
    @MainActor static func url(store: NativeWorkspaceStore, courseID: String, relativePath: String) async throws -> URL {
        guard let path = try await store.invokePrivate("nativeMaterial:path", ["courseId": courseID, "relPath": relativePath]) as? String else {
            throw DesktopRuntimeError("자료 파일의 경로를 찾지 못했습니다.")
        }
        return URL(fileURLWithPath: path)
    }
}

/// A file representation lets editors consume bytes without depending on the
/// sending view or an app-private drag string. A URL representation also permits
/// normal Files and external-app drops.
enum NativeLibraryAssetProvider {
    static func make(url: URL, retaining owner: AnyObject? = nil) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            _ = owner
            completion(url, false, nil)
            return nil
        }
        return provider
    }
}

struct NativeLibraryMaterialDrag: ViewModifier {
    let url: URL?
    let store: NativeWorkspaceStore
    let document: NativeDocumentReference
    @ViewBuilder func body(content: Content) -> some View {
        if let url {
            content.onDrag {
                if url.pathExtension.lowercased() == "pdf" {
                    NativeLibraryPDFDragExport.provider(store: store, document: document)
                } else {
                    NativeLibraryAssetProvider.make(url: url)
                }
            }
        }
        else { content }
    }
}

/// Prepare the annotated file only when the receiving app requests it. Do not
/// advertise the original file URL: a destination could choose it over the PDF
/// representation and silently lose the user's handwriting.
@MainActor
final class NativeLibraryPDFDragExport {
    private let store: NativeWorkspaceStore
    private let document: NativeDocumentReference
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BandalPDFDrag-" + UUID().uuidString, isDirectory: true)
    private var preparation: Task<URL, Error>?

    private init(store: NativeWorkspaceStore, document: NativeDocumentReference) {
        self.store = store
        self.document = document
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func provider(store: NativeWorkspaceStore, document: NativeDocumentReference) -> NSItemProvider {
        let export = NativeLibraryPDFDragExport(store: store, document: document)
        let provider = NSItemProvider()
        provider.suggestedName = (document.relativePath as NSString).lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            let progress = Progress(totalUnitCount: 1)
            let loading = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    let url = try await export.file()
                    try Task.checkCancellation()
                    completion(url, false, nil)
                    progress.completedUnitCount = 1
                } catch { completion(nil, false, error) }
            }
            progress.cancellationHandler = { loading.cancel() }
            return progress
        }
        return provider
    }

    private func file() async throws -> URL {
        if let preparation { return try await preparation.value }
        let task = Task { @MainActor [store, document, directory] in
            try await store.flushDocuments()
            guard let output = try await store.invokePrivate("nativePDF:exportBytes", [
                "courseId": document.courseID, "relPath": document.relativePath
            ]) as? [String: Any], let encoded = output["data"] as? String,
                  let name = output["suggestedName"] as? String else {
                throw DesktopRuntimeError("필기를 포함한 PDF를 준비하지 못했습니다.")
            }
            return try await Task.detached(priority: .userInitiated) {
                guard let bytes = Data(base64Encoded: encoded) else {
                    throw DesktopRuntimeError("필기를 포함한 PDF를 읽지 못했습니다.")
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent((name as NSString).lastPathComponent)
                try bytes.write(to: url, options: .atomic)
                return url
            }.value
        }
        preparation = task
        return try await task.value
    }
}
