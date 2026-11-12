import XCTest
import PDFKit
import SQLite3
@testable import Bandal

/// Search and recognition timings. The query budget always runs; the long measurements run when asked:
///   TEST_RUNNER_BANDAL_HANDWRITING_BENCHMARK=1        100 synthetic pages through the indexer
///   TEST_RUNNER_BANDAL_HANDWRITING_SAMPLES=<folder>   real notes: a pulled BandalDesktop folder (bandal.db + PDFOriginals)
final class NativeSearchPerformanceTests: XCTestCase {
    private var root: URL!
    private var runtime: DesktopRuntime!
    private var courseID = ""

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-performance-\(UUID().uuidString)")
        runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy"))
        runtime.handwritingTiming = (debounce: 0.2, launch: 0.2, idle: 0.2)
        try await runtime.start()
        courseID = (try await runtime.invoke("courses:create", request: ["name": "성능", "color": "blue"]) as! [String: Any])["id"] as! String
    }
    override func tearDown() async throws { runtime = nil; try? FileManager.default.removeItem(at: root) }

    private static let words = ["엔트로피", "열역학", "카르노", "순환", "등온", "단열", "효율", "상태", "함수", "가역", "과정", "미분", "적분", "행렬", "고유값", "벡터", "공간", "선형", "변환", "확률",
                                "entropy", "energy", "system", "process", "cycle", "matrix", "vector", "linear", "function", "integral", "derivative", "theorem", "proof", "lemma", "boundary"]
    private func text(_ seed: Int, words count: Int) -> String {
        var state = UInt64(seed &* 2654435761 &+ 12345), parts: [String] = []
        for _ in 0..<count { state = state &* 6364136223846793005 &+ 1442695040888963407; parts.append(Self.words[Int(state >> 33) % Self.words.count]) }
        return parts.joined(separator: " ")
    }
    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    /// 3,000 PDF pages, 4,000 handwritten lines and 3,000 messages: three sections from one statement inside 50 ms.
    func testUnifiedQueryAnswersWithinFiftyMilliseconds() async throws {
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": false])
        let note = try await runtime.invoke("pdfNotes:create", request: ["courseId": courseID, "title": "필기", "paper": "blank", "orientation": "portrait"]) as! [String: Any]
        let binding = try await runtime.invokePrivate("nativePDF:binding", request: ["courseId": courseID, "relPath": note["relPath"]!]) as! [String: Any]
        let document = binding["materialID"] as! String, course = courseID
        let session = UUID().uuidString
        _ = try await runtime.invoke("chat:open", request: ["courseId": courseID, "sessionId": session])
        try await runtime.withSyncStorage { context, _ in
            try context.transaction {
                let now = NativeRepositoryContext.nowISO
                for index in 0..<3_000 {
                    let body = self.text(index, words: 220)
                    try context.run("INSERT INTO native_search_documents(course_id,rel_path,kind,page,body,search_key) VALUES(?,?,?,?,?,?)", [course, "교재\(index / 150).pdf", "pdf", index % 150 + 1, body, body.lowercased()])
                }
                for index in 0..<4_000 {
                    try context.run("INSERT INTO handwriting_text(document_id,page_index,line_index,text,bbox,confidence,updated_at) VALUES(?,?,?,?,?,?,?)",
                                    [document, index / 20, index % 20, self.text(100_000 + index, words: 6), "[0.1,0.1,0.6,0.03]", 0.7, now])
                }
                for index in 0..<3_000 {
                    let message = UUID().uuidString
                    try context.run("INSERT INTO messages(id,course_id,session_id,role,turn_seq,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", [message, course, session, index % 2 == 0 ? "user" : "assistant", index / 2 + 1, now, now])
                    try context.run("INSERT INTO message_blocks(id,message_id,ord,kind,payload_json,created_at,updated_at) VALUES(?,?,0,'text',?,?,?)",
                                    [UUID().uuidString, message, try NativeRepositoryContext.json(["text": self.text(200_000 + index, words: 60)]), now, now])
                }
            }
        }
        var report: [String] = []
        for query in ["엔트로피 열역학", "카르노 순환 등온", "entropy energy", "theorem proof lemma", "엔트로피", "고유값", "matrix", "없는단어없음", "미분", "순환"] {
            var times: [Double] = [], hits = 0
            for _ in 0..<15 {
                let started = CFAbsoluteTimeGetCurrent()
                let result = try await runtime.invoke("search:unified", request: ["query": query]) as! [String: Any]
                times.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
                hits = (result["sections"] as! [[String: Any]]).reduce(0) { $0 + ($1["groups"] as! [[String: Any]]).reduce(0) { $0 + max(1, ($1["hits"] as? [[String: Any]])?.count ?? 0) } }
            }
            let value = median(times)
            report.append(String(format: "SEARCH_TIMING query=%@ chars=%d median_ms=%.1f max_ms=%.1f hits=%d", query, query.unicodeScalars.count, value, times.max() ?? 0, hits))
            // The trigram index answers three characters or more; two characters scan and are reported, not budgeted.
            if query.unicodeScalars.count >= 3 { XCTAssertLessThan(value, 50, query) }
        }
        report.forEach { print($0) }
    }

    /// Render and recognise one page of ink, repeated: the steady cost per page after Vision has loaded.
    func testRecognitionTimePerPage() throws {
        let size = CGSize(width: 595, height: 842)
        var rows: [[String: Any]] = []
        for (index, line) in ["엔트로피 증가 법칙", "Carnot cycle efficiency", "dS = dQ / T", "고립계의 엔트로피", "heat engine", "상태 함수와 경로", "ideal gas law", "PV = nRT"].enumerated() {
            rows += NativeHandwritingFixture.strokes(line, at: CGPoint(x: 50, y: 110 + CGFloat(index) * 85), fontSize: 40, pageSize: size)
        }
        rows = rows.map { $0.merging(["kind": "ink", "id": UUID().uuidString]) { _, new in new } }
        var render: [Double] = [], recognise: [Double] = [], lines = 0
        for pass in 0..<8 {
            let started = CFAbsoluteTimeGetCurrent()
            let image = try XCTUnwrap(NativeHandwritingRecognizer.image(rows: rows, pageSize: size).cgImage)
            let rendered = CFAbsoluteTimeGetCurrent()
            lines = try NativeHandwritingRecognizer.recognize(image).count
            // The first request loads the models.
            if pass > 0 { render.append((rendered - started) * 1000); recognise.append((CFAbsoluteTimeGetCurrent() - rendered) * 1000) }
            else { print(String(format: "RECOGNITION_TIMING first_page_ms=%.0f", (CFAbsoluteTimeGetCurrent() - started) * 1000)) }
        }
        print(String(format: "RECOGNITION_TIMING strokes=%d lines=%d render_ms=%.1f recognise_ms=%.1f page_ms=%.1f", rows.count, lines, median(render), median(recognise), median(render) + median(recognise)))
    }

    func testInitialIndexOfOneHundredPages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BANDAL_HANDWRITING_BENCHMARK"] == "1", "Set TEST_RUNNER_BANDAL_HANDWRITING_BENCHMARK=1")
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": false])
        let note = try await runtime.invoke("pdfNotes:create", request: ["courseId": courseID, "title": "100쪽", "paper": "blank", "orientation": "portrait"]) as! [String: Any]
        let path = note["relPath"] as! String
        let binding = try await runtime.invokePrivate("nativePDF:binding", request: ["courseId": courseID, "relPath": path]) as! [String: Any]
        _ = try await runtime.invoke("pdf:restructure", request: ["courseId": courseID, "relPath": path, "expectedRevision": binding["documentRevision"]!, "operationId": UUID().uuidString,
                                                                 "pages": [["source": 1]] + Array(repeating: ["source": NSNull()], count: 99)])
        let size = CGSize(width: 595, height: 842)
        for page in 1...100 {
            for (index, line) in ["엔트로피 \(page)쪽 정리", "Carnot cycle", "dS = dQ / T", "상태 함수", "heat engine"].enumerated() {
                for stroke in NativeHandwritingFixture.strokes(line, at: CGPoint(x: 50, y: 120 + CGFloat(index) * 110), fontSize: 40, pageSize: size) {
                    _ = try await runtime.invoke("drawings:create", request: stroke.merging(["courseId": courseID, "relPath": path, "page": page, "kind": "ink"]) { _, new in new })
                }
            }
        }
        let started = CFAbsoluteTimeGetCurrent()
        _ = try await runtime.invoke("settings:set", request: ["handwritingSearch": true])
        while true {
            try await Task.sleep(for: .milliseconds(200))
            let status = try await runtime.invoke("handwriting:status") as! [String: Any]
            if status["active"] as? Bool == false, status["total"] as? Int == 100, status["done"] as? Int == 100 { break }
            if CFAbsoluteTimeGetCurrent() - started > 1_200 { XCTFail("index did not finish: \(status)"); break }
        }
        let seconds = CFAbsoluteTimeGetCurrent() - started
        let lines = try await runtime.withSyncStorage { context, _ in try context.query("SELECT COUNT(*) AS n FROM handwriting_text").first?["n"] as? Int ?? 0 }
        print(String(format: "INDEX_TIMING pages=100 seconds=%.1f per_page_ms=%.0f lines=%d", seconds, seconds * 10, lines))
    }

    /// Reads real handwriting out of a pulled BandalDesktop folder and prints each recognised line with its confidence.
    /// TEST_RUNNER_BANDAL_HANDWRITING_PAGES="courseID|relPath|page;…" picks the pages; otherwise the three pages with most ink.
    func testRealHandwritingSamples() throws {
        guard let folder = ProcessInfo.processInfo.environment["BANDAL_HANDWRITING_SAMPLES"] else { throw XCTSkip("Set TEST_RUNNER_BANDAL_HANDWRITING_SAMPLES") }
        let base = URL(fileURLWithPath: folder), db = try DesktopSQLite(url: base.appendingPathComponent("bandal.db"), readOnly: true)
        var pages: [(course: String, path: String, page: Int)] = (ProcessInfo.processInfo.environment["BANDAL_HANDWRITING_PAGES"] ?? "").split(separator: ";").compactMap { item in
            let parts = item.split(separator: "|").map(String.init); return parts.count == 3 ? Int(parts[2]).map { (parts[0], parts[1], $0) } : nil
        }
        // No choice: every page with ink, timed, without printing what it says.
        let survey = pages.isEmpty
        if survey {
            pages = try db.query("SELECT course_id,rel_path,page,COUNT(*) AS n FROM pdf_drawings WHERE kind='ink' AND deleted_at IS NULL GROUP BY course_id,rel_path,page ORDER BY course_id,rel_path,page", params: [Any]())
                .map { ($0["course_id"] as! String, $0["rel_path"] as! String, $0["page"] as! Int) }
        }
        var times: [Double] = []
        for target in pages {
            let rows = try db.query("SELECT id,kind,data_json,style_json,page FROM pdf_drawings WHERE course_id=? AND rel_path=? AND page=? AND kind='ink' AND deleted_at IS NULL ORDER BY created_at", params: [target.course, target.path, target.page]).map { row -> [String: Any] in
                ["id": row["id"]!, "kind": "ink", "page": row["page"]!, "data": try NativeRepositoryContext.jsonObject(row["data_json"] as! String), "style": try NativeRepositoryContext.jsonObject(row["style_json"] as! String)]
            }
            let sha = try db.query("SELECT b.bound_sha FROM pdf_document_aliases a JOIN pdf_document_bindings b ON b.material_id=a.material_id WHERE a.course_id=? AND a.rel_path=?", params: [target.course, target.path]).first?["bound_sha"] as? String
            let original = sha.flatMap { PDFDocument(url: base.appendingPathComponent("PDFOriginals/" + $0 + ".pdf")) }
            let size = original.flatMap { NativeHandwritingRecognizer.pageSize(of: $0, page: target.page) } ?? CGSize(width: 595, height: 842)
            let started = CFAbsoluteTimeGetCurrent()
            let image = NativeHandwritingRecognizer.image(rows: rows, pageSize: size)
            let lines = try NativeHandwritingRecognizer.recognize(try XCTUnwrap(image.cgImage))
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000; times.append(elapsed)
            let name = target.course + "|" + target.path + "|" + String(target.page)
            let hangul = lines.filter { $0.text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }.count
            let latin = lines.filter { $0.text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic } }.count
            let symbols = lines.filter { $0.text.contains { "=+∑∫√^/".contains($0) } }.count
            print(String(format: "SAMPLE page=%@ strokes=%d lines=%d hangul=%d latin=%d math=%d mean_confidence=%.2f ms=%.0f", name, rows.count, lines.count, hangul, latin, symbols,
                         lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count), elapsed))
            guard !survey else { continue }
            for line in lines { print(String(format: "SAMPLE_LINE %.2f | %@", line.confidence, line.text)) }
            let shot = XCTAttachment(image: image); shot.name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "|", with: "_"); shot.lifetime = .keepAlways; add(shot)
        }
        if times.count > 1 { print(String(format: "SAMPLE_SUMMARY pages=%d total_s=%.1f median_ms=%.0f max_ms=%.0f", times.count, times.dropFirst().reduce(0, +) / 1000, median(Array(times.dropFirst())), times.dropFirst().max() ?? 0)) }
    }
}
