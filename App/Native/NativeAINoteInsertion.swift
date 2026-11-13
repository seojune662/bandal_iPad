import CoreGraphics
import CryptoKit
import Foundation

/// What "노트에 넣기" places its note next to, in order: the passage or area the question was asked about,
/// then a passage the answer quotes, then the middle of what is on screen.
struct NativeAINoteTarget: Equatable {
    var page: Int
    /// An area the question captured (a region question), when this app run still remembers it.
    var region: CGRect?
    /// Passages to look for on `page`, the question's own first.
    var passages: [String]

    /// `question` is the asking message's attachments; those of other documents do not count.
    static func resolve(question: [NativeAssistantAttachment], answer: String, courseID: String, relativePath: String,
                        visiblePage: Int, pageCount: Int, region: (NativeAssistantAttachment) -> CGRect?) -> NativeAINoteTarget {
        let quotes = NativeAINotePlacement.quotes(in: answer)
        let asked = question.first { $0.courseID == courseID && $0.relativePath == relativePath && ($0.page.map { (1...max(1, pageCount)).contains($0) } ?? false) }
        guard let asked, let page = asked.page else { return NativeAINoteTarget(page: visiblePage, passages: quotes) }
        if let area = region(asked) { return NativeAINoteTarget(page: page, region: area, passages: []) }
        let passage = (asked.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeAINoteTarget(page: page, passages: (passage.isEmpty ? [] : [String(passage.prefix(300))]) + quotes)
    }

    /// The attachments of the question an answer replies to: the nearest user message before it.
    static func question(for answer: NativeChatMessage, in messages: [NativeChatMessage]) -> [NativeAssistantAttachment] {
        guard let index = messages.firstIndex(where: { $0.id == answer.id }) else { return [] }
        return messages[..<index].last { $0.role == "user" }?.attachments ?? []
    }
}

/// Areas captured for region questions in this app run. A capture carries its image but not where on the page it
/// came from, and its format is synced, so the editor that captured it remembers the area by the image's digest.
@MainActor
enum NativeAINoteAnchors {
    private static var areas: [(key: String, page: Int, area: CGRect)] = []
    static func remember(image: String?, page: Int, area: CGRect) {
        guard let image, !image.isEmpty else { return }
        let key = digest(image)
        areas.removeAll { $0.key == key }
        areas.append((key, page, area))
        if areas.count > 32 { areas.removeFirst(areas.count - 32) }
    }
    static func area(for attachment: NativeAssistantAttachment) -> CGRect? {
        guard let image = attachment.imageDataURL, !image.isEmpty, let page = attachment.page else { return nil }
        let key = digest(image)
        let match = areas.last { (entry: (key: String, page: Int, area: CGRect)) -> Bool in entry.key == key && entry.page == page }
        return match?.area
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Sizes of text boxes as the page draws them (NativePDFObjectRenderer's text layout), in page widths.
enum NativeAINoteMeasure {
    /// The box for `text` in `style` no wider than `maxWidth`: its natural width (never more than `maxWidth`) and its height.
    static func box(_ text: String, style: [String: Any], maxWidth: Double, pageWidth: Double) -> CGSize {
        guard pageWidth > 0, maxWidth > 0 else { return .zero }
        let padding = NativePDFObjectRenderer.baseFontSize(style, surfaceWidth: pageWidth) * 0.36
        let layout = NativePDFObjectRenderer.textLayout(data: ["text": text], style: style, surfaceWidth: pageWidth,
                                                         contentWidth: max(1, maxWidth * pageWidth - 2 * padding))
        let used = layout.manager.usedRect(for: layout.container).width
        // Two points of slack: the same text laid out again at exactly this width must not wrap sooner.
        let width = min(maxWidth, (ceil(used) + 2 + 2 * padding) / pageWidth)
        let height = (ceil(layout.height * 1_000) / 1_000 + 2 * padding) / pageWidth
        return CGSize(width: width, height: height)
    }
}

/// The last place for a note that fits nowhere on its page: that page's section of the PDF's page note
/// (NativePDFPageNoteDocument). The note file may be open in another tab, so the write goes through the
/// workspace's external-mutation barrier, which reopens that tab on the new text.
@MainActor
enum NativeAIPageNote {
    struct Undo: Equatable {
        let courseID: String, relativePath: String
        /// Nil: the note went to the appendix (a page the note file does not have yet).
        let page: Int?
        let added: String
    }

    static func append(_ markdown: String, page: Int, courseID: String, relativePath: String, store: NativeWorkspaceStore) async throws -> Undo {
        let note = try await store.openPDFPageNote(courseID: courseID, relativePath: relativePath)
        let body = NativePDFPageNoteDocument.safeContent(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        let result = try await store.withExternalMutation({
            var (document, mtime) = try await read(note.courseID, note.relativePath, store: store)
            let index = document.pages.indices.contains(page - 1) ? page - 1 : nil
            let existing = index.map { document.pages[$0] } ?? document.appendix
            let added = (existing.isEmpty ? "" : "\n\n") + (index == nil ? "p.\(page)\n\n" : "") + body
            if let index { document.pages[index] = existing + added } else { document.appendix = existing + added }
            try await write(document, mtime: mtime, note.courseID, note.relativePath, store: store)
            var result: [String: Any] = ["changedCourseIDs": [String](), "changedDocuments": [["courseId": note.courseID, "relPath": note.relativePath]], "added": added]
            if let index { result["page"] = index + 1 }
            return result
        }) as? [String: Any]
        guard let added = result?["added"] as? String else { throw DesktopRuntimeError("페이지 필기에 넣지 못했어요.") }
        return Undo(courseID: note.courseID, relativePath: note.relativePath, page: result?["page"] as? Int, added: added)
    }

    /// Takes the note out again, only while it is still the end of its section: the user's later writing stays.
    static func revert(_ undo: Undo, store: NativeWorkspaceStore) async throws {
        _ = try await store.withExternalMutation({
            var (document, mtime) = try await read(undo.courseID, undo.relativePath, store: store)
            let current = undo.page.flatMap { document.pages.indices.contains($0 - 1) ? document.pages[$0 - 1] : nil } ?? (undo.page == nil ? document.appendix : nil)
            guard var text = current, text.hasSuffix(undo.added) else { throw DesktopRuntimeError("페이지 필기가 바뀌어 되돌리지 못했어요.") }
            text.removeLast(undo.added.count)
            if let page = undo.page { document.pages[page - 1] = text } else { document.appendix = text }
            try await write(document, mtime: mtime, undo.courseID, undo.relativePath, store: store)
            return ["changedCourseIDs": [String](), "changedDocuments": [["courseId": undo.courseID, "relPath": undo.relativePath]]] as [String: Any]
        })
    }

    private static func read(_ courseID: String, _ path: String, store: NativeWorkspaceStore) async throws -> (NativePDFPageNoteDocument, NSNumber) {
        guard let value = try await store.invoke("notes:read", ["courseId": courseID, "relPath": path]) as? [String: Any],
              let text = value["markdown"] as? String, let mtime = value["mtime"] as? NSNumber,
              let document = NativePDFPageNoteDocument(text) else { throw DesktopRuntimeError("페이지 필기를 읽지 못했어요.") }
        return (document, mtime)
    }
    private static func write(_ document: NativePDFPageNoteDocument, mtime: NSNumber, _ courseID: String, _ path: String, store: NativeWorkspaceStore) async throws {
        _ = try await store.invoke("notes:write", ["courseId": courseID, "relPath": path, "markdown": try document.markdown(), "expectedMtime": mtime])
    }
}
