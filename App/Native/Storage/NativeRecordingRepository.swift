import Foundation

/// Recording metadata and transcript cursors share the canonical SQLite file.
/// Audio is flushed before acknowledging its corresponding metadata update.
final class NativeRecordingRepository {
    private let context: NativeRepositoryContext
    init(context: NativeRepositoryContext) { self.context = context }
    private func get(_ id: String) throws -> [String: Any] {
        guard let row = try context.db.query("SELECT payload FROM recording_sessions WHERE id=?", params: [id]).first else { throw DesktopRuntimeError("녹음을 찾을 수 없습니다.") }; return try NativeValue.object(row["payload"])
    }
    @discardableResult private func save(_ value: [String: Any]) throws -> [String: Any] {
        let id = try NativeValue.string(value["id"], "녹음"), previous = try get(id)
        guard previous["courseId"] as? String == value["courseId"] as? String, previous["audioRelPath"] as? String == value["audioRelPath"] as? String else { throw DesktopRuntimeError("녹음의 저장 위치가 변경되었습니다.") }
        _ = try context.db.run("UPDATE recording_sessions SET payload=? WHERE id=?", params: [try NativeValue.json(value), id]); return value
    }
    private func audioURL(_ session: [String: Any], allowMissing: Bool = false) throws -> URL {
        try context.materialURL(courseID: NativeValue.string(session["courseId"], "과목"), relativePath: NativeValue.string(session["audioRelPath"], "녹음 경로"), allowMissing: allowMissing)
    }
    private static func header(_ samples: Int) -> Data {
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        text("RIFF"); u32(UInt32(36 + samples * 2)); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16); text("data"); u32(UInt32(samples * 2)); return bytes
    }
    private func segments(_ id: String, after: Int? = nil) throws -> [[String: Any]] {
        let sql = "SELECT id,session_id AS sessionId,start_sample AS startSample,end_sample AS endSample,text FROM recording_segments WHERE session_id=?"
        if let after { return try context.db.query(sql + " AND id > ? ORDER BY id LIMIT 200", params: [id,after]) }
        return try context.db.query(sql + " ORDER BY id DESC LIMIT 200", params: [id]).reversed()
    }
    private func anchors(_ id: String) throws -> [[String: Any]] {
        try context.db.query("SELECT payload FROM recording_anchors WHERE session_id=? ORDER BY rowid LIMIT 1000", params: [id]).map { try NativeValue.object($0["payload"]) }
    }
    private func segment(_ id: String, _ value: [String: Any], samples: Int) throws -> [String: Any] {
        let start = try NativeValue.int(value["startSample"], "자막 시작", max: samples), end = try NativeValue.int(value["endSample"], "자막 종료", min: start, max: samples)
        guard let text = value["text"] as? String, text.count <= 1_000_000 else { throw DesktopRuntimeError("자막 형식이 올바르지 않습니다.") }
        let result = try context.db.run("INSERT INTO recording_segments(session_id,start_sample,end_sample,text) VALUES(?,?,?,?)", params: [id,start,end,text])
        return ["id": result["lastInsertRowid"] ?? 0,"sessionId":id,"startSample":start,"endSample":end,"text":text]
    }
    func recover() throws {
        for row in try context.db.query("SELECT payload FROM recording_sessions", params: []) {
            var session = try NativeValue.object(row["payload"])
            guard ["recording","paused","processing","interrupted"].contains(session["status"] as? String ?? "") else { continue }
            session["status"] = "interrupted"
            if session["error"] == nil || session["error"] is NSNull { session["error"] = "녹음이 중단되었습니다. 저장된 음성을 다시 듣거나 자막을 다시 생성할 수 있어요." }
            do {
                let url = try audioURL(session), handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
                let size = try handle.seekToEnd(); guard size >= 44 else { throw DesktopRuntimeError("녹음 헤더가 손상되었습니다.") }
                let count = Int((size-44)/2); guard count <= 24*3600*16000 else { throw DesktopRuntimeError("녹음 길이를 확인할 수 없습니다.") }
                try handle.truncate(atOffset: UInt64(44 + count*2)); try handle.seek(toOffset: 0); try handle.write(contentsOf: Self.header(count)); try handle.synchronize(); session["samples"] = count
            } catch { session["error"] = "원음 파일을 찾거나 복구하지 못했습니다. 과목 폴더 연결을 확인해 주세요." }
            try save(session)
        }
    }
    func handle(_ channel: String, _ request: [String: Any]) throws -> Any? {
        guard channel.hasPrefix("recordings:") || channel.hasPrefix("nativeRecording:") else { return nil }
        switch channel {
        case "recordings:list":
            let course = try NativeValue.string(request["courseId"], "과목"); _ = try context.courseFolder(course)
            return try context.db.query("SELECT payload FROM recording_sessions WHERE course_id=? ORDER BY created_at DESC LIMIT 200", params: [course]).map { try NativeValue.object($0["payload"]) }
        case "recordings:resolve":
            let course = try NativeValue.string(request["courseId"], "과목"), path = try NativeValue.string(request["relPath"], "경로")
            _ = try context.materialURL(courseID: course, relativePath: path)
            if let row = try context.db.query("SELECT payload FROM recording_sessions WHERE course_id=? AND json_extract(payload,'$.audioRelPath')=? LIMIT 1", params: [course,path]).first { return try NativeValue.object(row["payload"]) }; return NativeValue.null
        case "nativeRecording:create":
            let course = try NativeValue.string(request["courseId"], "과목"), title = try NativeValue.string(request["title"], "제목"), model = try NativeValue.string(request["modelId"], "음성 모델")
            guard LocalSpeechModel(rawValue: model) != nil else { throw DesktopRuntimeError("알 수 없는 음성 모델입니다.") }
            let id = UUID().uuidString, now = NativeValue.now()
            let session: [String: Any] = ["id":id,"courseId":course,"title":String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),"modelId":model,"createdAt":now,"status":"ready","audioRelPath":"녹음/\(id)/audio.wav","samples":0,"transcribedSamples":0,"nextSequence":0,"error":NativeValue.null]
            let url = try audioURL(session, allowMissing: true)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.header(0).write(to: url, options: .withoutOverwriting)
            let output = try FileHandle(forUpdating: url)
            do { try output.synchronize(); try output.close() } catch { try? output.close(); throw error }
            do { _ = try context.db.run("INSERT INTO recording_sessions(id,course_id,created_at,payload) VALUES(?,?,?,?)", params: [id,course,now,try NativeValue.json(session)]) }
            catch { try? FileManager.default.removeItem(at: url); throw error }
            context.emit?("materials:changed", ["courseId":course]); return session
        case "nativeRecording:get": return try get(NativeValue.string(request["id"], "녹음"))
        case "nativeRecording:save":
            guard let session = request["session"] as? [String: Any] else { throw DesktopRuntimeError("녹음 형식이 올바르지 않습니다.") }; return try save(session)
        case "nativeRecording:status":
            var session = try get(NativeValue.string(request["id"], "녹음")); session["status"] = try NativeValue.string(request["status"], "상태"); session["error"] = request["error"] ?? NativeValue.null; return try save(session)
        case "nativeRecording:audioPath": return try audioURL(get(NativeValue.string(request["id"], "녹음"))).path
        case "nativeRecording:recover": try recover(); return NativeValue.ok
        case "nativeRecording:markdown":
            let id = try NativeValue.string(request["id"], "녹음"), session = try get(id)
            func time(_ value: Any?) -> String {
                let seconds = ((value as? NSNumber)?.intValue ?? 0) / 16000
                return String(format:"%02d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60)
            }
            let title = (session["title"] as? String ?? "강의 녹음").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")
            let path = try NativeValue.string(session["audioRelPath"],"원음 경로")
            let escaped = path.split(separator:"/").map { String($0).addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? String($0) }.joined(separator:"/")
            var lines = ["# " + title,"",String((session["createdAt"] as? String ?? "").prefix(10)) + " · " + time(session["samples"]),"","[녹음 듣기](" + escaped + ")",""]
            for mark in try anchors(id) { lines.append("- **" + time(mark["sample"]) + "** " + (mark["label"] as? String ?? "")) }
            for segment in try context.db.query("SELECT start_sample,text FROM recording_segments WHERE session_id=? ORDER BY id",params:[id]) { lines += ["**" + time(segment["start_sample"]) + "** " + (segment["text"] as? String ?? ""),""] }
            return ["courseId":session["courseId"]!,"title":title,"markdown":lines.joined(separator:"\n")]
        case "recordings:read":
            let id = try NativeValue.string(request["id"], "녹음")
            let after = try request["afterId"].map { try NativeValue.int($0, "자막 번호") }
            return ["session":try get(id),"segments":try segments(id, after: after),"anchors":try anchors(id)]
        case "nativeRecording:append":
            let id = try NativeValue.string(request["id"], "녹음"), sequence = try NativeValue.int(request["sequence"], "오디오 순서")
            var session = try get(id)
            let envelope = request["pcm"] as? [String: Any]
            let bytes = (request["pcm"] as? Data) ?? (envelope?["__bandalBytes"] as? String).flatMap { Data(base64Encoded:$0) }
            guard let bytes, !bytes.isEmpty, bytes.count <= 32000, bytes.count % 2 == 0, session["status"] as? String == "recording" else { throw DesktopRuntimeError("올바르지 않은 오디오 청크입니다.") }
            let next = try NativeValue.int(session["nextSequence"], "오디오 순서"), count = try NativeValue.int(session["samples"], "녹음 길이")
            if sequence < next { return session }; guard sequence == next, count+bytes.count/2 <= 24*3600*16000 else { throw DesktopRuntimeError("오디오 순서 또는 녹음 길이를 확인해 주세요.") }
            let handle = try FileHandle(forUpdating: audioURL(session)); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(44+count*2)); try handle.write(contentsOf: bytes); try handle.seek(toOffset: 0); try handle.write(contentsOf: Self.header(count+bytes.count/2)); try handle.synchronize()
            session["samples"] = count+bytes.count/2; session["nextSequence"] = next+1; return try save(session)
        case "nativeRecording:segment":
            let id = try NativeValue.string(request["id"], "녹음"), session = try get(id)
            return try segment(id, request, samples: NativeValue.int(session["samples"], "녹음 길이"))
        case "nativeRecording:commitTranscriptWindow":
            return try context.transaction {
                let id = try NativeValue.string(request["id"], "녹음"); var session = try get(id)
                let samples = try NativeValue.int(session["samples"], "녹음 길이"), cursor = try NativeValue.int(session["transcribedSamples"], "자막 위치")
                let start = try NativeValue.int(request["startSample"], "자막 시작", max:samples), end = try NativeValue.int(request["endSample"], "자막 종료", min:start+1, max:samples)
                guard let text = request["text"] as? String, text.count <= 1_000_000 else { throw DesktopRuntimeError("올바르지 않은 자막입니다.") }
                if end <= cursor { return ["session":session] }
                guard start == cursor else { throw DesktopRuntimeError("자막 저장 위치가 변경되었습니다.") }
                var result: [String: Any] = [:]
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result["segment"] = try segment(id, request, samples:samples) }
                session["transcribedSamples"] = end; session["error"] = NativeValue.null; result["session"] = try save(session); return result
            }
        case "nativeRecording:resetTranscript", "nativeRecording:replaceTranscript":
            return try context.transaction {
                let id = try NativeValue.string(request["id"], "녹음"); var session = try get(id)
                _ = try context.db.run("DELETE FROM recording_segments WHERE session_id=?", params:[id])
                session["transcribedSamples"] = 0; session["error"] = NativeValue.null
                if channel == "nativeRecording:replaceTranscript" {
                    let samples = try NativeValue.int(session["samples"], "녹음 길이")
                    guard let values = request["segments"] as? [[String:Any]] else { throw DesktopRuntimeError("올바르지 않은 자막입니다.") }
                    for value in values { _ = try segment(id,value,samples:samples) }
                    session["transcribedSamples"] = try NativeValue.int(request["transcribedSamples"], "자막 위치", max:samples)
                    if let model = request["modelId"] as? String { guard LocalSpeechModel(rawValue:model) != nil else { throw DesktopRuntimeError("음성 모델을 확인해 주세요.") }; session["modelId"] = model }
                    session["status"] = "complete"
                }
                return try save(session)
            }
        case "recordings:anchor":
            let id = try NativeValue.string(request["id"], "녹음"), session = try get(id), label = try NativeValue.string(request["label"], "표시 이름")
            guard try anchors(id).count < 1000 else { throw DesktopRuntimeError("한 녹음에 최대 1,000개의 표시를 저장할 수 있습니다.") }
            if let path = request["relPath"] as? String {
                guard ["pdf","md"].contains((path as NSString).pathExtension.lowercased()) else { throw DesktopRuntimeError("PDF 또는 노트를 선택해 주세요.") }
                _ = try context.materialURL(courseID: NativeValue.string(session["courseId"], "과목"), relativePath:path)
            }
            let count = try NativeValue.int(session["samples"], "녹음 길이")
            let value: [String:Any] = ["id":UUID().uuidString,"sample":min(try NativeValue.int(request["sample"] ?? count,"표시 위치"),count),"label":String(label.prefix(300)),"relPath":request["relPath"] ?? NativeValue.null,"page":try request["page"].map { try NativeValue.int($0,"페이지",min:1) } as Any? ?? NativeValue.null]
            _ = try context.db.run("INSERT INTO recording_anchors(id,session_id,payload) VALUES(?,?,?)", params:[value["id"]!,id,try NativeValue.json(value)]); return value
        default: return nil
        }
    }
}
