import UIKit
import XCTest
@testable import Bandal

@MainActor
final class NativeRichTextEditorTests: XCTestCase {
    private var windows: [UIWindow] = []
    private func closeEditors(_ session: NativeMarkdownSession) {
        session.retireAfterMaterialMutation()
        for window in windows { window.endEditing(true); window.isHidden = true }
        windows.removeAll()
    }
    private func editor(_ source: String, page: Int? = nil) async throws -> (NativeMarkdownSession, NativeRichTextEditor.Coordinator, NativeRichTextView, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rich-editor-\(UUID())")
        var stored = source, version = 1.0
        let session = NativeMarkdownSession(courseID: "course", relativePath: "note.md", draftFile: .init(documentID: UUID().uuidString, directory: directory), debounceNanoseconds: 60_000_000_000) { channel, request in
            if channel == "notes:read" { return ["markdown": stored, "mtime": version] }
            XCTAssertEqual(request["expectedMtime"] as? Double, version)
            stored = try XCTUnwrap(request["markdown"] as? String); version += 1; return ["mtime": version]
        }
        await session.load()
        let parent = NativeRichTextEditor(session: session, pageIndex: page, appendix: false, sourceMode: false, fontScale: 1, editorFont: "sans", loadImage: { _ in nil }, openLink: { _ in }, requestInsertion: { _ in })
        let coordinator = NativeRichTextEditor.Coordinator(parent: parent), view = NativeRichTextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        coordinator.view = view; view.delegate = coordinator
        view.compositionEnded = { [weak coordinator] in coordinator?.finishComposition() }
        coordinator.installCallbacks(); coordinator.reset()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let controller = UIViewController(); window.rootViewController = controller
        controller.view.addSubview(view); view.frame = controller.view.bounds
        window.makeKeyAndVisible(); view.becomeFirstResponder(); windows.append(window)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(view.isFirstResponder)
        return (session, coordinator, view, directory)
    }
    func testRenderedEditNativeUndoRedoAndFlushPreserveHiddenSyntax() async throws {
        let original = "# Title\n\n**bold** and [site](https://example.com)\n"
        let (session, coordinator, view, directory) = try await editor(original)
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(view.text, "Title\n\nbold and site\n")
        view.text = view.text.replacingOccurrences(of: "bold", with: "changed")
        coordinator.textViewDidChange(view)
        XCTAssertEqual(session.text, original.replacingOccurrences(of: "bold", with: "changed"))
        if view.sourceUndo.groupingLevel > 0 { view.sourceUndo.endUndoGrouping() }
        XCTAssertTrue(view.sourceUndo.canUndo)
        XCTAssertEqual(view.sourceUndo.undoActionName, "노트 편집")
        view.sourceUndo.undo()
        XCTAssertEqual(session.text, original)
        view.sourceUndo.redo()
        XCTAssertTrue(session.text.contains("**changed**"))
        try await session.flush()
        XCTAssertFalse(session.dirty)
    }
    func testFormattingChangesDisplayAndSourceThenUndoRestoresBoth() async throws {
        let (session, coordinator, view, directory) = try await editor("Title\n")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.selectedRange = NSRange(location: 0, length: 5)
        coordinator.format("bold")
        XCTAssertEqual(session.text, "**Title**\n")
        XCTAssertEqual(view.text, "Title\n")
        let font = try XCTUnwrap(view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        if view.sourceUndo.groupingLevel > 0 { view.sourceUndo.endUndoGrouping() }
        view.sourceUndo.undo(); XCTAssertEqual(session.text, "Title\n")
    }
    func testExistingLinkActionsUseCurrentURLAndNativeUndoRestoresMarkup() async throws {
        let original = "[**한글**](https://old.example \"title\")\n"
        let (session, coordinator, view, directory) = try await editor(original)
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.selectedRange = NSRange(location: 1, length: 0)
        var insertion: String?
        coordinator.parent.requestInsertion = { insertion = $0 }
        coordinator.format("edit-link")
        XCTAssertEqual(insertion, "link:https://old.example")
        coordinator.format("link:https://new.example")
        XCTAssertEqual(session.text, original.replacingOccurrences(of: "old.example", with: "new.example"))
        coordinator.format("link")
        XCTAssertEqual(session.text, "**한글**\n")
        view.sourceUndo.undo()
        XCTAssertEqual(session.text, original.replacingOccurrences(of: "old.example", with: "new.example"))
        view.sourceUndo.undo()
        XCTAssertEqual(session.text, original)
    }
    func testDuplicatePanesShareEditsButKeepSelectionAndUndoIndependent() async throws {
        let (session, first, firstView, directory) = try await editor("Left\nRight\n")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        let peerSession = NativeMarkdownSession(sharing: session, paneID: "peer")
        await peerSession.load()
        let peerParent = NativeRichTextEditor(session: peerSession, pageIndex: nil, appendix: false, sourceMode: false, fontScale: 1, editorFont: "sans", loadImage: { _ in nil }, openLink: { _ in }, requestInsertion: { _ in })
        let peer = NativeRichTextEditor.Coordinator(parent: peerParent)
        let peerView = NativeRichTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), textContainer: nil)
        peer.view = peerView; peerView.delegate = peer; peer.installCallbacks(); peer.reset()
        peerView.selectedRange = NSRange(location: 7, length: 0)
        firstView.selectedRange = NSRange(location: 4, length: 0)
        first.apply(.init(markdown: "Left!\nRight\n", sourceSelection: NSRange(location: 5, length: 0)))
        XCTAssertEqual(peerView.text, "Left!\nRight\n")
        XCTAssertEqual(peerView.selectedRange.location, 8)
        peer.apply(.init(markdown: "Left!\nRight?\n", sourceSelection: NSRange(location: 12, length: 0)))
        XCTAssertEqual(firstView.text, "Left!\nRight?\n")
        XCTAssertEqual(firstView.selectedRange.location, 5)
        firstView.sourceUndo.undo()
        XCTAssertEqual(session.text, "Left\nRight?\n", "Undo in the first pane must keep the peer's later edit")
        XCTAssertEqual(peerView.text, session.text)
        peerView.sourceUndo.undo()
        XCTAssertEqual(session.text, "Left\nRight\n")
        firstView.sourceUndo.redo()
        XCTAssertEqual(session.text, "Left!\nRight\n")
        try await peerSession.flush()
        XCTAssertFalse(session.dirty)
    }
    func testPeerEditDuringRepeatedKoreanCompositionSurvivesCommitAndUndo() async throws {
        let (session, coordinator, view, directory) = try await editor("한\nOther\n")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        let peer = NativeMarkdownSession(sharing: session, paneID: "peer")
        await peer.load()
        view.selectedRange = NSRange(location: 1, length: 0)
        view.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0)); coordinator.textViewDidChange(view)
        XCTAssertEqual(session.text, "한ㄱ\nOther\n")
        peer.update("한ㄱ\nPeer\n", isComposing: false)
        view.setMarkedText("구", selectedRange: NSRange(location: 1, length: 0)); coordinator.textViewDidChange(view)
        view.setMarkedText("국", selectedRange: NSRange(location: 1, length: 0)); coordinator.textViewDidChange(view)
        XCTAssertEqual(session.text, "한국\nPeer\n")
        coordinator.commitComposition()
        XCTAssertEqual(view.text, "한국\nPeer\n")
        view.sourceUndo.undo()
        XCTAssertEqual(session.text, "한\nPeer\n")
        try await session.flush()
    }
    func testContinuousTypingIncludingNewlineIsOneUndoBurst() async throws {
        let (session, coordinator, view, directory) = try await editor("Peer content")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        for character in "\nMy text" {
            let input = String(character), range = view.selectedRange
            XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: range, replacementText: input))
            view.text = (view.text as NSString).replacingCharacters(in: range, with: input)
            view.selectedRange = NSRange(location: range.location + input.utf16.count, length: 0)
            coordinator.textViewDidChangeSelection(view)
            coordinator.textViewDidChange(view)
        }
        coordinator.format("undo")
        XCTAssertEqual(session.text, "Peer content")
        coordinator.format("redo")
        XCTAssertEqual(session.text, "Peer content\nMy text")
    }
    func testUIKitInsertTextBurstKeepsUndoRegistrationBalancedAndRestoresSource() async throws {
        let (session, coordinator, view, directory) = try await editor("**Peer**")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        let registrationBefore = view.sourceUndo.isUndoRegistrationEnabled
        for input in ["\n", "A", "l", "p", "h", "a", " ", "😀"] {
            view.insertText(input)
            XCTAssertEqual(view.sourceUndo.isUndoRegistrationEnabled, registrationBefore)
        }
        XCTAssertTrue(session.text.contains("Alpha 😀"))
        coordinator.format("undo")
        XCTAssertEqual(session.text, "**Peer**")
        coordinator.format("redo")
        XCTAssertTrue(session.text.contains("Alpha 😀"))
        XCTAssertEqual(view.sourceUndo.isUndoRegistrationEnabled, registrationBefore)
    }
    func testUIKitTypingAfterExplicitCaretMoveStartsSeparateUndoBurst() async throws {
        let (session, coordinator, view, directory) = try await editor("Peer")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        for input in ["A", "B", "C"] { view.insertText(input) }
        view.deleteBackward()
        XCTAssertEqual(session.text, "PeerAB")
        view.selectedRange = NSRange(location: 0, length: 0)
        coordinator.textViewDidChangeSelection(view)
        for input in ["X", "Y", "Z"] { view.insertText(input) }
        XCTAssertEqual(session.text, "XYZPeerAB")
        coordinator.format("undo")
        XCTAssertEqual(session.text, "PeerAB", "Moving the caret starts a new typing burst")
        coordinator.format("undo")
        XCTAssertEqual(session.text, "Peer", "Typing and backspace at the same caret stay in their first burst")
    }
    func testDuplicatePaneUndoThenTypingBeforeRepeatedNewlineAndLettersKeepsExactCaret() async throws {
        let heading = "Shared opening paragraph.", original = "# Shared opening paragraph.\nFirst pane edit."
        let (session, coordinator, view, directory) = try await editor(original)
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        let peerSession = NativeMarkdownSession(sharing: session, paneID: "peer")
        await peerSession.load()
        let peerParent = NativeRichTextEditor(session: peerSession, pageIndex: nil, appendix: false, sourceMode: false, fontScale: 1, editorFont: "sans", loadImage: { _ in nil }, openLink: { _ in }, requestInsertion: { _ in })
        let peer = NativeRichTextEditor.Coordinator(parent: peerParent)
        let peerView = NativeRichTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 600), textContainer: nil)
        peer.view = peerView; peerView.delegate = peer; peer.installCallbacks(); peer.reset()
        view.selectedRange = NSRange(location: heading.utf16.count, length: 0)
        for character in "\nSecond pane edit." { view.insertText(String(character)) }
        XCTAssertEqual(session.text, "# " + heading + "\nSecond pane edit.\nFirst pane edit.")
        coordinator.format("undo")
        XCTAssertEqual(session.text, original)
        XCTAssertEqual(view.selectedRange, NSRange(location: heading.utf16.count, length: 0), "Undo restores the actual insertion position, which can be inside the document")
        var input = ""
        for character in "\nFinal second pane text." {
            let key = String(character); input += key
            view.insertText(key)
            XCTAssertEqual(session.text, "# " + heading + input + "\nFirst pane edit.")
            XCTAssertEqual(view.selectedRange, NSRange(location: heading.utf16.count + input.utf16.count, length: 0), "Repeated neighboring newline/F/i must not move the caret past existing text")
            XCTAssertEqual(peerView.text, view.text)
        }
        coordinator.format("undo")
        XCTAssertEqual(session.text, original)
        coordinator.format("redo")
        XCTAssertEqual(session.text, "# " + heading + input + "\nFirst pane edit.")
        try await session.flush()
    }
    func testDisplayChangeFallbackUsesUIKitCaretInsteadOfAmbiguousDiffCaret() async throws {
        let (session, coordinator, view, directory) = try await editor("First")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.text = "FFirst"
        view.selectedRange = NSRange(location: 1, length: 0)
        coordinator.textViewDidChange(view)
        XCTAssertEqual(session.text, "FFirst")
        XCTAssertEqual(view.selectedRange, NSRange(location: 1, length: 0))
        view.insertText("inal ")
        XCTAssertEqual(session.text, "Final First")
    }
    func testCompactPaperWrapsNewInputAtCurrentWidthAndReservesPageNumberSpace() async throws {
        let (session, coordinator, view, directory) = try await editor("")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.compactPaperLayout = true; view.isScrollEnabled = false
        view.frame = CGRect(x: 0, y: 0, width: 288, height: 408)
        view.setNeedsLayout(); view.layoutIfNeeded()
        let input = "Second page has a different explanation."
        for character in input { view.insertText(String(character)) }
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(session.text, input)
        XCTAssertEqual(view.textContainerInset.left, 16)
        XCTAssertGreaterThanOrEqual(view.textContainerInset.top, 40)
        XCTAssertEqual(view.textContainer.size.width, 256, accuracy: 0.5)
        XCTAssertEqual(view.contentOffset.x, -view.adjustedContentInset.left, accuracy: 0.5)
        let layout = view.layoutManager, container = view.textContainer
        layout.ensureLayout(for: container)
        XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxX, container.size.width + 0.5)
        XCTAssertGreaterThan(layout.lineFragmentRect(forGlyphAt: layout.numberOfGlyphs - 1, effectiveRange: nil).minY, layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY)
        view.frame.size.width = 420; view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.textContainer.size.width, 388, accuracy: 0.5)
        coordinator.commitComposition()
        XCTAssertEqual(session.text, input)
    }
    func testDiscardWithUnchangedDiskTextStillClearsPaneCompositionAndUndo() async throws {
        let (session, coordinator, view, directory) = try await editor("Original")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        coordinator.apply(.init(markdown: "Saved", sourceSelection: NSRange(location: 5, length: 0)))
        try await session.flush()
        XCTAssertTrue(view.sourceUndo.canUndo)
        coordinator.composition = coordinator.projection
        session.preserveUnmergedText("Unresolved pane candidate")
        XCTAssertTrue(session.frozen)
        try await session.reloadDiscardingDraft()
        XCTAssertEqual(session.text, "Saved")
        XCTAssertEqual(view.text, "Saved")
        XCTAssertNil(coordinator.composition)
        XCTAssertFalse(view.sourceUndo.canUndo)
        XCTAssertFalse(session.frozen)
        XCTAssertTrue(view.isEditable)
    }
    func testEditorZoomKeyboardCommandsUpdatePreferenceWithoutEditingDocument() throws {
        let defaults = UserDefaults.standard, key = NativeNoteFontScale.key, previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(1.0, forKey: key)
        let view = NativeRichTextView(frame: .zero, textContainer: nil)
        var editingCommands = [String]()
        view.command = { editingCommands.append($0) }
        let commands = view.keyCommands ?? []
        let increase = try XCTUnwrap(commands.first { $0.input == "=" && $0.modifierFlags == .command && $0.propertyList as? String == "zoom-in" })
        _ = view.perform(increase.action, with: increase)
        XCTAssertEqual(defaults.double(forKey: key), 1.125)
        let decrease = try XCTUnwrap(commands.first { $0.input == "-" && $0.modifierFlags == .control && $0.propertyList as? String == "zoom-out" })
        _ = view.perform(decrease.action, with: decrease)
        XCTAssertEqual(defaults.double(forKey: key), 1)
        XCTAssertTrue(editingCommands.isEmpty)
        XCTAssertFalse(commands.contains { ($0.propertyList as? String)?.hasPrefix("zoom-") == true && $0.modifierFlags.contains(.alternate) })
    }
    func testPageBodyEditKeepsOpaqueManifestOtherPagesAndAppendixExact() async throws {
        let original = "<!-- bandal:pdf-page-note {\"version\":1,\"source\":\"A.pdf\",\"fingerprint\":\"abc\",\"pages\":[{\"width\":100,\"height\":200},{\"width\":100,\"height\":200}],\"future\":{\"keep\":true}} -->\n# Page note\n\n<!-- bandal:page 1 -->\n\n**First**\n\n<!-- bandal:page 2 -->\n\n    Second code\n\n<!-- bandal:appendix -->\n\nArchived text\n"
        let (session, coordinator, view, directory) = try await editor(original, page: 0)
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(view.text, "First")
        view.text = "Changed"; coordinator.textViewDidChange(view)
        XCTAssertEqual(session.text, original.replacingOccurrences(of: "**First**", with: "**Changed**"))
        try await session.flush(); XCTAssertFalse(session.dirty)
        session.freezeForMaterialMutation(); session.retireAfterMaterialMutation()
        view.text = "late update"; coordinator.textViewDidChange(view); coordinator.commitComposition()
        XCTAssertTrue(session.text.contains("**Changed**")); XCTAssertFalse(session.text.contains("late update"))
    }
    func testPageUIKitTypingPreservesSpacesEmptyParagraphsAndLeadingIndentation() async throws {
        let prefix = "<!-- bandal:pdf-page-note {\"version\":1,\"source\":\"A.pdf\",\"fingerprint\":\"abc\",\"pages\":[{\"width\":100,\"height\":200},{\"width\":100,\"height\":200}],\"future\":{\"keep\":true}} -->\n# Page note\n\n<!-- bandal:page 1 -->\n\n  Keep first page  \n\n<!-- bandal:page 2 -->"
        let suffix = "\n\n<!-- bandal:appendix -->\n\n  Archived text  \n\n"
        let original = prefix + suffix
        let (session, coordinator, view, directory) = try await editor(original, page: 1)
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        let input = "\n    Second page has a different explanation.\n\n    Next line  "
        var expected = ""
        for character in input {
            let key = String(character)
            view.insertText(key); expected += key
            XCTAssertEqual(view.text, expected, "Every key, including trailing spaces and blank paragraphs, remains visible")
            XCTAssertEqual(NativePDFPageNoteDocument(session.text)?.pages[1], expected)
        }
        XCTAssertEqual(session.text, prefix + "\n\n" + input + suffix)
        try await session.flush()
        try await session.reloadDiscardingDraft()
        XCTAssertEqual(view.text, input)
        XCTAssertEqual(NativePDFPageNoteDocument(session.text)?.pages[0], "  Keep first page  ")
        coordinator.commitComposition()
    }
    func testSourceModeUsesExactSourceAndFontPreferenceChangesRenderingOnly() async throws {
        let original = "# Heading\n**Bold**\n"
        let (session, coordinator, view, directory) = try await editor(original)
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        coordinator.parent.sourceMode = true; coordinator.projection = NativeRichTextDocument(coordinator.source, sourceMode: true); coordinator.render()
        XCTAssertEqual(view.text, original)
        coordinator.parent.fontScale = 1.2; coordinator.parent.editorFont = "mono"; coordinator.render()
        let font = try XCTUnwrap(view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(font.pointSize, 16)
        XCTAssertEqual(session.text, original); XCTAssertFalse(session.dirty)
    }
    func testFlushCommitsMarkedKoreanTextBeforeWritingSource() async throws {
        let (session, coordinator, view, directory) = try await editor("**한**")
        defer { closeEditors(session); try? FileManager.default.removeItem(at: directory) }
        view.selectedRange = NSRange(location: 1, length: 0)
        view.setMarkedText("글", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        coordinator.textViewDidChange(view)
        XCTAssertTrue(session.dirty)
        XCTAssertEqual(session.text, "**한글**")
        try await session.flush()
        XCTAssertNil(view.markedTextRange)
        XCTAssertEqual(session.text, "**한글**")
        XCTAssertEqual(view.text, "한글")
        XCTAssertFalse(session.dirty)
    }

    func testMathAttachmentCacheUsesResolvedThemeColor() throws {
        let light = NativeRichTextMath.image("x^2", size: 21, color: .label, traits: UITraitCollection(userInterfaceStyle: .light))
        let dark = NativeRichTextMath.image("x^2", size: 21, color: .label, traits: UITraitCollection(userInterfaceStyle: .dark))
        XCTAssertEqual(light.size, dark.size)
        XCTAssertNotEqual(try XCTUnwrap(light.pngData()), try XCTUnwrap(dark.pngData()))
        let repeated = NativeRichTextMath.image("x^2", size: 21, color: .label, traits: UITraitCollection(userInterfaceStyle: .light))
        XCTAssertTrue(light === repeated)
    }

}
