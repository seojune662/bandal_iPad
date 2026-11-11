import Foundation

final class NativeChatRepository {
    private let context: NativeRepositoryContext
    init(context: NativeRepositoryContext) { self.context = context }
    private func session(_ id: String) throws -> [String:Any] {
        guard let row = try context.db.query("SELECT * FROM agent_sessions WHERE id=? AND deleted_at IS NULL",params:[id]).first else { throw DesktopRuntimeError("대화를 찾을 수 없습니다.",code:"NOT_FOUND") }
        var value = NativeValue.mapped(row,["id":"id","course_id":"courseId","surface":"surface","provider":"provider","cli_session_id":"cliSessionId","model":"model","effort":"effort","status":"status","last_used_at":"lastUsedAt","title":"title"])
        value["accessPolicy"] = (try? NativeValue.decode(row["access_policy"])) ?? ["mode":"ask","scope":["course":true,"browser":false,"screen":false]]
        return value
    }
    private func scoped(_ request: [String:Any]) throws -> [String:Any] {
        let value = try session(NativeValue.string(request["sessionId"],"대화"))
        guard value["courseId"] as? String == request["courseId"] as? String else { throw DesktopRuntimeError("대화와 과목이 일치하지 않습니다.") }
        if let workspace = request["workspace"] as? [String: Any], let id = workspace["id"] as? String {
            let policy = value["accessPolicy"] as? [String: Any] ?? [:]
            guard NativeAssistantPayload.scopeID(policy, course: value["courseId"] as? String ?? "") == id else { throw DesktopRuntimeError("대화와 작업 공간이 일치하지 않습니다.") }
        }
        return value
    }
    private func history(_ id: String) throws -> [[String:Any]] {
        try context.db.query("SELECT * FROM (SELECT * FROM messages WHERE session_id=? AND deleted_at IS NULL ORDER BY turn_seq DESC,CASE role WHEN 'user' THEN 1 ELSE 0 END,created_at DESC LIMIT 200) ORDER BY turn_seq,CASE role WHEN 'user' THEN 0 ELSE 1 END,created_at",params:[id]).map { row in
            var value = NativeValue.mapped(row,["id":"id","course_id":"courseId","session_id":"sessionId","role":"role","turn_seq":"turnSeq","created_at":"createdAt"])
            value["blocks"] = try context.db.query("SELECT * FROM message_blocks WHERE message_id=? AND deleted_at IS NULL ORDER BY ord",params:[row["id"]!]).map { block -> [String:Any] in
                var value = NativeValue.mapped(block,["id":"id","message_id":"messageId","ord":"ord","kind":"kind"]); value["payload"] = try NativeValue.decode(block["payload_json"]); return value
            }; return value
        }
    }
    private func append(course: String,id: String,role: String,turn: Int,text: String,interrupted: Bool = false, extras: [[String: Any]] = []) throws -> [String:Any] {
        let message = UUID().uuidString, block = UUID().uuidString, now = NativeValue.now()
        var payload: [String:Any] = ["text":text]; if interrupted { payload["interrupted"] = true }
        _ = try context.db.run("INSERT INTO messages(id,course_id,session_id,role,turn_seq,created_at,updated_at) VALUES(?,?,?,?,?,?,?)",params:[message,course,id,role,turn,now,now])
        _ = try context.db.run("INSERT INTO message_blocks(id,message_id,ord,kind,payload_json,created_at,updated_at) VALUES(?,?,0,'text',?,?,?)",params:[block,message,try NativeValue.json(payload),now,now])
        var blocks: [[String: Any]] = [["id":block,"messageId":message,"ord":0,"kind":"text","payload":payload]]
        for (index, extra) in extras.enumerated() {
            let extraID = UUID().uuidString, kind = extra["kind"] as? String ?? "metadata", data = extra["payload"] ?? [:]
            _ = try context.db.run("INSERT INTO message_blocks(id,message_id,ord,kind,payload_json,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", params:[extraID,message,index+1,kind,try NativeValue.json(data),now,now])
            blocks.append(["id":extraID,"messageId":message,"ord":index+1,"kind":kind,"payload":data])
        }
        return ["id":message,"courseId":course,"sessionId":id,"role":role,"turnSeq":turn,"createdAt":now,"blocks":blocks]
    }
    private static func keepsNoHistory(_ row: [String: Any]) -> Bool {
        ((try? NativeValue.decode(row["access_policy"])) as? [String: Any])?["ephemeral"] as? Bool == true
    }
    func recover() throws {
        try context.transaction {
            // 설정 › AI › 대화 기록 저장 off: a conversation begun then is gone, rows and all, by the next launch.
            for row in try context.db.query("SELECT id,access_policy FROM agent_sessions WHERE access_policy LIKE '%ephemeral%'",params:[]) where Self.keepsNoHistory(row) {
                let id = row["id"] as! String
                // The image cache is rebuilt from a block's own payload when another conversation still needs the file.
                for block in try context.db.query("SELECT payload_json FROM message_blocks WHERE kind='attachment' AND message_id IN (SELECT id FROM messages WHERE session_id=?)",params:[id]) {
                    guard let payload = (try? NativeValue.decode(block["payload_json"])) as? [String: Any], let image = NativeAssistantPayload.image(payload["imageDataURL"] as? String),
                          let bytes = image["dataBase64"].flatMap({ Data(base64Encoded:$0) }), let type = image["mediaType"] else { continue }
                    try? context.files.removeItem(at:NativeAssistantPayload.assetURL(root:context.root,hash:NativeSyncFormat.hash(bytes),mediaType:type))
                }
                _ = try context.db.run("DELETE FROM message_blocks WHERE message_id IN (SELECT id FROM messages WHERE session_id=?)",params:[id])
                _ = try context.db.run("DELETE FROM messages WHERE session_id=?",params:[id])
                _ = try context.db.run("DELETE FROM agent_sessions WHERE id=?",params:[id])
            }
            for row in try context.db.query("SELECT id,course_id FROM agent_sessions WHERE status='running' AND deleted_at IS NULL",params:[]) {
                let id = row["id"] as! String, course = row["course_id"] as! String
                for message in try context.db.query("SELECT turn_seq FROM messages u WHERE session_id=? AND role='user' AND deleted_at IS NULL AND NOT EXISTS(SELECT 1 FROM messages a WHERE a.session_id=u.session_id AND a.turn_seq=u.turn_seq AND a.role='assistant' AND a.deleted_at IS NULL)",params:[id]) {
                    _ = try append(course:course,id:id,role:"assistant",turn:(message["turn_seq"] as? NSNumber)?.intValue ?? 0,text:"",interrupted:true)
                }
                _ = try context.db.run("UPDATE agent_sessions SET status='idle',updated_at=? WHERE id=?",params:[NativeValue.now(),id])
            }
        }
    }
    func handle(_ channel: String, _ request: [String:Any]) throws -> Any? {
        switch channel {
        case "chat:open":
            return try context.transaction {
            let course = try NativeValue.string(request["courseId"],"과목"), id = try NativeValue.string(request["sessionId"],"대화"); _ = try context.courseFolder(course)
            if try context.db.query("SELECT id FROM agent_sessions WHERE id=?",params:[id]).isEmpty {
                let provider = request["provider"] as? String ?? "claude-code"; guard ["claude-code","codex","gemini"].contains(provider) else { throw DesktopRuntimeError("AI 제공자를 확인해 주세요.") }
                let now = NativeValue.now()
                _ = try context.db.run("INSERT INTO agent_sessions(id,course_id,surface,provider,status,created_at,updated_at) VALUES(?,?,?,?,'idle',?,?)",params:[id,course,request["surface"] as? String == "desktop" ? "desktop" : "app",provider,now,now])
                if let workspace = request["workspace"] as? [String: Any] {
                    guard workspace["courseId"] as? String == course,
                          let kind = workspace["kind"] as? String, ["course", "project"].contains(kind),
                          workspace["id"] as? String == (kind == "course" ? "course:" + course : "project:" + (workspace["projectId"] as? String ?? "")) else { throw DesktopRuntimeError("작업 공간을 확인해 주세요.") }
                    if kind == "project" {
                        let snapshot = try NativeLearningRepository(context: context).handle("learning:get", ["binding": ["courseId":course,"rootRelPath":workspace["rootRelPath"] as? String ?? ""]]) as? [String: Any]
                        guard snapshot?["projectId"] as? String == workspace["projectId"] as? String else { throw DesktopRuntimeError("프로젝트가 변경되었습니다.") }
                    }
                    let policy: [String: Any] = ["mode":"ask","scope":["course":true,"browser":false,"screen":false],"workspace":workspace]
                    _ = try context.db.run("UPDATE agent_sessions SET access_policy=? WHERE id=?",params:[try NativeValue.json(policy),id])
                }
            }
            return ["history":try history(id),"sessionInfo":try scoped(request),"pendingPermissions":[]]
            }
        case "chat:conversations":
            let course = try NativeValue.string(request["courseId"],"과목"); _ = try context.courseFolder(course)
            let rows = try context.db.query("SELECT s.*,COUNT(m.id) AS message_count FROM agent_sessions s JOIN messages m ON m.session_id=s.id AND m.deleted_at IS NULL WHERE s.course_id=? AND s.deleted_at IS NULL GROUP BY s.id ORDER BY COALESCE(s.last_used_at,s.created_at) DESC",params:[course])
            return ["conversations":rows.filter { row in
                guard !Self.keepsNoHistory(row), request["surface"] == nil || row["surface"] as? String == request["surface"] as? String else { return false }
                guard let workspace = request["workspace"] as? [String: Any], let scope = workspace["id"] as? String else { return true }
                let policy = (try? NativeValue.decode(row["access_policy"])) as? [String: Any] ?? [:]
                return NativeAssistantPayload.scopeID(policy, course: course) == scope
            }.map { NativeValue.mapped($0,["id":"id","course_id":"courseId","surface":"surface","provider":"provider","title":"title","model":"model","last_used_at":"lastUsedAt","created_at":"createdAt","message_count":"messageCount"]) }]
        case "chat:rename":
            let current = try scoped(request), id = current["id"] as! String
            guard current["status"] as? String != "running" else { throw DesktopRuntimeError("진행 중인 응답을 중지한 뒤 변경해 주세요.",code:"BUSY") }
            let title = try NativeValue.string(request["title"],"대화 제목").trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty else { throw DesktopRuntimeError("대화 제목을 입력해 주세요.") }
            _ = try context.db.run("UPDATE agent_sessions SET title=?,updated_at=? WHERE id=?",params:[String(title.prefix(80)),NativeValue.now(),id])
            return ["title":String(title.prefix(80))]
        case "chat:deleteAll":
            // Settings › AI › 대화 기록 모두 지우기. A running answer keeps its conversation.
            let now = NativeValue.now()
            _ = try context.db.run("UPDATE agent_sessions SET deleted_at=?,updated_at=? WHERE deleted_at IS NULL AND status!='running'",params:[now,now])
            return NativeValue.ok
        case "chat:setProvider", "chat:setConfiguration", "chat:setModel", "chat:deleteConversation":
            let current = try scoped(request), id = current["id"] as! String
            guard current["status"] as? String != "running" else { throw DesktopRuntimeError("진행 중인 응답을 중지한 뒤 변경해 주세요.",code:"BUSY") }
            let now = NativeValue.now()
            if channel == "chat:deleteConversation" { _ = try context.db.run("UPDATE agent_sessions SET deleted_at=?,updated_at=? WHERE id=?",params:[now,now,id]); return NativeValue.ok }
            if channel == "chat:setProvider" {
                let provider = try NativeValue.string(request["provider"],"AI 제공자"); guard ["claude-code","codex","gemini"].contains(provider) else { throw DesktopRuntimeError("AI 제공자를 확인해 주세요.") }
                _ = try context.db.run("UPDATE agent_sessions SET provider=?,cli_session_id=NULL,model=NULL,effort=NULL,transcript_path=NULL,launch_config_json=NULL,updated_at=? WHERE id=?",params:[provider,now,id]); return try session(id)
            }
            let model = try NativeValue.string(request["model"],"모델")
            _ = try context.db.run("UPDATE agent_sessions SET model=?,effort=?,updated_at=? WHERE id=?",params:[model,request["effort"] ?? NativeValue.null,now,id])
            return ["model":model,"effort":request["effort"] ?? NativeValue.null]
        case "nativeChat:begin":
            return try context.transaction {
                let current = try scoped(request), id = current["id"] as! String, course = current["courseId"] as! String
                guard current["status"] as? String != "running" else { throw DesktopRuntimeError("응답을 기다리거나 중지해 주세요.",code:"BUSY") }
                let text = try NativeValue.string(request["content"],"메시지")
                let sequence = (try context.db.query("SELECT COALESCE(MAX(turn_seq),0)+1 AS n FROM messages WHERE session_id=? AND deleted_at IS NULL",params:[id]).first?["n"] as? NSNumber)?.intValue ?? 1
                // The first message decides whether the conversation is kept: the panel opens its row before the user types.
                if sequence == 1 {
                    var policy = current["accessPolicy"] as? [String: Any] ?? [:]
                    if request["ephemeral"] as? Bool == true { policy["ephemeral"] = true } else { policy.removeValue(forKey:"ephemeral") }
                    _ = try context.db.run("UPDATE agent_sessions SET access_policy=? WHERE id=?",params:[try NativeValue.json(policy),id])
                }
                let attachments = try NativeAssistantPayload.validatedAttachments(request["attachments"])
                for attachment in attachments { _ = try NativeAssistantPayload.cacheImage(attachment,context:context) }
                var extras = attachments.map { ["kind":"attachment", "payload":$0] as [String: Any] }
                var metadata: [String: Any] = ["mode": request["mode"] as? String ?? "chat"]
                if let workspace = request["workspace"] { metadata["workspace"] = workspace }
                if let document = request["documentContext"] { metadata["documentContext"] = document }
                extras.append(["kind":"request-context", "payload":metadata])
                let message = try append(course:course,id:id,role:"user",turn:sequence,text:text,extras:extras)
                let now = NativeValue.now()
                _ = try context.db.run("UPDATE agent_sessions SET status='running',title=CASE WHEN title IS NULL OR title='' THEN ? ELSE title END,last_used_at=?,updated_at=? WHERE id=?",params:[String(text.prefix(80)),now,now,id])
                context.emit?("chat:message",["sessionId":id,"message":message])
                return ["turnSeq":sequence,"sessionInfo":try session(id),"history":try history(id)]
            }
        case "nativeChat:finish":
            return try context.transaction {
                let current = try scoped(request), id = current["id"] as! String, course = current["courseId"] as! String
                let turn = try NativeValue.int(request["turnSeq"],"응답 순서",min:1)
                if let usage = request["usage"] as? [String:Any] {
                    let input = try NativeValue.int(usage["inputTokens"] ?? 0,"입력 토큰",min:0)
                    let output = try NativeValue.int(usage["outputTokens"] ?? 0,"출력 토큰",min:0)
                    let duration = try NativeValue.int(request["durationMs"] ?? 0,"응답 시간",min:0)
                    _ = try context.db.run("INSERT OR IGNORE INTO agent_usage(id,session_id,course_id,provider,model,turn_at,input_tokens,output_tokens,duration_ms) VALUES(?,?,?,?,?,?,?,?,?)",params:["native:\(id):\(turn)",id,course,current["provider"] ?? "claude-code",request["model"] ?? NativeValue.null,NativeValue.now(),input,output,duration])
                }
                // Replaying a completion after a lost acknowledgement is safe.
                if try context.db.query("SELECT id FROM messages WHERE session_id=? AND turn_seq=? AND role='assistant' AND deleted_at IS NULL",params:[id,turn]).isEmpty {
                    guard let text = request["text"] as? String else { throw DesktopRuntimeError("응답 형식이 올바르지 않습니다.") }
                    // "source" blocks: the materials the answer read, shown as chips under it.
                    let sources = (request["sources"] as? [[String: Any]] ?? []).prefix(NativeAssistantService.sourceLimit).compactMap { source -> [String: Any]? in
                        guard let owner = source["courseId"] as? String, let path = source["relPath"] as? String, !path.isEmpty else { return nil }
                        var payload: [String: Any] = ["courseId":owner,"relPath":path]
                        if let page = (source["page"] as? NSNumber)?.intValue, page >= 1 { payload["page"] = page }
                        return ["kind":"source","payload":payload]
                    }
                    let extras = (request["artifacts"] as? [[String: Any]] ?? []).map { ["kind":"artifact","payload":$0] as [String: Any] } + sources
                    let message = try append(course:course,id:id,role:"assistant",turn:turn,text:text,interrupted:request["interrupted"] as? Bool == true,extras:extras)
                    context.emit?("chat:message",["sessionId":id,"message":message])
                }
                let now = NativeValue.now(); _ = try context.db.run("UPDATE agent_sessions SET status='idle',last_used_at=?,updated_at=? WHERE id=?",params:[now,now,id]); return NativeValue.ok
            }
        case "chat:grants":
            let course = try NativeValue.string(request["courseId"],"과목")
            return ["grants":try context.db.query("SELECT id,rule,created_at AS createdAt FROM permission_grants WHERE course_id=? AND deleted_at IS NULL ORDER BY created_at",params:[course])]
        case "chat:revokeGrant":
            let now = NativeValue.now(); _ = try context.db.run("UPDATE permission_grants SET deleted_at=?,updated_at=? WHERE id=?",params:[now,now,try NativeValue.string(request["id"],"권한")]); return NativeValue.ok
        default:return nil
        }
    }
}
