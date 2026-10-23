import SwiftUI
import Combine

/// Retains only document identities, so scoped mutations invalidate cached,
/// offscreen cards without querying every visible PDF again.
@MainActor
struct NativeLibraryThumbnailRevisions {
    private struct Document {
        let root: String, course: String, path: String
    }
    private var documents: [String: Document] = [:]
    private var revisions: [String: UInt64] = [:]
    private var rootRevisions: [String: UInt64] = [:]

    mutating func key(root: String, course: String, path: String) -> String {
        let identity = root + ":" + course + ":" + path
        documents[identity] = Document(root: root, course: course, path: path)
        return [identity, String(revisions[identity] ?? 0), String(rootRevisions[root] ?? 0)].joined(separator: ":")
    }

    mutating func receive(_ event: NativeWorkspaceEvent, root: String) {
        let value = event.payload as? [String: Any] ?? [:]
        if event.channel == "nativeWorkspace:externalMutationFinished" {
            if value["changedDocuments"] is [[String: Any]] || value["changedCourseIDs"] is [String] {
                for (identity, document) in documents where document.root == root {
                    if Self.affects(value, course: document.course, path: document.path) { revisions[identity, default: 0] &+= 1 }
                }
            } else { rootRevisions[root, default: 0] &+= 1 }
        } else if ["nativeWorkspace:pdfContentChanged", "nativeWorkspace:materialReplaced"].contains(event.channel),
                  let course = value["courseId"] as? String, let path = value["relPath"] as? String {
            revisions[root + ":" + course + ":" + path, default: 0] &+= 1
        }
    }

    static func affects(_ payload: Any, course: String?, path: String) -> Bool {
        let value = payload as? [String: Any] ?? [:]
        let mutation: [String: Any]? = course.map { ["courseId": $0, "relPath": path] }
        return NativeWorkspaceStore.affects(changedDocuments: value["changedDocuments"] as? [[String: Any]],
            changedCourseIDs: (value["changedCourseIDs"] as? [String]).map(Set.init), mutation)
    }
}

/// Keeps the original PDF preview cached separately from editable objects. An
/// ink update does not reopen and decode the PDF. A document-scoped event
/// revision invalidates the composite even while its card is offscreen.
@MainActor
final class NativeLibraryDocumentThumbnailCache {
    static let shared = NativeLibraryDocumentThumbnailCache()
    private let cache = NativeThumbnailImageCache(bytes: 16 * 1024 * 1024, count: 40)
    private let worker = NativeThumbnailWorkQueue(name: "bandal.library.thumbnail-composite")
    private var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private var revisions = NativeLibraryThumbnailRevisions()

    func image(url: URL, course: String, material: NativeMaterial, store: NativeWorkspaceStore, refresh: String) async -> UIImage? {
        observe(store)
        let revision = "\(material.mtime ?? 0):\(material.size ?? 0)"
        let identity = revisions.key(root: store.root.path, course: course, path: material.relPath)
        let key = [identity, revision, refresh].joined(separator: ":")
        return await cache.image(key: key) { [worker] in
            guard !Task.isCancelled else { return nil }
            async let original = NativeLibraryThumbnailCache.shared.image(url: url, revision: revision)
            do {
                let snapshot = try await store.invokePrivate("nativePDF:thumbnailSnapshot", ["courseId": course, "relPath": material.relPath, "page": 1]) as? [String: Any] ?? [:]
                guard !Task.isCancelled else { return nil }
                let rows = snapshot["drawings"] as? [[String: Any]] ?? []
                let annotations = snapshot["annotations"] as? [[String: Any]] ?? []
                guard !rows.isEmpty || !annotations.isEmpty else { return await original }
                var images: [String: UIImage] = [:]
                for row in rows where row["kind"] as? String == "image" {
                    guard !Task.isCancelled else { return nil }
                    guard let data = row["data"] as? [String: Any], let image = data["image"] as? [String: Any],
                          let relative = image["relPath"] as? String, let id = row["id"] as? String,
                          let imageURL = try? await NativeLibraryMaterialAccess.url(store: store, courseID: course, relativePath: relative) else { continue }
                    images[id] = await NativeLibraryThumbnailCache.shared.image(url: imageURL, revision: "")
                }
                guard let base = await original, !Task.isCancelled else { return nil }
                let input = NativeThumbnailCompositeInput(base: base, rows: rows, annotations: annotations, images: images)
                return await worker.image { input.render() }?.image
            } catch { return await original }
        }
    }

    private func observe(_ store: NativeWorkspaceStore) {
        let token = ObjectIdentifier(store)
        guard subscriptions[token] == nil else { return }
        let root = store.root.path
        subscriptions[token] = store.events.sink { [weak self] event in
            self?.revisions.receive(event, root: root)
        }
    }

    nonisolated static func composite(base: UIImage, rows: [[String: Any]], annotations: [[String: Any]], images: [String: UIImage]) -> UIImage {
        let paths = NativePDFInkPathCache(byteLimit: 8 * 1024 * 1024, countLimit: 256)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: format).image { renderer in
            base.draw(in: CGRect(origin: .zero, size: base.size))
            let context = renderer.cgContext
            let mapper = InkCoordinateMapper.whiteboard(size: base.size)
            for annotation in annotations {
                guard let rects = annotation["rects"] as? [[String: Any]] else { continue }
                let color: UIColor
                switch annotation["color"] as? String {
                case "green": color = UIColor(red: 0.45, green: 0.83, blue: 0.56, alpha: 1)
                case "pink": color = UIColor(red: 1, green: 0.56, blue: 0.71, alpha: 1)
                case "blue": color = UIColor(red: 0.44, green: 0.73, blue: 1, alpha: 1)
                default: color = UIColor(red: 1, green: 0.9, blue: 0.35, alpha: 1)
                }
                context.saveGState(); context.setBlendMode(.multiply); context.setFillColor(color.withAlphaComponent(0.32).cgColor)
                for rect in rects {
                    guard let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                          let width = rect["width"] as? Double, let height = rect["height"] as? Double else { continue }
                    context.fill(CGRect(x: x * base.size.width, y: y * base.size.height, width: width * base.size.width, height: height * base.size.height))
                }
                context.restoreGState()
            }
            for raw in rows {
                var row = raw
                if row["nativePath"] == nil, ["ink", "highlighter"].contains(row["kind"] as? String ?? ""), (row["data"] as? [String: Any])?["inkVersion"] == nil {
                    row["nativePath"] = try? NativePDFLegacyInk.path(row, aspect: base.size.height / max(1, base.size.width))
                }
                NativePDFObjectRenderer.drawPrepared(row, in: context, mapper: mapper, image: images[row["id"] as? String ?? ""], preparedInk: paths.prepare(row, aspect: base.size.height / max(1, base.size.width)), compact: true)
            }
        }
    }
}

struct NativeLibraryMaterialThumbnail: View {
    let store: NativeWorkspaceStore
    let material: NativeMaterial
    let courseID: String?
    let url: URL?
    let symbol: String
    var refresh = ""
    @State private var image: UIImage?
    @State private var loadedIdentity = ""
    @State private var mutationRevision = 0
    private var revision: String { "\(material.mtime ?? 0):\(material.size ?? 0)" }
    private var taskID: String { [courseID ?? "", url?.path ?? "", revision, refresh, String(mutationRevision)].joined(separator: ":") }
    var body: some View {
        renderedPreview
            .task(id: taskID) { await loadPreview() }
            .onReceive(store.events, perform: receive)
            .accessibilityHidden(true)
    }
    private var renderedPreview: some View {
        NativeLibraryThumbnail(url: url, symbol: symbol, revision: revision, isDirectory: material.isDirectory)
            .overlay { overlayImage }
    }
    @ViewBuilder private var overlayImage: some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFit().padding(3)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    private func loadPreview() async {
        let identity = [courseID ?? "", url?.path ?? "", revision].joined(separator: ":")
        if loadedIdentity != identity { image = nil; loadedIdentity = identity }
        guard material.kind == "pdf", let url, let courseID else { return }
        // Let an immediate document-open request reach storage before optional previews.
        try? await Task.sleep(for: .milliseconds(mutationRevision > 0 ? 250 : 120))
        guard !Task.isCancelled else { return }
        let next = await NativeLibraryDocumentThumbnailCache.shared.image(url: url, course: courseID, material: material,
            store: store, refresh: refresh)
        guard !Task.isCancelled else { return }
        image = next
    }
    private func receive(_ event: NativeWorkspaceEvent) {
        if event.channel == "nativeWorkspace:externalMutationFinished" {
            if NativeLibraryThumbnailRevisions.affects(event.payload, course: courseID, path: material.relPath) { mutationRevision &+= 1 }
            return
        }
        guard ["nativeWorkspace:pdfContentChanged", "nativeWorkspace:materialReplaced"].contains(event.channel),
              let value = event.payload as? [String: Any], value["courseId"] as? String == courseID,
              value["relPath"] as? String == material.relPath else { return }
        mutationRevision &+= 1
    }
}

/// Owned immutable snapshots are handed to one renderer; no cache or UIKit view
/// is shared with the main actor while the bitmap is being composed.
struct NativeThumbnailCompositeInput: @unchecked Sendable {
    let base: UIImage
    let rows: [[String: Any]]
    var annotations: [[String: Any]] = []
    var images: [String: UIImage] = [:]
    func render() -> UIImage {
        NativeLibraryDocumentThumbnailCache.composite(base: base, rows: rows, annotations: annotations, images: images)
    }
}
