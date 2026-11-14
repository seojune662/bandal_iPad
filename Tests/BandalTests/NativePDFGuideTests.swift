import PDFKit
import XCTest
@testable import Bandal

/// 짚어주기: finding a quoted passage, placing its note, the tool the model calls, and the player's hold on the reading position.
final class NativePDFGuideResolverTests: XCTestCase {
    private func found(_ quote: String, in text: String) -> [String] {
        NativePDFGuideResolver.ranges(of: quote, in: text).map { (text as NSString).substring(with: $0) }
    }

    func testQuoteBrokenOverALineIsFoundAcrossTheBreak() {
        let text = "열역학 제2법칙\n고립계의 엔트로\n피는 감소하지 않는다.\nEntropy of an isolated\nsystem never decreases."
        XCTAssertEqual(found("고립계의 엔트로피는 감소하지 않는다", in: text), ["고립계의 엔트로\n피는 감소하지 않는다"])
        XCTAssertEqual(found("isolated system never", in: text), ["isolated\nsystem never"])
        // Spacing the PDF and the model disagree on, either way.
        XCTAssertEqual(found("고립계의엔트로피는", in: text).count, 1)
        XCTAssertEqual(found("엔트 로피는  감소", in: text).count, 1)
        XCTAssertEqual(found("ENTROPY of an", in: text).count, 1, "case does not count")
    }

    func testCompatibilityFormsDashesAndQuotesMatch() {
        let decomposed = "엔트로피는 상태 함수".decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(decomposed.unicodeScalars.count, "엔트로피는 상태 함수".unicodeScalars.count)
        XCTAssertEqual(found("상태 함수", in: decomposed).count, 1, "Hangul stored decomposed")
        XCTAssertEqual(found("efficient", in: "an e\u{FB03}cient engine").count, 1, "a ligature")
        XCTAssertEqual(found("1 - Tc/Th", in: "효율은 1 \u{2212} Tc/Th 이다").count, 1, "a minus sign")
        XCTAssertEqual(found("\"heat engine\"", in: "the \u{201C}heat engine\u{201D} runs").count, 1)
        XCTAssertEqual(found("두 등온 과정과 두 단열 과정", in: "두 등온 과정과, 두 단열 과정으로").count, 1, "a dropped comma")
        XCTAssertEqual(found("soft", in: "so\u{00AD}ft").count, 1, "a soft hyphen")
    }

    func testMissingQuoteFindsNothing() {
        let text = "카르노 순환\n두 등온 과정과 두 단열 과정으로 이루어진다."
        XCTAssertTrue(found("이 페이지에 없는 구절", in: text).isEmpty)
        XCTAssertTrue(found("", in: text).isEmpty)
        XCTAssertTrue(found("두", in: text).isEmpty, "one character points at too many places")
        XCTAssertTrue(found("  \n ", in: text).isEmpty)
        XCTAssertTrue(found("카르노", in: "").isEmpty)
        XCTAssertNil(NativePDFGuideResolver.pick([], after: nil))
    }

    func testRepeatedQuoteListsEveryPlaceAndMovesOnFromThePreviousStep() {
        let text = "엔트로피 정의\n가역 과정의 엔트로피 변화\n비가역 과정의 엔\n트로피 변화"
        let ranges = NativePDFGuideResolver.ranges(of: "엔트로피", in: text)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["엔트로피", "엔트로피", "엔\n트로피"])
        XCTAssertEqual(ranges.map(\.location), ranges.map(\.location).sorted())
        XCTAssertEqual(NativePDFGuideResolver.pick(ranges, after: nil), ranges[0])
        XCTAssertEqual(NativePDFGuideResolver.pick(ranges, after: ranges[0].location), ranges[1])
        XCTAssertEqual(NativePDFGuideResolver.pick(ranges, after: ranges[1].location), ranges[2])
        // Past the last one it starts over.
        XCTAssertEqual(NativePDFGuideResolver.pick(ranges, after: ranges[2].location), ranges[0])
    }

    func testHandwrittenLinesAreSearchedWhenTheTextLacksTheQuote() {
        let lines = [NativePDFGuideResolver.Line(text: "엔트로피 증가", box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05)),
                     NativePDFGuideResolver.Line(text: "법칙 정리", box: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.05)),
                     NativePDFGuideResolver.Line(text: "dS = dQ / T", box: CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.05))]
        XCTAssertEqual(NativePDFGuideResolver.boxes(of: "증가 법칙", in: lines), [lines[0].box, lines[1].box], "across two written lines")
        XCTAssertEqual(NativePDFGuideResolver.boxes(of: "dS=dQ/T", in: lines), [lines[2].box])
        XCTAssertEqual(NativePDFGuideResolver.boxes(of: "카르노", in: lines), [])
        XCTAssertEqual(NativePDFGuideResolver.boxes(of: "증가", in: []), [])
    }

    /// The host's half on a real page: PDFKit's text, its selection, and rectangles on the page.
    @MainActor func testLocateOnARealPageGivesOneRectPerLine() throws {
        let bounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { renderer in
            renderer.beginPage()
            for (row, line) in ["열역학 제2법칙", "고립계의 엔트로피는", "감소하지 않는다.", "엔트로피는 상태 함수이다."].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 60, y: 90 + CGFloat(row) * 44), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.black])
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 800, height: 1000)); view.document = document
        let across = try NativePDFGuideStage.run(["action": "locate", "page": 1, "quote": "엔트로피는 감소하지"], view: view, scroll: nil, document: document)
        let rects = try XCTUnwrap(across["rects"] as? [[Double]])
        XCTAssertEqual(rects.count, 2, "\(rects)")
        XCTAssertLessThan(rects[0][1], rects[1][1], "top to bottom")
        XCTAssertTrue(rects.allSatisfy { $0[0] > 0 && $0[0] < 0.5 && $0[2] > 0 && $0[3] > 0 && $0[3] < 0.1 })
        // The same word again further down: the step after it moves on to it.
        let first = try NativePDFGuideStage.run(["action": "locate", "page": 1, "quote": "엔트로피는"], view: view, scroll: nil, document: document)
        let second = try NativePDFGuideStage.run(["action": "locate", "page": 1, "quote": "엔트로피는", "after": first["location"] as Any], view: view, scroll: nil, document: document)
        XCTAssertGreaterThan(try XCTUnwrap(second["location"] as? Int), try XCTUnwrap(first["location"] as? Int))
        XCTAssertGreaterThan(try XCTUnwrap((second["rects"] as? [[Double]])?.first?[1]), try XCTUnwrap((first["rects"] as? [[Double]])?.first?[1]))
        // Not there, and a page the document does not have: nothing to point at, no failure.
        XCTAssertEqual((try NativePDFGuideStage.run(["action": "locate", "page": 1, "quote": "카르노 순환"], view: view, scroll: nil, document: document)["rects"] as? [[Double]])?.count, 0)
        XCTAssertTrue(try NativePDFGuideStage.run(["action": "locate", "page": 9, "quote": "엔트로피"], view: view, scroll: nil, document: document).isEmpty)
    }
}

final class NativePDFGuidePlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 820, height: 1100)
    private func place(_ target: CGRect?, height: CGFloat = 90) -> (side: NativePDFGuidePlacement.Side, frame: CGRect) {
        NativePDFGuidePlacement.place(target: target, in: screen, top: 80, bottom: 0) { _ in height }
    }

    func testNoteSitsUnderThePassageAndOverItWhenThatIsFull() {
        let high = place(CGRect(x: 100, y: 300, width: 400, height: 24))
        XCTAssertEqual(high.side, .below)
        XCTAssertGreaterThan(high.frame.minY, 324)
        let low = place(CGRect(x: 100, y: 1000, width: 400, height: 24))
        XCTAssertEqual(low.side, .above)
        XCTAssertLessThan(low.frame.maxY, 1000)
    }

    func testWithoutRoomOrAPassageItBecomesASubtitle() {
        let missing = place(nil)
        XCTAssertEqual(missing.side, .subtitle)
        XCTAssertEqual(missing.frame.maxY, screen.maxY - NativePDFGuidePlacement.margin, accuracy: 0.5)
        XCTAssertEqual(missing.frame.midX, screen.midX, accuracy: 0.5)
        // A passage taking the whole page leaves no side: the subtitle covers it rather than wander.
        XCTAssertEqual(place(CGRect(x: 20, y: 90, width: 780, height: 990)).side, .subtitle)
        XCTAssertEqual(place(CGRect(x: 0, y: -400, width: 300, height: 20)).side, .subtitle, "off screen")
    }

    func testANoteBesideThePassageNeverCoversItOrThePointer() {
        for y in stride(from: 90.0, through: 1060, by: 35) {
            for (x, width) in [(30.0, 300.0), (60, 700), (420, 360), (40, 140)] {
                for height in [60.0, 160, 320] {
                    let target = CGRect(x: x, y: y, width: width, height: 24)
                    let placed = place(target, height: height)
                    XCTAssertTrue(screen.contains(placed.frame), "\(placed) for \(target)")
                    guard placed.side != .subtitle else { continue }
                    XCTAssertFalse(placed.frame.intersects(target.insetBy(dx: -NativePDFGuidePlacement.pointerReach, dy: 0)), "\(placed) covers \(target)")
                    XCTAssertGreaterThanOrEqual(placed.frame.minY, 80 + NativePDFGuidePlacement.margin - 0.5, "under the palette band")
                }
            }
        }
    }
}

final class NativePDFGuideToolTests: XCTestCase {
    private let pdf: [String: Any] = ["courseId": "c", "relPath": "강의/열역학.pdf", "title": "열역학", "kind": "pdf", "selection": ""]

    func testStepsAreValidatedNotRepaired() throws {
        let steps = try NativePDFGuideStep.list([["page": 2, "quote": "  효율은 1 - Tc/Th\n", "note": " 카르노 효율 "], ["page": 1, "quote": "", "note": "설명만"]])
        XCTAssertEqual(steps, [.init(page: 2, quote: "효율은 1 - Tc/Th", note: "카르노 효율"), .init(page: 1, quote: "", note: "설명만")])
        XCTAssertThrowsError(try NativePDFGuideStep.list([]))
        XCTAssertThrowsError(try NativePDFGuideStep.list([["page": 0, "quote": "a", "note": "b"]]))
        XCTAssertThrowsError(try NativePDFGuideStep.list([["page": 1.5, "quote": "a", "note": "b"]]))
        XCTAssertThrowsError(try NativePDFGuideStep.list([["page": 1, "quote": "a", "note": "  "]]))
        XCTAssertThrowsError(try NativePDFGuideStep.list(Array(repeating: ["page": 1, "quote": "a", "note": "b"], count: NativePDFGuideStep.maxSteps + 1)))
        XCTAssertEqual(try NativePDFGuideStep.list([["page": 1, "quote": String(repeating: "가", count: 900), "note": String(repeating: "나", count: 900)]]).first.map { [$0.quote.count, $0.note.count] },
                       [NativePDFGuideStep.maxQuote, NativePDFGuideStep.maxNote])
    }

    func testOnlyGuideModeWithAPDFOpenOffersTheTool() {
        let reads: [[String: Any]] = [NativePDFGuideTool.definition, ["name": "list_materials"], ["name": "read_material"]]
        func tools(_ mode: String?, _ document: [String: Any], course: String = "c", workspace: [String: Any] = [:], start: [[String: Any]] = reads) -> (names: [String], system: String) {
            var input: [String: Any] = ["system": "기본", "tools": start]
            NativePDFGuideTool.configure(&input, mode: mode, document: document, course: course, workspace: workspace)
            return ((input["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }, input["system"] as? String ?? "")
        }
        XCTAssertEqual(tools(nil, pdf).names, ["list_materials", "read_material"])
        XCTAssertEqual(tools("chat", pdf).system, "기본")
        let guided = tools("guide", pdf)
        XCTAssertEqual(guided.names, ["list_materials", "read_material", NativePDFGuideTool.name])
        XCTAssertTrue(guided.system.hasPrefix("기본\n짚어주기 모드입니다."), guided.system)
        // 지금 노트 leaves only the read; the guide still points into that note.
        XCTAssertEqual(tools("guide", pdf, start: [["name": "read_material"]]).names, ["read_material", NativePDFGuideTool.name])
        XCTAssertEqual(tools("guide", ["courseId": "c", "relPath": "노트.md", "kind": "note"]).names, ["list_materials", "read_material"])
        XCTAssertEqual(tools("guide", [:]).system, "기본")
        XCTAssertEqual(tools("guide", pdf, course: "other").names, ["list_materials", "read_material"], "another folder's PDF")
        XCTAssertEqual(tools("guide", pdf, course: "project", workspace: ["linkedCourseId": "c"]).names.last, NativePDFGuideTool.name)
        XCTAssertEqual(tools("guide", ["courseId": "c", "relPath": "스캔.PDF"]).names.last, NativePDFGuideTool.name, "kind missing: the extension says PDF")
    }

    func testPresentSendsTheStepsToTheOpenPDFOnly() throws {
        var sent: [(String, [String: Any])] = []
        let result = try NativePDFGuideTool.present(["steps": [["page": 3, "quote": "엔트로피는 상태 함수이므로", "note": "상태 함수"]]], document: pdf, course: "c", workspace: [:]) { channel, value in
            sent.append((channel, value as? [String: Any] ?? [:]))
        }
        XCTAssertTrue(result.contains("1단계"), result)
        XCTAssertEqual(sent.map(\.0), [NativePDFGuideTool.event])
        XCTAssertEqual(sent.first?.1["courseId"] as? String, "c"); XCTAssertEqual(sent.first?.1["relPath"] as? String, "강의/열역학.pdf")
        XCTAssertEqual(try NativePDFGuideStep.list(sent.first?.1["steps"]), [.init(page: 3, quote: "엔트로피는 상태 함수이므로", note: "상태 함수")])
        XCTAssertThrowsError(try NativePDFGuideTool.present(["steps": [["page": 1, "quote": "a", "note": "b"]]], document: ["courseId": "c", "relPath": "노트.md"], course: "c", workspace: [:]) { _, _ in XCTFail("sent") })
        XCTAssertThrowsError(try NativePDFGuideTool.present(["steps": "없음"], document: pdf, course: "c", workspace: [:]) { _, _ in XCTFail("sent") })
    }
}

/// The player against a stand-in host: what it asks for, and what it holds and gives back.
@MainActor
final class NativePDFGuidePlayerTests: XCTestCase {
    private var requests: [[String: Any]] = []
    private var located: [[Double]] = [[0.1, 0.2, 0.5, 0.03]]
    private var lines: [[String: Any]] = []
    private let origin: [String: Any] = ["page": 3, "zoom": 1.0, "progress": 0.42, "horizontalProgress": 0.5]

    private func player() -> NativePDFGuidePlayer {
        let guide = NativePDFGuidePlayer(documentPath: "강의자료.pdf")
        guide.host = { [unowned self] command, request in
            XCTAssertEqual(command, "guide")
            self.requests.append(request)
            switch request["action"] as? String {
            case "origin": return self.origin
            case "locate": return ["rects": self.located, "location": 10]
            case "show": return ["settle": 0.05]
            case "frames": return ["frames": (request["rects"] as? [[Double]] ?? []).map { [$0[0] * 800, $0[1] * 1000, $0[2] * 800, $0[3] * 1000] }]
            case "restore": return ["settle": 0.05]
            default: return [:]
            }
        }
        guide.handwriting = { [unowned self] _ in self.lines }
        return guide
    }
    private func actions() -> [String] { requests.compactMap { $0["action"] as? String } }
    private func waitUntil(_ condition: @autoclosure () -> Bool, _ message: String = "") async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }
    private let steps: [NativePDFGuideStep] = [.init(page: 2, quote: "효율은", note: "카르노 효율"), .init(page: 4, quote: "엔트로피", note: "상태 함수")]

    func testClosingGoesBackToTheHeldPositionThenLetsGo() async {
        let guide = player()
        guide.play(steps, ready: true)
        await waitUntil(guide.captioned && guide.target != nil, "the first passage is pointed at")
        XCTAssertEqual(actions().prefix(4), ["origin", "locate", "show", "frames"])
        XCTAssertEqual(guide.target?.frames, [CGRect(x: 80, y: 200, width: 400, height: 30)])
        XCTAssertTrue(guide.hold(["page": 2]), "a step's scroll is not the reading position")
        XCTAssertEqual(guide.origin?["progress"] as? Double, 0.42)
        guide.close()
        await waitUntil(guide.origin == nil)
        let restore = requests.last { $0["action"] as? String == "restore" }
        XCTAssertEqual(restore?["page"] as? Int, 3); XCTAssertEqual(restore?["progress"] as? Double, 0.42)
        XCTAssertFalse(guide.playing); XCTAssertNil(guide.target)
        XCTAssertFalse(guide.hold(["page": 3]))
    }

    func testATouchStopsItWhereItIsAndHandsBackThatPosition() async {
        let guide = player()
        var released: [[String: Any]?] = []
        guide.onRelease = { released.append($0) }
        guide.play(steps, ready: true)
        await waitUntil(guide.captioned)
        _ = guide.hold(["page": 2, "progress": 0.3])
        guide.interrupt()
        XCTAssertFalse(guide.playing); XCTAssertFalse(guide.captioned); XCTAssertNil(guide.origin)
        XCTAssertEqual(released.count, 1); XCTAssertEqual(released.first??["page"] as? Int, 2)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(actions().contains("restore"), "the reader's position is not taken back from them")
        guide.interrupt()
        XCTAssertEqual(released.count, 1, "nothing more to hand back")
    }

    func testHiddenMidwayKeepsThePositionForTheNextShowing() async {
        let guide = player()
        var later: [[String: Any]] = [], released: [[String: Any]?] = []
        guide.onRestoreLater = { later.append($0) }; guide.onRelease = { released.append($0) }
        guide.play(steps, ready: true)
        await waitUntil(guide.captioned)
        _ = guide.hold(["page": 2])
        guide.suspend()
        XCTAssertFalse(guide.playing)
        XCTAssertEqual(later.first?["page"] as? Int, 3)
        XCTAssertEqual(guide.origin?["page"] as? Int, 3, "a flush while hidden still saves where the reader was")
        // Shown again: the layout that restores the position lets go of it, handing nothing back.
        guide.interrupt()
        XCTAssertNil(guide.origin); XCTAssertEqual(released.count, 1); XCTAssertNil(released.first ?? nil)
    }

    func testStepsWaitForTheDocumentAndControlsMoveBetweenThem() async {
        let guide = player()
        guide.play(steps, ready: false)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(requests.isEmpty)
        guide.layoutApplied(visible: true, ready: true)
        await waitUntil(guide.captioned && guide.index == 0)
        guide.advance()
        XCTAssertFalse(guide.typing, "a tap writes the rest at once")
        guide.advance()
        await waitUntil(guide.index == 1 && guide.captioned, "the next tap moves on")
        XCTAssertEqual(requests.last { $0["action"] as? String == "locate" }?["page"] as? Int, 4)
        guide.togglePause(); XCTAssertTrue(guide.paused)
        guide.previous()
        await waitUntil(guide.index == 0 && guide.captioned)
        XCTAssertFalse(guide.paused)
        guide.interrupt()
    }

    func testAPassageNotOnThePageIsLookedForInTheHandwritingThenLeftAsANote() async {
        located = []
        lines = [["text": "카르노 효율은", "box": [0.1, 0.5, 0.4, 0.05]], ["text": "두 온도로 정해진다", "box": [0.1, 0.56, 0.5, 0.05]]]
        let guide = player()
        guide.play([.init(page: 2, quote: "효율은 두 온도로", note: "필기에서 찾음"), .init(page: 2, quote: "어디에도 없는 구절", note: "설명만")], ready: true)
        await waitUntil(guide.captioned)
        XCTAssertEqual(requests.last { $0["action"] as? String == "show" }?["rects"] as? [[Double]], [[0.1, 0.5, 0.4, 0.05], [0.1, 0.56, 0.5, 0.05]])
        XCTAssertEqual(guide.target?.frames.count, 2)
        guide.next()
        await waitUntil(guide.index == 1 && guide.captioned)
        XCTAssertNil(guide.target, "no pointer for a passage that is nowhere")
        XCTAssertEqual(requests.last { $0["action"] as? String == "show" }?["rects"] as? [[Double]], [])
        guide.interrupt()
    }

    func testAClosedSurfaceEndsItHoldingNothing() async {
        let guide = player()
        guide.host = { _, request in
            if request["action"] as? String == "origin" { return ["page": 1] }
            throw NativePDFError.invalid("PDF 화면 연결이 닫혔습니다.")
        }
        guide.play(steps, ready: true)
        await waitUntil(!guide.playing)
        XCTAssertNil(guide.origin); XCTAssertFalse(guide.captioned)
    }
}

private final class NativePDFGuideAIProtocol: URLProtocol {
    static var replies: [String] = []
    static var requests: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path.hasSuffix("/config") == true {
            let config: [String: Any] = ["models": [["id": "gpt-6-luna", "provider": "openai", "label": "GPT-6 Luna", "contextCap": 100000, "badge": 1]],
                                         "auto": ["id": "gpt-6-luna", "provider": "openai", "contextCap": 30000], "consentVersion": 1, "usage": ["consents": ["openai": 1, "anthropic": 1]]]
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: config)); client?.urlProtocolDidFinishLoading(self)
            return
        }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        }
        if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { Self.requests.append(object) }
        let reply = Self.replies.isEmpty ? "" : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A guide-mode turn end to end: the model sees the tool, its steps reach the open PDF within the same turn.
@MainActor
final class NativePDFGuideTurnTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var service: NativeAssistantService!
    private var identity: [String: Any] = [:]
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-guide-\(UUID().uuidString)")
        runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let course = try await runtime.invoke("courses:create", request: ["name": "AI test", "color": "blue"]) as! [String: Any]
        identity = ["courseId": course["id"]!, "sessionId": UUID().uuidString, "provider": "codex"]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NativePDFGuideAIProtocol.self]
        var environment = DesktopAIEnvironment(); environment.session = URLSession(configuration: config)
        environment.endpoint = { AIEndpoint(userID: "user-a", projectURL: URL(string: "https://project.test")!, publishableKey: "pk", token: { "jwt" }) }; environment.hasConsent = { _, _, _ in true }
        NativePDFGuideAIProtocol.requests = []; NativePDFGuideAIProtocol.replies = []
        service = NativeAssistantService(runtime: runtime, ai: DesktopAIService(environment: environment))
        runtime.onNativeCall = { [weak service] channel, request in guard let service else { throw CancellationError() }; return try await service.handle(channel, request) }
        _ = try await runtime.invoke("chat:open", request: identity)
    }
    override func tearDown() async throws {
        runtime.onNativeCall = nil; runtime.onEmit = nil; service = nil; runtime = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func event(_ object: [String: Any]) throws -> String { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n\n" }
    private func send(_ request: [String: Any]) async throws -> [(String, [String: Any])] {
        var emitted: [(String, [String: Any])] = []
        let completed = expectation(description: "turn complete")
        runtime.onEmit = { channel, value in
            let payload = value as? [String: Any] ?? [:]
            emitted.append((channel, payload))
            if channel == "chat:event-batch", (payload["events"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "turn-complete" }) == true { completed.fulfill() }
        }
        _ = try await runtime.invoke("chat:send", request: request)
        await fulfillment(of: [completed], timeout: 8)
        return emitted
    }

    func testGuideTurnHandsTheStepsToTheOpenPDF() async throws {
        let course = identity["courseId"] as! String
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["steps": [["page": 2, "quote": "효율은 1 - Tc/Th", "note": "카르노 효율"], ["page": 1, "quote": "고립계", "note": "제2법칙"]]]), as: UTF8.self)
        NativePDFGuideAIProtocol.replies = [try event(["type": "response.completed", "response": ["output": [["type": "function_call", "call_id": "steps-1", "name": NativePDFGuideTool.name, "arguments": arguments]]]]),
                                            try event(["type": "response.output_text.delta", "delta": "PDF에서 짚어 드렸어요."]) + "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"]
        let document: [String: Any] = ["courseId": course, "relPath": "열역학.pdf", "title": "열역학.pdf", "kind": "pdf", "selection": ""]
        let emitted = try await send(identity.merging(["content": "효율 공식이 어디 있어?", "mode": NativeAssistantMode.guide.rawValue, "documentContext": document]) { _, new in new })
        let offered = (NativePDFGuideAIProtocol.requests.first?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(offered, ["list_materials", "read_material", NativePDFGuideTool.name])
        XCTAssertTrue((NativePDFGuideAIProtocol.requests.first?["instructions"] as? String ?? "").contains("짚어주기 모드"))
        let guide = try XCTUnwrap(emitted.first { $0.0 == NativePDFGuideTool.event }?.1)
        XCTAssertEqual(guide["courseId"] as? String, course); XCTAssertEqual(guide["relPath"] as? String, "열역학.pdf")
        XCTAssertEqual(try NativePDFGuideStep.list(guide["steps"]).map(\.page), [2, 1])
        let output = try XCTUnwrap((NativePDFGuideAIProtocol.requests.last?["input"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call_output" }?["output"] as? String)
        XCTAssertTrue(output.contains("2단계"), output)
        XCTAssertEqual(NativePDFGuideAIProtocol.requests.count, 2, "one turn: the steps call and the closing line")

        // The same question in 대화 never offers the tool.
        NativePDFGuideAIProtocol.requests = []
        NativePDFGuideAIProtocol.replies = [try event(["type": "response.output_text.delta", "delta": "답"]) + "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"]
        let plain = try await send(identity.merging(["content": "효율 공식", "mode": "chat", "documentContext": document]) { _, new in new })
        XCTAssertEqual((NativePDFGuideAIProtocol.requests.first?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["list_materials", "read_material"])
        XCTAssertFalse(plain.contains { $0.0 == NativePDFGuideTool.event })
    }
}
