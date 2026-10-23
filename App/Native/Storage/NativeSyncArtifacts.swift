import Foundation
import CoreFoundation

/// CommonSync envelopes for SQLite domains that do not own PDF ink. Planning is
/// read-only; the sync journal publishes files and SQLite changes together.
final class NativeSyncArtifacts {
    private typealias F = NativeSyncFormat
    private typealias C = NativeRepositoryContext
    private let context: C
    private let null = NSNull()
    init(context: NativeRepositoryContext) { self.context = context }

    func snapshot() throws -> NativeSyncSnapshot {
        var result = NativeSyncSnapshot()
        func add(_ id: String, _ kind: String, _ payload: [String: Any], source: [String: Any] = [:], deleted: Bool = false) {
            result.records.append(F.record(id: id, kind: kind, payload: payload, deleted: deleted)); result.sources[id] = source
        }
        for row in try context.query("SELECT * FROM course_groups ORDER BY id") {
            add("artifact:course-group:\(row["id"]!)", "artifact", ["recordType": "desktop-course-group", "id": row["id"]!, "name": row["name"]!, "sortOrder": row["sort_order"]!, "createdAt": row["created_at"]!], deleted: isDeleted(row))
        }
        for row in try context.query("SELECT * FROM board_tasks ORDER BY id") {
            add("task:\(row["id"]!)", "task", ["id": row["id"]!, "courseID": row["course_id"] ?? null, "title": row["title"]!, "completed": row["status"] as? String == "done", "due": row["due_at"] ?? null,
                "desktop": ["notes": row["notes"] ?? "", "status": row["status"]!, "kind": row["kind"] ?? "task", "color": row["color"] ?? "none", "startAt": row["start_at"] ?? null, "dueAt": row["due_at"] ?? null, "allDay": (row["all_day"] as? NSNumber)?.boolValue ?? false, "sortOrder": row["sort_order"]!, "createdAt": row["created_at"]!]], deleted: isDeleted(row))
        }
        for row in try context.query("SELECT * FROM favorites ORDER BY id") {
            add("favorite:\(row["id"]!)", "favorite", ["id": row["id"]!, "courseID": row["course_id"] ?? null, "label": row["label"]!, "descriptor": try F.object(row["descriptor_json"]), "sortOrder": row["sort_order"]!, "createdAt": row["created_at"]!], deleted: isDeleted(row))
        }
        for session in try context.query("SELECT * FROM agent_sessions ORDER BY id") {
            let id = session["id"] as! String
            add("chat:\(id)", "chat", ["recordType": "desktop-chat-session", "id": id, "courseID": session["course_id"]!, "title": session["title"] ?? null, "provider": session["provider"]!, "model": session["model"] ?? null, "surface": session["surface"] ?? "app", "reasoningEffort": session["effort"] ?? null, "createdAt": session["created_at"]!, "lastUsedAt": session["last_used_at"] ?? null, "workspace": ((try? NativeValue.decode(session["access_policy"])) as? [String: Any])?["workspace"] ?? null], deleted: isDeleted(session))
            for message in try context.query("SELECT * FROM messages WHERE session_id=? ORDER BY turn_seq,id", [id]) {
                let blocks = try context.query("SELECT * FROM message_blocks WHERE message_id=? ORDER BY ord", [message["id"]!]).map { row -> [String: Any] in
                    var payload = try NativeValue.decode(row["payload_json"])
                    if row["kind"] as? String == "attachment", var capture = payload as? [String: Any], let asset = try NativeAssistantPayload.cacheImage(capture,context:context) {
                        result.assets.append(asset)
                        capture.removeValue(forKey:"imageDataURL")
                        capture["imageAsset"] = ["sha256":asset["sha256"]!,"byteCount":asset["byteCount"]!,"contentType":asset["contentType"]!,"originalName":asset["originalName"]!]
                        payload = capture
                    }
                    return ["id": row["id"]!, "order": row["ord"]!, "kind": row["kind"]!, "payload": payload, "createdAt": row["created_at"]!, "updatedAt": row["updated_at"]!, "deletedAt": row["deleted_at"] ?? null]
                }
                add("chat:message:\(message["id"]!)", "chat", ["recordType": "desktop-chat-message", "id": message["id"]!, "courseID": message["course_id"]!, "sessionID": id, "role": message["role"]!, "turnSequence": message["turn_seq"]!, "createdAt": message["created_at"]!, "updatedAt": message["updated_at"]!, "blocks": blocks], deleted: isDeleted(message))
            }
        }
        try appendRecordings(to: &result)
        try appendLearning(to: &result)
        return result
    }

    func plan(_ record: [String: Any], assets: [String: URL]) throws -> NativeSyncPlan? {
        try F.validate(record)
        let kind = record["kind"] as! String, p = record["payload"] as! [String: Any], recordID = record["id"] as! String
        let deleted = record["deleted"] as! Bool, now = C.nowISO
        let tombstone: Any = deleted ? now : null
        let desktop = p["desktop"] as? [String: Any] ?? [:]
        func id(_ prefix: String) throws -> String {
            let value = try F.identity(p["id"])
            guard recordID == prefix + value else { throw C.validation("Sync identity mismatch") }; return value
        }
        func row(_ table: String, _ values: [String: Any], courseID: String? = nil) -> NativeSyncPlan {
            NativeSyncPlan(courseID: courseID, apply: { [context] in try F.upsert(context, table: table, values: values) })
        }
        switch kind {
        case "task":
            let task = try id("task:"), course = try optionalCourse(p["courseID"], deleted: deleted)
            let title = try string(p["title"], "task title", allowEmpty: true)
            let taskKind = try string(desktop["kind"] ?? "task", "task kind")
            guard ["task", "exam", "assignment", "class"].contains(taskKind) else { throw C.validation("Unsupported task kind") }
            return row("board_tasks", ["id": task, "course_id": course as Any? ?? null, "title": title, "notes": try string(desktop["notes"] ?? "", "task notes", allowEmpty: true), "status": p["completed"] as? Bool == true ? "done" : desktop["status"] as? String == "in-progress" ? "in-progress" : "todo",
                "kind": taskKind, "color": desktop["color"] as? String ?? "none", "start_at": desktop["startAt"] ?? null, "due_at": present(p["due"]) ?? desktop["dueAt"] ?? null, "all_day": desktop["allDay"] as? Bool == true ? 1 : 0, "sort_order": try integer(desktop["sortOrder"] ?? 0, min: -1_000_000), "created_at": desktop["createdAt"] ?? now, "updated_at": now, "deleted_at": tombstone], courseID: course)
        case "favorite":
            let favorite = try id("favorite:"), course = try optionalCourse(p["courseID"], deleted: deleted)
            guard let descriptor = p["descriptor"] as? [String: Any] else { throw C.validation("Invalid favorite descriptor") }
            return row("favorites", ["id": favorite, "course_id": course as Any? ?? null, "label": try string(p["label"], "favorite label", allowEmpty: true), "descriptor_json": try F.canonical(descriptor), "sort_order": try integer(p["sortOrder"] ?? 0, min: -1_000_000), "created_at": p["createdAt"] ?? now, "updated_at": now, "deleted_at": tombstone], courseID: course)
        case "artifact" where p["recordType"] as? String == "desktop-course-group":
            return row("course_groups", ["id": try id("artifact:course-group:"), "name": try string(p["name"], "course group name"), "sort_order": try integer(p["sortOrder"] ?? 0, min: -1_000_000), "created_at": p["createdAt"] ?? now, "updated_at": now, "deleted_at": tombstone])
        case "chat" where p["recordType"] as? String == "desktop-chat-session":
            let session = try id("chat:"), course = try requiredCourse(p["courseID"], deleted: deleted)
            guard let provider = p["provider"] as? String, ["claude-code", "codex", "gemini"].contains(provider), let surface = p["surface"] as? String, ["app", "desktop"].contains(surface) else { throw C.validation("Unsupported chat provider or surface") }
            let old = try context.query("SELECT * FROM agent_sessions WHERE id=?", [session]).first
            if let old {
                guard old["course_id"] as? String == course else { throw C.conflict("Chat identity belongs to another course") }
                guard old["status"] as? String != "running" else { throw C.conflict("The conversation is active on this device") }
            }
            // Only workspace identity is portable; permission grants remain local.
            var policy = (old.flatMap { try? NativeValue.decode($0["access_policy"]) } as? [String: Any]) ?? ["mode":"ask","scope":["course":true,"browser":false,"screen":false]]
            if let workspace = p["workspace"] as? [String: Any] {
                guard workspace["courseId"] as? String == course, let scope = workspace["id"] as? String,
                      scope == "course:" + course || (workspace["kind"] as? String == "project" && scope == "project:" + (workspace["projectId"] as? String ?? "")) else { throw C.validation("Invalid chat workspace") }
                if let existing = (policy["workspace"] as? [String: Any])?["id"] as? String, existing != scope { throw C.conflict("Chat workspace identity changed") }
                policy["workspace"] = workspace
            }
            // Device-specific grants, launch config, transcript paths and CLI
            // resume IDs are never accepted from another device.
            return row("agent_sessions", ["id": session, "course_id": course, "title": p["title"] ?? null, "provider": provider, "model": p["model"] ?? null, "access_policy": p["workspace"] is [String: Any] ? try F.canonical(policy) : old?["access_policy"] ?? null, "surface": surface, "effort": p["reasoningEffort"] ?? null, "status": old?["status"] ?? "idle", "last_used_at": p["lastUsedAt"] ?? null, "created_at": p["createdAt"] ?? now, "updated_at": now, "deleted_at": tombstone], courseID: course)
        case "chat" where p["recordType"] as? String == "desktop-chat-message":
            let message = try id("chat:message:"), course = try requiredCourse(p["courseID"], deleted: deleted), sessionID = try F.identity(p["sessionID"])
            guard let session = try context.query("SELECT * FROM agent_sessions WHERE id=?", [sessionID]).first, session["course_id"] as? String == course,
                  deleted || !isDeleted(session), let role = p["role"] as? String, ["user", "assistant"].contains(role), let blocks = p["blocks"] as? [[String: Any]] else { throw C.validation("Invalid chat message") }
            guard session["status"] as? String != "running" else { throw C.conflict("The conversation is active on this device") }
            if let old = try context.query("SELECT course_id,session_id FROM messages WHERE id=?", [message]).first, old["course_id"] as? String != course || old["session_id"] as? String != sessionID { throw C.conflict("Message identity belongs to another conversation") }
            let sequence = try integer(p["turnSequence"])
            let imageAssets = blocks.compactMap { ($0["payload"] as? [String: Any])?["imageAsset"] as? [String: Any] }
            guard imageAssets.count <= 6, try imageAssets.reduce(0, { try $0 + integer($1["byteCount"]) }) <= 21_000_000 else { throw C.validation("Chat attachment image budget exceeded") }
            var ids = Set<String>(), orders = Set<Int>(), values: [[String: Any]] = []
            var attachmentFiles: [NativeSyncFileChange] = []
            for block in blocks {
                let blockID = try F.identity(block["id"]), order = try integer(block["order"]), blockKind = try string(block["kind"], "chat block kind")
                guard ids.insert(blockID).inserted, orders.insert(order).inserted else { throw C.validation("Duplicate chat block identity or order") }
                if let existing = try context.query("SELECT message_id FROM message_blocks WHERE id=?", [blockID]).first, existing["message_id"] as? String != message { throw C.conflict("Chat block belongs to another message") }
                var payload = block["payload"] ?? null
                if blockKind == "attachment", var capture = payload as? [String: Any], let asset = capture["imageAsset"] as? [String: Any] {
                    guard let type = asset["contentType"] as? String, ["image/png","image/jpeg","image/webp","image/gif"].contains(type) else { throw C.validation("Invalid attachment image type") }
                    let url = try verifiedAsset(asset["sha256"],byteCount:asset["byteCount"],assets:assets,limit:21_000_000)
                    let bytes = try Data(contentsOf:url), hash = F.hash(bytes)
                    guard hash == asset["sha256"] as? String else { throw C.validation("Attachment image changed during import") }
                    capture.removeValue(forKey:"imageAsset"); capture["imageDataURL"] = "data:" + type + ";base64," + bytes.base64EncodedString()
                    _ = try NativeAssistantPayload.validatedAttachments([capture])
                    attachmentFiles.append(.init(target:NativeAssistantPayload.assetURL(root:context.root,hash:hash,mediaType:type),data:bytes))
                    payload = capture
                }
                values.append(["id": blockID, "message_id": message, "ord": order, "kind": blockKind, "payload_json": try F.canonical(payload), "created_at": block["createdAt"] ?? now, "updated_at": block["updatedAt"] ?? now, "deleted_at": block["deletedAt"] ?? null])
            }
            return NativeSyncPlan(files: attachmentFiles, courseID: course, apply: { [context] in
                try F.upsert(context, table: "messages", values: ["id": message, "course_id": course, "session_id": sessionID, "role": role, "turn_seq": sequence, "created_at": p["createdAt"] ?? now, "updated_at": p["updatedAt"] ?? now, "deleted_at": tombstone])
                try context.run("DELETE FROM message_blocks WHERE message_id=?", [message])
                for value in values { try F.upsert(context, table: "message_blocks", values: value) }
            })
        case "recording": return try planRecording(record, assets: assets)
        case "artifact" where p["recordType"] as? String == "desktop-learning-project": return try planLearning(record, assets: assets)
        default: return nil // Opaque envelopes stay in the global projection store.
        }
    }

    private func appendRecordings(to snapshot: inout NativeSyncSnapshot) throws {
        let materials = try context.query("SELECT id,course_id,rel_path FROM materials_index WHERE deleted_at IS NULL")
        for row in try context.query("SELECT * FROM recording_sessions ORDER BY id") {
            let session = try F.object(row["payload"]), id = try F.identity(session["id"]), courseID = try F.identity(session["courseId"])
            guard let course = try context.query("SELECT * FROM courses WHERE id=?", [courseID]).first, !isDeleted(course), !["recording", "paused", "processing"].contains(session["status"] as? String ?? "") else { continue }
            let path = try context.materialURL(courseID: courseID, relativePath: string(session["audioRelPath"], "recording path")), asset = try F.asset(materialID: "recording:" + id, url: path, hash: context.contentHash(path))
            let previous = try prior("recording:" + id)?["segments"] as? [[String: Any]] ?? []
            let segments = try context.query("SELECT * FROM recording_segments WHERE session_id=? ORDER BY start_sample,id", [id]).map { row -> [String: Any] in
                let start = try integer(row["start_sample"]), end = try integer(row["end_sample"], min: start), text = try string(row["text"], "transcript", allowEmpty: true)
                let hash = try F.digest(["recording": id, "start": start, "end": end, "text": text]), time = Double(start) / 16000
                let stableID = previous.first { ($0["time"] as? NSNumber)?.doubleValue == time && $0["text"] as? String == text }?["id"] as? String ?? Self.segmentID(hash)
                return ["id": stableID, "time": time, "text": text, "endSample": end]
            }
            let anchors = try context.query("SELECT payload FROM recording_anchors WHERE session_id=? ORDER BY rowid", [id]).map { row -> [String: Any] in
                let anchor = try F.object(row["payload"]), relative = anchor["relPath"] as? String
                let materialID = materials.first { $0["course_id"] as? String == courseID && $0["rel_path"] as? String == relative }?["id"]
                return ["id": anchor["id"]!, "time": Double(try integer(anchor["sample"])) / 16000, "materialID": materialID ?? null, "page": anchor["page"] ?? null, "desktop": ["label": anchor["label"] ?? "표시", "relPath": relative as Any? ?? null]]
            }
            let payload: [String: Any] = ["id": id, "courseID": courseID, "title": session["title"] ?? "녹음", "fileName": "Recordings/\(id).wav", "createdAt": session["createdAt"]!, "duration": Double(try integer(session["samples"])) / 16000, "state": session["status"] as? String == "complete" ? "completed" : "interrupted", "segments": segments, "anchors": anchors, "assetRevision": asset["sha256"]!, "byteCount": asset["byteCount"]!, "desktop": ["session": session]]
            snapshot.records.append(F.record(id: "recording:" + id, kind: "recording", payload: payload)); snapshot.assets.append(asset)
            snapshot.sources["recording:" + id] = ["courseID": courseID, "path": path.path, "hash": asset["sha256"]!]
        }
    }

    private func planRecording(_ record: [String: Any], assets: [String: URL]) throws -> NativeSyncPlan {
        let p = record["payload"] as! [String: Any], id = try F.identity(p["id"]), courseID = try requiredCourse(p["courseID"], deleted: false), now = C.nowISO
        guard record["id"] as? String == "recording:" + id, p["fileName"] as? String == "Recordings/\(id).wav" else { throw C.validation("Invalid recording identity") }
        guard record["deleted"] as? Bool != true else { throw C.conflict("Recording deletion requires explicit local removal; original audio retained") }
        let old = try context.query("SELECT payload FROM recording_sessions WHERE id=?", [id]).first.map { try F.object($0["payload"]) }
        if let old {
            guard old["courseId"] as? String == courseID else { throw C.conflict("Recording identity belongs to another course") }
            guard !["recording", "paused", "processing"].contains(old["status"] as? String ?? "") else { throw C.conflict("Recording is active on this device") }
        }
        let source = try verifiedAsset(p["assetRevision"], byteCount: p["byteCount"], assets: assets)
        let audio = try NativeSyncRecordingAudio.read(source)
        guard audio.originalHash == p["assetRevision"] as? String else { throw C.conflict("Recording source changed while importing") }
        let desktop = p["desktop"] as? [String: Any] ?? [:], remoteSession = desktop["session"] as? [String: Any] ?? [:]
        let relative = try string(old?["audioRelPath"] ?? remoteSession["audioRelPath"] ?? "녹음/\(id)/audio.wav", "recording path")
        let target = try context.materialURL(courseID: courseID, relativePath: relative, allowMissing: true)
        // A remote session cannot replace another recording or an unrelated file.
        let owner = try context.query("SELECT id FROM recording_sessions WHERE course_id=? AND json_extract(payload,'$.audioRelPath')=? AND id<>?", [courseID, relative, id])
        guard owner.isEmpty else { throw C.conflict("Recording audio belongs to another session") }
        if old == nil && context.files.fileExists(atPath: target.path), try F.hash(target) != F.hash(audio.data) { throw C.conflict("Recording path already contains a different original") }
        guard let segments = p["segments"] as? [[String: Any]] ?? (p["segments"] == nil ? [] : nil), let anchors = p["anchors"] as? [[String: Any]] ?? (p["anchors"] == nil ? [] : nil) else { throw C.validation("Invalid recording transcript or anchors") }
        var session = remoteSession
        session.merge(["id": id, "courseId": courseID, "title": try string(p["title"], "recording title", allowEmpty: true), "modelId": remoteSession["modelId"] ?? "zipformer-ko", "createdAt": p["createdAt"] ?? now, "status": p["state"] as? String == "completed" ? "complete" : "interrupted", "audioRelPath": relative, "samples": audio.samples, "transcribedSamples": segments.isEmpty ? 0 : audio.samples, "nextSequence": remoteSession["nextSequence"] ?? 0, "error": remoteSession["error"] ?? null]) { _, new in new }
        var transcriptRows: [[Any]] = [], ranges = Set<String>()
        for (index, segment) in segments.enumerated() {
            let time = try finite(segment["time"]), start = sample(time, count: audio.samples)
            let end = try present(segment["endSample"]).map { min(audio.samples, try integer($0, min: start)) } ?? sample(index + 1 < segments.count ? finite(segments[index + 1]["time"]) : Double(audio.samples) / 16000, count: audio.samples)
            guard end >= start, ranges.insert("\(start):\(end)").inserted else { throw C.validation("Invalid or duplicate recording transcript range") }
            transcriptRows.append([id, start, end, try string(segment["text"], "transcript", allowEmpty: true)])
        }
        var anchorRows: [[String: Any]] = [], anchorIDs = Set<String>()
        for anchor in anchors {
            let anchorID = try F.identity(anchor["id"])
            guard anchorIDs.insert(anchorID).inserted else { throw C.validation("Duplicate recording anchor") }
            if let owner = try context.query("SELECT session_id FROM recording_anchors WHERE id=?", [anchorID]).first, owner["session_id"] as? String != id { throw C.conflict("Recording anchor belongs to another session") }
            var relative: Any = null
            if let materialID = present(anchor["materialID"]) {
                guard let material = try context.query("SELECT * FROM materials_index WHERE id=? AND deleted_at IS NULL", [F.identity(materialID)]).first, material["course_id"] as? String == courseID else { throw C.validation("Recording anchor crosses a course boundary or references a missing material") }
                relative = material["rel_path"]!
            }
            let detail = anchor["desktop"] as? [String: Any] ?? [:]
            let value: [String: Any] = ["id": anchorID, "sample": sample(try finite(anchor["time"]), count: audio.samples), "label": detail["label"] ?? "표시", "relPath": relative, "page": try present(anchor["page"]).map { try integer($0, min: 1) } as Any? ?? null]
            anchorRows.append(["id": anchorID, "session_id": id, "payload": try F.canonical(value)])
        }
        let serialized = try F.canonical(session)
        return NativeSyncPlan(files: [NativeSyncFileChange(target: target, data: audio.data)], source: ["courseID": courseID, "path": target.path, "hash": p["assetRevision"]!], courseID: courseID, apply: { [context] in
            try F.upsert(context, table: "recording_sessions", values: ["id": id, "course_id": courseID, "created_at": session["createdAt"]!, "payload": serialized])
            try context.run("DELETE FROM recording_segments WHERE session_id=?", [id]); try context.run("DELETE FROM recording_anchors WHERE session_id=?", [id])
            for values in transcriptRows { try context.run("INSERT INTO recording_segments(session_id,start_sample,end_sample,text) VALUES(?,?,?,?)", values) }
            for values in anchorRows { try F.upsert(context, table: "recording_anchors", values: values) }
        })
    }

    private func prior(_ id: String) throws -> [String: Any]? {
        guard try context.tableExists("ipad_sync_projection"), let row = try context.query("SELECT payload_json FROM ipad_sync_projection WHERE id=?", [id]).first else { return nil }; return try F.object(row["payload_json"])
    }
    private func requiredCourse(_ value: Any?, deleted: Bool) throws -> String {
        let id = try F.identity(value)
        guard let row = try context.query("SELECT id,deleted_at FROM courses WHERE id=?", [id]).first, deleted || !isDeleted(row) else { throw C.validation("Sync course is unavailable") }; return id
    }
    private func optionalCourse(_ value: Any?, deleted: Bool) throws -> String? { try present(value).map { try requiredCourse($0, deleted: deleted) } }
    private func verifiedAsset(_ value: Any?, byteCount: Any?, assets: [String: URL], limit: Int = Int.max) throws -> URL {
        guard let hash = value as? String, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, let url = assets[hash] else { throw C.validation("Verified sync asset is unavailable") }
        let identity = try C.identity(url)
        guard identity["directory"] as? Bool == false, let size = Int(identity["size"] as? String ?? ""), size <= limit, try F.hash(url) == hash, try C.sameIdentity(identity, C.identity(url)) else { throw C.validation("Sync asset hash or size mismatch") }
        if let byteCount = present(byteCount), try integer(byteCount) != size { throw C.validation("Sync asset size mismatch") }
        return url
    }
    private func isDeleted(_ row: [String: Any]) -> Bool { present(row["deleted_at"]) != nil }
    private func present(_ value: Any?) -> Any? { value is NSNull ? nil : value }
    private func string(_ value: Any?, _ name: String, allowEmpty: Bool = false) throws -> String { try C.requireString(value, name, allowEmpty: allowEmpty) }
    private func integer(_ value: Any?, min: Int = 0) throws -> Int { try NativeValue.int(value, "sync integer", min: min) }
    private func finite(_ value: Any?) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { throw C.validation("Invalid recording time") }; return number.doubleValue
    }
    private func sample(_ time: Double, count: Int) -> Int { time >= Double(count) / 16000 ? count : Int((time * 16000).rounded()) }
    private static func segmentID(_ hash: String) -> String {
        let chars = Array(hash)
        return String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-4" + String(chars[13..<16]) + "-a" + String(chars[17..<20]) + "-" + String(chars[20..<32])
    }
}

/// Exact WAV conversion preserves original sample indices used by transcript
/// and PDF anchors. Unsupported audio is retained as a sync conflict.
enum NativeSyncRecordingAudio {
    static func read(_ url: URL) throws -> (data: Data, samples: Int, originalHash: String) {
        let identity = try NativeRepositoryContext.identity(url)
        let source = try Data(contentsOf: url, options: .mappedIfSafe)
        func fail() -> DesktopRuntimeError { NativeRepositoryContext.validation("Unsupported or incomplete recording WAV") }
        guard source.count >= 44 else { throw fail() }
        func text(_ offset: Int, _ count: Int) -> String { String(decoding: source[offset..<offset + count], as: UTF8.self) }
        func u16(_ offset: Int) -> UInt16 { UInt16(source[offset]) | UInt16(source[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 { UInt32(source[offset]) | UInt32(source[offset + 1]) << 8 | UInt32(source[offset + 2]) << 16 | UInt32(source[offset + 3]) << 24 }
        guard text(0, 4) == "RIFF", text(8, 8) == "WAVEfmt ", u32(16) == 16, text(36, 4) == "data", u16(22) == 1, u32(24) == 16000 else { throw fail() }
        let float = u16(20) == 3 && u16(34) == 32, pcm = u16(20) == 1 && u16(34) == 16, bytes = float ? 4 : 2
        guard float || pcm, (source.count - 44) % bytes == 0, Int(u32(40)) == source.count - 44, UInt64(u32(4)) + 8 == source.count else { throw fail() }
        let samples = (source.count - 44) / bytes
        guard samples <= 24 * 3600 * 16000 else { throw fail() }
        let hash = NativeSyncFormat.hash(source)
        if pcm {
            guard try NativeRepositoryContext.sameIdentity(identity, NativeRepositoryContext.identity(url)) else { throw fail() }
            return (source, samples, hash)
        }
        var result = Data(); result.reserveCapacity(44 + samples * 2)
        func append16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        func append32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        result.append(contentsOf: "RIFF".utf8); append32(UInt32(36 + samples * 2)); result.append(contentsOf: "WAVEfmt ".utf8); append32(16)
        append16(1); append16(1); append32(16000); append32(32000); append16(2); append16(16); result.append(contentsOf: "data".utf8); append32(UInt32(samples * 2))
        for index in 0..<samples {
            let value = Float(bitPattern: u32(44 + index * 4)); guard value.isFinite else { throw fail() }
            let clamped = min(1, max(-1, Double(value))), scaled = clamped * (clamped < 0 ? 32768 : 32767)
            // Match JavaScript Math.round, including the negative half case.
            let converted = Int16(floor(scaled + 0.5)); append16(UInt16(bitPattern: converted))
        }
        guard try NativeRepositoryContext.sameIdentity(identity, NativeRepositoryContext.identity(url)) else { throw fail() }
        return (result, samples, hash)
    }
}

private extension NativeSyncArtifacts {
    static let learningDirectory = ".bandal/learning"
    static let maximumLearningFileBytes = 64 * 1024 * 1024
    static func allowedLearningPath(_ value: String) -> Bool {
        value.range(of: #"^(?:manifest|state)\.json$|^(?:articles|artifacts|results)/[a-zA-Z0-9_-]+\.json$"#, options: .regularExpression) != nil
    }
    func appendLearning(to snapshot: inout NativeSyncSnapshot) throws {
        var projectIDs = Set<String>()
        for course in try context.query("SELECT id FROM courses WHERE deleted_at IS NULL ORDER BY id") {
            let courseID = course["id"] as! String, folder = try context.courseFolder(courseID)
            var roots: [URL] = []
            // Do not follow directory symlinks. The repository path resolver
            // checks real containment again for each discovered source.
            guard let enumerator = context.files.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, _ in false }) else { throw C.validation("Learning course directory is unavailable") }
            while let entry = enumerator.nextObject() as? URL {
                let resource = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if resource.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if resource.isDirectory == true && entry.lastPathComponent == ".bandal" {
                    let project = entry.deletingLastPathComponent(), learning = entry.appendingPathComponent("learning")
                    if context.files.fileExists(atPath: learning.appendingPathComponent("manifest.json").path) { roots.append(project) }
                    enumerator.skipDescendants()
                }
            }
            for root in roots.sorted(by: { $0.path < $1.path }) {
                let relative = root == folder ? "" : String(root.path.dropFirst(folder.path.count + 1))
                _ = try context.resolve(in: folder, relativePath: relative, allowRoot: true)
                let learning = try context.resolve(in: root, relativePath: Self.learningDirectory)
                let manifestURL = try context.resolve(in: learning, relativePath: "manifest.json"), stateURL = try context.resolve(in: learning, relativePath: "state.json")
                let manifest = try jsonFile(manifestURL), state = try jsonFile(stateURL), projectID = try F.identity(manifest["projectId"])
                guard manifest["format"] as? String == "bandal-learning", (manifest["formatVersion"] as? NSNumber)?.intValue == 1, state["projectId"] as? String == projectID, projectIDs.insert(projectID).inserted else { throw C.conflict("Learning project identities conflict") }
                var paths = ["manifest.json", "state.json"]
                for child in ["articles", "artifacts", "results"] {
                    let directory = try context.resolve(in: learning, relativePath: child)
                    if !context.files.fileExists(atPath: directory.path) { continue }
                    for file in try context.files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []) {
                        let path = child + "/" + file.lastPathComponent
                        if Self.allowedLearningPath(path) { paths.append(path) }
                    }
                }
                var files: [[String: Any]] = []
                for path in paths.sorted() {
                    let url = try context.resolve(in: learning, relativePath: path)
                    var asset = try F.asset(materialID: "artifact:learning-file:\(projectID):\(F.digest(path))", url: url, hash: context.contentHash(url))
                    guard try integer(asset["byteCount"]) <= Self.maximumLearningFileBytes else { throw C.validation("Learning source exceeds original supported size") }
                    let recordID = asset["materialID"] as! String
                    asset["contentType"] = "application/json"
                    let payload: [String: Any] = ["recordType": "desktop-learning-file", "courseID": courseID, "projectID": projectID, "relPath": path, "assetRevision": asset["sha256"]!, "byteCount": asset["byteCount"]!, "fileName": url.lastPathComponent, "contentType": "application/json"]
                    snapshot.records.append(F.record(id: recordID, kind: "artifact", payload: payload)); snapshot.assets.append(asset)
                    snapshot.sources[recordID] = ["path": url.path, "hash": asset["sha256"]!, "courseID": courseID]
                    files.append(["recordID": recordID, "relPath": path, "assetRevision": asset["sha256"]!, "byteCount": asset["byteCount"]!])
                }
                let projectRecordID = "artifact:learning-project:" + projectID
                snapshot.records.append(F.record(id: projectRecordID, kind: "artifact", payload: ["recordType": "desktop-learning-project", "id": projectID, "courseID": courseID, "rootRelPath": relative, "stateRevision": state["revision"] ?? 0, "files": files]))
                snapshot.sources[projectRecordID] = ["courseID": courseID, "root": root.path]
            }
        }
    }

    func planLearning(_ record: [String: Any], assets: [String: URL]) throws -> NativeSyncPlan? {
        let p = record["payload"] as! [String: Any], projectID = try F.identity(p["id"])
        guard record["id"] as? String == "artifact:learning-project:" + projectID, record["deleted"] as? Bool != true,
              let files = p["files"] as? [[String: Any]], files.count <= 100_000 else { throw C.validation("Unsupported learning project sync format") }
        let courseID = try requiredCourse(p["courseID"], deleted: false), relative = try string(p["rootRelPath"], "learning root", allowEmpty: true)
        let folder = try context.courseFolder(courseID), root = try context.resolve(in: folder, relativePath: relative, allowRoot: true)
        let learning = try context.resolve(in: root, relativePath: Self.learningDirectory)
        let prior = try prior(record["id"] as! String), previousFiles = prior?["files"] as? [[String: Any]] ?? []
        if let prior, prior["courseID"] as? String != courseID || prior["rootRelPath"] as? String != relative { throw C.conflict("Learning project belongs to another location") }
        let manifestURL = try context.resolve(in: learning, relativePath: "manifest.json")
        if context.files.fileExists(atPath: manifestURL.path) {
            let old = try jsonFile(manifestURL)
            guard old["projectId"] as? String == projectID else { throw C.conflict("Learning folder contains another project") }
        }
        var changes: [NativeSyncFileChange] = [], paths = Set<String>(), manifest: [String: Any]?, state: [String: Any]?
        for item in files {
            let path = try string(item["relPath"], "learning file path")
            guard Self.allowedLearningPath(path), paths.insert(path).inserted, item["recordID"] as? String == "artifact:learning-file:\(projectID):\(try F.digest(path))" else { throw C.validation("Invalid learning project file") }
            let source = try verifiedAsset(item["assetRevision"], byteCount: item["byteCount"], assets: assets, limit: Self.maximumLearningFileBytes)
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard F.hash(data) == item["assetRevision"] as? String else { throw C.conflict("Learning source changed while importing") }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw C.validation("Learning source is not a JSON object") }
            if path == "manifest.json" { manifest = object }; if path == "state.json" { state = object }
            let target = try context.resolve(in: learning, relativePath: path)
            if context.files.fileExists(atPath: target.path) {
                let hash = try F.hash(target)
                if hash == item["assetRevision"] as? String { continue }
                if let priorFile = previousFiles.first(where: { $0["relPath"] as? String == path }) {
                    guard hash == priorFile["assetRevision"] as? String else { throw C.conflict("Learning source changed while importing") }
                } else { throw C.conflict("A learning source already exists without a sync baseline") }
            }
            changes.append(NativeSyncFileChange(target: target, data: data))
        }
        guard let manifest, let state, manifest["format"] as? String == "bandal-learning", (manifest["formatVersion"] as? NSNumber)?.intValue == 1,
              manifest["projectId"] as? String == projectID, state["projectId"] as? String == projectID,
              (state["schemaVersion"] as? NSNumber)?.intValue == 1, try integer(state["revision"]) == integer(p["stateRevision"]) else { throw C.validation("Learning manifest and state identity mismatch") }
        // Files are opaque artifacts in this app. Preserve every field, and
        // publish state last so another reader never sees an incomplete bundle.
        changes.sort { a, b in
            if a.target.lastPathComponent == "state.json" { return false }
            if b.target.lastPathComponent == "state.json" { return true }
            return a.target.path < b.target.path
        }
        return NativeSyncPlan(files: changes, source: ["courseID": courseID, "root": root.path], courseID: courseID)
    }
    func jsonFile(_ url: URL) throws -> [String: Any] {
        let info = try C.identity(url)
        guard info["directory"] as? Bool == false, let size = Int(info["size"] as? String ?? ""), size <= Self.maximumLearningFileBytes,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url, options: .mappedIfSafe)) as? [String: Any] else { throw C.validation("Invalid learning source") }; return value
    }
}
