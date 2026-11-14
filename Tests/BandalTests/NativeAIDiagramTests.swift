import XCTest
@testable import Bandal

final class NativeAIDiagramTests: XCTestCase {
    private typealias D = NativeAIDiagram
    private let a4 = 841.89 / 595.28
    /// Text boxes as if every character took 0.012 page widths and a line 0.03.
    private let measure: D.Measure = { text, _, maxWidth in
        let natural = Double(text.count) * 0.012 + 0.02
        return CGSize(width: min(maxWidth, natural), height: 0.03 * (natural / maxWidth).rounded(.up))
    }
    private func spec(_ nodes: [String], _ edges: [(String, String)], title: String? = nil) throws -> D.Spec {
        var arguments: [String: Any] = ["nodes": nodes.map { ["id": $0, "label": "개념 " + $0] }, "edges": edges.map { ["from": $0.0, "to": $0.1] }]
        if let title { arguments["title"] = title }
        return try D.parse(arguments)
    }
    private func assertNoOverlap(_ layout: D.Layout, file: StaticString = #filePath, line: UInt = #line) {
        for (i, a) in layout.nodes.enumerated() {
            for b in layout.nodes[(i + 1)...] where a.intersects(b) && !a.intersection(b).isEmpty { XCTFail("\(a) overlaps \(b)", file: file, line: line) }
            XCTAssertTrue(CGRect(origin: .zero, size: layout.size).insetBy(dx: -1e-9, dy: -1e-9).contains(a), file: file, line: line)
        }
        // No connector passes through a box it does not join.
        for connector in layout.connectors {
            for (p, q) in zip(connector.points, connector.points.dropFirst()) {
                for (index, box) in layout.nodes.enumerated() where ![connectorEnds(connector, layout).0, connectorEnds(connector, layout).1].contains(index) {
                    XCTAssertFalse(D.crosses(p, q, box.insetBy(dx: 0.002, dy: 0.002)), "edge \(connector.edge) crosses box \(index)", file: file, line: line)
                }
            }
        }
    }
    private var current: D.Spec?
    private func connectorEnds(_ connector: D.Layout.Connector, _ layout: D.Layout) -> (Int, Int) {
        let edge = current!.edges[connector.edge]; return (edge.from, edge.to)
    }

    // MARK: Input

    func testParseKeepsTheModelToAFewShortBoxes() throws {
        let parsed = try D.parse(["title": "고유값\n정리", "nodes": [["id": "a", "label": String(repeating: "가", count: 60)], ["id": "b", "label": "끝"]],
                                  "edges": [["from": "a", "to": "b", "label": "다음"], ["from": "a", "to": "b"], ["from": "b", "to": "b"]]])
        XCTAssertEqual(parsed.title, "고유값 정리")
        XCTAssertEqual(parsed.nodes[0].label.count, D.maxLabel); XCTAssertTrue(parsed.nodes[0].label.hasSuffix("…"))
        XCTAssertEqual(parsed.edges, [D.Edge(from: 0, to: 1, label: "다음")], "a repeated edge and a self loop are dropped")
        XCTAssertEqual(try D.parse(["nodes": [["id": "a", "label": "하나"]]]).edges, [], "edges may be left out")
        let tooMany = (0...D.maxNodes).map { ["id": "n\($0)", "label": "\($0)"] }
        XCTAssertThrowsError(try D.parse(["nodes": tooMany, "edges": []]))
        XCTAssertThrowsError(try D.parse(["nodes": [], "edges": []]))
        XCTAssertThrowsError(try D.parse(["nodes": [["id": "a", "label": "x"], ["id": "a", "label": "y"]], "edges": []]))
        XCTAssertThrowsError(try D.parse(["nodes": [["id": "a", "label": "x"]], "edges": [["from": "a", "to": "z"]]]))
        XCTAssertThrowsError(try D.parse(["nodes": [["id": "a"]], "edges": []]))
    }

    func testOfferedOnlyWithAPDFOpenWhateverTheScope() {
        let all: [[String: Any]] = [["name": "list_materials"], D.tool, ["name": "read_material"]]
        let pdf: [String: Any] = ["courseId": "c", "relPath": "자료/강의.pdf", "kind": "pdf"]
        func names(_ tools: [[String: Any]]) -> [String] { tools.compactMap { $0["name"] as? String } }
        XCTAssertEqual(names(D.offered(all, from: all, document: pdf)), ["list_materials", "read_material", D.toolName])
        XCTAssertEqual(names(D.offered([["name": "read_material"]], from: all, document: pdf)), ["read_material", D.toolName], "지금 노트 still draws on the open PDF")
        XCTAssertEqual(names(D.offered(all, from: all, document: ["courseId": "c", "relPath": "노트.md", "kind": "note"])), ["list_materials", "read_material"])
        XCTAssertEqual(names(D.offered(all, from: all, document: [:])), ["list_materials", "read_material"])
        let schema = D.tool["inputSchema"] as? [String: Any], nodes = (schema?["properties"] as? [String: Any])?["nodes"] as? [String: Any]
        XCTAssertEqual(nodes?["maxItems"] as? Int, D.maxNodes)
        XCTAssertNil((schema?["properties"] as? [String: Any])?["x"], "no coordinates are asked of the model")
    }

    // MARK: Layout

    func testChainGoesDownOneBoxUnderTheOther() throws {
        current = try spec(["a", "b", "c", "d"], [("a", "b"), ("b", "c"), ("c", "d")], title: "흐름")
        let layout = try XCTUnwrap(D.layout(current!, direction: .down, measure: measure))
        assertNoOverlap(layout)
        for (upper, lower) in zip(layout.nodes, layout.nodes.dropFirst()) { XCTAssertGreaterThan(lower.minY, upper.maxY); XCTAssertEqual(lower.midX, upper.midX, accuracy: 1e-9) }
        XCTAssertEqual(layout.connectors.count, 3)
        for (index, connector) in layout.connectors.enumerated() {
            XCTAssertEqual(connector.points.count, 2, "nothing in the way: straight")
            let from = layout.nodes[index], to = layout.nodes[index + 1]
            XCTAssertEqual(connector.points[0].y, from.maxY, accuracy: 0.01); XCTAssertEqual(connector.points[1].y, to.minY, accuracy: 0.01)
        }
        let title = try XCTUnwrap(layout.title)
        XCTAssertLessThanOrEqual(title.maxY, layout.nodes[0].minY)
        XCTAssertEqual(title.minY, 0, accuracy: 1e-9)
    }

    func testTooWideToGoDownGoesSideways() throws {
        current = try spec(["root"] + (1...11).map { "l\($0)" }, (1...11).map { ("root", "l\($0)") })
        XCTAssertNil(D.layout(current!, direction: .down, measure: measure), "eleven boxes side by side are too narrow to read")
        let layout = try XCTUnwrap(D.layout(current!, direction: .right, measure: measure))
        assertNoOverlap(layout)
        XCTAssertTrue(layout.nodes.dropFirst().allSatisfy { $0.minX > layout.nodes[0].maxX })
        let plan = try XCTUnwrap(D.plan(current!, anchor: CGRect(x: 0.5, y: 0.5, width: 0, height: 0), obstacles: .init(), aspect: a4, measure: { _ in self.measure }))
        XCTAssertEqual(plan.layout.size, layout.size)
    }

    func testCycleAndSkippedLayerGoAroundTheBoxesInTheWay() throws {
        current = try spec(["a", "b", "c"], [("a", "b"), ("b", "c"), ("c", "a")])
        XCTAssertEqual(D.backEdges(current!), [2])
        for direction in [D.Direction.down, .right] {
            let layout = try XCTUnwrap(D.layout(current!, direction: direction, measure: measure))
            assertNoOverlap(layout)
            XCTAssertEqual(layout.connectors[2].points.count, 4, "the edge back to the start rounds the outside")
        }
        current = try spec(["a", "b", "c"], [("a", "b"), ("b", "c"), ("a", "c")])
        let layout = try XCTUnwrap(D.layout(current!, direction: .down, measure: measure))
        assertNoOverlap(layout)
        XCTAssertEqual(layout.connectors.map(\.points.count), [2, 2, 4])
    }

    func testOppositeArrowsRunSideBySide() throws {
        current = try spec(["a", "b"], [("a", "b"), ("b", "a")])
        let layout = try XCTUnwrap(D.layout(current!, direction: .down, measure: measure))
        let there = layout.connectors[0].points, back = layout.connectors[1].points
        XCTAssertGreaterThan(abs(there[0].x - back[1].x), 0.01)
    }

    func testTreeKeepsBranchesInLayersAndLabelsBesideArrows() throws {
        var parsed = try spec(["a", "b", "c", "d", "e"], [("a", "b"), ("a", "c"), ("b", "d"), ("c", "e")])
        parsed.edges[0] = D.Edge(from: 0, to: 1, label: "원인")
        current = parsed
        let layout = try XCTUnwrap(D.layout(parsed, direction: .down, measure: measure))
        assertNoOverlap(layout)
        XCTAssertEqual(layout.nodes[1].minY, layout.nodes[2].minY, accuracy: 1e-9)
        XCTAssertLessThan(layout.nodes[3].midX, layout.nodes[4].midX, "children stay under their own parent's side")
        let label = try XCTUnwrap(layout.connectors[0].label)
        for box in layout.nodes { XCTAssertFalse(label.intersects(box) && !label.intersection(box).isEmpty, "\(label) covers \(box)") }
        XCTAssertNil(layout.connectors[1].label)
    }

    // MARK: Objects and placement

    func testRowsAreOrdinaryValidObjectsOnThePage() throws {
        current = try spec(["a", "b", "c"], [("a", "b"), ("b", "c"), ("c", "a")], title: "순환")
        let layout = try XCTUnwrap(D.layout(current!, direction: .down, measure: measure))
        let rows = D.rows(layout, spec: current!, page: 2, origin: CGPoint(x: 0.1, y: 0.2), aspect: a4, scale: 1)
        XCTAssertEqual(Set(rows.compactMap { $0["kind"] as? String }), ["textbox", "rect", "arrow", "line"])
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "rect" }.count, 3)
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "arrow" }.count, 3, "one head per edge")
        XCTAssertEqual(rows.filter { $0["kind"] as? String == "textbox" }.count, 4)
        for row in rows {
            let kind = try XCTUnwrap(row["kind"] as? String)
            XCTAssertNoThrow(try NativePDFRepositoryValidation.data(row["data"], kind: kind), "\(row)")
            XCTAssertNoThrow(try NativePDFRepositoryValidation.style(row["style"]), "\(row)")
            XCTAssertEqual(row["page"] as? Int, 2)
            XCTAssertNil(row["id"], "new objects")
        }
        let first = try XCTUnwrap(NativePDFEditingGeometry.union(rows, aspect: a4))
        XCTAssertEqual(first.minX, 0.1, accuracy: 0.003); XCTAssertEqual(first.minY, 0.2, accuracy: 0.003)
        XCTAssertEqual(first.width, layout.size.width, accuracy: 0.01); XCTAssertEqual(first.height, layout.size.height / a4, accuracy: 0.01)
    }

    func testPlanUsesFreeSpaceAndRefusesAFullPage() throws {
        current = try spec(["a", "b", "c", "d"], [("a", "b"), ("b", "c"), ("c", "d")])
        // The top half is printed: the diagram goes below, clear of it.
        let printed = [CGRect(x: 0.08, y: 0.05, width: 0.84, height: 0.45)]
        let plan = try XCTUnwrap(D.plan(current!, anchor: CGRect(x: 0.5, y: 0.3, width: 0, height: 0), obstacles: .init(text: printed), aspect: a4, measure: { _ in self.measure }))
        XCTAssertGreaterThan(plan.rect.minY, 0.5); XCTAssertLessThanOrEqual(plan.rect.maxY, 1)
        XCTAssertEqual(plan.rect.width, plan.layout.size.width, accuracy: 1e-9)
        let full = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        XCTAssertNil(D.plan(current!, anchor: .zero, obstacles: .init(text: full), aspect: a4, measure: { _ in self.measure }))
        // A page with room only for the smaller size gets the 80 % version.
        let scaled: (Double) -> D.Measure = { scale in { text, role, width in let size = self.measure(text, role, width); return CGSize(width: size.width * scale, height: size.height * scale) } }
        // Room for 95 % of the flattest full-size layout (one row, sideways) under the top edge.
        let flat = try XCTUnwrap(D.layout(current!, direction: .right, measure: scaled(1)))
        let room = (NativeAINotePlacement.inset + NativeAINotePlacement.gap + 0.95 * flat.size.height) / a4
        let tight = [CGRect(x: 0, y: room, width: 1, height: 1 - room)]
        let small = try XCTUnwrap(D.plan(current!, anchor: .zero, obstacles: .init(objects: tight), aspect: a4, measure: scaled))
        XCTAssertEqual(small.scale, 0.8)
    }

    // MARK: Reaching the editor

    @MainActor
    func testDrawWaitsForTheEditorThatClaimsIt() async throws {
        let pdf: [String: Any] = ["courseId": "c", "relPath": "강의.pdf", "kind": "pdf"]
        var events: [String] = []
        let answer = try await D.draw(["nodes": [["id": "a", "label": "하나"], ["id": "b", "label": "둘"]], "edges": [["from": "a", "to": "b"]]], document: pdf) { channel, payload in
            events.append(channel)
            guard let payload = payload as? [String: Any], payload["relPath"] as? String == "강의.pdf", let request = payload["request"] as? D.Request else { return }
            XCTAssertTrue(request.claim()); XCTAssertFalse(request.claim(), "one editor draws it")
            XCTAssertEqual(request.spec.nodes.count, 2)
            Task { @MainActor in request.finish(.success("넣었습니다")) }
        }
        XCTAssertEqual(answer, "넣었습니다"); XCTAssertEqual(events, [D.channel])
    }

    @MainActor
    func testDrawFailsWhenNoEditorHasThePDFOrTheInputIsBad() async throws {
        let pdf: [String: Any] = ["courseId": "c", "relPath": "강의.pdf", "kind": "pdf"]
        let nodes: [String: Any] = ["nodes": [["id": "a", "label": "하나"]], "edges": []]
        do { _ = try await D.draw(nodes, document: pdf, emit: { _, _ in }, claimTimeout: .milliseconds(50)); XCTFail("nobody claimed it") }
        catch { XCTAssertTrue(error.localizedDescription.contains("열려 있지 않아"), error.localizedDescription) }
        do { _ = try await D.draw(nodes, document: ["courseId": "c", "relPath": "노트.md", "kind": "note"], emit: { _, _ in XCTFail("no event without a PDF") }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("PDF"), error.localizedDescription) }
        do { _ = try await D.draw(["nodes": []], document: pdf, emit: { _, _ in XCTFail("no event for bad input") }); XCTFail() } catch {}
    }
}

private final class NativeAIDiagramProtocol: URLProtocol {
    static var replies: [String] = []
    static var requests: [[String: Any]] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path.hasSuffix("/config") == true {
            let config: [String: Any] = ["models": [["id": "gpt-6-luna", "provider": "openai", "label": "GPT-6 Luna", "contextCap": 100000, "badge": 1]],
                                         "auto": ["id": "gpt-6-luna", "provider": "openai", "contextCap": 30000], "consentVersion": 1, "usage": ["consents": ["openai": 1]]]
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

/// The tool through NativeAssistantService: offered with a PDF open, and its call answered by the editor that claims it.
@MainActor
final class NativeAIDiagramServiceTests: XCTestCase {
    private typealias D = NativeAIDiagram
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var service: NativeAssistantService!
    private var identity: [String: Any] = [:]
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swift-diagram-\(UUID().uuidString)")
        runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        let course = try await runtime.invoke("courses:create", request: ["name": "AI diagram", "color": "blue"]) as! [String: Any]
        identity = ["courseId": course["id"]!, "sessionId": UUID().uuidString, "provider": "codex"]
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NativeAIDiagramProtocol.self]
        var environment = DesktopAIEnvironment(); environment.session = URLSession(configuration: config)
        environment.endpoint = { AIEndpoint(userID: "user-a", projectURL: URL(string: "https://project.test")!, publishableKey: "pk", token: { "jwt" }) }
        environment.hasConsent = { _, _, _ in true }
        NativeAIDiagramProtocol.requests = []; NativeAIDiagramProtocol.replies = []
        service = NativeAssistantService(runtime: runtime, ai: DesktopAIService(environment: environment))
        runtime.onNativeCall = { [weak service] channel, request in guard let service else { throw CancellationError() }; return try await service.handle(channel, request) }
        _ = try await runtime.invoke("chat:open", request: identity)
    }
    override func tearDown() async throws {
        runtime.onNativeCall = nil; runtime.onEmit = nil; service = nil; runtime = nil
        try? FileManager.default.removeItem(at: root)
    }
    private func event(_ value: [String: Any]) throws -> String { "data: " + String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "\n\n" }

    func testDrawDiagramIsOfferedWithAPDFAndItsAnswerGoesBackToTheModel() async throws {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["nodes": [["id": "a", "label": "입력"], ["id": "b", "label": "출력"]], "edges": [["from": "a", "to": "b"]]]), as: UTF8.self)
        NativeAIDiagramProtocol.replies = [try event(["type": "response.completed", "response": ["output": [["type": "function_call", "call_id": "d1", "name": D.toolName, "arguments": arguments]]]]),
                                           try event(["type": "response.output_text.delta", "delta": "넣었어요"]) + "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"]
        let completed = expectation(description: "turn complete")
        var labels: [String] = [], claimed: D.Spec?
        runtime.onEmit = { channel, value in
            if channel == D.channel, let payload = value as? [String: Any], let request = payload["request"] as? D.Request, request.claim() {
                claimed = request.spec; request.finish(.success("도식을 PDF 1쪽에 넣었습니다."))
            }
            guard channel == "chat:event-batch", let events = (value as? [String: Any])?["events"] as? [[String: Any]] else { return }
            labels += events.compactMap { $0["type"] as? String == "tool-start" ? $0["label"] as? String : nil }
            if events.contains(where: { $0["type"] as? String == "turn-complete" }) { completed.fulfill() }
        }
        let course = identity["courseId"] as! String
        _ = try await runtime.invoke("chat:send", request: identity.merging(["content": "도식으로 그려 줘", "referenceScope": "note",
            "documentContext": ["courseId": course, "relPath": "강의.pdf", "title": "강의.pdf", "kind": "pdf", "selection": ""]]) { _, new in new })
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual((NativeAIDiagramProtocol.requests.first?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["read_material", D.toolName])
        XCTAssertEqual(claimed?.nodes.map(\.label), ["입력", "출력"])
        XCTAssertEqual(labels.last, "도식 그리는 중")
        let outputs = (NativeAIDiagramProtocol.requests.last?["input"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "function_call_output" }.compactMap { $0["output"] as? String }
        XCTAssertEqual(outputs, ["도식을 PDF 1쪽에 넣었습니다."])
    }

    func testNoDiagramToolWithoutAPDF() async throws {
        NativeAIDiagramProtocol.replies = [try event(["type": "response.output_text.delta", "delta": "답"]) + "data: {\"type\":\"response.completed\",\"response\":{\"output\":[]}}\n\n"]
        let completed = expectation(description: "turn complete")
        runtime.onEmit = { channel, value in
            if channel == "chat:event-batch", ((value as? [String: Any])?["events"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "turn-complete" }) == true { completed.fulfill() }
        }
        _ = try await runtime.invoke("chat:send", request: identity.merging(["content": "설명"]) { _, new in new })
        await fulfillment(of: [completed], timeout: 8)
        XCTAssertEqual((NativeAIDiagramProtocol.requests.first?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["list_materials", "read_material"])
    }
}
