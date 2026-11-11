import XCTest
@testable import Bandal

final class NativeUnifiedSearchTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var courseID = ""
    private var otherCourseID = ""

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("unified-search-\(UUID().uuidString)")
        runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        try await runtime.start()
        // Recognition is not under test here: handwritten lines are written to the index directly.
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": false])
        courseID = try await course("열역학")
        otherCourseID = try await course("선형대수")
    }
    override func tearDown() async throws { runtime = nil; try? FileManager.default.removeItem(at: root) }

    private func course(_ name: String) async throws -> String {
        (try await runtime.invoke("courses:create", request: ["name": name, "color": "blue"]) as! [String: Any])["id"] as! String
    }
    private func note(_ name: String, _ text: String, course: String) async throws {
        _ = try await runtime.invoke("materials:writeFile", request: ["courseId": course, "dirRelPath": "", "fileName": name, "encoding": "utf8", "data": text])
        _ = try await runtime.invoke("search:query", request: ["courseId": course, "query": "색인"])
    }
    /// A paper note with recognised lines on the given pages (1-based).
    @discardableResult private func handwritten(_ title: String, lines: [(page: Int, text: String)], course: String) async throws -> String {
        let created = try await runtime.invoke("pdfNotes:create", request: ["courseId": course, "title": title, "paper": "blank", "orientation": "portrait"]) as! [String: Any]
        let path = created["relPath"] as! String
        let binding = try await runtime.invokePrivate("nativePDF:binding", request: ["courseId": course, "relPath": path]) as! [String: Any]
        let document = binding["materialID"] as! String
        try await runtime.withSyncStorage { context, _ in
            for (index, line) in lines.enumerated() {
                try context.run("INSERT INTO handwriting_text(document_id,page_index,line_index,text,bbox,confidence,updated_at) VALUES(?,?,?,?,?,?,?)",
                                [document, line.page - 1, index, line.text, "[0.1,0.2,0.5,0.04]", 0.8, NativeRepositoryContext.nowISO])
            }
        }
        return path
    }
    @discardableResult private func conversation(_ turns: [(String, String)], course: String, ephemeral: Bool = false) async throws -> String {
        let session = UUID().uuidString
        let identity: [String: Any] = ["courseId": course, "sessionId": session]
        _ = try await runtime.invoke("chat:open", request: identity)
        for (index, turn) in turns.enumerated() {
            _ = try await runtime.invokePrivate("nativeChat:begin", request: identity.merging(["content": turn.0, "ephemeral": ephemeral]) { _, new in new })
            _ = try await runtime.invokePrivate("nativeChat:finish", request: identity.merging(["turnSeq": index + 1, "text": turn.1]) { _, new in new })
        }
        return session
    }
    private func search(_ query: String, course: String? = nil) async throws -> [String: [[String: Any]]] {
        var request: [String: Any] = ["query": query]
        if let course { request["courseId"] = course }
        let result = try await runtime.invoke("search:unified", request: request) as! [String: Any]
        let sections = result["sections"] as! [[String: Any]]
        XCTAssertEqual(sections.map { $0["id"] as? String }, ["material", "handwriting", "chat"])
        return Dictionary(uniqueKeysWithValues: sections.map { ($0["id"] as! String, $0["groups"] as! [[String: Any]]) })
    }
    private func hits(_ group: [String: Any]?) -> [[String: Any]] { group?["hits"] as? [[String: Any]] ?? [] }

    func testOneQueryReturnsMaterialsHandwritingAndConversationsInOrder() async throws {
        try await note("1주차.md", "색인. 카르노 순환은 두 등온 과정과 두 단열 과정으로 이루어진다.", course: courseID)
        let path = try await handwritten("필기", lines: [(1, "엔트로피는 줄지 않는다"), (3, "카르노 순환 효율 = 1 - Tc/Th")], course: courseID)
        let session = try await conversation([("카르노 순환이 뭐야?", "카르노 순환은 이상적인 열기관의 순환입니다.")], course: courseID)

        let found = try await search("카르노 순환")
        let material = try XCTUnwrap(found["material"]?.first)
        XCTAssertEqual(material["relPath"] as? String, "1주차.md"); XCTAssertEqual(material["courseName"] as? String, "열역학")
        XCTAssertTrue((hits(material).first?["snippet"] as? String ?? "").contains("카르노 순환"))
        let ink = try XCTUnwrap(found["handwriting"]?.first)
        XCTAssertEqual(ink["relPath"] as? String, path)
        XCTAssertEqual(hits(ink).first?["page"] as? Int, 3)
        XCTAssertEqual(hits(ink).first?["box"] as? [Double], [0.1, 0.2, 0.5, 0.04])
        let chat = try XCTUnwrap(found["chat"]?.first)
        XCTAssertEqual(chat["sessionId"] as? String, session); XCTAssertEqual(chat["title"] as? String, "카르노 순환이 뭐야?")
        // Both the question and the answer match: one conversation, two messages.
        XCTAssertEqual(hits(chat).count, 2); XCTAssertNotNil(hits(chat).first?["messageId"] as? String)
    }

    func testTwoCharactersScanAndOneCharacterIsRefused() async throws {
        try await note("미분.md", "색인. 편미분과 전미분의 차이", course: courseID)
        try await handwritten("필기", lines: [(2, "미분 가능하면 연속")], course: courseID)
        try await conversation([("미분 설명해줘", "기울기입니다.")], course: courseID)
        let found = try await search("미분")
        XCTAssertEqual(found["material"]?.count, 1); XCTAssertEqual(found["handwriting"]?.count, 1); XCTAssertEqual(found["chat"]?.count, 1)
        do { _ = try await search("미"); XCTFail("one character must not search") } catch {}
    }

    func testScopeGroupsFilesAndNamesMatch() async throws {
        try await note("고유값.md", "색인. 행렬의 대각화", course: otherCourseID)
        try await note("기록.md", "색인. 고유값 분해를 복습", course: courseID)
        try await handwritten("풀이", lines: [(1, "고유값 문제 1"), (2, "고유값 문제 2"), (2, "고유값 문제 3")], course: otherCourseID)

        let everywhere = try await search("고유값")
        // A file whose name matches comes first, even without matching text.
        XCTAssertEqual(everywhere["material"]?.compactMap { $0["relPath"] as? String }, ["고유값.md", "기록.md"])
        XCTAssertTrue(hits(everywhere["material"]?.first).isEmpty)
        // Three lines on two pages of one note: one row that opens to three places.
        XCTAssertEqual(everywhere["handwriting"]?.count, 1)
        XCTAssertEqual(hits(everywhere["handwriting"]?.first).compactMap { $0["page"] as? Int }.sorted(), [1, 2, 2])

        let scoped = try await search("고유값", course: courseID)
        XCTAssertEqual(scoped["material"]?.compactMap { $0["relPath"] as? String }, ["기록.md"])
        XCTAssertEqual(scoped["handwriting"]?.count, 0)
    }

    func testDeletedAndUnsavedConversationsAndTrashedNotesAreNotResults() async throws {
        let kept = try await conversation([("라그랑주 승수법", "제약 조건이 있는 최적화입니다.")], course: courseID)
        let deleted = try await conversation([("라그랑주 승수법 예제", "예제입니다.")], course: courseID)
        try await conversation([("라그랑주 승수법 비밀", "저장하지 않는 대화")], course: courseID, ephemeral: true)
        _ = try await runtime.invoke("chat:deleteConversation", request: ["courseId": courseID, "sessionId": deleted])
        let path = try await handwritten("버릴 노트", lines: [(1, "라그랑주 승수법 정리")], course: courseID)
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": true])
        _ = try await runtime.invoke("materials:delete", request: ["courseId": courseID, "relPath": path])

        let found = try await search("라그랑주 승수법")
        XCTAssertEqual(found["chat"]?.compactMap { $0["sessionId"] as? String }, [kept])
        XCTAssertEqual(found["handwriting"]?.count, 0)
    }

    func testABroadQueryKeepsTheTopTwentyPerSection() async throws {
        try await runtime.withSyncStorage { context, _ in
            try context.transaction {
                for index in 0..<1_100 {
                    try context.run("INSERT INTO native_search_documents(course_id,rel_path,kind,page,body,search_key) VALUES(?,?,?,?,?,?)",
                                    [self.courseID, "교재\(index % 40).pdf", "pdf", index + 1, "공통 단어 페이지 \(index)", "공통 단어 페이지 \(index)"])
                }
            }
        }
        let result = try await runtime.invoke("search:unified", request: ["query": "공통 단어"]) as! [String: Any]
        XCTAssertEqual(result["capped"] as? Bool, true)
        let material = (result["sections"] as! [[String: Any]])[0]["groups"] as! [[String: Any]]
        XCTAssertEqual(material.reduce(0) { $0 + hits($1).count }, NativeUnifiedSearchRepository.cappedSectionSize)
    }

    func testSnippetIsOneLineAroundTheMatch() {
        let text = String(repeating: "앞부분 ", count: 40) + "여기 핵심어 등장\n다음 줄 " + String(repeating: "뒷부분 ", count: 40)
        let snippet = NativeUnifiedSearchRepository.snippet(text, needle: "핵심어")
        XCTAssertTrue(snippet.contains("핵심어")); XCTAssertFalse(snippet.contains("\n"))
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…")); XCTAssertLessThanOrEqual(snippet.count, 76)
    }
}
