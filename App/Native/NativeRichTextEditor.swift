import SwiftUI
import UIKit

struct NativeRichTextEditor: UIViewRepresentable {
    @ObservedObject var session: NativeMarkdownSession
    var pageIndex: Int?
    var appendix: Bool
    var sourceMode: Bool
    var fontScale: Double
    var editorFont: String
    var loadImage: (String) async -> UIImage?
    var openLink: (String) -> Void
    var requestInsertion: (String) -> Void
    var importMedia: (([NativeDroppedMedia]) async throws -> String)? = nil
    var mediaError: ((String) -> Void)? = nil
    var selectionChanged: ((String) -> Void)? = nil
    var formatsChanged: ((Set<String>) -> Void)? = nil
    var codeLanguageChanged: ((String?) -> Void)? = nil
    var scrollsInternally = true
    var compactPaperLayout = false
    var contentHeightChanged: ((CGFloat) -> Void)? = nil
    var focusChanged: ((Bool) -> Void)? = nil
    var captureViewChanged: ((UIView) -> Void)? = nil
    var selectionOnly = false
    var editorAccessibilityID = "native-markdown-textview"

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UITextView {
        let view = NativeRichTextView(frame: .zero, textContainer: nil)
        let coordinator = context.coordinator
        coordinator.view = view; view.delegate = coordinator; view.textDropDelegate = coordinator
        view.backgroundColor = UIColor(NativeDesktopTheme.bgApp); view.tintColor = UIColor(NativeDesktopTheme.accent)
        view.textContainer.lineFragmentPadding = 0; view.alwaysBounceVertical = true
        view.isScrollEnabled = scrollsInternally
        view.isEditable = !selectionOnly && !session.frozen && !session.retired
        view.compactPaperLayout = compactPaperLayout
        view.keyboardDismissMode = .interactive; view.smartQuotesType = .no; view.smartDashesType = .no
        view.adjustsFontForContentSizeCategory = true
        view.accessibilityIdentifier = editorAccessibilityID; view.accessibilityLabel = "텍스트 노트 편집기"
        view.command = { [weak coordinator] in coordinator?.format($0) }
        view.compositionEnded = { [weak coordinator] in coordinator?.finishComposition() }
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false; tap.delegate = coordinator; view.addGestureRecognizer(tap)
        coordinator.installCallbacks(); coordinator.reset()
        coordinator.installMediaDrop(on: view)
        captureViewChanged?(view)
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(title: "제목", image: UIImage(systemName: "textformat.size"), primaryAction: UIAction { [weak coordinator] _ in coordinator?.format("h2") }),
            UIBarButtonItem(title: "굵게", image: UIImage(systemName: "bold"), primaryAction: UIAction { [weak coordinator] _ in coordinator?.format("bold") }),
            UIBarButtonItem(title: "할 일", image: UIImage(systemName: "checklist"), primaryAction: UIAction { [weak coordinator] _ in coordinator?.format("task") }),
            UIBarButtonItem(title: "삽입", image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak coordinator] _ in coordinator?.showInsertions(query: "", slashRange: nil) }),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "실행 취소", image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak view] _ in view?.undoManager?.undo() }),
            UIBarButtonItem(title: "다시 실행", image: UIImage(systemName: "arrow.uturn.forward"), primaryAction: UIAction { [weak view] _ in view?.undoManager?.redo() }),
            UIBarButtonItem(title: "완료", style: .done, target: coordinator, action: #selector(Coordinator.done))]
        toolbar.sizeToFit(); view.inputAccessoryView = toolbar
        return view
    }
    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.accessibilityIdentifier = editorAccessibilityID
        captureViewChanged?(uiView)
        let c = context.coordinator
        let pageChanged = c.parent.pageIndex != pageIndex || c.parent.appendix != appendix || c.parent.session !== session
        let modeChanged = c.parent.sourceMode != sourceMode
        let appearanceChanged = c.parent.fontScale != fontScale || c.parent.editorFont != editorFont
        if pageChanged || modeChanged { c.commitComposition() }
        c.parent = self; uiView.isEditable = !selectionOnly && !session.frozen && !session.retired; uiView.isScrollEnabled = scrollsInternally
        (uiView as? NativeRichTextView)?.compactPaperLayout = compactPaperLayout
        if pageChanged { c.reset() }
        else if c.lastPublished != session.text && c.source != c.displayText { c.receiveSharedText(reset: false) }
        else if modeChanged || appearanceChanged { c.projection = NativeRichTextDocument(c.source, sourceMode: sourceMode); c.render() }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else { return nil }
        // Fixed PDF papers must use the proposed frame even when UITextView's
        // scrolling is off; its intrinsic text width can otherwise exceed it.
        return CGSize(width: width, height: height)
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.commitComposition(); coordinator.cancelImageRequests(); coordinator.parent.session.prepareForFlush = nil
        coordinator.parent.session.applyFormat = nil; coordinator.parent.session.setEditingEnabled = nil
        coordinator.parent.session.applyRemoteText = nil
        coordinator.imageInspector?.dismiss(animated: false)
        coordinator.menu?.removeFromSuperview(); view.delegate = nil; view.textDropDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate, UITextDropDelegate {
        var parent: NativeRichTextEditor
        weak var view: NativeRichTextView?
        var source = "", projection = NativeRichTextDocument("")
        var lastPublished: String?
        var lastPublishedDisplay: String?
        var composition: NativeRichTextDocument?
        var compositionSelection = NSRange(location: 0, length: 0)
        var applying = false
        var images: [String: UIImage] = [:], requestedImages = Set<String>()
        private var imageGeneration = UUID()
        private var imageTasks: [String: Task<Void, Never>] = [:]
        private var pendingImagePaths = Set<String>()
        private var attachmentUpdate: Task<Void, Never>?
        weak var menu: UIView?
        weak var imageInspector: UIViewController?
        private var mediaDrop: NativeEditorDropInteraction?
        private var dropAnchor: (source: String, range: NSRange, page: Int?, appendix: Bool, session: ObjectIdentifier)?
        private var importingMedia = false
        private var typingGroupOpen = false
        private var typingSelection: NSRange?
        private var typingIdle: Task<Void, Never>?
        private var pendingUserEdit = false
        private struct UserEdit {
            let document: NativeRichTextDocument
            let range: NSRange
            let replacement: String
            let sourceSelection: NSRange
        }
        private var pendingEdit: UserEdit?
        private var inputSourceSelection: NSRange?
        init(parent: NativeRichTextEditor) { self.parent = parent }
        func installMediaDrop(on view: UITextView) {
            let drop = NativeEditorDropInteraction(view: view, imagesOnly: false) { [weak self] items, _ in self?.receiveMedia(items) }
            drop.isEnabled = { [weak self] in
                guard let self else { return false }
                return !parent.selectionOnly && parent.importMedia != nil && parent.session.canEdit && !parent.session.frozen && !parent.session.retired && !importingMedia
            }
            drop.onBegin = { [weak self, weak view] point in
                guard let self, let view else { return }
                commitComposition()
                let location = view.closestPosition(to: point).map { view.offset(from: view.beginningOfDocument, to: $0) } ?? view.selectedRange.location
                let range = projection.sourceRange(for: NSRange(location: max(0, min(location, (view.text as NSString).length)), length: 0))
                dropAnchor = (source, NSRange(location: range.location, length: 0), parent.pageIndex, parent.appendix, ObjectIdentifier(parent.session))
                parent.focusChanged?(true)
            }
            drop.onError = { [weak self] error in self?.parent.mediaError?(error.localizedDescription) }
            mediaDrop = drop
        }
        private func receiveMedia(_ items: [NativeDroppedMedia]) {
            guard let anchor = dropAnchor, let importer = parent.importMedia,
                  anchor.session == ObjectIdentifier(parent.session),
                  anchor.page == parent.pageIndex, anchor.appendix == parent.appendix else { return }
            dropAnchor = nil; importingMedia = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { importingMedia = false }
                do {
                    let markup = try await importer(items)
                    guard parent.session.canEdit, !parent.session.frozen, !parent.session.retired,
                          anchor.session == ObjectIdentifier(parent.session),
                          anchor.page == parent.pageIndex, anchor.appendix == parent.appendix else {
                        throw DesktopRuntimeError("편집 중인 페이지가 바뀌어 첨부를 넣지 않았습니다. 다시 놓아 주세요.")
                    }
                    commitComposition()
                    let inserted = (anchor.source as NSString).replacingCharacters(in: anchor.range, with: markup)
                    let merged = try NativeMarkdownTextChange.rebase(from: anchor.source, to: inserted, onto: displayText)
                    let selected = NativeMarkdownTextChange(from: inserted, to: merged).translate(NSRange(location: anchor.range.location + markup.utf16.count, length: 0))
                    apply(.init(markdown: merged, sourceSelection: selected))
                    try await parent.session.flush()
                } catch { parent.mediaError?(error.localizedDescription) }
            }
        }
        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
            // File/image drops must use the durable asset path above. UIKit's
            // default NSTextAttachment insertion would disappear on Markdown save.
            if drop.dropSession.items.contains(where: { NativeEditorMediaImport.supports($0.itemProvider, imagesOnly: false) }) {
                return UITextDropProposal(operation: .cancel)
            }
            return drop.suggestedProposal
        }
        var displayText: String {
            if let index = parent.pageIndex, let note = NativePDFPageNoteDocument(parent.session.text) {
                return parent.appendix ? note.appendix : note.pages.indices.contains(index) ? note.pages[index] : ""
            }
            return parent.session.text
        }
        func installCallbacks() {
            view?.layoutWidthChanged = { [weak self] in
                guard let self, !applying else { return }; render()
            }
            view?.appearanceChanged = { [weak self] in
                guard let self, !applying else { return }; render()
            }
            parent.session.prepareForFlush = { [weak self] in self?.commitComposition() }
            parent.session.applyFormat = { [weak self] in self?.format($0) }
            parent.session.setEditingEnabled = { [weak self] enabled in
                guard let self else { return }; self.view?.isEditable = enabled && !self.parent.selectionOnly
            }
            parent.session.applyRemoteText = { [weak self] reset in self?.receiveSharedText(reset: reset) }
            view?.contentHeightChanged = { [weak self] height in self?.parent.contentHeightChanged?(height) }
            view?.textInputWillBegin = { [weak self] in
                guard let self, let view, !applying else { return }
                inputSourceSelection = projection.sourceRange(for: view.selectedRange)
            }
            view?.textInputFinished = { [weak self] in
                guard let self else { return }
                if typingGroupOpen { typingSelection = view?.selectedRange }
                pendingUserEdit = false; pendingEdit = nil; inputSourceSelection = nil
            }
        }
        func reset() {
            imageInspector?.dismiss(animated: false)
            cancelImageRequests()
            endTypingGroup()
            pendingEdit = nil; inputSourceSelection = nil
            source = displayText; projection = NativeRichTextDocument(source, sourceMode: parent.sourceMode); composition = nil
            lastPublishedDisplay = source; lastPublished = parent.session.text
            view?.sourceUndo.removeAllActions(); menu?.removeFromSuperview(); render(selection: NSRange(location: 0, length: 0))
        }
        func receiveSharedText(reset: Bool) {
            guard let view else { return }
            if !reset, view.markedTextRange != nil || composition != nil { return }
            endTypingGroup()
            let old = source, current = displayText
            guard old != current || reset else { lastPublished = parent.session.text; return }
            let selected = projection.sourceRange(for: view.selectedRange)
            if reset {
                applying = true; view.unmarkText(); applying = false
                composition = nil; view.sourceUndo.removeAllActions()
            }
            source = current; lastPublishedDisplay = current; lastPublished = parent.session.text
            projection = NativeRichTextDocument(current, sourceMode: parent.sourceMode)
            let moved = NativeMarkdownTextChange(from: old, to: current).translate(selected)
            let start = projection.visibleOffset(for: moved.location), end = projection.visibleOffset(for: NSMaxRange(moved))
            render(selection: NSRange(location: start, length: max(0, end - start)))
        }
        @discardableResult
        func publish(_ text: String, composing: Bool, base: String? = nil) -> Bool {
            let session = parent.session
            let merged: String
            do { merged = try NativeMarkdownTextChange.rebase(from: base ?? lastPublishedDisplay ?? source, to: text, onto: displayText) }
            catch { preserveUnmerged(text); return false }
            var accepted = false
            if merged == displayText { accepted = session.update(session.text, isComposing: composing) }
            else if let index = parent.pageIndex {
                guard let note = NativePDFPageNoteDocument(session.text) else { session.reportProjectionError("페이지 필기 경계를 읽지 못했습니다. 원문을 보존했으니 파일을 다시 읽어 주세요."); return false }
                guard note.pages.indices.contains(index), let updated = NativeMarkdownPageProjection.replacing(in: session.text, page: index, appendix: parent.appendix, text: merged) else { session.reportProjectionError("페이지 필기 위치가 변경되었습니다. 다시 열어 주세요."); return false }
                accepted = session.update(updated, isComposing: composing)
            } else { accepted = session.update(merged, isComposing: composing) }
            if accepted { lastPublished = session.text; lastPublishedDisplay = composing ? text : displayText }
            return accepted
        }
        private func preserveUnmerged(_ text: String) {
            let full: String
            if let page = parent.pageIndex, let replaced = NativeMarkdownPageProjection.replacing(in: parent.session.text, page: page, appendix: parent.appendix, text: text) { full = replaced }
            else { full = text }
            parent.session.preserveUnmergedText(full)
        }
        func commitComposition() {
            guard let view else { return }
            view.unmarkText(); finishComposition(); endTypingGroup()
        }
        func finishComposition() {
            guard let view, !applying else { return }
            if view.text != projection.text || composition != nil { acceptDisplayChange(view) }
            else { publish(source, composing: false) }
            scheduleAttachmentUpdate()
        }
        func textViewDidChange(_ textView: UITextView) { guard let view else { return }; acceptDisplayChange(view) }
        func acceptDisplayChange(_ view: NativeRichTextView) {
            guard !applying, !parent.session.frozen, !parent.session.retired else { return }
            if view.markedTextRange != nil {
                if composition == nil {
                    composition = projection
                    compositionSelection = pendingEdit?.sourceSelection ?? inputSourceSelection ?? projection.sourceRange(for: view.selectedRange)
                }
                pendingEdit = nil
                let pending = composition!.incorporating(view.text ?? "")
                publish(pending.markdown, composing: true); return
            }
            let base = composition ?? projection
            let change: (markdown: String, sourceCaret: Int)
            let selection: NSRange
            let priorSelection = composition != nil ? compositionSelection : pendingEdit?.sourceSelection ?? inputSourceSelection
            if let edit = pendingEdit, edit.document.markdown == base.markdown,
               NSMaxRange(edit.range) <= (base.text as NSString).length,
               (base.text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == view.text {
                // Identical neighboring characters make a minimal text diff
                // ambiguous. UIKit's actual replacement range determines both
                // the source edit and the caret, including a newline before a
                // newline or typing "Fi" immediately before existing "First".
                change = base.replacing(edit.range, with: edit.replacement)
                selection = NSRange(location: change.sourceCaret, length: 0)
            } else {
                change = base.incorporating(view.text ?? "")
                selection = NativeRichTextDocument(change.markdown, sourceMode: parent.sourceMode).sourceRange(for: view.selectedRange)
            }
            composition = nil
            pendingEdit = nil
            beginTypingGroup()
            apply(NativeRichTextCommands.Edit(markdown: change.markdown, sourceSelection: selection), oldSelection: priorSelection)
            typingSelection = view.selectedRange
            pendingUserEdit = false
            updateSlashMenu()
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !applying else { return true }
            pendingUserEdit = true
            let selection = projection.sourceRange(for: textView.selectedRange)
            pendingEdit = composition == nil && textView.markedTextRange == nil ? UserEdit(document: projection, range: range, replacement: text, sourceSelection: selection) : nil
            if text == "\n", !parent.sourceMode, textView.markedTextRange == nil, let change = NativeRichTextCommands.continuedLine(in: projection, selection: range) { pendingEdit = nil; apply(change, oldSelection: selection); return false }
            if text == "\t", !parent.sourceMode {
                pendingEdit = nil
                if let change = NativeRichTextTable.edit("table-next", markdown: source, selection: projection.sourceRange(for: range)) { apply(change) } else { format("indent") }
                return false
            }
            return true
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focusChanged?(true) }
        func textViewDidEndEditing(_ textView: UITextView) { finishComposition(); endTypingGroup(); parent.focusChanged?(false); Task { try? await parent.session.flush() } }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !applying, textView.markedTextRange == nil else { return }
            if typingGroupOpen, !pendingUserEdit, view?.isProcessingTextInput != true, textView.selectedRange != typingSelection { endTypingGroup() }
            updateSlashMenu()
            publishFormats()
            let range = projection.sourceRange(for: textView.selectedRange)
            let raw = source as NSString
            guard range.location >= 0, NSMaxRange(range) <= raw.length else { return }
            parent.selectionChanged?(range.length == 0 ? "" : raw.substring(with: range))
        }
        private func publishFormats() {
            guard let view else { return }
            let selected = view.selectedRange
            let matching = projection.runs.filter { run in selected.length > 0 ? NSIntersectionRange(run.visible, selected).length > 0 : run.visible.location <= selected.location && NSMaxRange(run.visible) >= selected.location }
            var styles = matching.dropFirst().reduce(matching.first?.styles ?? []) { $0.intersection($1.styles) }
            if styles.contains("bolditalic") { styles.formUnion(["bold", "italic"]) }
            let raw = source as NSString, caret = min(raw.length, projection.sourceRange(for: selected).location)
            let line = raw.substring(with: raw.lineRange(for: NSRange(location: caret, length: 0)))
            if line.range(of: #"^\s*[-*+] \[[ xX]\] "#, options: .regularExpression) != nil { styles.insert("task") }
            else if line.range(of: #"^\s*\d+[.)] "#, options: .regularExpression) != nil { styles.insert("number") }
            else if line.range(of: #"^\s*[-*+] "#, options: .regularExpression) != nil { styles.insert("bullet") }
            if styles.isDisjoint(with: ["h1", "h2", "h3", "h4", "h5", "h6", "quote", "codeblock", "task", "bullet", "number"]) { styles.insert("paragraph") }
            if NativeRichTextCommands.link(in: projection, selection: selected) != nil { styles.insert("link") }
            parent.codeLanguageChanged?(NativeRichTextCommands.codeBlock(in: projection, selection: selected)?.language)
            parent.formatsChanged?(styles)
        }
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool { parent.openLink(URL.absoluteString); return false }
        func apply(_ change: NativeRichTextCommands.Edit, oldSelection: NSRange? = nil) {
            guard let view, !parent.session.frozen, !parent.session.retired else { return }
            let old: String, merged: String
            do {
                old = try NativeMarkdownTextChange.rebase(from: lastPublishedDisplay ?? source, to: source, onto: displayText)
                merged = try NativeMarkdownTextChange.rebase(from: lastPublishedDisplay ?? source, to: change.markdown, onto: displayText)
            } catch { preserveUnmerged(change.markdown); receiveSharedText(reset: false); return }
            let prior = NativeMarkdownTextChange(from: source, to: old).translate(oldSelection ?? projection.sourceRange(for: view.selectedRange))
            let selected = NativeMarkdownTextChange(from: change.markdown, to: merged).translate(change.sourceSelection)
            guard publish(merged, composing: false, base: displayText) else { return }
            if old != merged {
                let manager = view.sourceUndo
                let registrationWasEnabled = manager.isUndoRegistrationEnabled
                if !registrationWasEnabled { manager.enableUndoRegistration() }
                let needsGroup = !manager.isUndoing && !manager.isRedoing && manager.groupingLevel == 0
                if needsGroup { manager.beginUndoGrouping() }
                manager.registerUndo(withTarget: self) { target in target.applyUndo(from: merged, to: old, selection: prior) }
                // A String literal selects Foundation’s LocalizedStringResource overload
                // on newer SDKs; use the stable String API on all supported iOS runtimes.
                let actionName: String = "노트 편집"
                manager.setActionName(actionName)
                if needsGroup { manager.endUndoGrouping() }
                if !registrationWasEnabled { manager.disableUndoRegistration() }
            }
            source = displayText; projection = NativeRichTextDocument(source, sourceMode: parent.sourceMode)
            let start = projection.visibleOffset(for: selected.location), end = projection.visibleOffset(for: NSMaxRange(selected))
            render(selection: NSRange(location: start, length: max(0, end - start)))
        }
        private func applyUndo(from after: String, to before: String, selection: NSRange) {
            do {
                let merged = try NativeMarkdownTextChange.rebase(from: after, to: before, onto: displayText)
                let selected = NativeMarkdownTextChange(from: before, to: merged).translate(selection)
                apply(.init(markdown: merged, sourceSelection: selected))
            } catch { parent.session.reportProjectionError("다른 탭이 같은 부분을 변경하여 이 편집을 되돌리지 않았어요.") }
        }
        private func beginTypingGroup() {
            guard let view, !view.sourceUndo.isUndoing, !view.sourceUndo.isRedoing else { return }
            if !typingGroupOpen {
                view.sourceUndo.beginUndoGrouping()
                typingGroupOpen = true
            }
            typingIdle?.cancel()
            typingIdle = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                self?.endTypingGroup()
            }
        }
        private func endTypingGroup() {
            typingIdle?.cancel(); typingIdle = nil
            pendingUserEdit = false
            guard typingGroupOpen, let view else { return }
            typingGroupOpen = false; typingSelection = nil
            if view.sourceUndo.groupingLevel > 0 { view.sourceUndo.endUndoGrouping() }
        }
        func format(_ command: String) {
            guard let view, view.isEditable else { return }
            commitComposition(); view.becomeFirstResponder()
            if command == "link", NativeRichTextCommands.link(in: projection, selection: view.selectedRange) != nil {
                apply(NativeRichTextCommands.apply("unlink", to: projection, selection: view.selectedRange)); return
            }
            if command == "edit-link" {
                if let link = NativeRichTextCommands.link(in: projection, selection: view.selectedRange) { parent.requestInsertion("link:" + link.destination) }
                return
            }
            if ["link", "image", "wikilink", "page"].contains(command) { parent.requestInsertion(command); return }
            if command == "undo" { view.sourceUndo.undo(); return }; if command == "redo" { view.sourceUndo.redo(); return }
            if command.hasPrefix("table-") {
                if let change = NativeRichTextTable.edit(command, markdown: source, selection: projection.sourceRange(for: view.selectedRange)) { apply(change) }
                return
            }
            apply(NativeRichTextCommands.apply(command, to: projection, selection: view.selectedRange))
        }
        private func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false) -> UIFont {
            let size = size * CGFloat(parent.fontScale)
            var font: UIFont = mono || parent.editorFont == "mono" ? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular) : .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            if parent.editorFont == "serif", !mono, let descriptor = font.fontDescriptor.withDesign(.serif) { font = UIFont(descriptor: descriptor, size: size) }
            if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) { font = UIFont(descriptor: descriptor, size: size) }
            return UIFontMetrics(forTextStyle: .body).scaledFont(for: font)
        }
        func render(selection: NSRange? = nil) {
            Task { @MainActor [weak self] in await Task.yield(); self?.publishFormats() }
            guard let view, view.markedTextRange == nil else { return }
            applying = true; defer { applying = false }
            let selected = selection ?? view.selectedRange
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5; paragraph.paragraphSpacing = 9
            let base: [NSAttributedString.Key: Any] = [.font: font(16, mono: parent.sourceMode), .foregroundColor: UIColor(NativeDesktopTheme.text), .paragraphStyle: paragraph]
            let attributed = NSMutableAttributedString(string: projection.text, attributes: base)
            for run in projection.runs {
                let style = run.styles; var attributes: [NSAttributedString.Key: Any] = [:]
                let heading = (1...6).first { style.contains("h\($0)") }
                let size: CGFloat = heading.map { [30, 24, 20, 18, 17, 16][$0 - 1] } ?? 16
                attributes[.font] = font(size, bold: heading != nil || style.contains("bold") || style.contains("bolditalic") || style.contains("callout") || style.contains("tableheader"), italic: style.contains("italic") || style.contains("bolditalic") || style.contains("math"), mono: style.contains("code") || style.contains("codeblock") || style.contains("table") || parent.sourceMode)
                if style.contains("strike") || style.contains("checked") { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if style.contains("code") || style.contains("codeblock") || style.contains("callout") || style.contains("metadata") { attributes[.backgroundColor] = UIColor.secondarySystemFill }
                if style.contains("quote") || style.contains("callout") { let p = paragraph.mutableCopy() as! NSMutableParagraphStyle; p.firstLineHeadIndent = 16; p.headIndent = 16; attributes[.paragraphStyle] = p; attributes[.foregroundColor] = UIColor.secondaryLabel }
                if style.contains("table") {
                    let visible = projection.text as NSString
                    let row = visible.substring(with: visible.lineRange(for: NSRange(location: run.visible.location, length: 0)))
                    let columns = max(1, row.components(separatedBy: "\t").count)
                    let available = max(120, view.bounds.width - view.textContainerInset.left - view.textContainerInset.right)
                    let width = available / CGFloat(columns)
                    let p = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    p.tabStops = (1..<columns).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * width + 8, options: [:]) }
                    p.defaultTabInterval = width; p.firstLineHeadIndent = 8; p.headIndent = 8
                    p.lineSpacing = 0; p.paragraphSpacing = 0; p.minimumLineHeight = 36 * CGFloat(parent.fontScale)
                    attributes[.paragraphStyle] = p
                    attributes[.nativeTableColumns] = columns
                    attributes[.nativeTableHeader] = style.contains("tableheader")
                }
                if style.contains("rule") || style.contains("metadata") { attributes[.foregroundColor] = UIColor.tertiaryLabel }
                if let destination = run.destination, !style.contains("image"), !style.contains("math") { attributes[.link] = destination; attributes[.foregroundColor] = UIColor(NativeDesktopTheme.accent); attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if style.contains("math"), let formula = run.destination {
                    let attachment = NSTextAttachment(), image = NativeRichTextMath.image(formula, size: 21 * CGFloat(parent.fontScale), color: UIColor(NativeDesktopTheme.text), traits: view.traitCollection)
                    attachment.image = image; let width = min(image.size.width, max(160, view.bounds.width - 80))
                    attachment.bounds = CGRect(x: 0, y: -8, width: width, height: image.size.height * width / image.size.width)
                    attributes[.attachment] = attachment
                }
                if style.contains("image"), let path = run.destination {
                    attributes[.attachment] = imageAttachment(images[path] ?? placeholder(path), layout: run.imageLayout)
                    if let layout = run.imageLayout {
                        let p = paragraph.mutableCopy() as! NSMutableParagraphStyle
                        p.alignment = layout.alignment == .center ? .center : layout.alignment == .right ? .right : .left
                        attributes[.paragraphStyle] = p
                    }
                    requestImage(path)
                }
                attributed.addAttributes(attributes, range: run.visible)
            }
            view.attributedText = attributed
            pendingImagePaths.removeAll()
            let location = min(selected.location, attributed.length), length = min(selected.length, attributed.length - location)
            view.selectedRange = NSRange(location: location, length: length); view.typingAttributes = base
            view.isEditable = !parent.session.frozen && !parent.session.retired
        }
        func cancelImageRequests() {
            imageGeneration = UUID()
            for task in imageTasks.values { task.cancel() }
            imageTasks.removeAll(); requestedImages.removeAll(); images.removeAll()
            pendingImagePaths.removeAll(); attachmentUpdate?.cancel(); attachmentUpdate = nil
        }
        private func requestImage(_ path: String) {
            guard requestedImages.insert(path).inserted else { return }
            let generation = imageGeneration, session = parent.session, loader = parent.loadImage
            imageTasks[path] = Task { @MainActor [weak self] in
                let loaded = await loader(path)
                guard let self, !Task.isCancelled, imageGeneration == generation,
                      parent.session === session, !session.retired else { return }
                imageTasks[path] = nil
                guard projection.runs.contains(where: { $0.styles.contains("image") && $0.destination == path }) else {
                    requestedImages.remove(path); return
                }
                guard let loaded else { return }
                images[path] = loaded; pendingImagePaths.insert(path)
                scheduleAttachmentUpdate()
            }
        }
        private func scheduleAttachmentUpdate() {
            guard !pendingImagePaths.isEmpty, attachmentUpdate == nil else { return }
            let generation = imageGeneration
            attachmentUpdate = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled, imageGeneration == generation else { return }
                attachmentUpdate = nil
                updateLoadedAttachments()
            }
        }
        /// Image completions only replace attachment attributes, never the
        /// text storage contents, caret, undo history, or active IME composition.
        /// Several completions in one turn share this single update.
        private func updateLoadedAttachments() {
            guard let view, !applying, view.markedTextRange == nil, composition == nil,
                  !parent.session.retired, !parent.session.frozen,
                  view.text == projection.text else { return }
            let paths = pendingImagePaths; pendingImagePaths.removeAll()
            guard !paths.isEmpty else { return }
            applying = true; defer { applying = false }
            view.textStorage.beginEditing()
            for run in projection.runs where run.styles.contains("image") {
                guard let path = run.destination, paths.contains(path), let image = images[path],
                      run.visible.location >= 0, NSMaxRange(run.visible) <= view.textStorage.length else { continue }
                view.textStorage.addAttribute(.attachment, value: imageAttachment(image, layout: run.imageLayout), range: run.visible)
            }
            view.textStorage.endEditing()
            view.setNeedsLayout()
        }
        private func imageAttachment(_ image: UIImage, layout: NativeRichTextImageLayout?) -> NSTextAttachment {
            let attachment = NSTextAttachment(); attachment.image = image
            let available = max(40, (view?.bounds.width ?? 640) - (view?.textContainerInset.left ?? 28) - (view?.textContainerInset.right ?? 28))
            let base = min(560, available)
            let width = layout?.widthPercent.map { base * CGFloat($0) / 100 } ?? min(base, image.size.width)
            let height = width * image.size.height / max(1, image.size.width)
            let scale = min(1, 600 / max(1, height))
            attachment.bounds = CGRect(x: 0, y: 0, width: width * scale, height: height * scale)
            return attachment
        }
        private func placeholder(_ path: String) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 420, height: 120)).image { context in
                UIColor.secondarySystemBackground.setFill(); context.fill(CGRect(x: 0, y: 0, width: 420, height: 120))
                let label = "▧  " + ((path.removingPercentEncoding ?? path) as NSString).lastPathComponent
                (label as NSString).draw(in: CGRect(x: 20, y: 45, width: 380, height: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.secondaryLabel])
            }
        }
        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view, view.isEditable, !parent.sourceMode, let position = view.closestPosition(to: recognizer.location(in: view)) else { return }
            // closestPosition can report the caret *after* an attachment when its
            // right half is tapped. Hit its rendered rectangle instead.
            let point = recognizer.location(in: view)
            if let image = projection.runs.first(where: { run in
                guard run.styles.contains("image") else { return false }
                return attachmentRect(run).insetBy(dx: -4, dy: -4).contains(point)
            }) {
                showImageInspector(image); return
            }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            if let link = projection.runs.first(where: { NSLocationInRange(offset, $0.visible) && ($0.styles.contains("link") || $0.styles.contains("wikilink")) }), let destination = link.destination {
                parent.openLink(destination); return
            }
            if let math = projection.runs.first(where: { NSLocationInRange(offset, $0.visible) && $0.styles.contains("math") }), let formula = math.destination {
                view.selectedRange = math.visible; parent.requestInsertion("math:" + formula); return
            }
            guard let run = projection.runs.first(where: { NSLocationInRange(offset, $0.visible) && ($0.styles.contains("task") || $0.styles.contains("checked")) }) else { return }
            let raw = (source as NSString).substring(with: run.source), checked = run.styles.contains("checked")
            let replacement = raw.replacingOccurrences(of: checked ? #"\[[xX]\]"# : #"\[ \]"#, with: checked ? "[ ]" : "[x]", options: .regularExpression)
            apply(.init(markdown: (source as NSString).replacingCharacters(in: run.source, with: replacement), sourceSelection: NSRange(location: NSMaxRange(run.source), length: 0)))
        }
        private func attachmentRect(_ run: NativeRichTextDocument.Run) -> CGRect {
            guard let view else { return .zero }
            let glyphs = view.layoutManager.glyphRange(forCharacterRange: run.visible, actualCharacterRange: nil)
            return view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
                .offsetBy(dx: view.textContainerInset.left, dy: view.textContainerInset.top)
        }
        func showImageInspector(_ image: NativeRichTextDocument.Run) {
            guard let view, !parent.session.frozen, !parent.session.retired, imageInspector == nil else { return }
            let beforeComposition = source
            commitComposition()
            let currentRange = NativeMarkdownTextChange(from: beforeComposition, to: source).translate(image.source)
            guard let image = projection.runs.first(where: { $0.styles.contains("image") && $0.source == currentRange }) else { return }
            var responder: UIResponder? = view
            while responder != nil, !(responder is UIViewController) { responder = responder?.next }
            guard let presenter = responder as? UIViewController, presenter.presentedViewController == nil else { return }
            view.resignFirstResponder(); view.selectedRange = image.visible
            var expectedSource = source, selected = image.source
            let attachment = view.attributedText.attribute(.attachment, at: image.visible.location, effectiveRange: nil) as? NSTextAttachment
            let available = min(560, max(40, view.bounds.width - view.textContainerInset.left - view.textContainerInset.right))
            let currentWidth = image.imageLayout?.widthPercent.map(Double.init) ?? Double((attachment?.bounds.width ?? available) / available * 100)
            let controller = UIHostingController(rootView: NativeMarkdownImageInspector(
                layout: image.imageLayout ?? NativeRichTextImageLayout(),
                widthPercent: min(100, max(20, currentWidth)),
                action: { [weak self] command in
                    guard let self, let view = self.view, !parent.session.frozen, !parent.session.retired else { return }
                    // A peer pane may have edited the note while this popover was
                    // open. Never apply its old image range to different content.
                    guard source == expectedSource, displayText == expectedSource else {
                        imageInspector?.dismiss(animated: true)
                        parent.mediaError?("문서가 변경되었습니다. 이미지를 다시 선택해 주세요.")
                        return
                    }
                    let start = projection.visibleOffset(for: selected.location)
                    let end = projection.visibleOffset(for: NSMaxRange(selected))
                    let visible = NSRange(location: start, length: max(1, end - start))
                    let edit = NativeRichTextCommands.apply(command, to: projection, selection: visible)
                    apply(edit)
                    expectedSource = source; selected = edit.sourceSelection
                    if command == "image-delete" { imageInspector?.dismiss(animated: true) }
                    else { view.scrollRangeToVisible(view.selectedRange) }
                },
                close: { [weak self] in self?.imageInspector?.dismiss(animated: true) }
            ))
            controller.modalPresentationStyle = .popover
            controller.preferredContentSize = CGSize(width: 300, height: 260)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view; popover.sourceRect = attachmentRect(image)
                popover.permittedArrowDirections = [.up, .down]
            }
            imageInspector = controller
            presenter.present(controller, animated: true)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func updateSlashMenu() {
            guard let view, !parent.sourceMode, view.isFirstResponder, view.selectedRange.length == 0 else { menu?.removeFromSuperview(); return }
            let text = projection.text as NSString, cursor = min(view.selectedRange.location, text.length)
            let line = text.lineRange(for: NSRange(location: cursor, length: 0)), prefix = text.substring(with: NSRange(location: line.location, length: cursor - line.location))
            guard prefix.hasPrefix("/"), !prefix.contains(" ") else { menu?.removeFromSuperview(); return }
            showInsertions(query: String(prefix.dropFirst()), slashRange: NSRange(location: line.location, length: prefix.utf16.count))
        }
        func showInsertions(query: String, slashRange: NSRange?) {
            guard let view else { return }; menu?.removeFromSuperview()
            let choices = NativeRichTextCommands.insertions.filter { query.isEmpty || ($0.title + " " + $0.id + " " + $0.keywords).localizedCaseInsensitiveContains(query) }
            guard !choices.isEmpty else { return }
            let scroll = UIScrollView(); scroll.backgroundColor = .secondarySystemBackground; scroll.layer.cornerRadius = 10; scroll.layer.borderWidth = 1; scroll.layer.borderColor = UIColor.separator.cgColor
            let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 0
            for choice in choices {
                let button = UIButton(type: .system); button.contentHorizontalAlignment = .leading; button.setTitle("  " + choice.title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 15); button.heightAnchor.constraint(equalToConstant: 42).isActive = true
                button.accessibilityIdentifier = "native-markdown-insert-" + choice.id
                button.addAction(UIAction { [weak self, weak scroll] _ in
                    guard let self else { return }; scroll?.removeFromSuperview()
                    if let slashRange { let change = projection.replacing(slashRange, with: ""); apply(.init(markdown: change.markdown, sourceSelection: NSRange(location: change.sourceCaret, length: 0))) }
                    format(choice.id)
                }, for: .touchUpInside); stack.addArrangedSubview(button)
            }
            let height = min(280, CGFloat(choices.count) * 42), width = min(280, max(160, view.bounds.width - 40))
            let caret = view.selectedTextRange.map { view.caretRect(for: $0.end) } ?? CGRect(x: 24, y: 30, width: 1, height: 20)
            scroll.frame = CGRect(x: min(max(12, caret.minX), max(12, view.bounds.width - width - 12)), y: caret.maxY + 6, width: width, height: height)
            stack.frame = CGRect(x: 0, y: 0, width: width, height: CGFloat(choices.count) * 42); scroll.addSubview(stack); scroll.contentSize = stack.bounds.size
            view.addSubview(scroll); menu = scroll
        }
        @objc func done() { menu?.removeFromSuperview(); view?.resignFirstResponder() }
    }
}

private struct NativeMarkdownImageInspector: View {
    @State var layout: NativeRichTextImageLayout
    @State var widthPercent: Double
    let action: (String) -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("이미지").font(.headline)
                Spacer()
                Button("완료", action: close)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("크기 \(Int(widthPercent))%").font(.subheadline)
                Slider(value: $widthPercent,
                       in: 20...100, step: 5, onEditingChanged: { editing in
                    if !editing { action("image-width:" + String(Int(widthPercent))) }
                })
                .accessibilityLabel("이미지 크기").accessibilityIdentifier("native-markdown-image-size")
            }
            Picker("위치", selection: $layout.alignment) {
                Image(systemName: "text.alignleft").tag(NativeRichTextImageLayout.Alignment.left).accessibilityLabel("왼쪽")
                Image(systemName: "text.aligncenter").tag(NativeRichTextImageLayout.Alignment.center).accessibilityLabel("가운데")
                Image(systemName: "text.alignright").tag(NativeRichTextImageLayout.Alignment.right).accessibilityLabel("오른쪽")
            }
            .pickerStyle(.segmented).accessibilityIdentifier("native-markdown-image-alignment")
            .onChange(of: layout.alignment) { _, alignment in action("image-align:" + alignment.rawValue) }
            HStack {
                Button("위로", systemImage: "arrow.up") { action("image-move-up") }
                Spacer()
                Button("아래로", systemImage: "arrow.down") { action("image-move-down") }
                Spacer()
                Button("삭제", systemImage: "trash", role: .destructive) { action("image-delete") }
            }.font(.subheadline)
        }.padding(20)
    }
}

final class NativeRichTextView: UITextView {
    let sourceUndo = UndoManager()
    var command: ((String) -> Void)?
    var compositionEnded: (() -> Void)?
    var layoutWidthChanged: (() -> Void)?
    var appearanceChanged: (() -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    var textInputWillBegin: (() -> Void)?
    var textInputFinished: (() -> Void)?
    private var textInputDepth = 0
    var isProcessingTextInput: Bool { textInputDepth > 0 }
    var compactPaperLayout = false { didSet { if oldValue != compactPaperLayout { setNeedsLayout() } } }
    private var previousContentHeight: CGFloat = 0
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) { appearanceChanged?() }
    }
    private var previousLayoutWidth: CGFloat = 0
    override var undoManager: UndoManager? { sourceUndo }
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        if let textContainer { super.init(frame: frame, textContainer: textContainer) }
        else {
            let storage = NSTextStorage(), layout = NativeRichTextLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true; container.heightTracksTextView = false
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            super.init(frame: frame, textContainer: container)
        }
        sourceUndo.groupsByEvent = false; sourceUndo.disableUndoRegistration()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); sourceUndo.groupsByEvent = false; sourceUndo.disableUndoRegistration() }
    // UIKit can report a second caret change after didChange and our source render.
    // Keep the whole input operation together; that caret movement is not a user
    // selection change and must not split a continuous typing undo group.
    override func insertText(_ text: String) {
        beginTextInput(); defer { finishTextInput() }
        super.insertText(text)
    }
    override func deleteBackward() {
        beginTextInput(); defer { finishTextInput() }
        super.deleteBackward()
    }
    override func replace(_ range: UITextRange, withText text: String) {
        beginTextInput(); defer { finishTextInput() }
        super.replace(range, withText: text)
    }
    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        beginTextInput(); defer { finishTextInput() }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }
    private func beginTextInput() {
        if textInputDepth == 0 { textInputWillBegin?() }
        textInputDepth += 1
    }
    private func finishTextInput() {
        textInputDepth -= 1
        if textInputDepth == 0 { textInputFinished?() }
    }
    override func unmarkText() { super.unmarkText(); compositionEnded?() }
    override var keyCommands: [UIKeyCommand]? {
        var commands: [(String, UIKeyModifierFlags, String)] = [("b", .command, "bold"), ("i", .command, "italic"), ("k", .command, "link"), ("z", .command, "undo"), ("z", [.command, .shift], "redo"), ("1", [.command, .alternate], "h1"), ("2", [.command, .alternate], "h2"), ("3", [.command, .alternate], "h3"), ("7", [.command, .shift], "number"), ("8", [.command, .shift], "bullet"), ("9", [.command, .shift], "task")]
        for modifier: UIKeyModifierFlags in [.command, .control] {
            commands += [("=", modifier, "zoom-in"), ("+", modifier, "zoom-in"), ("+", [modifier, .shift], "zoom-in"), ("-", modifier, "zoom-out"), ("_", modifier, "zoom-out"), ("_", [modifier, .shift], "zoom-out")]
        }
        return commands.map { input, modifiers, action in let item = UIKeyCommand(title: action, action: #selector(shortcut(_:)), input: input, modifierFlags: modifiers, propertyList: action); item.wantsPriorityOverSystemBehavior = true; return item } + (super.keyCommands ?? [])
    }
    @objc private func shortcut(_ sender: UIKeyCommand) {
        guard let action = sender.propertyList as? String else { return }
        if action == "zoom-in" || action == "zoom-out" {
            let defaults = UserDefaults.standard
            defaults.set(NativeNoteFontScale.step(defaults.double(forKey: NativeNoteFontScale.key), direction: action == "zoom-in" ? 1 : -1), forKey: NativeNoteFontScale.key)
        } else { command?(action) }
    }
    override func layoutSubviews() {
        let horizontal = compactPaperLayout ? 16 : max(28, (bounds.width - 820) / 2)
        // The compact page's top-right number occupies y=12...40.
        let next = UIEdgeInsets(top: compactPaperLayout ? 48 : 40, left: horizontal, bottom: compactPaperLayout ? 20 : 100, right: horizontal)
        if textContainerInset != next { textContainerInset = next }
        if bounds.width > 0 {
            let width = max(1, bounds.width - next.left - next.right)
            if abs(textContainer.size.width - width) > 0.5 { textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude) }
        }
        super.layoutSubviews()
        if bounds.width > 0, abs(bounds.width - previousLayoutWidth) > 0.5 {
            previousLayoutWidth = bounds.width; layoutWidthChanged?()
        }
        if bounds.width > 0 {
            layoutManager.ensureLayout(for: textContainer)
            // Caret reveal may leave a horizontal offset from the previous
            // width. Body text wraps, so that stale offset must not hide inset.
            let left = -adjustedContentInset.left
            if abs(contentOffset.x - left) > 0.5 { contentOffset = CGPoint(x: left, y: contentOffset.y) }
            let height = ceil(layoutManager.usedRect(for: textContainer).maxY + textContainerInset.top + textContainerInset.bottom)
            if abs(height - previousContentHeight) > 0.5 {
                previousContentHeight = height
                Task { @MainActor [weak self] in guard let self else { return }; contentHeightChanged?(previousContentHeight) }
            }
        }
    }
}
