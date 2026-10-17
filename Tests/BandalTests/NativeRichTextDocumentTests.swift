import Foundation
import XCTest
@testable import Bandal

final class NativeRichTextDocumentTests: XCTestCase {
    func testSupportedSyntaxRendersWithoutMarkdownMarkers() {
        let source = "# Heading\n**bold** _italic_ ~~old~~ `x*y`\n- [ ] todo\n- [x] done\n> quote\n[site](https://example.com) [[Note|Alias]]\n"
        let document = NativeRichTextDocument(source)
        XCTAssertEqual(document.text, "Heading\nbold italic old x*y\n☐ todo\n☑ done\nquote\nsite Alias\n")
        XCTAssertEqual(document.incorporating(document.text).markdown, source)
        XCTAssertTrue(document.runs.contains { $0.styles.contains("h1") })
        XCTAssertTrue(document.runs.contains { $0.styles.contains("code") })
    }
    func testEditingStyledTextPreservesExactUntouchedSourceAndLinkDestination() {
        let source = "## Heading\r\n\r\n**bold** and [label](https://example.com?q=1 \"title\")\r\n<!-- opaque -->\r\n"
        let document = NativeRichTextDocument(source)
        let range = (document.text as NSString).range(of: "bold")
        let changed = document.replacing(range, with: "new text").markdown
        XCTAssertEqual(changed, source.replacingOccurrences(of: "**bold**", with: "**new text**"))
        let link = (document.text as NSString).range(of: "label")
        XCTAssertEqual(document.replacing(link, with: "renamed").markdown, source.replacingOccurrences(of: "[label]", with: "[renamed]"))
    }
    func testUnicodeCompositionUsesOriginalProjectionUntilCommit() {
        let document = NativeRichTextDocument("# 제목\n**안녕 👩🏽‍💻**\n")
        let intermediate = document.incorporating("제목\n안녕 👩🏽‍💻ㅎ\n").markdown
        let final = document.incorporating("제목\n안녕 👩🏽‍💻한글\n").markdown
        XCTAssertEqual(intermediate, "# 제목\n**안녕 👩🏽‍💻ㅎ**\n")
        XCTAssertEqual(final, "# 제목\n**안녕 👩🏽‍💻한글**\n")
        let emoji = NativeRichTextDocument("😀")
        XCTAssertEqual(emoji.incorporating("😎").markdown, "😎")
    }
    func testUnknownExtensionsAndFrontMatterSurviveUnrelatedEditsExactly() {
        let source = "---\ncustom: {opaque: true}\n---\n# Title\n<div data-x=\"1\">custom</div>\n[^x]: footnote\n$$\\frac{x}{y}$$\n"
        let document = NativeRichTextDocument(source)
        XCTAssertEqual(document.replacing((document.text as NSString).range(of: "Title"), with: "Changed").markdown, source.replacingOccurrences(of: "# Title", with: "# Changed"))
        XCTAssertEqual(NativeRichTextDocument(source, sourceMode: true).text, source)
    }
    func testFencedCodePreservesLanguageAndLiteralMarkers() {
        let source = "```swift\nlet text = \"**literal**\"\n```\nAfter\n"
        let document = NativeRichTextDocument(source)
        XCTAssertTrue(document.text.contains("**literal**")); XCTAssertFalse(document.text.contains("```"))
        XCTAssertEqual(document.replacing((document.text as NSString).range(of: "literal"), with: "edited").markdown, source.replacingOccurrences(of: "literal", with: "edited"))
    }
    func testExistingLinkUpdateAndRemovalPreserveFormattedLabelTitleAndNeighbors() throws {
        let source = "앞 **고정** [**링크 😀**](https://old.example/path \"보존할 제목\") 뒤\r\n<!-- opaque -->"
        let document = NativeRichTextDocument(source)
        let selected = (document.text as NSString).range(of: "링크 😀")
        XCTAssertEqual(try XCTUnwrap(NativeRichTextCommands.link(in: document, selection: selected)).destination, "https://old.example/path")
        let update = NativeRichTextCommands.apply("link:https://new.example/a b)", to: document, selection: selected)
        XCTAssertEqual(update.markdown, source.replacingOccurrences(of: "https://old.example/path", with: "https://new.example/a%20b%29"))
        let removed = NativeRichTextCommands.apply("unlink", to: document, selection: NSRange(location: selected.location + 1, length: 0))
        XCTAssertEqual(removed.markdown, "앞 **고정** **링크 😀** 뒤\r\n<!-- opaque -->")
        XCTAssertTrue(NativeRichTextDocument(removed.markdown).runs.contains { $0.styles.contains("bold") })
    }
    func testLinkActionsDoNotTreatCodeOrImagesAsEditableLinks() {
        for source in ["`[literal](https://example.com)`", "![photo](assets/photo.png)", "plain text"] {
            let document = NativeRichTextDocument(source), selected = NSRange(location: 0, length: document.text.utf16.count)
            XCTAssertNil(NativeRichTextCommands.link(in: document, selection: selected))
            XCTAssertEqual(NativeRichTextCommands.apply("unlink", to: document, selection: selected).markdown, source)
        }
    }
    func testCodeLanguageOnlyUpdatesSelectedFenceAndKeepsBodyAndOtherMetadata() throws {
        let source = "```swift\nlet a = 1\n```\n\n  ~~~~python {opaque=true}\r\nprint('안녕')\r\n  ~~~~\r\nAfter\n"
        let document = NativeRichTextDocument(source), selected = (document.text as NSString).range(of: "print")
        XCTAssertEqual(try XCTUnwrap(NativeRichTextCommands.codeBlock(in: document, selection: selected)).language, "python")
        let updated = NativeRichTextCommands.apply("code-language:javascript", to: document, selection: selected)
        XCTAssertEqual(updated.markdown, source.replacingOccurrences(of: "~~~~python", with: "~~~~javascript"))
        XCTAssertEqual((updated.markdown as NSString).substring(with: updated.sourceSelection), "print")
        let removed = NativeRichTextCommands.apply("code-language:", to: document, selection: selected)
        XCTAssertEqual(removed.markdown, source.replacingOccurrences(of: "~~~~python", with: "~~~~"))
        let after = (document.text as NSString).range(of: "After")
        XCTAssertNil(NativeRichTextCommands.codeBlock(in: document, selection: after))
        XCTAssertEqual(NativeRichTextCommands.apply("code-language:json", to: document, selection: after).markdown, source)
    }
    func testEditorFontScaleUsesDesktopStepsAndClampsBoundaries() {
        XCTAssertEqual(NativeNoteFontScale.step(0.875, direction: -1), 0.875)
        XCTAssertEqual(NativeNoteFontScale.step(1.5, direction: 1), 1.5)
        XCTAssertEqual(NativeNoteFontScale.step(1, direction: 1), 1.125)
        XCTAssertEqual(NativeNoteFontScale.step(1, direction: -1), 0.875)
        XCTAssertEqual(NativeNoteFontScale.step(0, direction: 1), 1.125)
    }
    func testTableCellsAndImageReferencesSurviveEdits() {
        let source = "| First | Second |\n| :--- | ---: |\n| A | B |\n![alt](assets/a%20b.png)\n"
        let document = NativeRichTextDocument(source)
        XCTAssertFalse(document.text.contains("---")); XCTAssertFalse(document.text.contains("!["))
        XCTAssertTrue(document.runs.contains { $0.styles.contains("image") && $0.destination == "assets/a%20b.png" })
        XCTAssertEqual(document.replacing((document.text as NSString).range(of: "First"), with: "Name").markdown, source.replacingOccurrences(of: "First", with: "Name"))
    }
    func testInlineFormatToggleAndHeadingRetainUnknownNeighborBlocks() {
        let document = NativeRichTextDocument("hello\n\n::: opaque\ncustom\n:::\n")
        let bold = NativeRichTextCommands.apply("bold", to: document, selection: NSRange(location: 0, length: 5))
        XCTAssertEqual(bold.markdown, "**hello**\n\n::: opaque\ncustom\n:::\n")
        let unbold = NativeRichTextCommands.apply("bold", to: NativeRichTextDocument(bold.markdown), selection: NSRange(location: 0, length: 5))
        XCTAssertEqual(unbold.markdown, document.markdown)
        let heading = NativeRichTextCommands.apply("h2", to: document, selection: NSRange(location: 0, length: 5))
        XCTAssertEqual(heading.markdown, "## hello\n\n::: opaque\ncustom\n:::\n")
    }
    func testEnterContinuesAndExitsListsWithoutCheckedStateLeak() throws {
        let task = NativeRichTextDocument("- [x] Complete")
        let continued = try XCTUnwrap(NativeRichTextCommands.continuedLine(in: task, selection: NSRange(location: task.text.utf16.count, length: 0)))
        XCTAssertEqual(continued.markdown, "- [x] Complete\n- [ ] ")
        let empty = NativeRichTextDocument("- [ ] ")
        XCTAssertEqual(NativeRichTextCommands.continuedLine(in: empty, selection: NSRange(location: empty.text.utf16.count, length: 0))?.markdown, "")
        let numbered = NativeRichTextDocument("9. Nine")
        XCTAssertEqual(NativeRichTextCommands.continuedLine(in: numbered, selection: NSRange(location: numbered.text.utf16.count, length: 0))?.markdown, "9. Nine\n10. ")
    }
    func testTypingAtBoldEndStaysInsideFormatting() {
        let document = NativeRichTextDocument("**bold** then")
        XCTAssertEqual(document.replacing(NSRange(location: 4, length: 0), with: "!").markdown, "**bold!** then")
    }
    func testInsertionTemplatesRemainValidAfterRenderedEdit() {
        for command in ["table", "codeblock", "callout", "rule", "math", "wikilink"] {
            let inserted = NativeRichTextCommands.apply(command, to: NativeRichTextDocument(""), selection: NSRange(location: 0, length: 0))
            let document = NativeRichTextDocument(inserted.markdown)
            XCTAssertEqual(document.incorporating(document.text).markdown, inserted.markdown, command)
            XCTAssertFalse(document.text.isEmpty, command)
        }
    }
    func testDeletingEntireInlineSpanDoesNotCreatePhantomRuleOrCode() {
        for source in ["**bold**", "_italic_", "~~old~~", "`code`"] {
            let document = NativeRichTextDocument(source)
            XCTAssertEqual(document.replacing(NSRange(location: 0, length: document.text.utf16.count), with: "").markdown, "", source)
        }
    }
    func testPageSectionPatchPreservesUnknownManifestAndOtherSections() throws {
        let original = "<!-- bandal:pdf-page-note {\"future\":true} -->\n# Original\n\n<!-- bandal:page 1 -->\n\nBefore\n\n<!-- bandal:page 2 -->\n\nUntouched\n\n<!-- bandal:appendix -->\n\nArchived\n"
        let value = try XCTUnwrap(NativeMarkdownPageProjection.replacing(in: original, page: 0, appendix: false, text: "    code\n<!-- bandal:page 2 -->"))
        XCTAssertTrue(value.hasPrefix("<!-- bandal:pdf-page-note {\"future\":true} -->"))
        XCTAssertTrue(value.contains("    code\n&lt;!-- bandal:page 2 -->"))
        XCTAssertTrue(value.hasSuffix("<!-- bandal:page 2 -->\n\nUntouched\n\n<!-- bandal:appendix -->\n\nArchived\n"))
    }

    func testCrossStyleDeletionKeepsRemainingDelimitersBalanced() {
        let document = NativeRichTextDocument("**bold** _italic_ [link](https://example.com)")
        let partial = document.replacing(NSRange(location: 2, length: 5), with: "").markdown
        XCTAssertEqual(partial, "**bo**_alic_ [link](https://example.com)")
        XCTAssertEqual(NativeRichTextDocument(partial).text, "boalic link")
        XCTAssertEqual(document.replacing(NSRange(location: 0, length: document.text.utf16.count), with: "").markdown, "")
        let linked = document.replacing(NSRange(location: 8, length: 6), with: "X").markdown
        XCTAssertEqual(NativeRichTextDocument(linked).text, "bold itaXnk")
        XCTAssertTrue(linked.contains("https://example.com"))
    }
    func testCommonMarkDelimiterAndCodeFenceBoundaries() {
        let document = NativeRichTextDocument("snake_case_name 2 * 3 * 4 **bold** ``a`b``\n```swift\n```not closing\n**literal**\n```\n")
        XCTAssertTrue(document.text.hasPrefix("snake_case_name 2 * 3 * 4 bold a`b"))
        XCTAssertTrue(document.text.contains("```not closing\n**literal**"))
        XCTAssertEqual(document.incorporating(document.text).markdown, document.markdown)
    }
    func testTableRowColumnAndCellNavigationRetainEscapedAndCodePipes() throws {
        let source = "Before\n\n| A | B |\n| --- | --- |\n| a\\|b | `x|y` |\n\nAfter"
        let caret = NSRange(location: (source as NSString).range(of: "a\\|b").location, length: 0)
        let added = try XCTUnwrap(NativeRichTextTable.edit("table-column-after", markdown: source, selection: caret))
        XCTAssertTrue(added.markdown.contains("| a\\|b |  | `x|y` |"))
        let removed = try XCTUnwrap(NativeRichTextTable.edit("table-column-delete", markdown: added.markdown, selection: NSRange(location: (added.markdown as NSString).range(of: "|  |").location + 2, length: 0)))
        XCTAssertEqual(removed.markdown, source)
        let row = try XCTUnwrap(NativeRichTextTable.edit("table-row-after", markdown: source, selection: caret))
        XCTAssertTrue(row.markdown.contains("|  |  |\n\nAfter"))
        let next = try XCTUnwrap(NativeRichTextTable.edit("table-next", markdown: source, selection: caret))
        XCTAssertEqual((source as NSString).substring(with: next.sourceSelection), "`x|y`")
        XCTAssertTrue(NativeRichTextDocument(source).text.contains("a|b \t x|y"))
    }
    func testMathAttachmentsRetainExactInlineAndBlockTeX() {
        let source = "Inline $x^2 + \\frac{a}{b}$ text\n\n$$\n\\sum_{n=1}^{10} n\n$$\nEnd"
        let document = NativeRichTextDocument(source)
        XCTAssertEqual(document.runs.filter { $0.styles.contains("math") }.count, 2)
        XCTAssertFalse(document.text.contains("$"))
        XCTAssertEqual(document.incorporating(document.text).markdown, source)
    }

    func testFrontmatterChipEditsCannotLeaveOrphanedMetadataOrConsumeFollowingBody() {
        let metadata = "---\r\ntitle: opaque\r\nfuture: {nested: true}\r\n---"
        let original = metadata + "\r\n\r\n# Body\r\n"
        let document = NativeRichTextDocument(original)
        XCTAssertEqual(document.text, "文 문서 속성\r\n\r\nBody\r\n")
        let chip = document.runs.first { $0.styles.contains("metadata") }!
        XCTAssertEqual((original as NSString).substring(with: chip.source), metadata)
        XCTAssertEqual(document.replacing(chip.visible, with: "").markdown, "\r\n\r\n# Body\r\n")
        let partial = NSRange(location: chip.visible.location + 1, length: 1)
        XCTAssertEqual(document.replacing(partial, with: "Replacement").markdown, "Replacement\r\n\r\n# Body\r\n")
        let body = (document.text as NSString).range(of: "Body")
        XCTAssertEqual(document.replacing(body, with: "Edited").markdown, metadata + "\r\n\r\n# Edited\r\n")
    }

    func testLiteralCodeBlocksAndEscapedPunctuationStayLiteralAfterEdits() {
        let fenced = NativeRichTextDocument("```markdown\n$$\nx^2\n$$\n**literal**\n```\n")
        XCTAssertFalse(fenced.runs.contains { $0.styles.contains("math") || $0.styles.contains("bold") })
        XCTAssertTrue(fenced.text.contains("$$\nx^2\n$$\n**literal**"))
        let indented = NativeRichTextDocument("    **literal** and [link](destination)\n")
        XCTAssertEqual(indented.text, indented.markdown)
        XCTAssertFalse(indented.runs.contains { $0.styles.contains("bold") || $0.styles.contains("link") })
        let escaped = NativeRichTextDocument("before \\* after")
        let range = (escaped.text as NSString).range(of: "*")
        XCTAssertEqual(escaped.replacing(range, with: "").markdown, "before  after")
        XCTAssertEqual(escaped.replacing(range, with: "changed").markdown, "before changed after")
    }

    func testTypingAtDocumentStartNeverReplacesExistingContent() {
        for source in ["Original text", "**Original** text", "![image](assets/a.png) after", "[site](https://example.com) after"] {
            let document = NativeRichTextDocument(source)
            let range = document.sourceRange(for: NSRange(location: 0, length: 0))
            XCTAssertEqual(range.length, 0, source)
            let changed = document.incorporating("X" + document.text)
            XCTAssertEqual((changed.markdown as NSString).length, (source as NSString).length + 1, source)
            XCTAssertTrue(changed.markdown.contains("Original") || changed.markdown.contains("assets/a.png") || changed.markdown.contains("https://example.com"), source)
            XCTAssertEqual(NativeRichTextDocument(changed.markdown).text, "X" + document.text, source)
        }
    }
    func testEnterClosesAndSplitsInlineFormattingWithoutBreakingLists() throws {
        let bold = NativeRichTextDocument("**bold**")
        XCTAssertEqual(bold.replacing(NSRange(location: 4, length: 0), with: "\n").markdown, "**bold**\n")
        XCTAssertEqual(bold.replacing(NSRange(location: 0, length: 0), with: "\n").markdown, "\n**bold**")
        XCTAssertEqual(bold.replacing(NSRange(location: 2, length: 0), with: "\n").markdown, "**bo**\n**ld**")
        let list = NativeRichTextDocument("- **bold**")
        let end = try XCTUnwrap(NativeRichTextCommands.continuedLine(in: list, selection: NSRange(location: list.text.utf16.count, length: 0)))
        XCTAssertEqual(end.markdown, "- **bold**\n- ")
        let middle = try XCTUnwrap(NativeRichTextCommands.continuedLine(in: list, selection: NSRange(location: 4, length: 0)))
        XCTAssertEqual(middle.markdown, "- **bo**\n- **ld**")
    }

    func testEmptyHeadingAndTableHeaderHaveNativeProjectionStyles() {
        XCTAssertEqual(NativeRichTextDocument("##\n").text, "\n")
        let document = NativeRichTextDocument("| One | Two |\n| --- | --- |\n| short | longer |\n")
        XCTAssertTrue(document.runs.contains { $0.styles.contains("tableheader") })
        let body = (document.text as NSString).range(of: "short")
        XCTAssertFalse(document.runs.first { NSLocationInRange(body.location, $0.visible) }!.styles.contains("tableheader"))
    }

}
