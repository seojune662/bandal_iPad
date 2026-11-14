import PDFKit
import UIKit
import XCTest
@testable import Bandal

final class NativeAINotePlacementTests: XCTestCase {
    private let a4 = 841.89 / 595.28
    private typealias P = NativeAINotePlacement

    /// Nothing may come within `gap` page widths of the placed rect.
    private func assertClear(_ rect: CGRect, of obstacles: [CGRect], gap: Double, aspect: Double, file: StaticString = #filePath, line: UInt = #line) {
        let grown = CGRect(x: rect.minX - gap + 1e-9, y: rect.minY - gap / aspect + 1e-9, width: rect.width + 2 * gap - 2e-9, height: rect.height + 2 * gap / aspect - 2e-9)
        for box in obstacles where grown.intersects(box) && !grown.intersection(box).isEmpty {
            XCTFail("\(rect) comes within \(gap) of \(box)", file: file, line: line); return
        }
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(rect), "\(rect) leaves the page", file: file, line: line)
    }
    /// A page of text: lines 0.015 tall every 0.022 from `top` to `bottom`, across `left`…`right`.
    private func lines(left: Double = 0.12, right: Double = 0.88, top: Double = 0.06, bottom: Double = 0.94, skipping hole: ClosedRange<Double>? = nil) -> [CGRect] {
        stride(from: top, to: bottom, by: 0.022).compactMap { y in
            hole.map { $0.contains(y) } == true ? nil : CGRect(x: left, y: y, width: right - left, height: 0.015)
        }
    }

    // MARK: Empty page

    func testEmptyPagePutsTheNoteOnTheAnchor() throws {
        let size = CGSize(width: 0.6, height: 0.1), anchor = CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let rect = try XCTUnwrap(P.nearestFree(size: size, anchor: anchor, obstacles: .init(), aspect: a4))
        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.006); XCTAssertEqual(rect.midY, 0.5, accuracy: 0.006)
        XCTAssertEqual(rect.size, size)
        let placed = try XCTUnwrap(P.place(sizes: [CGSize(width: 0.8, height: 0.2), size], anchor: anchor, obstacles: .init(), aspect: a4))
        XCTAssertEqual(placed.size, 0, "the widest note fits, so it is the one used"); XCTAssertFalse(placed.inMargin)
        XCTAssertGreaterThanOrEqual(placed.rect.minX, P.inset - 1e-9); XCTAssertLessThanOrEqual(placed.rect.maxX, 1 - P.inset + 1e-9)
    }

    func testAnchorNearThePageEdgeStaysInsideThePage() throws {
        let rect = try XCTUnwrap(P.place(sizes: [CGSize(width: 0.8, height: 0.15)], anchor: CGRect(x: 0.98, y: 0.99, width: 0, height: 0), obstacles: .init(), aspect: a4)).rect
        XCTAssertLessThanOrEqual(rect.maxX, 1 - P.inset + 1e-9); XCTAssertLessThanOrEqual(rect.maxY, 1 - P.inset / a4 + 1e-9)
    }

    func testTooLargeForAnyPageIsNil() {
        XCTAssertNil(P.nearestFree(size: CGSize(width: 1.2, height: 0.1), anchor: .zero, obstacles: .init(), aspect: a4))
        XCTAssertNil(P.place(sizes: [CGSize(width: 0.8, height: 1.1)], anchor: .zero, obstacles: .init(), aspect: a4))
    }

    // MARK: Dense page

    func testDensePageWithOneGapUsesTheGapNearestThePassage() throws {
        let text = lines(skipping: 0.5...0.62)
        let passage = CGRect(x: 0.12, y: 0.39, width: 0.5, height: 0.015)
        let placed = try XCTUnwrap(P.place(sizes: [CGSize(width: 0.8, height: 0.06), CGSize(width: 0.46, height: 0.09)], anchor: passage, obstacles: .init(text: text), aspect: a4))
        XCTAssertFalse(placed.inMargin)
        XCTAssertGreaterThan(placed.rect.minY, 0.49); XCTAssertLessThan(placed.rect.maxY, 0.64)
        assertClear(placed.rect, of: text, gap: P.gap, aspect: a4)
    }

    func testDensePageTakesAShortNoteInTheMarginAndALongOneNowhere() throws {
        let text = lines(left: 0.2, right: 0.8)
        let passage = text[20]
        // Body width notes do not fit between lines.
        let wide = [CGSize(width: 0.8, height: 0.06), CGSize(width: 0.34, height: 0.12)]
        XCTAssertNil(P.place(sizes: wide, anchor: passage, obstacles: .init(text: text), aspect: a4))
        let short = try XCTUnwrap(P.place(sizes: wide, marginSizes: [CGSize(width: 0.22, height: 0.3), CGSize(width: 0.16, height: 0.4)], anchor: passage, obstacles: .init(text: text), aspect: a4))
        XCTAssertTrue(short.inMargin); XCTAssertEqual(short.size, 1, "only the narrower margin note fits beside 0.2 of margin")
        XCTAssertTrue(short.rect.maxX <= 0.2 || short.rect.minX >= 0.8, "\(short.rect) is in a margin")
        XCTAssertEqual(short.rect.midY, passage.midY, accuracy: 0.05, "beside the passage")
        assertClear(short.rect, of: text, gap: P.marginGap, aspect: a4)
        // Taller than the margin: it goes to the page note.
        XCTAssertNil(P.place(sizes: wide, marginSizes: [CGSize(width: 0.16, height: 1.0)], anchor: passage, obstacles: .init(text: text), aspect: a4))
    }

    func testMarginsAreOutsideThePrintedContentOnly() {
        XCTAssertTrue(P.margins(around: [], aspect: a4).isEmpty)
        let regions = P.margins(around: [CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)], aspect: a4)
        XCTAssertEqual(regions.count, 4)
        for region in regions { XCTAssertTrue(region.intersection(CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)).isEmpty || region.intersection(CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)).width * region.intersection(CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)).height < 1e-9) }
    }

    func testObjectsAndHandwritingBlockAsMuchAsText() throws {
        // Free page except for one sticky note right where the anchor is.
        let sticker = CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.2)
        let rect = try XCTUnwrap(P.nearestFree(size: CGSize(width: 0.3, height: 0.08), anchor: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), obstacles: .init(objects: [sticker]), aspect: a4))
        assertClear(rect, of: [sticker], gap: P.gap, aspect: a4)
        let rect2 = try XCTUnwrap(P.nearestFree(size: CGSize(width: 0.3, height: 0.08), anchor: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), obstacles: .init(handwriting: [sticker]), aspect: a4))
        XCTAssertEqual(rect, rect2)
    }

    // MARK: Handwriting-heavy page

    func testHandwritingHeavyPageFindsTheOneBandLeftAndCoversNoStroke() throws {
        // Words of ink on every line but one band, plus a printed heading.
        var strokes: [CGRect] = []
        for y in stride(from: 0.08, to: 0.95, by: 0.035) where !(0.55...0.7).contains(y) {
            for x in stride(from: 0.06, to: 0.9, by: 0.09) { strokes.append(CGRect(x: x, y: y, width: 0.06, height: 0.02)) }
        }
        let heading = [CGRect(x: 0.1, y: 0.03, width: 0.5, height: 0.02)]
        let handwriting = P.handwritingLines(strokes, aspect: a4)
        XCTAssertLessThan(handwriting.count, strokes.count / 5, "words of a line become one line")
        let obstacles = P.Obstacles(text: heading, objects: strokes, handwriting: handwriting)
        let placed = try XCTUnwrap(P.place(sizes: [CGSize(width: 0.8, height: 0.08), CGSize(width: 0.46, height: 0.12)], anchor: CGRect(x: 0.5, y: 0.3, width: 0, height: 0), obstacles: obstacles, aspect: a4))
        XCTAssertGreaterThan(placed.rect.minY, 0.54); XCTAssertLessThan(placed.rect.maxY, 0.72)
        assertClear(placed.rect, of: strokes + handwriting + heading, gap: P.gap, aspect: a4)
    }

    func testHandwritingLinesJoinWordsButNotLines() {
        let line1 = [CGRect(x: 0.1, y: 0.2, width: 0.08, height: 0.02), CGRect(x: 0.2, y: 0.205, width: 0.06, height: 0.018), CGRect(x: 0.205, y: 0.19, width: 0.005, height: 0.006)]
        let line2 = [CGRect(x: 0.1, y: 0.26, width: 0.1, height: 0.02), CGRect(x: 0.22, y: 0.26, width: 0.1, height: 0.02)]
        let far = [CGRect(x: 0.8, y: 0.2, width: 0.05, height: 0.02)]
        let result = P.handwritingLines(line1 + line2 + far, aspect: a4).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertEqual(result.count, 3, "\(result)")
        XCTAssertEqual(result[0].minX, 0.1, accuracy: 1e-9); XCTAssertEqual(result[0].maxX, 0.26, accuracy: 1e-9)
        XCTAssertEqual(result[1].minX, 0.8, accuracy: 1e-9)
        XCTAssertEqual(result[2].maxX, 0.32, accuracy: 1e-9)
        XCTAssertTrue(P.handwritingLines([], aspect: a4).isEmpty)
    }

    func testThousandsOfStrokesStayFast() throws {
        var strokes: [CGRect] = []
        for index in 0..<4000 { strokes.append(CGRect(x: Double(index % 80) / 90, y: Double(index / 80) / 60, width: 0.008, height: 0.01)) }
        let started = Date()
        let lines = P.handwritingLines(strokes, aspect: a4)
        _ = P.place(sizes: [CGSize(width: 0.8, height: 0.1), CGSize(width: 0.34, height: 0.2)], marginSizes: [CGSize(width: 0.12, height: 0.2)],
                    anchor: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), obstacles: .init(objects: strokes, handwriting: lines), aspect: a4)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "debug build, simulator")
    }

    // MARK: What the answer points at

    func testQuotesLongestFirstAndShortTermsIgnored() {
        let answer = "핵심은 “고유벡터는 방향이 바뀌지 않는 벡터”라는 점이에요. \"det\" 는 짧아서 빼요.\n> 행렬식이 0이면 역행렬이 없다\n그리고 「선형 변환」도."
        XCTAssertEqual(P.quotes(in: answer), ["고유벡터는 방향이 바뀌지 않는 벡터", "행렬식이 0이면 역행렬이 없다", "선형 변환"])
        XCTAssertEqual(P.quotes(in: "따옴표 없음"), [])
    }

    func testRangeIgnoresLineBreaksSpacingAndCase() throws {
        let page = "3.2 Eigen\nvalues\n고유벡터는 방향이\n바뀌지 않는 벡터이다. 그 다음 문장."
        let text = page as NSString
        let found = try XCTUnwrap(P.range(of: "고유벡터는 방향이 바뀌지 않는 벡터", in: page))
        XCTAssertEqual(text.substring(with: found), "고유벡터는 방향이\n바뀌지 않는 벡터")
        XCTAssertEqual(text.substring(with: try XCTUnwrap(P.range(of: "EIGENVALUES", in: page))), "Eigen\nvalues")
        // Quoted start, paraphrased end: the first 24 characters still place it.
        let paraphrase = try XCTUnwrap(P.range(of: "고유벡터는 방향이 바뀌지 않는 벡터라고 교재는 설명합니다", in: page))
        XCTAssertTrue(text.substring(with: paraphrase).hasPrefix("고유벡터는"))
        XCTAssertNil(P.range(of: "없는 문장입니다", in: page)); XCTAssertNil(P.range(of: "고유", in: page), "too short to point anywhere")
    }

    func testContentBoxesIgnorePaperRulingAndFindPrint() {
        let width = 40, height = 60
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in stride(from: 4, to: height, by: 6) { for x in 0..<width { pixels[y * width + x] = 228 } } // app ruling, ~0.89
        for y in 20..<24 { for x in 5..<30 where x % 3 != 0 { pixels[y * width + x] = 40 } }             // a line of print
        let boxes = P.contentBoxes(pixels: pixels, width: width, height: height)
        XCTAssertFalse(boxes.isEmpty)
        for box in boxes {
            XCTAssertGreaterThanOrEqual(box.minY, 20.0 / 60 - 1e-9); XCTAssertLessThanOrEqual(box.maxY, 24.0 / 60 + 1e-9)
            XCTAssertGreaterThanOrEqual(box.minX, 4.0 / 40 - 1e-9); XCTAssertLessThanOrEqual(box.maxX, 30.0 / 40 + 1e-9)
        }
        // Light text on a dark slide is content too: the paper colour is the commonest one.
        let dark = [UInt8](repeating: 30, count: width * height)
        XCTAssertTrue(P.contentBoxes(pixels: dark, width: width, height: height).isEmpty)
    }

    /// The real page reader: text lines, a figure without text, and the quoted passage, all in display coordinates.
    func testPageScanFindsTextFigureAndPassageWhereTheyAreDrawn() throws {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage()
            ("고유벡터는 방향이 바뀌지 않는 벡터이다." as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            UIColor.black.setFill(); UIRectFill(CGRect(x: 300, y: 600, width: 200, height: 120))
        }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let scan = NativeAINotePageScan.scan(page, passages: ["없는 구절입니다", "방향이 바뀌지 않는 벡터"])
        let passage = try XCTUnwrap(scan.passage)
        XCTAssertEqual(passage.midY, (80 + 9) / 842, accuracy: 0.02, "\(passage)")
        XCTAssertGreaterThan(passage.minX, 60 / 595); XCTAssertLessThan(passage.maxX, 0.7)
        XCTAssertTrue(scan.textLines.contains { abs($0.midY - passage.midY) < 0.02 })
        let figure = CGRect(x: 300.0 / 595, y: 600.0 / 842, width: 200.0 / 595, height: 120.0 / 842)
        XCTAssertTrue(scan.content.contains { $0.intersects(figure) }, "the figure is content")
        XCTAssertFalse(scan.content.contains { $0.midY > 0.3 && $0.midY < 0.65 }, "the blank middle stays free")
        // A note asked about that passage goes near it, and covers neither the text nor the figure.
        let placed = try XCTUnwrap(P.place(sizes: [CGSize(width: 0.8, height: 0.1)], anchor: passage, obstacles: .init(text: scan.printed), aspect: 842.0 / 595))
        XCTAssertLessThan(placed.rect.minY, 0.3)
        assertClear(placed.rect, of: scan.printed, gap: P.gap, aspect: 842.0 / 595)
    }

    // MARK: Which place the question pointed at

    private func attachment(_ text: String? = nil, image: String? = nil, path: String = "강의.pdf", page: Int? = 3) -> NativeAssistantAttachment {
        NativeAssistantAttachment(title: "강의", text: text, imageDataURL: image, courseID: "c", relativePath: path, page: page)
    }

    func testTargetPrefersTheQuestionsAreaThenItsPassageThenTheAnswersQuotes() {
        let answer = "“방향이 바뀌지 않는 벡터”입니다."
        let area = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
        let region = NativeAINoteTarget.resolve(question: [attachment(image: "data:image/png;base64,AA")], answer: answer, courseID: "c", relativePath: "강의.pdf",
                                                visiblePage: 1, pageCount: 9, region: { _ in area })
        XCTAssertEqual(region, NativeAINoteTarget(page: 3, region: area, passages: []))
        let passage = NativeAINoteTarget.resolve(question: [attachment("고유값의 정의")], answer: answer, courseID: "c", relativePath: "강의.pdf",
                                                 visiblePage: 1, pageCount: 9, region: { _ in nil })
        XCTAssertEqual(passage, NativeAINoteTarget(page: 3, passages: ["고유값의 정의", "방향이 바뀌지 않는 벡터"]))
        // Another document's capture, or a page this PDF no longer has, says nothing about this page.
        for question in [[attachment("고유값", path: "다른.pdf")], [attachment("고유값", page: 12)], []] {
            XCTAssertEqual(NativeAINoteTarget.resolve(question: question, answer: answer, courseID: "c", relativePath: "강의.pdf", visiblePage: 5, pageCount: 9, region: { _ in nil }),
                           NativeAINoteTarget(page: 5, passages: ["방향이 바뀌지 않는 벡터"]))
        }
    }

    func testQuestionIsTheUserMessageRightBeforeTheAnswer() throws {
        let capture = attachment("구절")
        func message(_ id: String, _ role: String, _ attachments: [NativeAssistantAttachment] = []) -> NativeChatMessage {
            NativeChatMessage(["id": id, "role": role, "blocks": [["kind": "text", "payload": ["text": id]]] + attachments.map { ["kind": "attachment", "payload": $0.request] }])!
        }
        let messages = [message("q1", "user"), message("a1", "assistant"), message("q2", "user", [capture]), message("a2", "assistant")]
        XCTAssertEqual(NativeAINoteTarget.question(for: messages[3], in: messages).map(\.id), [capture.id])
        XCTAssertEqual(NativeAINoteTarget.question(for: messages[1], in: messages), [])
        XCTAssertEqual(NativeAINoteTarget.question(for: message("gone", "assistant"), in: messages), [])
    }

    @MainActor
    func testCapturedAreaIsRememberedByItsImage() {
        let image = "data:image/png;base64,\(UUID().uuidString)", area = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)
        NativeAINoteAnchors.remember(image: image, page: 3, area: area)
        XCTAssertEqual(NativeAINoteAnchors.area(for: attachment(image: image)), area)
        XCTAssertNil(NativeAINoteAnchors.area(for: attachment(image: image, page: 4)))
        XCTAssertNil(NativeAINoteAnchors.area(for: attachment(image: "data:image/png;base64,other")))
        XCTAssertNil(NativeAINoteAnchors.area(for: attachment("text only")))
    }
}
