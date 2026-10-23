import Darwin
import PDFKit
import QuickLook
import UIKit
import UniformTypeIdentifiers

@MainActor
final class DesktopFileServices: NSObject, UIDocumentPickerDelegate, QLPreviewControllerDataSource, @MainActor QLPreviewControllerDelegate {
    weak var presenter: UIViewController?
    private let runtime: DesktopRuntime
    private var selection: CheckedContinuation<[URL]?, Error>?
    private weak var activePicker: UIDocumentPickerViewController?
    private weak var activeShare: UIActivityViewController?
    private var shareIdentifier: UUID?
    private var cancelShare: (() -> Void)?
    private var presentationGeneration = 0
    private var previewURLs: [ObjectIdentifier: URL] = [:]
    private var ownedExports: Set<URL> = []
    private lazy var staging = DesktopFileStaging.shared(root: runtime.root)
    private var clipboardSequence = 0
    private var clipboardSnapshot: (token: Int, changeCount: Int)?
    init(runtime: DesktopRuntime) { self.runtime = runtime }

    /// Retiring a renderer must settle its native continuations, including a
    /// picker/share sheet whose normal UIKit callback will arrive later.
    func cancelPresentations() {
        presentationGeneration += 1
        let pending = selection; selection = nil
        let picker = activePicker; activePicker = nil
        let cancel = cancelShare; cancelShare = nil; shareIdentifier = nil
        let share = activeShare; activeShare = nil
        pending?.resume(returning: nil); cancel?()
        picker?.dismiss(animated: false); share?.dismiss(animated: false)
        if let preview = presenter?.presentedViewController as? QLPreviewController,
           previewURLs[ObjectIdentifier(preview)] != nil { preview.dismiss(animated: false) }
        let previews = Array(previewURLs.values); previewURLs.removeAll()
        previews.forEach(releaseTemporaryFile)
    }

    func readAttachment(courseID: String, relPath: String) async throws -> Data {
        guard let path = try await runtime.invokePrivate("nativeMaterial:path", request: ["courseId": courseID, "relPath": relPath]) as? String else {
            throw DesktopRuntimeError("첨부할 자료를 확인하지 못했습니다.")
        }
        let root = runtime.root
        return try await Task.detached {
            let file = try DesktopMaterialFile(path: path, root: root)
            guard file.size <= 25 * 1024 * 1024 else { throw DesktopRuntimeError("브라우저에는 25MB 이하의 파일을 첨부할 수 있습니다.") }
            var bytes = Data(), offset: UInt64 = 0
            while offset < file.size {
                try Task.checkCancellation()
                let chunk = try file.read(offset: offset, count: Int(min(256 * 1024, UInt64(file.size) - offset)))
                guard !chunk.isEmpty else { throw DesktopRuntimeError("자료 읽기가 중단되었습니다.") }
                bytes += chunk; offset += UInt64(chunk.count)
            }
            return bytes
        }.value
    }

    func canHandle(_ channel: String) -> Bool {
        ["courses:pickFolder", "plugins:pickFolder", "settings:pickDataRoot", "native:saveFile", "native:pickFiles", "native:chatPickAttachments", "native:marketPickPreview", "native:marketSanitizePreview", "native:marketPickPluginArchive", "native:revealFile", "native:openLogs", "materials:reveal", "materials:preview", "materials:share", "materials:export", "chat:pickAttachments", "chat:openArtifact", "print:savePdfAs", "print:pdf", "clipboard:beginCopy", "clipboard:writeImage"].contains(channel)
    }

    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "native:marketSanitizePreview":
            guard let dataURL = request["dataUrl"] as? String, dataURL.hasPrefix("data:image/png;base64,"), dataURL.utf8.count <= 6 * 1024 * 1024,
                  let data = Data(base64Encoded: String(dataURL.dropFirst("data:image/png;base64,".count))) else { throw DesktopRuntimeError("미리보기 PNG를 확인해 주세요.") }
            return try DesktopMarketMedia.preview(data, pickedImage: false).base64EncodedString()
        case "native:marketPickPreview", "native:marketPickPluginArchive":
            let archive = channel == "native:marketPickPluginArchive"
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: archive ? [.zip] : [.image], asCopy: true)
            guard let file = try await pick(picker)?.first else { return NSNull() }
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let maximum = (archive ? 8 : 10) * 1024 * 1024
            guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= maximum else { throw DesktopRuntimeError(archive ? "플러그인 ZIP은 8MB까지 선택할 수 있습니다." : "이미지는 10MB까지 선택할 수 있습니다.") }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard data.count <= maximum else { throw DesktopRuntimeError("선택한 파일이 너무 큽니다.") }
            if archive { return ["data": data.base64EncodedString(), "fileName": file.lastPathComponent] }
            return ["dataUrl": "data:image/png;base64," + (try DesktopMarketMedia.preview(data, pickedImage: true)).base64EncodedString(), "fileName": file.lastPathComponent]
        case "chat:pickAttachments", "native:chatPickAttachments", "native:pickFiles":
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .content], asCopy: true)
            picker.allowsMultipleSelection = channel == "chat:pickAttachments" || channel == "native:chatPickAttachments" || request["multiple"] as? Bool == true
            let files = try await pick(picker) ?? []
            guard files.count <= 20 else { throw DesktopRuntimeError("파일은 한 번에 20개까지 선택할 수 있습니다.") }
            var paths: [String] = []
            do {
                for file in files {
                    let access = file.startAccessingSecurityScopedResource()
                    defer { if access { file.stopAccessingSecurityScopedResource() } }
                    let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    let attachment = channel == "chat:pickAttachments" || channel == "native:chatPickAttachments"
                    guard properties.isRegularFile == true, properties.fileSize != nil else { throw DesktopRuntimeError("가져올 파일을 확인해 주세요.") }
                    if attachment, properties.fileSize! > 64 * 1024 * 1024 { throw DesktopRuntimeError("채팅 첨부 파일은 64MB까지 선택할 수 있습니다.") }
                    paths.append(try staging.copy(file).path)
                }
                return ["paths": paths]
            } catch { staging.discard(paths: paths); throw error }
        case "clipboard:beginCopy":
            clipboardSequence += 1
            clipboardSnapshot = (clipboardSequence, UIPasteboard.general.changeCount)
            return ["token": clipboardSequence]
        case "clipboard:writeImage":
            let snapshot = clipboardSnapshot; clipboardSnapshot = nil
            guard let snapshot, request["token"] as? Int == snapshot.token, UIPasteboard.general.changeCount == snapshot.changeCount else { return ["written": false] }
            let html = request["html"] as? String ?? "", text = request["text"] as? String ?? ""
            let png = request["png"] as? String
            guard html.utf8.count + text.utf8.count + (png?.utf8.count ?? 0) <= 64 * 1024 * 1024 else { throw DesktopRuntimeError("복사할 이미지가 너무 큽니다.") }
            var item: [String: Any] = [UTType.html.identifier: Data(html.utf8), UTType.utf8PlainText.identifier: Data(text.utf8)]
            if let png {
                guard png.hasPrefix("data:image/png;base64,"), let data = Data(base64Encoded: String(png.dropFirst("data:image/png;base64,".count))), let image = UIImage(data: data), let validPNG = image.pngData() else { throw DesktopRuntimeError("이미지를 읽지 못했습니다.") }
                item[UTType.png.identifier] = validPNG
            }
            UIPasteboard.general.setItems([item])
            return ["written": true]
        case "native:revealFile":
            guard let path = request["path"] as? String else { throw DesktopRuntimeError("파일을 확인해 주세요.") }
            let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(runtime.root.resolvingSymlinksInPath().path + "/") else { throw DesktopRuntimeError("파일 경로에 접근할 수 없습니다.") }
            try preview(target)
            return ["ok": true]
        case "native:openLogs":
            await runtime.log.flush()
            let folder = runtime.root.appendingPathComponent("Logs")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("bandal.log")
            if !FileManager.default.fileExists(atPath: file.path) { try Data("반달 iPad 실행 기록\n".utf8).write(to: file, options: .atomic) }
            try preview(file)
            return ["ok": true]
        case "courses:pickFolder", "plugins:pickFolder", "settings:pickDataRoot":
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            guard let selected = try await pick(picker)?.first else { return channel == "plugins:pickFolder" ? ["path": NSNull()] : NSNull() }
            let url = try DesktopFileAccess.shared(root: runtime.root).authorize(selected)
            if channel == "settings:pickDataRoot" {
                _ = try await runtime.invoke("settings:set", request: ["dataRoot": url.path])
                return ["dataRoot": url.path]
            }
            if channel == "plugins:pickFolder" { return ["path": url.path] }
            return ["path": url.path, "name": url.lastPathComponent]
        case "native:saveFile", "print:savePdfAs":
            guard let name = request["suggestedName"] as? String, let encoded = (request["data"] ?? request["base64"]) as? String, let bytes = Data(base64Encoded: encoded) else { throw DesktopRuntimeError("내보낼 파일을 확인해 주세요.") }
            let source = try temporaryFile(name: name, data: bytes)
            defer { releaseTemporaryFile(source) }
            let picker = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
            let destination = try await pick(picker)?.first
            if channel == "print:savePdfAs" { return ["ok": true, "canceled": destination == nil, "savedPath": destination?.path as Any? ?? NSNull()] }
            return ["saved": destination != nil, "path": destination?.path as Any? ?? NSNull()]
        case "print:pdf":
            guard let encoded = request["base64"] as? String, let bytes = Data(base64Encoded: encoded), PDFDocument(data: bytes) != nil else { throw DesktopRuntimeError("인쇄할 PDF를 확인해 주세요.") }
            let printer = UIPrintInteractionController.shared
            let information = UIPrintInfo(dictionary: nil)
            information.jobName = request["jobName"] as? String ?? "반달"
            information.outputType = .general
            printer.printInfo = information; printer.printingItem = bytes
            guard let view = presenter?.view else { throw DesktopRuntimeError("인쇄 창을 열 수 없습니다.") }
            let printed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                printer.present(from: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), in: view, animated: true) { _, printed, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: printed) }
                }
            }
            return ["ok": true, "printed": printed]
        case "materials:reveal", "materials:preview", "chat:openArtifact":
            let source = try await materialSnapshot(request)
            do { try preview(source) } catch { releaseTemporaryFile(source); throw error }
            return ["ok": true]
        case "materials:export":
            let source = try await materialSnapshot(request, includingPDFAnnotations: true)
            defer { releaseTemporaryFile(source) }
            let destination = try await pick(UIDocumentPickerViewController(forExporting: [source], asCopy: true))?.first
            return ["saved": destination != nil, "canceled": destination == nil]
        case "materials:share":
            let source = try await materialSnapshot(request, includingPDFAnnotations: true)
            defer { releaseTemporaryFile(source) }
            guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw DesktopRuntimeError("열린 창을 닫은 뒤 다시 시도해 주세요.") }
            let identifier = UUID()
            defer { if shareIdentifier == identifier { cancelShare = nil; activeShare = nil; shareIdentifier = nil } }
            let shared = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                let completion = DesktopDialogCompletion<Result<Bool, Error>> { continuation.resume(with: $0) }
                let activity = UIActivityViewController(activityItems: [source], applicationActivities: nil)
                activity.view.accessibilityIdentifier = "bandal-material-share"
                shareIdentifier = identifier; activeShare = activity; cancelShare = { completion.finish(.success(false)) }
                activity.completionWithItemsHandler = { _, completed, _, error in
                    if let error { completion.finish(.failure(error)) } else { completion.finish(.success(completed)) }
                }
                activity.popoverPresentationController?.sourceView = presenter.view
                activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
                presenter.present(activity, animated: true)
            }
            return ["shared": shared, "canceled": !shared]
        default: throw DesktopRuntimeError("Unknown file service: \(channel)", code: "ENOSYS")
        }
    }

    private func materialSnapshot(_ request: [String: Any], includingPDFAnnotations: Bool = false) async throws -> URL {
        let generation = presentationGeneration
        guard let courseID = request["courseId"] as? String, let relative = request["relPath"] as? String,
              let path = try await runtime.invokePrivate("nativeMaterial:path", request: ["courseId": courseID, "relPath": relative]) as? String else { throw DesktopRuntimeError("자료를 확인해 주세요.") }
        if includingPDFAnnotations, (relative as NSString).pathExtension.lowercased() == "pdf" {
            // Library exports must use the same canonical ink/image/highlight
            // compositor as the PDF editor. Never silently fall back to the
            // original when binding validation or image resolution fails.
            guard let output = try await runtime.invokePrivate("nativePDF:exportBytes", request: ["courseId": courseID, "relPath": relative]) as? [String: Any],
                  let name = output["suggestedName"] as? String, let encoded = output["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { throw DesktopRuntimeError("필기를 포함한 PDF를 준비하지 못했습니다.") }
            guard generation == presentationGeneration else { throw CancellationError() }
            try Task.checkCancellation()
            return try temporaryFile(name: name, data: data)
        }
        let source = try await DesktopMaterialExport.snapshot(path: path, root: runtime.root)
        guard generation == presentationGeneration else {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            throw CancellationError()
        }
        ownedExports.insert(source)
        return source
    }

    private func preview(_ url: URL) throws {
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw DesktopRuntimeError("열린 창을 닫은 뒤 다시 시도해 주세요.") }
        let preview = QLPreviewController(); preview.dataSource = self; preview.delegate = self
        previewURLs[ObjectIdentifier(preview)] = url
        presenter.present(preview, animated: true)
    }

    private func temporaryFile(name: String, data: Data) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.utf8.contains(0) else { throw DesktopRuntimeError("파일 이름을 확인해 주세요.") }
        let folder = runtime.root.appendingPathComponent("Temporary/Exports/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try data.write(to: file, options: .atomic)
        ownedExports.insert(file)
        return file
    }

    private func releaseTemporaryFile(_ file: URL) {
        guard ownedExports.remove(file) != nil else { return }
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? FileManager.default.removeItem(at: folder) }
    }

    private func pick(_ picker: UIDocumentPickerViewController) async throws -> [URL]? {
        guard selection == nil, let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw DesktopRuntimeError("열린 파일 선택 창을 먼저 닫아 주세요.") }
        picker.view.accessibilityIdentifier = "bandal-document-picker"
        picker.delegate = self
        return try await withCheckedThrowingContinuation { continuation in
            selection = continuation; activePicker = picker
            presenter.present(picker, animated: true)
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard activePicker === controller else { return }
        let pending = selection; selection = nil; activePicker = nil; pending?.resume(returning: urls)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard activePicker === controller else { return }
        let pending = selection; selection = nil; activePicker = nil; pending?.resume(returning: nil)
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURLs[ObjectIdentifier(controller)] == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        // UIKit may finish querying a preview that navigation just cancelled.
        (previewURLs[ObjectIdentifier(controller)] ?? runtime.root.appendingPathComponent("Temporary/UnavailablePreview")) as NSURL
    }
    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        if let source = previewURLs.removeValue(forKey: ObjectIdentifier(controller)) { releaseTemporaryFile(source) }
    }
}
