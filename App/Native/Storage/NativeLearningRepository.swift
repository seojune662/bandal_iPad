import Foundation
import PDFKit

/// File-backed learning data keeps the desktop manifest/state schema. Unknown
/// fields and immutable article/artifact files survive every native mutation.
final class NativeLearningRepository {
    private typealias C = NativeRepositoryContext
    private let context: C
    private let null = NSNull()
    private static let directory = ".bandal/learning"
    private static let collections = ["articles", "words", "occurrences", "artifacts", "cards", "quizAttempts", "runs", "history", "exports", "pathAliases"]
    init(context: NativeRepositoryContext) { self.context = context }
    private struct Project {
        let course: String
        let relative: String
        let root: URL
        let stateURL: URL
        let before: String
        var state: [String: Any]
        var recovery: String = "none"
        var pendingFiles: [NativeSyncFileChange] = []
        var binding: [String: Any] { ["courseId": course, "rootRelPath": relative] }
        var snapshot: [String: Any] { state.merging(["binding": binding, "recovery": recovery, "warnings": recovery == "previous" ? ["이전 저장본을 읽었습니다. 현재 파일의 원본은 보존했습니다."] : []]) { _, new in new } }
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        guard channel.hasPrefix("learning:") || channel.hasPrefix("nativeLearning:") else { return nil }
        switch channel {
        case "nativeLearning:putArtifact", "nativeLearning:updateRun", "nativeLearning:putArticle", "learning:saveProgress", "learning:completeArticle", "learning:reviewCard", "learning:saveQuizAnswer", "learning:finishQuiz", "learning:dismissRun": return try learningMutation(channel, request)
        case "learning:create": return try context.withMaterialLock { try create(request) }
        case "learning:list":
            return try context.withMaterialLock {
                let requested = request["courseId"] as? String, includeDeleted = request["includeDeleted"] as? Bool == true
                var projects: [[String: Any]] = []
                for row in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL ORDER BY sort_order,created_at") {
                    let course = row["id"] as! String
                    for project in try discover(course: course) where includeDeleted || project.state["deletedAt"] as? String == nil {
                        if let requested, requested != course && project.state["linkedCourseId"] as? String != requested { continue }
                        projects.append(summary(project))
                    }
                }
                return ["projects": projects]
            }
        case "learning:get": return try context.withMaterialLock { try read(request).snapshot }
        case "learning:getArticle", "learning:getArtifact":
            return try context.withMaterialLock {
                let project = try read(request), id = try NativeSyncFormat.identity(request["id"]), artifact = channel == "learning:getArtifact"
                if !artifact { return try retainedArticle(id, project: project) }
                let rows = project.state[artifact ? "artifacts" : "articles"] as? [[String: Any]] ?? []
                guard let ref = rows.first(where: { $0["id"] as? String == id }), let relative = ref[artifact ? "relPath" : "snapshotRelPath"] as? String else { throw C.notFound("learning source", id) }
                let url = try context.resolve(in: project.root, relativePath: relative), raw = try object(at: url)
                guard raw["id"] as? String == id else { throw C.conflict("Learning source identity changed") }
                if artifact, let hash = ref["contentHash"] as? String {
                    // Original artifacts use two-space JSON plus a final newline.
                    let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    let sortedHash = NativeSyncFormat.hash(bytes + Data([10]))
                    if try NativeSyncFormat.hash(url) != hash, sortedHash != hash {
                        // The desktop hash is property-order-sensitive; require the
                        // exact stored bytes before interpreting unknown content.
                        throw C.conflict("Learning artifact changed; original retained")
                    }
                }
                return artifact ? resolveAliases(raw, project: project) : raw
            }
        case "learning:resolveSource":
            return try context.withMaterialLock {
                let project = try read(request)
                guard let source = request["sourceRef"] as? [String: Any] else { throw C.validation("Invalid learning source") }
                do {
                    let resolved = try validateSource(resolveAliases(source, project: project) as? [String: Any] ?? source, project: project, verifyQuote: false)
                    let relative = resolved["relPath"] as? String ?? ""
                    var result: [String: Any] = ["relPath": resolved["pathScope"] as? String == "course" || project.relative.isEmpty ? relative : project.relative + "/" + relative, "missing": false]
                    if let owner = resolved["sourceCourseId"] { result["sourceCourseId"] = owner }; return result
                } catch { return ["relPath": NSNull(), "missing": true] }
            }
        case "learning:saveWord": return try mutate(request) { project in try self.saveWord(request, project: &project) }
        case "learning:updateWord":
            return try mutate(request) { project in
                let id = try NativeSyncFormat.identity(request["wordId"])
                var words = project.state["words"] as? [[String: Any]] ?? []
                guard let index = words.firstIndex(where: { $0["id"] as? String == id }) else { throw C.notFound("learning word", id) }
                for key in ["lemma", "meaning", "pronunciation", "partOfSpeech"] where request[key] != nil { words[index][key] = try self.string(request[key], key, empty: key != "lemma") }
                if let status = request["status"] as? String { guard ["new", "learning", "known"].contains(status) else { throw C.validation("Invalid word status") }; words[index]["status"] = status }
                if request["meaning"] != nil, var source = words[index]["dictionarySource"] as? [String: Any] { source["modified"] = true; words[index]["dictionarySource"] = source }
                words[index]["updatedAt"] = C.nowISO; project.state["words"] = words
            }
        case "learning:updateOccurrence":
            return try mutate(request) { project in
                let id = try NativeSyncFormat.identity(request["occurrenceId"])
                var occurrences = project.state["occurrences"] as? [[String: Any]] ?? []
                guard let index = occurrences.firstIndex(where: { $0["id"] as? String == id }) else { throw C.notFound("learning occurrence", id) }
                occurrences[index]["meaning"] = try self.string(request["meaning"], "meaning", empty: true); project.state["occurrences"] = occurrences
            }
        case "learning:rename", "learning:updateSettings":
            return try mutate(request) { project in
                if channel == "learning:rename" || request["name"] != nil { project.state["name"] = try self.string(request["name"], "name") }
                if request["topic"] != nil { project.state["topic"] = try self.string(request["topic"], "topic") }
                try self.settings(request, into: &project.state)
            }
        case "learning:delete", "learning:restore":
            let result = try mutate(request, allowDeleted: true) { project in project.state["deletedAt"] = channel == "learning:delete" ? C.nowISO : self.null as Any }
            return channel == "learning:delete" ? ["ok": true] : result
        default: return nil
        }
    }

    func recoverInterruptedRuns() throws {
        for row in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL") {
            guard let course = row["id"] as? String else { continue }
            let projects: [Project]
            do { projects = try discover(course: course, tolerateInvalid: true) }
            catch { context.emit?("learning:recoveryWarning", ["courseId": course, "message": error.localizedDescription]); continue }
            for project in projects where project.recovery == "none" && project.state["deletedAt"] as? String == nil {
                for var run in project.state["runs"] as? [[String: Any]] ?? [] where ["queued", "running", "validating"].contains(run["status"] as? String ?? "") {
                    run["status"] = "interrupted"; run["message"] = "앱이 종료되어 생성을 중단했습니다. 다시 실행해 주세요."; run["updatedAt"] = C.nowISO
                    do { _ = try learningMutation("nativeLearning:updateRun", ["binding": project.binding, "run": run]) }
                    catch { context.emit?("learning:recoveryWarning", ["binding": project.binding, "message": error.localizedDescription]) }
                }
            }
        }
    }

    private func learningMutation(_ channel: String, _ request: [String: Any]) throws -> Any {
        try mutate(request) { project in
            switch channel {
            case "nativeLearning:putArtifact":
                guard let draft = request["artifact"] as? [String: Any] else { throw C.validation("학습 결과가 비어 있습니다.") }
                try self.putArtifact(draft, project: &project)
            case "nativeLearning:updateRun":
                guard let run = request["run"] as? [String: Any] else { throw C.validation("학습 실행을 확인해 주세요.") }
                let id = try NativeSyncFormat.identity(run["id"])
                var runs = project.state["runs"] as? [[String: Any]] ?? []
                if let i = runs.firstIndex(where: { $0["id"] as? String == id }) { runs[i] = run } else { runs.append(run) }
                project.state["runs"] = runs
            case "nativeLearning:putArticle":
                guard var article = request["article"] as? [String: Any], let paragraphs = article["paragraphs"] as? [[String: Any]], !paragraphs.isEmpty else { throw C.validation("기사 본문을 읽지 못했습니다.") }
                let id = try NativeSyncFormat.identity(article["id"]), title = try self.string(article["title"], "기사 제목")
                let url = try self.string(article["sourceUrl"], "기사 주소")
                guard let address = URL(string: url), ["http", "https"].contains(address.scheme ?? ""), address.host != nil else { throw C.validation("기사 주소가 올바르지 않습니다.") }
                let text = paragraphs.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                guard !text.isEmpty, text.utf8.count <= 2_000_000 else { throw C.validation("기사 본문 크기를 확인해 주세요.") }
                let hash = NativeSyncFormat.hash(Data(text.utf8)), path = Self.directory + "/articles/\(id).json"
                article["contentHash"] = hash; article["createdAt"] = C.nowISO
                article["canonicalUrl"] = article["canonicalUrl"] ?? url
                article["wordCount"] = article["wordCount"] ?? 0; article["estimatedMinutes"] = article["estimatedMinutes"] ?? 1
                try self.immutable(article, path: path, project: &project)
                var rows = project.state["articles"] as? [[String: Any]] ?? []
                guard !rows.contains(where: { $0["id"] as? String == id }) else { throw C.conflict("이미 저장된 기사입니다.") }
                rows.append(["id": id, "title": title, "sourceUrl": url, "canonicalUrl": article["canonicalUrl"] ?? url, "snapshotRelPath": path, "exportRelPath": self.null, "contentHash": hash, "wordCount": article["wordCount"] ?? 0, "estimatedMinutes": article["estimatedMinutes"] ?? 1, "createdAt": article["createdAt"]!, "status": "unread", "progress": ["paragraphId": self.null, "scrollFraction": 0], "completedAt": self.null, "matchedWordIds": []])
                project.state["articles"] = rows
                self.history("article-added", entity: id, summary: title, project: &project)
            case "learning:saveProgress", "learning:completeArticle":
                let id = try NativeSyncFormat.identity(request["articleId"])
                var rows = project.state["articles"] as? [[String: Any]] ?? []
                guard let i = rows.firstIndex(where: { $0["id"] as? String == id }) else { throw C.notFound("기사", id) }
                if channel == "learning:completeArticle" {
                    if rows[i]["status"] as? String == "completed" { return }
                    rows[i]["status"] = "completed"; rows[i]["completedAt"] = C.nowISO
                    self.history("article-completed", entity: id, summary: "기사를 다 읽었습니다.", project: &project)
                } else {
                    guard let fraction = request["scrollFraction"] as? NSNumber, fraction.doubleValue.isFinite, (0...1).contains(fraction.doubleValue) else { throw C.validation("읽기 위치를 확인해 주세요.") }
                    if let paragraph = request["paragraphId"] as? String {
                        let article = try self.retainedArticle(id, project: project)
                        guard (article["paragraphs"] as? [[String: Any]] ?? []).contains(where: { $0["id"] as? String == paragraph }) else { throw C.validation("본문 문단을 찾지 못했습니다.") }
                    }
                    rows[i]["progress"] = ["paragraphId": request["paragraphId"] ?? self.null, "scrollFraction": fraction]
                    if rows[i]["status"] as? String == "unread" { rows[i]["status"] = "reading" }
                }
                project.state["articles"] = rows
            case "learning:reviewCard": try self.reviewCard(request, project: &project)
            case "learning:saveQuizAnswer", "learning:finishQuiz": try self.quizMutation(channel, request, project: &project)
            case "learning:dismissRun":
                let id = try NativeSyncFormat.identity(request["runId"])
                var rows = project.state["runs"] as? [[String: Any]] ?? []
                guard let i = rows.firstIndex(where: { $0["id"] as? String == id }), ["failed", "cancelled", "interrupted", "complete"].contains(rows[i]["status"] as? String ?? "") else { throw C.validation("종료한 학습 실행을 선택해 주세요.") }
                rows[i]["dismissedAt"] = C.nowISO; project.state["runs"] = rows
            default: throw C.validation("학습 작업을 확인해 주세요.")
            }
        }
    }

    @discardableResult
    private func immutable(_ object: [String: Any], path: String, project: inout Project) throws -> Data {
        let url = try context.resolve(in: project.root, relativePath: path)
        let bytes = Data(try C.json(object).utf8)
        if context.files.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == bytes else { throw C.conflict("학습 결과 원본을 덮어쓸 수 없습니다.") }; return bytes
        }
        // No file becomes visible until its state reference and revision can
        // commit together. The shared journal restores all three on restart.
        project.pendingFiles.append(.init(target: url, data: bytes, expectedMissing: true))
        return bytes
    }
    private func history(_ kind: String, entity: String, summary: String, project: inout Project, id: String = UUID().uuidString.lowercased(), resultPath: String? = nil) {
        var rows = project.state["history"] as? [[String: Any]] ?? []
        var row: [String: Any] = ["id": id, "kind": kind, "entityId": entity, "summary": summary, "createdAt": C.nowISO]
        if let resultPath { row["resultRelPath"] = resultPath }
        rows.append(row); project.state["history"] = rows
    }
    private func retainedArticle(_ id: String, project: Project) throws -> [String: Any] {
        guard let ref = (project.state["articles"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == id }),
              let path = ref["snapshotRelPath"] as? String else { throw C.notFound("기사", id) }
        let value = try object(at: context.resolve(in: project.root, relativePath: path))
        guard value["id"] as? String == id, let paragraphs = value["paragraphs"] as? [[String: Any]],
              !paragraphs.isEmpty, paragraphs.allSatisfy({ $0["text"] is String }) else { throw C.conflict("저장된 기사 원본을 확인해 주세요.") }
        let hash = NativeSyncFormat.hash(Data(paragraphs.compactMap { $0["text"] as? String }.joined(separator: "\n\n").utf8))
        guard value["contentHash"] as? String == hash, ref["contentHash"] as? String == hash,
              ["sourceUrl", "canonicalUrl", "title", "createdAt"].allSatisfy({ value[$0] as? String == ref[$0] as? String }) else {
            throw C.conflict("저장된 기사 본문이나 출처가 변경되었습니다. 원본을 보존했습니다.")
        }
        return value
    }
    private func artifact(_ id: String, project: Project) throws -> [String: Any] {
        guard let ref = (project.state["artifacts"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == id }), let path = ref["relPath"] as? String else { throw C.notFound("학습 결과", id) }
        let url = try context.resolve(in: project.root, relativePath: path)
        guard try NativeSyncFormat.hash(url) == ref["contentHash"] as? String else { throw C.conflict("학습 결과 원본이 변경되었습니다.") }
        return try object(at: url)
    }
    private func putArtifact(_ draft: [String: Any], project: inout Project) throws {
        let id = try NativeSyncFormat.identity(draft["id"] ?? UUID().uuidString.lowercased()), kind = try string(draft["kind"], "결과 종류")
        guard ["quiz", "cards", "summary"].contains(kind) else { throw C.validation("지원하지 않는 학습 결과입니다.") }
        var refs = project.state["artifacts"] as? [[String: Any]] ?? []
        guard !refs.contains(where: { $0["id"] as? String == id }) else { throw C.conflict("이미 저장된 학습 결과입니다.") }
        let sources = try (draft["sourceRefs"] as? [[String: Any]] ?? []).map { try validateSource($0, project: project, verifyQuote: true) }
        guard !sources.isEmpty else { throw C.validation("학습 결과에 원문 근거가 필요합니다.") }
        let title = try string(draft["title"], "학습 결과 제목")
        var output: [String: Any] = ["id": id, "schemaVersion": 1, "revision": 0, "kind": kind, "title": title, "createdAt": C.nowISO, "sourceRefs": sources, "articleIds": draft["articleIds"] ?? [], "wordIds": draft["wordIds"] ?? []]
        if kind == "summary" { output["markdown"] = try string(draft["markdown"], "요약 본문") }
        else {
            let key = kind == "quiz" ? "questions" : "cards"
            guard var rows = draft[key] as? [[String: Any]], !rows.isEmpty, rows.count <= 100 else { throw C.validation("학습 결과 문항을 확인해 주세요.") }
            var ids = Set<String>()
            for i in rows.indices {
                let rowID = try NativeSyncFormat.identity(rows[i]["id"] ?? UUID().uuidString.lowercased())
                guard ids.insert(rowID).inserted else { throw C.validation("중복 학습 문항입니다.") }
                rows[i]["id"] = rowID
                rows[i]["sourceRefs"] = sources
                if kind == "cards" { _ = try string(rows[i]["front"], "카드 앞면"); _ = try string(rows[i]["back"], "카드 뒷면") }
                else {
                    let type = rows[i]["type"] as? String ?? ""
                    guard ["choice", "cloze", "short-answer"].contains(type) else { throw C.validation("퀴즈 유형을 확인해 주세요.") }
                    _ = try string(rows[i]["prompt"], "문제"); let answer = try string(rows[i]["answer"], "정답")
                    rows[i]["explanation"] = try string(rows[i]["explanation"] ?? "", "해설", empty: true)
                    if type == "choice" {
                        guard let options = rows[i]["options"] as? [[String: String]], options.count >= 2, options.count <= 10, Set(options.compactMap { $0["id"] }).count == options.count, options.allSatisfy({ !($0["text"] ?? "").isEmpty }), options.contains(where: { $0["id"] == answer }) else { throw C.validation("퀴즈 선택지와 정답이 일치하지 않습니다.") }
                    }
                }
            }
            output[key] = rows
            if kind == "cards" {
                var cards = project.state["cards"] as? [[String: Any]] ?? []
                guard Set(cards.compactMap { $0["id"] as? String }).isDisjoint(with: ids) else { throw C.conflict("이미 존재하는 카드입니다.") }
                cards += rows.map { $0.merging(["artifactId": id, "status": "new", "dueAt": C.nowISO, "intervalDays": 0, "repetitions": 0, "lapses": 0, "lastReviewedAt": null]) { _, new in new } }
                project.state["cards"] = cards
            }
        }
        let path = Self.directory + "/artifacts/\(id).json"
        let bytes = try immutable(output, path: path, project: &project)
        let hash = NativeSyncFormat.hash(bytes)
        refs.append(["id": id, "kind": kind, "title": title, "relPath": path, "exportRelPath": null, "createdAt": output["createdAt"]!, "contentHash": hash, "sourceRefs": sources, "articleIds": output["articleIds"]!, "wordIds": output["wordIds"]!])
        project.state["artifacts"] = refs
        history("artifact-created", entity: id, summary: title, project: &project)
    }
    private func reviewCard(_ request: [String: Any], project: inout Project) throws {
        let id = try NativeSyncFormat.identity(request["cardId"]), reviewID = try NativeSyncFormat.identity(request["reviewId"])
        let rating = request["rating"] as? String ?? ""
        guard ["again", "hard", "good"].contains(rating) else { throw C.validation("복습 평가를 선택해 주세요.") }
        if let prior = (project.state["history"] as? [[String: Any]] ?? []).first(where: { $0["id"] as? String == reviewID }) {
            guard prior["entityId"] as? String == id && prior["kind"] as? String == "card-reviewed" else { throw C.conflict("다른 복습에 사용한 식별자입니다.") }
            if let path = prior["resultRelPath"] as? String {
                let receipt = try object(at: context.resolve(in: project.root, relativePath: path))
                guard receipt["id"] as? String == reviewID, receipt["cardId"] as? String == id, receipt["rating"] as? String == rating else { throw C.conflict("이미 저장한 복습과 다른 요청입니다.") }
            }
            return
        }
        var cards = project.state["cards"] as? [[String: Any]] ?? []
        guard let index = cards.firstIndex(where: { $0["id"] as? String == id }) else { throw C.notFound("카드", id) }
        let before = cards[index]; var card = before
        let now = Date(), repeats = (card["repetitions"] as? NSNumber)?.intValue ?? 0
        var seconds: Double = 86400
        if rating == "again" { card["status"] = "learning"; card["intervalDays"] = 0; card["repetitions"] = 0; card["lapses"] = ((card["lapses"] as? NSNumber)?.intValue ?? 0) + 1; seconds = 600 }
        else if rating == "hard" { card["status"] = "learning" }
        else { let days = [1, 3, 7, 14, 30][min(max(0, repeats), 4)]; card["status"] = "review"; card["intervalDays"] = days; card["repetitions"] = repeats + 1; seconds = Double(days) * 86400 }
        card["dueAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)); card["lastReviewedAt"] = C.nowISO
        let path = Self.directory + "/results/review-\(reviewID).json"
        try immutable(["id": reviewID, "cardId": id, "rating": rating, "reviewedAt": C.nowISO, "before": before, "after": card], path: path, project: &project)
        cards[index] = card; project.state["cards"] = cards
        history("card-reviewed", entity: id, summary: "플래시카드를 복습했습니다.", project: &project, id: reviewID, resultPath: path)
    }
    private func quizMutation(_ channel: String, _ request: [String: Any], project: inout Project) throws {
        let artifactID = try NativeSyncFormat.identity(request["artifactId"]), attemptID = try NativeSyncFormat.identity(request["attemptId"])
        let quiz = try artifact(artifactID, project: project)
        guard quiz["kind"] as? String == "quiz", let questions = quiz["questions"] as? [[String: Any]] else { throw C.validation("퀴즈 자료가 아닙니다.") }
        var attempts = project.state["quizAttempts"] as? [[String: Any]] ?? []
        let existing = attempts.firstIndex(where: { $0["id"] as? String == attemptID })
        if let existing, attempts[existing]["artifactId"] as? String != artifactID { throw C.conflict("다른 퀴즈의 실행 식별자입니다.") }
        if channel == "learning:finishQuiz", existing == nil { throw C.notFound("퀴즈 실행", attemptID) }
        var attempt: [String: Any] = existing.map { attempts[$0] } ?? ["id": attemptID, "artifactId": artifactID, "answers": [], "startedAt": C.nowISO, "completedAt": null, "score": 0, "total": questions.filter { $0["type"] as? String != "short-answer" }.count, "selfCheckedCount": 0, "selfPassedCount": 0, "resultRelPath": null]
        if attempt["completedAt"] as? String != nil { if channel == "learning:finishQuiz" { return }; throw C.conflict("이미 완료한 퀴즈입니다.") }
        var answers = attempt["answers"] as? [[String: Any]] ?? []
        if channel == "learning:saveQuizAnswer" {
            let questionID = try NativeSyncFormat.identity(request["questionId"])
            guard let question = questions.first(where: { $0["id"] as? String == questionID }) else { throw C.notFound("문항", questionID) }
            let answer = try string(request["answer"], "답안", empty: question["type"] as? String != "choice"), type = question["type"] as? String
            guard answer.count <= 20_000 else { throw C.validation("답안이 너무 깁니다.") }
            if type == "choice", !(question["options"] as? [[String: String]] ?? []).contains(where: { $0["id"] == answer }) { throw C.validation("선택지를 다시 확인해 주세요.") }
            let normalize: (String) -> String = { $0.precomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            let correct = type == "choice" ? question["answer"] as? String == answer : ([question["answer"] as? String ?? ""] + (question["acceptedAnswers"] as? [String] ?? [])).contains { normalize($0) == normalize(answer) }
            var row: [String: Any] = ["questionId": questionID, "answer": answer, "correct": type == "short-answer" ? null : correct as Any, "answeredAt": C.nowISO]
            if type == "short-answer", let check = request["selfCheck"] { guard let check = check as? Bool else { throw C.validation("자기 평가를 확인해 주세요.") }; row["selfCheck"] = check }
            if let index = answers.firstIndex(where: { $0["questionId"] as? String == questionID }) { answers[index] = row } else { answers.append(row) }
            attempt["answers"] = answers; attempt["score"] = answers.filter { $0["correct"] as? Bool == true }.count
            attempt["selfCheckedCount"] = answers.filter { $0["selfCheck"] != nil }.count; attempt["selfPassedCount"] = answers.filter { $0["selfCheck"] as? Bool == true }.count
        } else {
            guard questions.allSatisfy({ q in answers.contains { a in a["questionId"] as? String == q["id"] as? String && !(a["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (q["type"] as? String != "short-answer" || a["selfCheck"] is Bool) } }) else { throw C.validation("모든 문항에 답하고 서술형 답안을 자기 점검해 주세요.") }
            attempt["completedAt"] = C.nowISO
            let path = Self.directory + "/results/quiz-\(attemptID).json"; attempt["resultRelPath"] = path
            try immutable(attempt, path: path, project: &project)
            history("quiz-completed", entity: attemptID, summary: "퀴즈를 완료했습니다.", project: &project, resultPath: path)
        }
        if let existing { attempts[existing] = attempt } else { attempts.append(attempt) }
        project.state["quizAttempts"] = attempts
    }

    private func create(_ request: [String: Any]) throws -> [String: Any] {
        let name = try string(request["name"], "name"), topic = try string(request["topic"], "topic"), placement = request["placement"] as? String
        guard placement == "in-course" || placement == "standalone" else { throw C.validation("Choose a learning project location") }
        var state: [String: Any] = ["schemaVersion": 1, "projectId": UUID().uuidString.lowercased(), "revision": 0, "name": name, "topic": topic, "level": "intermediate", "readingMinutes": 4, "purpose": "unclassified", "topicIds": [], "readingSetupConfirmed": false, "createdAt": C.nowISO, "updatedAt": C.nowISO]
        for key in Self.collections { state[key] = [] }
        try settings(request, into: &state)
        let course: String, relative: String
        if placement == "standalone" {
            guard let created = try NativeLibraryRepository(context: context).handle("courses:create", ["name": name, "color": "blue", "workspaceKind": "study-space"]) as? [String: Any], let id = created["id"] as? String else { throw C.validation("Learning course could not be created") }
            course = id; relative = ""
        } else {
            course = try C.requireID(request["courseId"])
            relative = try string(request["rootRelPath"] ?? name.replacingOccurrences(of: #"[/\\:*?\"<>|]"#, with: "", options: .regularExpression), "learning folder")
        }
        let folder = try context.courseFolder(course), root = try context.resolve(in: folder, relativePath: relative, allowRoot: true)
        let existing = try discover(course: course)
        if let current = existing.first(where: { $0.root == root }) { guard current.state["deletedAt"] as? String == nil else { throw C.conflict("Restore this learning project before reusing it") }; return current.snapshot }
        guard !existing.contains(where: { C.contains($0.root.path, root.path) || C.contains(root.path, $0.root.path) }) else { throw C.conflict("Learning projects cannot be nested") }
        let directory = try context.resolve(in: root, relativePath: Self.directory)
        try context.files.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("state.json")
        if context.files.fileExists(atPath: stateURL.path) {
            state = try object(at: stateURL); try validate(state)
        } else {
            try context.atomicWrite(Data(try C.json(state).utf8), to: stateURL)
            try context.atomicWrite(Data(try C.json(state).utf8), to: directory.appendingPathComponent("previous.json"))
        }
        let manifest: [String: Any] = ["format": "bandal-learning", "formatVersion": 1, "projectId": state["projectId"]!]
        try context.atomicWrite(Data(try C.json(manifest).utf8), to: directory.appendingPathComponent("manifest.json"))
        let project = try load(course: course, relative: relative)
        changed(project); return project.snapshot
    }
    private func settings(_ input: [String: Any], into state: inout [String: Any]) throws {
        if let level = input["level"] as? String { guard ["beginner", "intermediate", "advanced"].contains(level) else { throw C.validation("Invalid learning level") }; state["level"] = level }
        if let value = input["readingMinutes"] { state["readingMinutes"] = try NativeValue.int(value, "reading minutes", min: 1, max: 30) }
        if let purpose = input["purpose"] as? String { guard ["unclassified", "english-reading", "course-review"].contains(purpose) else { throw C.validation("Invalid learning purpose") }; state["purpose"] = purpose }
        if let value = input["linkedCourseId"] { let id = try C.requireID(value); _ = try context.courseFolder(id); state["linkedCourseId"] = id }
        if let value = input["packId"] { state["packId"] = try string(value, "pack id") }
        if let value = input["topicIds"] { guard let values = value as? [String], values.count <= 3, Set(values).count == values.count else { throw C.validation("Invalid learning topics") }; state["topicIds"] = values }
        if let value = input["readingSetupConfirmed"] { guard let value = value as? Bool else { throw C.validation("Invalid learning setup") }; state["readingSetupConfirmed"] = value }
        if let value = input["ai"] {
            guard let value = value as? [String: Any], let provider = value["provider"] as? String, ["codex", "claude-code", "gemini"].contains(provider) else { throw C.validation("Invalid learning AI") }
            state["ai"] = ["provider": provider, "model": try string(value["model"], "model"), "effort": value["effort"] ?? null]
        }
    }
    private func read(_ request: [String: Any], allowDeleted: Bool = false) throws -> Project {
        guard let binding = request["binding"] as? [String: Any] else { throw C.validation("Learning binding is required") }
        let result = try load(course: C.requireID(binding["courseId"]), relative: string(binding["rootRelPath"], "learning root", empty: true))
        guard allowDeleted || result.state["deletedAt"] as? String == nil else { throw C.notFound("learning project", result.relative) }; return result
    }
    private func load(course: String, relative: String) throws -> Project {
        try context.assertPathAvailable(courseID: course, relativePath: relative)
        let folder = try context.courseFolder(course), root = try context.resolve(in: folder, relativePath: relative, allowRoot: true)
        let manifest = try object(at: context.resolve(in: root, relativePath: Self.directory + "/manifest.json"))
        guard manifest["format"] as? String == "bandal-learning", (manifest["formatVersion"] as? NSNumber)?.intValue == 1 else { throw C.validation("Unsupported learning manifest") }
        let url = try context.resolve(in: root, relativePath: Self.directory + "/state.json")
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var state: [String: Any], recovery: String
        do { state = try object(at: url); try validate(state); recovery = "none" }
        catch {
            let prior = try object(at: context.resolve(in: root, relativePath: Self.directory + "/previous.json")); try validate(prior)
            state = prior; recovery = "previous"
        }
        guard state["projectId"] as? String == manifest["projectId"] as? String else { throw C.conflict("Learning state identity does not match its manifest") }
        return Project(course: course, relative: relative, root: root, stateURL: url, before: before, state: state, recovery: recovery)
    }
    private func validate(_ state: [String: Any]) throws {
        guard (state["schemaVersion"] as? NSNumber)?.intValue == 1 else { throw C.validation("Unsupported learning state version") }
        _ = try NativeSyncFormat.identity(state["projectId"]); _ = try NativeValue.int(state["revision"], "learning revision")
        _ = try string(state["name"], "learning name"); _ = try string(state["topic"], "learning topic")
        for key in Self.collections where key != "pathAliases" || state[key] != nil {
            guard let items = state[key] as? [[String: Any]], items.count <= 100_000 else { throw C.validation("Invalid learning collection: " + key) }
            if key != "exports" && key != "pathAliases" {
                var seen = Set<String>()
                for item in items { guard seen.insert(try NativeSyncFormat.identity(item["id"])).inserted else { throw C.validation("Duplicate learning identity") } }
            }
        }
    }
    private func object(at url: URL) throws -> [String: Any] {
        let before = try C.identity(url)
        guard before["directory"] as? Bool == false, (Int(before["size"] as? String ?? "") ?? Int.max) <= 64 * 1024 * 1024,
              let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], try C.sameIdentity(before, C.identity(url)) else { throw C.validation("Learning source is invalid or changed while reading") }; return result
    }
    private func mutate(_ request: [String: Any], allowDeleted: Bool = false, change: (inout Project) throws -> Void) throws -> [String: Any] {
        try context.withMaterialLock {
            var project = try read(request, allowDeleted: allowDeleted)
            guard project.recovery == "none" else { throw C.conflict("The current learning state needs recovery; original retained") }
            let revision = try NativeValue.int(project.state["revision"], "learning revision")
            if let expected = request["expectedRevision"], try NativeValue.int(expected, "learning revision") != revision { throw C.conflict("Learning project changed; read the latest revision") }
            let journal = try NativeSyncJournal(context: context)
            try journal.requireSettled()
            let prior = try C.json(project.state)
            try change(&project)
            if try C.json(project.state) == prior { return project.snapshot }
            project.state["revision"] = revision + 1; project.state["updatedAt"] = C.nowISO
            try validate(project.state)
            let data = Data(try C.json(project.state).utf8)
            let previous = project.stateURL.deletingLastPathComponent().appendingPathComponent("previous.json")
            if project.pendingFiles.isEmpty {
                // Reading progress and draft answers change only state.json;
                // atomic publication already preserves their previous version.
                try context.atomicWrite(Data(project.before.utf8), to: previous)
                try context.atomicWrite(data, to: project.stateURL) {
                    guard try String(contentsOf: project.stateURL, encoding: .utf8) == project.before else { throw C.conflict("Learning source changed before saving") }
                }
            } else {
                let previousExists = context.files.fileExists(atPath: previous.path)
                let previousHash = previousExists ? try NativeSyncFormat.hash(previous) : nil
                var plan = NativeSyncPlan()
                plan.files = project.pendingFiles + [
                    .init(target: previous, data: Data(project.before.utf8), expectedHash: previousHash, expectedMissing: !previousExists),
                    .init(target: project.stateURL, data: data, expectedHash: NativeSyncFormat.hash(Data(project.before.utf8)))
                ]
                try journal.apply(plan, commit: {})
            }
            changed(project); return project.snapshot
        }
    }
    private func changed(_ project: Project) { context.emit?("learning:changed", ["binding": project.binding]); context.emit?("materials:changed", ["courseId": project.course]) }
    private func string(_ value: Any?, _ name: String, empty: Bool = false) throws -> String { try C.requireString(value, name, allowEmpty: empty) }
    private func discover(course: String, tolerateInvalid: Bool = false) throws -> [Project] {
        let folder = try context.courseFolder(course)
        var roots: [String] = [], count = 0
        func walk(_ root: URL, relative: String, depth: Int) throws {
            guard depth <= 64 else { throw C.validation("Learning folder nesting is too deep") }
            if context.files.fileExists(atPath: root.appendingPathComponent(Self.directory + "/manifest.json").path) { roots.append(relative); return }
            for entry in try context.files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                count += 1; guard count <= 100_000 else { throw C.validation("Learning discovery exceeds safe limits") }
                let resource = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if resource.isDirectory == true && resource.isSymbolicLink != true {
                    let path = (relative.isEmpty ? entry.lastPathComponent : relative + "/" + entry.lastPathComponent).precomposedStringWithCanonicalMapping
                    try walk(context.resolve(in: folder, relativePath: path), relative: path, depth: depth + 1)
                }
            }
        }
        try walk(folder, relative: "", depth: 0)
        return try roots.sorted().compactMap { relative in
            do { return try load(course: course, relative: relative) }
            catch {
                guard tolerateInvalid else { throw error }
                context.emit?("learning:recoveryWarning", ["courseId": course, "rootRelPath": relative, "message": error.localizedDescription])
                return nil
            }
        }
    }
    private func summary(_ project: Project) -> [String: Any] {
        let state = project.state
        var result: [String: Any] = ["binding": project.binding, "projectId": state["projectId"]!, "name": state["name"]!, "topic": state["topic"]!, "level": state["level"] ?? "intermediate", "readingMinutes": state["readingMinutes"] ?? 4, "articleCount": (state["articles"] as? [Any])?.count ?? 0, "completedArticleCount": (state["articles"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "completed" }.count, "wordCount": (state["words"] as? [Any])?.count ?? 0, "knownWordCount": (state["words"] as? [[String: Any]] ?? []).filter { $0["status"] as? String == "known" }.count, "dueCardCount": (state["cards"] as? [[String: Any]] ?? []).filter { ($0["dueAt"] as? String ?? "") <= C.nowISO }.count, "updatedAt": state["updatedAt"]!, "warning": project.recovery == "none" ? null : "이전 저장본을 읽었습니다." as Any]
        for field in ["purpose", "topicIds", "readingSetupConfirmed", "ai", "linkedCourseId", "packId", "deletedAt"] { if let value = state[field] { result[field] = value } }; return result
    }

    private func saveWord(_ request: [String: Any], project: inout Project) throws {
        let surface = try string(request["surface"], "word").trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = try string(request["sentence"], "sentence")
        guard surface.count <= 1000, let input = request["sourceRef"] as? [String: Any] else { throw C.validation("Word source is required") }
        let source = try validateSource(input, project: project, verifyQuote: true)
        guard source["kind"] as? String != "web", sentence.contains(surface), (source["quote"] as? String ?? "").contains(sentence) else { throw C.validation("The saved sentence and word must occur in the source quote") }
        let lemma = Self.lemma(try string(request["lemma"] ?? surface, "lemma")), part = try string(request["partOfSpeech"] ?? "", "part of speech", empty: true)
        var words = project.state["words"] as? [[String: Any]] ?? [], occurrences = project.state["occurrences"] as? [[String: Any]] ?? []
        var candidates = words.indices.filter { index in
            let word = words[index], wordPart = word["partOfSpeech"] as? String ?? ""
            let sameSurface = Self.lemma(word["surface"] as? String ?? "") == Self.lemma(surface) || occurrences.contains { $0["wordId"] as? String == word["id"] as? String && Self.lemma($0["surface"] as? String ?? "") == Self.lemma(surface) }
            return sameSurface && (part.isEmpty || wordPart.isEmpty || Self.lemma(part) == Self.lemma(wordPart)) && (request["lemma"] == nil || Self.lemma(word["lemma"] as? String ?? "") == lemma)
        }
        if part.isEmpty && candidates.count > 1 { let unresolved = candidates.filter { (words[$0]["partOfSpeech"] as? String ?? "").isEmpty }; if unresolved.count == 1 { candidates = unresolved } }
        if candidates.isEmpty && request["lemma"] != nil { candidates = words.indices.filter { Self.lemma(words[$0]["lemma"] as? String ?? "") == lemma && (part.isEmpty || (words[$0]["partOfSpeech"] as? String ?? "").isEmpty || Self.lemma(words[$0]["partOfSpeech"] as? String ?? "") == Self.lemma(part)) } }
        let index: Int, now = C.nowISO, meaning = try string(request["meaning"] ?? "", "meaning", empty: true), pronunciation = try string(request["pronunciation"] ?? "", "pronunciation", empty: true)
        let dictionary = try request["dictionarySource"].map { try dictionarySource($0) }
        if candidates.count == 1 { index = candidates[0] }
        else {
            var word: [String: Any] = ["id": UUID().uuidString.lowercased(), "surface": surface, "lemma": lemma, "meaning": meaning, "pronunciation": pronunciation, "partOfSpeech": part, "status": "new", "createdAt": now, "updatedAt": now]
            if let dictionary { word["dictionarySource"] = dictionary }; words.append(word); index = words.count - 1
        }
        let wordID = words[index]["id"] as! String, key = try C.json(source)
        if try occurrences.contains(where: { value in
            guard value["wordId"] as? String == wordID else { return false }
            return try C.json(value["sourceRef"] ?? null) == key
        }) { return }
        if (words[index]["meaning"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            words[index]["meaning"] = meaning; words[index]["dictionarySource"] = dictionary
            if (words[index]["pronunciation"] as? String ?? "").isEmpty { words[index]["pronunciation"] = pronunciation }
            if (words[index]["partOfSpeech"] as? String ?? "").isEmpty { words[index]["partOfSpeech"] = part }; words[index]["updatedAt"] = now
        }
        var occurrence: [String: Any] = ["id": UUID().uuidString.lowercased(), "wordId": wordID, "surface": surface, "sentence": sentence, "sourceRef": source, "meaning": meaning, "createdAt": now]
        if let dictionary { occurrence["dictionarySource"] = dictionary }; occurrences.append(occurrence)
        project.state["words"] = words; project.state["occurrences"] = occurrences
        var history = project.state["history"] as? [[String: Any]] ?? []
        history.append(["id": UUID().uuidString.lowercased(), "kind": "word-saved", "entityId": wordID, "summary": "«\(surface)» 단어와 예문을 저장했습니다.", "createdAt": now]); project.state["history"] = history
    }
    private static func lemma(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func dictionarySource(_ value: Any) throws -> [String: Any] {
        guard let value = value as? [String: Any] else { throw C.validation("Invalid dictionary source") }
        let headword = try string(value["headword"], "dictionary word"), version = try string(value["datasetVersion"], "dictionary version"), url = try string(value["url"], "dictionary URL")
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.!~*'()")
        let canonical = "https://en.wiktionary.org/wiki/" + (headword.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        guard version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil, url == canonical || url == canonical + "#English" else { throw C.validation("Dictionary attribution does not match its word") }; return value
    }
    private func validateSource(_ input: [String: Any], project: Project, verifyQuote: Bool) throws -> [String: Any] {
        var source = input
        let kind = try string(source["kind"], "source kind"), quote = try string(source["quote"] ?? "", "source quote", empty: !verifyQuote)
        if kind == "article" {
            let id = try NativeSyncFormat.identity(source["articleId"])
            let article = try retainedArticle(id, project: project), paragraphs = article["paragraphs"] as? [[String: Any]] ?? []
            if let prior = source["contentHash"] as? String, prior != article["contentHash"] as? String { throw C.conflict("기사 출처가 변경되었습니다. 원문을 다시 선택해 주세요.") }
            guard let paragraph = paragraphs.first(where: { ($0["text"] as? String ?? "").contains(quote) && (source["paragraphId"] == nil || $0["id"] as? String == source["paragraphId"] as? String) }) else { throw C.validation("Source quote was not found in the retained article") }
            source["paragraphId"] = paragraph["id"]; source["contentHash"] = article["contentHash"]; return source
        }
        guard kind == "material" else { throw C.validation("A saved article or material source is required") }
        let scope = source["pathScope"] as? String ?? "project", owner = source["sourceCourseId"] as? String ?? project.course
        guard ["course", "project"].contains(scope), source["sourceCourseId"] == nil || (scope == "course" && (owner == project.course || project.state["linkedCourseId"] as? String == owner)) else { throw C.validation("Learning source belongs to an unrelated course") }
        let root = scope == "course" ? try context.courseFolder(owner) : project.root
        let relative = try string(source["relPath"], "source path"), url = try context.resolve(in: root, relativePath: relative), identity = try C.identity(url)
        guard identity["directory"] as? Bool == false, (Int(identity["size"] as? String ?? "") ?? Int.max) <= 50 * 1024 * 1024 else { throw C.validation("Learning source exceeds the supported size") }
        let bytes = try Data(contentsOf: url), hash = NativeSyncFormat.hash(bytes)
        if let prior = source["contentHash"] as? String, prior != hash { throw C.conflict("Learning source changed; select the latest original") }
        if verifyQuote {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(data: bytes), !document.isLocked else { throw C.validation("PDF text could not be read") }
                if let page = source["page"] { let number = try NativeValue.int(page, "source page", min: 1, max: document.pageCount); text = document.page(at: number - 1)?.string ?? "" }
                else { text = (0..<min(200, document.pageCount)).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n") }
            } else { guard let decoded = String(data: bytes, encoding: .utf8) else { throw C.validation("This source has no supported text") }; text = decoded }
            let normalize: (String) -> String = { $0.precomposedStringWithCanonicalMapping.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard normalize(text).contains(normalize(quote)) else { throw C.validation("Source quote does not occur in the original material") }
        }
        guard try C.sameIdentity(identity, C.identity(url)) else { throw C.conflict("Learning source changed while reading") }
        source["contentHash"] = hash; return source
    }
    private func resolveAliases(_ value: Any, project: Project) -> Any {
        if let array = value as? [Any] { return array.map { resolveAliases($0, project: project) } }
        guard var object = value as? [String: Any] else { return value }
        if object["kind"] as? String == "material", var path = object["relPath"] as? String {
            let scope = object["pathScope"] as? String ?? "project", owner = object["sourceCourseId"] as? String ?? project.course
            for alias in project.state["pathAliases"] as? [[String: Any]] ?? [] where alias["scope"] as? String == scope && (alias["sourceCourseId"] as? String ?? project.course) == owner {
                if let from = alias["fromRelPath"] as? String, let to = alias["toRelPath"] as? String { path = C.repointed(path, from: from, to: to, directory: alias["isDirectory"] as? Bool == true) ?? path }
            }
            object["relPath"] = path
        }
        for (key, item) in object where key != "pathAliases" { if item is [String: Any] || item is [Any] { object[key] = resolveAliases(item, project: project) } }
        return object
    }

    /// Appended to the library's durable rename journal, including citations in
    /// linked courses. No file is written until every affected project validates.
    func planPathChanges(courseID: String, from: String, to: String, isDirectory: Bool, operationID: String) throws -> [[String: Any]] {
        _ = try NativeSyncFormat.identity(operationID)
        var writes: [[String: Any]] = []
        for row in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL ORDER BY id") {
            let owner = row["id"] as! String
            for var project in try discover(course: owner) where owner == courseID || project.state["linkedCourseId"] as? String == courseID {
                guard project.recovery == "none" else { throw C.conflict("Learning source requires recovery before renaming its material") }
                var aliases = project.state["pathAliases"] as? [[String: Any]] ?? []
                if let receipt = aliases.first(where: { $0["operationId"] as? String == operationID }) {
                    guard receipt["scope"] as? String == "course", receipt["fromRelPath"] as? String == from, receipt["toRelPath"] as? String == to, receipt["isDirectory"] as? Bool == isDirectory, (receipt["sourceCourseId"] as? String ?? owner) == courseID else { throw C.conflict("Learning path operation identity was reused") }; continue
                }
                let oldRoot = project.relative, newRoot = owner == courseID ? C.repointed(oldRoot, from: from, to: to, directory: isDirectory) ?? oldRoot : oldRoot
                func coursePath(_ path: String, _ base: String) -> String { base.isEmpty ? path : base + "/" + path }
                func inside(_ path: String, _ base: String) -> String? {
                    if base.isEmpty { return path }
                    let prefix = base + "/"; return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
                }
                func move(_ value: Any, parent: String = "") -> Any {
                    if let array = value as? [Any] { return array.map { move($0, parent: parent) } }
                    guard var object = value as? [String: Any] else { return value }
                    if object["kind"] as? String == "material", let path = object["relPath"] as? String {
                        let scope = object["pathScope"] as? String ?? (parent == "source" ? "course" : "project"), sourceOwner = object["sourceCourseId"] as? String ?? owner
                        if sourceOwner == courseID && (scope == "course" || owner == courseID) {
                            let absolute = scope == "course" ? path : coursePath(path, oldRoot)
                            let changed = C.repointed(absolute, from: from, to: to, directory: isDirectory) ?? absolute
                            if scope == "project", let relative = inside(changed, newRoot) { object["relPath"] = relative }
                            else { object["relPath"] = changed; object["pathScope"] = "course" }
                        }
                    }
                    for (key, item) in object where key != "pathAliases" { if item is [String: Any] || item is [Any] { object[key] = move(item, parent: key) } }
                    return object
                }
                project.state = move(project.state) as! [String: Any]
                if owner == courseID {
                    for collection in ["articles", "artifacts", "exports"] {
                        var entries = project.state[collection] as? [[String: Any]] ?? []
                        let key = collection == "exports" ? "relPath" : "exportRelPath"
                        for index in entries.indices {
                            if let path = entries[index][key] as? String {
                                let absolute = coursePath(path, oldRoot), changed = C.repointed(absolute, from: from, to: to, directory: isDirectory) ?? absolute
                                if let relative = inside(changed, newRoot) { entries[index][key] = relative }
                            }
                        }
                        project.state[collection] = entries
                    }
                }
                var alias: [String: Any] = ["fromRelPath": from, "toRelPath": to, "isDirectory": isDirectory, "scope": "course", "operationId": operationID]
                if owner != courseID { alias["sourceCourseId"] = courseID }; aliases.append(alias)
                if owner == courseID, let localFrom = inside(from, oldRoot), let localTo = inside(to, newRoot), localFrom != localTo {
                    aliases.append(["fromRelPath": localFrom, "toRelPath": localTo, "isDirectory": isDirectory, "scope": "project"])
                }
                project.state["pathAliases"] = aliases; project.state["revision"] = try NativeValue.int(project.state["revision"], "learning revision") + 1; project.state["updatedAt"] = C.nowISO
                let statePath = coursePath(Self.directory + "/state.json", newRoot)
                writes.append(["courseId": owner, "relPath": statePath, "before": project.before, "after": try C.json(project.state)])
            }
        }
        return writes
    }
}
