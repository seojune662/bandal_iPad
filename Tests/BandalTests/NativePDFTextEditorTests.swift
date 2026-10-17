import XCTest
import UIKit
import PDFKit
@testable import Bandal

@MainActor
final class NativePDFTextEditorTests: XCTestCase {
    private let page = CGSize(width: 600, height: 800)

    func testFontSizeCommitsOnceAndDefaultsRemainSeparateFromInk() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NativePDFTextEditorTests." + UUID().uuidString))
        var changes = 0
        let draft = NativePDFTextDraft(object: row(), pageSize: page, existing: false, defaults: defaults, onChange: { changes += 1 })
        draft.editingPoint = true; draft.pointDraft = "24"
        XCTAssertEqual(draft.style.fontSizePt, 14)
        draft.finishComposition()
        XCTAssertEqual(draft.style.fontSizePt, 24); XCTAssertEqual(changes, 1)
        draft.apply(["fill": "yellow", "align": "right", "opacity": 0.35])
        draft.saveDefaults()
        let created = NativePDFTextDraft.newObject(at: CGPoint(x: 0.5, y: 0.5), page: 2, pageSize: page, defaults: defaults)
        let style = try XCTUnwrap(created["style"] as? [String: Any])
        XCTAssertEqual(style["fontSizePt"] as? Double, 24); XCTAssertEqual(style["fill"] as? String, "yellow")
        XCTAssertEqual(style["align"] as? String, "right"); XCTAssertEqual(style["opacity"] as? Double, 0.35)
        XCTAssertEqual(NativePDFTextStyle.committedSize("nan", fallback: 14), 14)
        XCTAssertEqual(NativePDFTextStyle.committedSize("0", fallback: 14), 6)
        XCTAssertEqual(NativePDFTextStyle.committedSize("1000", fallback: 14), 96)
        XCTAssertEqual(NativePDFTextStyle.steppedSize(14, direction: 1), 16)
        XCTAssertEqual(NativePDFTextStyle.steppedSize(96, direction: 1), 96)
        XCTAssertNil(defaults.object(forKey: "native.pdf.pen"))
    }

    func testDraftPreservesUTF16RunsAndUnknownDataAcrossEditingAndInlineFormatting() throws {
        var source = row(text: "가😀나다")
        source["data"] = ["text": "가😀나다", "future": "keep", "box": box(), "textRuns": [
            ["from": 1, "to": 3, "style": ["bold": true, "color": "red"]]
        ]] as [String: Any]
        let draft = NativePDFTextDraft(object: source, pageSize: page, existing: true)
        let edited = NSMutableAttributedString(attributedString: draft.attributedText(scale: 2))
        edited.insert(NSAttributedString(string: "한", attributes: draft.typingAttributes(scale: 2)), at: 0)
        draft.acceptEditorText(edited, selection: NSRange(location: 2, length: 2), composing: false)
        draft.toggle("underline")
        let saved = try XCTUnwrap(draft.objectForSave()), data = try XCTUnwrap(saved["data"] as? [String: Any])
        XCTAssertEqual(data["text"] as? String, "한가😀나다"); XCTAssertEqual(data["future"] as? String, "keep")
        let runs = try XCTUnwrap(data["textRuns"] as? [[String: Any]])
        let emoji = try XCTUnwrap(runs.first { $0["from"] as? Int == 2 })
        XCTAssertEqual(emoji["to"] as? Int, 4)
        let style = try XCTUnwrap(emoji["style"] as? [String: Any])
        XCTAssertEqual(style["bold"] as? Bool, true); XCTAssertEqual(style["underline"] as? Bool, true)
        XCTAssertEqual(style["color"] as? String, "red")
        XCTAssertEqual((source["data"] as? [String: Any])?["text"] as? String, "가😀나다", "Cancellation never mutates the original row")
    }

    func testFinishingNumericFieldCannotRestoreItsUncommittedFractionOrInvalidText() {
        let draft = NativePDFTextDraft(object: row(), pageSize: page, existing: false)
        let coordinator = NativePDFTextSizeField(draft: draft).makeCoordinator()
        let field = NativePDFTextSizeField.SizeField()
        coordinator.textFieldDidBeginEditing(field)
        field.text = "24.7"; coordinator.changed(field)
        draft.commitPointInput()
        XCTAssertEqual(draft.style.fontSizePt, 25)
        coordinator.textFieldDidEndEditing(field)
        XCTAssertEqual(field.text, "25"); XCTAssertEqual(draft.pointDraft, "25")

        coordinator.textFieldDidBeginEditing(field)
        field.text = "nan"; coordinator.changed(field)
        draft.commitPointInput()
        coordinator.textFieldDidEndEditing(field)
        XCTAssertEqual(field.text, "25"); XCTAssertEqual(draft.pointDraft, "25")
        XCTAssertEqual(draft.style.fontSizePt, 25)
    }

    func testCaretFormattingStylesNewTypingWithoutReformattingExistingText() throws {
        let draft = NativePDFTextDraft(object: row(text: "기존"), pageSize: page, existing: true)
        draft.setSelection(NSRange(location: 2, length: 0))
        draft.toggle("bold"); draft.apply(["color": "blue"], inline: true)
        let edited = NSMutableAttributedString(attributedString: draft.attributedText(scale: 1))
        edited.append(NSAttributedString(string: " 새 글", attributes: draft.typingAttributes(scale: 1)))
        draft.acceptEditorText(edited, selection: NSRange(location: edited.length, length: 0), composing: false)
        let data = try XCTUnwrap(try XCTUnwrap(draft.objectForSave())["data"] as? [String: Any])
        let runs = try XCTUnwrap(data["textRuns"] as? [[String: Any]])
        XCTAssertEqual(runs.count, 1); XCTAssertEqual(runs[0]["from"] as? Int, 2)
        XCTAssertEqual((runs[0]["style"] as? [String: Any])?["bold"] as? Bool, true)
        XCTAssertEqual((runs[0]["style"] as? [String: Any])?["color"] as? String, "blue")
        XCTAssertEqual((draft.original["style"] as? [String: Any])?["bold"] as? Bool, nil)
    }

    func testEmptyNewDraftIsDroppedAndTwoPanesHaveIndependentFormattingTargets() throws {
        let a = NativePDFTextDraft(object: row(), pageSize: page, existing: false)
        let b = NativePDFTextDraft(object: row(), pageSize: page, existing: false)
        a.preset(size: 24, bold: true); b.preset(size: 10, bold: false)
        XCTAssertNil(a.objectForSave()); XCTAssertNil(b.objectForSave())
        XCTAssertEqual(a.style.fontSizePt, 24); XCTAssertEqual(b.style.fontSizePt, 10)
        XCTAssertTrue(a.style.bold); XCTAssertFalse(b.style.bold)
        let whitespace = NSAttributedString(string: " \n\t", attributes: a.typingAttributes(scale: 1))
        a.acceptEditorText(whitespace, selection: NSRange(location: 3, length: 0), composing: false)
        XCTAssertNil(a.objectForSave())
    }

    func testWidthResizeWrapsAtPhysicalPointsAndPreservesStylesAndRuns() throws {
        let text = String(repeating: "한글 English 문장 ", count: 12)
        let source = row(text: text)
        let wide = NativePDFTextDraft.fittedObject(source, pageSize: page)
        let initial = try XCTUnwrap(NativePDFEditingGeometry.bounds(wide))
        let narrow = try XCTUnwrap(NativePDFEditingGeometry.resized([wide], original: initial, corner: "se",
            to: CGPoint(x: initial.minX + initial.width / 2, y: 0.9)).first)
        let resized = try XCTUnwrap(NativePDFEditingGeometry.bounds(narrow))
        XCTAssertEqual(resized.minY, initial.minY); XCTAssertEqual(resized.height, initial.height)
        let fitted = NativePDFTextDraft.fittedObject(narrow, pageSize: page)
        XCTAssertGreaterThan(try XCTUnwrap(NativePDFEditingGeometry.bounds(fitted)).height, initial.height)
        XCTAssertEqual((fitted["style"] as? [String: Any])?["fontSizePt"] as? Int, 14)
        XCTAssertEqual((fitted["data"] as? [String: Any])?["text"] as? String, text)
        let draft = NativePDFTextDraft(object: fitted, pageSize: page, existing: true)
        let font1 = try XCTUnwrap(draft.attributedText(scale: 1).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let font2 = try XCTUnwrap(draft.attributedText(scale: 2.5).attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font1.pointSize, 14); XCTAssertEqual(font2.pointSize, 35)
        XCTAssertEqual(draft.style.fontSizePt, 14, "Display zoom never rewrites saved typographic points")
    }

    @MainActor
    func testLiveBoxMapsToOverlayFrameAndGrowsWithText() throws {
        let mapper = InkCoordinateMapper.whiteboard(size: page)
        let frame = NativePDFInkSurface.textEditorFrame(box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2), mapper: mapper)
        XCTAssertEqual(frame.minX, page.width * 0.1, accuracy: 0.01); XCTAssertEqual(frame.minY, page.height * 0.1, accuracy: 0.01)
        XCTAssertEqual(frame.width, page.width * 0.5, accuracy: 0.01); XCTAssertEqual(frame.height, page.height * 0.2, accuracy: 0.01)
        let draft = NativePDFTextDraft(object: NativePDFTextDraft.newObject(at: CGPoint(x: 0.3, y: 0.4), page: 1, pageSize: page), pageSize: page, existing: false)
        let empty = try XCTUnwrap(draft.box)
        draft.acceptEditorText(NSAttributedString(string: "줄 하나\n줄 둘\n줄 셋"), selection: NSRange(location: 0, length: 0), composing: false)
        let tall = try XCTUnwrap(draft.box)
        XCTAssertGreaterThan(tall.height, empty.height, "The on-page box grows with its text")
        XCTAssertEqual(tall.width, empty.width); XCTAssertEqual(tall.minX, empty.minX)
    }

    @MainActor
    func testTextInputScalesTypographyToOverlayWidth() throws {
        let draft = NativePDFTextDraft(object: NativePDFTextDraft.fittedObject(row(text: "scale"), pageSize: page), pageSize: page, existing: true)
        let input = NativePDFTextInput(draft: draft, onSave: {}, onCancel: {})
        XCTAssertEqual(input.view.pageBox, draft.box)
        input.view.frame = CGRect(x: 0, y: 0, width: draft.physicalWidth * 2, height: 100)
        input.update()
        let font = try XCTUnwrap(input.view.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertEqual(font.pointSize, 28, "14 pt text doubles with a 2x overlay")
        XCTAssertEqual(input.view.textContainerInset.left, 14 * 0.36 * 2, accuracy: 0.001)
        XCTAssertFalse(input.view.isScrollEnabled)
        input.detach()
    }

    func testKoreanCompositionProtectsKeyboardFinishAndEscape() throws {
        let view = NativePDFTextInputView(usingTextLayoutManager: false)
        var saved = 0, cancelled = 0
        view.onSave = { saved += 1 }; view.onCancel = { cancelled += 1 }
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        view.finishFromKeyboard(); view.cancelFromKeyboard()
        XCTAssertEqual(saved, 0); XCTAssertEqual(cancelled, 0)
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0))
        view.unmarkText(); view.finishFromKeyboard()
        XCTAssertEqual(view.text, "한"); XCTAssertEqual(saved, 1)
        view.cancelFromKeyboard(); XCTAssertEqual(cancelled, 1)
    }

    func testSharedTextLayoutExportsStyledKoreanAsExtractablePDFText() throws {
        var source = row(text: "한글 서식\n두 번째 문장")
        source["style"] = ["color": "blue", "width": 0.002, "opacity": 0.65, "fontSizePt": 24,
            "bold": true, "italic": true, "underline": true, "strike": true, "align": "center", "fill": "yellow"] as [String: Any]
        source = NativePDFTextDraft.fittedObject(source, pageSize: page)
        let fittedData = try XCTUnwrap(source["data"] as? [String: Any])
        XCTAssertNotNil(fittedData["box"] as? [String: Double], "Fitted geometry is canonical before the first JSON write")
        let mapper = InkCoordinateMapper.whiteboard(size: page)
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page)).pdfData { context in
            context.beginPage()
            NativePDFObjectRenderer.draw(source, in: context.cgContext, mapper: mapper, image: nil)
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let extracted = pdf.string ?? ""
        XCTAssertTrue(extracted.contains("한글 서식"), "Extracted PDF text: \(extracted.debugDescription)")
        XCTAssertTrue(extracted.contains("두 번째 문장"), "Extracted PDF text: \(extracted.debugDescription)")
        let rowData = try XCTUnwrap(source["data"] as? [String: Any]), style = try XCTUnwrap(source["style"] as? [String: Any])
        let attributed = NativePDFObjectRenderer.attributedText(data: rowData, style: style, surfaceWidth: page.width)
        XCTAssertEqual(attributed.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(attributed.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual((attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment, .center)
    }

    func testSwiftGeometryPreviewWithCGFloatCoordinatesDoesNotDisappear() throws {
        var source = row(text: "Preview 한글")
        source["data"] = ["text": "Preview 한글", "box": ["x": CGFloat(0.1), "y": CGFloat(0.2), "width": 0.5, "height": 0.2] as [String: Any]]
        let mapper = InkCoordinateMapper.whiteboard(size: page)
        XCTAssertNotNil(NativePDFObjectRenderer.hitBounds(source, mapper: mapper))
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page)).pdfData { context in
            context.beginPage(); NativePDFObjectRenderer.draw(source, in: context.cgContext, mapper: mapper, image: nil)
        }
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: bytes)).string?.contains("Preview") == true)
    }

    private func box() -> [String: Double] { ["x": 0.1, "y": 0.1, "width": 0.5, "height": 0.2] }
    private func row(text: String = "") -> [String: Any] {
        ["id": "text", "page": 1, "kind": "textbox", "data": ["text": text, "box": box()],
         "style": ["color": "ink", "width": 0.002, "opacity": 1, "fontSizePt": 14]]
    }
}
