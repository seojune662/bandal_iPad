import UIKit

/// AI에게 묻기 on a lasso selection. The selected area is drawn as it looks on the page (the PDF, ink, inserted
/// images and highlights), handed to the AI panel's composer as an attachment and the panel opens. Nothing is sent:
/// the reader writes the question and sends it, so a capture alone never reaches the AI service.
enum NativePDFAskAI {
    /// Value copies taken when the reader taps, before the first suspension: a later edit cannot enter the picture.
    struct Capture {
        let title: String
        let courseID: String
        let relativePath: String
        let page: Int
        /// The area, in the page's unit square.
        let bounds: CGRect
        let rows: [[String: Any]]
        let annotations: [[String: Any]]
        let revision: String
        let original: URL
    }

    /// The same picture a region chosen from the AI panel (영역) attaches.
    @MainActor static func attachment(_ capture: Capture, store: NativeWorkspaceStore) async throws -> NativeAssistantAttachment {
        var images: [String: UIImage] = [:]
        let budget = NativeEditorMediaImport.Budget()
        for row in capture.rows where row["kind"] as? String == "image" {
            guard let id = row["id"] as? String, let data = row["data"] as? [String: Any],
                  let image = data["image"] as? [String: Any], let relative = image["relPath"] as? String else { continue }
            let url = try await NativeLibraryMaterialAccess.url(store: store, courseID: capture.courseID, relativePath: relative)
            let read = try await Task.detached(priority: .userInitiated) { try NativeEditorMediaImport.readFile(url, imagesOnly: true, budget: budget) }.value
            guard let bitmap = read.image else { throw NativePDFError.invalid("삽입한 이미지를 읽지 못했습니다.") }
            images[id] = bitmap
        }
        try Task.checkCancellation()
        guard let image = await NativePDFRegionCapture.annotatedImage(url: capture.original, page: capture.page, bounds: capture.bounds,
                                                                     rows: capture.rows, annotations: capture.annotations, images: images),
              let dataURL = NativeAssistantAttachment.dataURL(image) else { throw NativePDFError.invalid("선택한 영역을 캡처하지 못했습니다. 다시 선택해 주세요.") }
        return NativeAssistantAttachment(title: capture.title, imageDataURL: dataURL, courseID: capture.courseID,
                                         relativePath: capture.relativePath, page: capture.page, revision: capture.revision)
    }

    /// Fills the composer of the current space's AI panel and opens it (the request 끝내고 요약 also uses), without sending.
    @MainActor static func open(_ attachment: NativeAssistantAttachment, store: NativeWorkspaceStore) {
        store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:assistantRequest",
                                               payload: NativeAssistantRequest(attachment: attachment, prompt: "", sends: false)))
    }
}
