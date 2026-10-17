import Foundation
import PDFKit

/// Imports the first iPad format without modifying its database or assets.
/// Published copies are verified before a single transaction installs rows and
/// a receipt. Retrying after interruption reuses only identical copies.
enum NativeLegacyMigration {
    private typealias C = NativeRepositoryContext
    private typealias F = NativeSyncFormat
    private typealias V = NativePDFRepositoryValidation
    private static let version = "native-to-desktop-v1"
    private struct Row { let table: String; let values: [String: Any] }
    private struct File { let target: URL; let source: URL?; let bytes: Data?; let hash: String }
    private struct Material { let payload: [String: Any]; let relative: String; let target: URL }

    static func apply(context c: NativeRepositoryContext, library: NativeLibraryRepository, pdf: NativePDFRepository) throws {
        try c.db.exec("CREATE TABLE IF NOT EXISTS ipad_legacy_archive(record_id TEXT PRIMARY KEY,kind TEXT NOT NULL,payload_json TEXT NOT NULL,envelope_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS ipad_legacy_migrations(version TEXT PRIMARY KEY,report_json TEXT NOT NULL)")
        if try c.query("SELECT 1 FROM ipad_legacy_migrations WHERE version=?", [version]).isEmpty {
            try migrate(c)
        }
        try restoreNavigation(c)
    }

    private static func snapshot(_ c: C) throws -> [String: Any] {
        let source = c.legacyRoot.appendingPathComponent("bandal.sqlite")
        var records: [[String: Any]] = [], receipts = Set<String>()
        if c.files.fileExists(atPath: source.path) {
            let old = try DesktopSQLite(url: source, readOnly: true)
            if try !old.query("SELECT 1 FROM sqlite_master WHERE type='table' AND name='local_mutation_receipts'", params: nil).isEmpty {
                receipts = Set(try old.query("SELECT mutation_id FROM local_mutation_receipts", params: nil).compactMap { $0["mutation_id"] as? String })
            }
            records = try old.query("SELECT id,kind,payload,revision,deleted,format_version AS formatVersion FROM records ORDER BY id", params: nil).map { row in
                var row = row
                guard let value = row["payload"] as? [String: String], let text = value["__buffer"], let data = Data(base64Encoded: text) else { throw fail("이전 자료의 본문을 읽지 못했습니다.") }
                row["payload"] = try DesktopJSON.decode(data); return row
            }
        }
        let directory = c.legacyRoot.appendingPathComponent("PendingEdits")
        let urls = c.files.fileExists(atPath: directory.path) ? try c.files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) : []
        let pending = try urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> [String: Any]? in
            guard var entry = try DesktopJSON.decode(Data(contentsOf: url)) as? [String: Any], let encoded = entry["payload"] as? String, let bytes = Data(base64Encoded: encoded) else { throw fail("이전 저장 대기 기록을 읽지 못했습니다.") }
            if let mutation = entry["mutationID"] as? String, receipts.contains(mutation) { return nil }
            entry["payload"] = try DesktopJSON.decode(bytes); entry["fileName"] = url.lastPathComponent; return entry
        }
        return ["records": records, "pending": pending]
    }

    private static func migrate(_ c: C) throws {
        let source = try snapshot(c)
        var selected: [String: [String: Any]] = [:]
        for record in source["records"] as? [[String: Any]] ?? [] {
            let id = try V.string(record["id"], "legacy identity")
            guard selected[id] == nil else { throw fail("이전 자료의 식별자가 중복됩니다.") }; selected[id] = record
        }
        for var record in source["pending"] as? [[String: Any]] ?? [] {
            let id = try V.string(record["id"], "legacy identity")
            record["formatVersion"] = 1; record["revision"] = 0; record["deleted"] = false; selected[id] = record
        }
        let records = selected.keys.sorted().map { selected[$0]! }
        guard !records.isEmpty else { return }
        for record in records {
            guard (record["formatVersion"] as? NSNumber)?.intValue == 1, record["payload"] is [String: Any], record["kind"] is String else { throw fail("지원하지 않는 이전 자료 형식입니다.") }
        }
        let archive = Data(try NativeValue.json(source).utf8), sourceHash = F.hash(archive)
        let recovery = c.root.appendingPathComponent("MigrationRecovery/" + sourceHash)
        try c.files.createDirectory(at: recovery, withIntermediateDirectories: true)
        try publish(File(target: recovery.appendingPathComponent("legacy-snapshot.json"), source: nil, bytes: archive, hash: sourceHash), c)
        let live = records.filter { ($0["deleted"] as? NSNumber)?.boolValue != true }
        func of(_ kind: String) -> [[String: Any]] { live.filter { $0["kind"] as? String == kind }.map { $0["payload"] as! [String: Any] } }
        let now = NativeValue.now(), milliseconds = Date().timeIntervalSince1970 * 1000, null = NSNull()
        var rows: [Row] = [], courses: [String: URL] = [:], materials: [String: Material] = [:], folders: [String: (String, String)] = [:], files: [File] = [], occupied = Set<String>()
        func add(_ table: String, _ values: [String: Any]) { rows.append(Row(table: table, values: values)) }
        func available(_ course: String, _ directory: String, _ proposed: String) throws -> String {
            let proposed = try name(proposed), ext = (proposed as NSString).pathExtension
            let suffix = ext.isEmpty ? "" : "." + ext, stem = String(proposed.dropLast(suffix.count))
            for index in 1...10_000 {
                let file = index == 1 ? proposed : "\(stem) (\(index))\(suffix)", relative = directory.isEmpty ? file : directory + "/" + file
                if occupied.insert(course + "/" + relative.precomposedStringWithCanonicalMapping.lowercased()).inserted { return relative }
            }
            throw fail("이전 파일 이름의 중복을 해결하지 못했습니다.")
        }
        for p in of("course") {
            let id = try uuid(p["id"]), title = try V.string(p["name"], "course name")
            guard courses[id] == nil, try c.query("SELECT id FROM courses WHERE id=?", [id]).isEmpty else { throw fail("이전 과목의 식별자가 이미 사용 중입니다.") }
            let folder = try c.resolve(in: c.root, relativePath: "Courses/iPad/" + id)
            try c.files.createDirectory(at: folder, withIntermediateDirectories: true); courses[id] = folder
            add("courses", ["id":id,"name":title,"slug":"ipad-"+id,"color":p["color"] ?? "green","folder_path":folder.path,"source":"managed","workspace_kind":"course","archived":0,"group_id":null,"sort_order":courses.count-1,"created_at":now,"updated_at":now,"deleted_at":null])
        }
        for p in of("artifact") where p["recordType"] as? String == "material-folder" {
            let id = try uuid(p["id"]), course = try uuid(p["courseID"])
            guard let root = courses[course], folders[id] == nil else { throw fail("이전 자료 폴더의 과목이나 식별자가 잘못되었습니다.") }
            let relative = try available(course, "", name(p["title"]))
            folders[id] = (course, relative); try c.files.createDirectory(at: c.resolve(in: root, relativePath: relative), withIntermediateDirectories: true)
        }
        for p in of("material") {
            let id = try uuid(p["id"]), course = try uuid(p["courseID"]), fileName = try name(p["fileName"]), kind = try V.string(p["kind"], "material kind")
            guard let root = courses[course], materials[id] == nil else { throw fail("이전 자료의 과목이나 식별자가 잘못되었습니다.") }
            var directory = ""
            if let folderID = p["folderID"] as? String {
                guard let folder = folders[folderID], folder.0 == course else { throw fail("이전 자료 폴더를 찾지 못했습니다.") }; directory = folder.1
            }
            let visible = kind == "note" ? try name(p["title"]).replacingOccurrences(of: "(?i)\\.md$", with: "", options: .regularExpression) + ".md" : fileName
            let relative = try available(course, directory, visible), target = try c.resolve(in: root, relativePath: relative)
            materials[id] = Material(payload:p,relative:relative,target:target)
            if kind == "whiteboard" {
                add("whiteboards", ["id":id,"course_id":course,"title":p["title"] ?? fileName,"sort_order":materials.count-1,"created_at":p["createdAt"] ?? now,"updated_at":now,"deleted_at":null,"background":"blank","surface":"light","page_count":1,"added_at":milliseconds]); continue
            }
            let file: File, count: Int
            if kind == "note" {
                guard let record = selected["note:" + id], (record["deleted"] as? NSNumber)?.boolValue != true, let note = record["payload"] as? [String: Any], let markdown = note["markdown"] as? String else { throw fail("이전 노트 본문이 없습니다.") }
                let bytes = Data(markdown.utf8); count = bytes.count; file = File(target:target,source:nil,bytes:bytes,hash:F.hash(bytes))
            } else {
                let revision = try V.digest(p["revision"])
                let versioned = try c.resolve(in:c.legacyRoot,relativePath:"Materials/\(id)/\(F.hash(Data(revision.utf8)))/\(fileName)")
                let old = try c.resolve(in:c.legacyRoot,relativePath:"Materials/\(id)/\(fileName)")
                let url = c.files.fileExists(atPath:versioned.path) ? versioned : old
                count = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard p["byteCount"] == nil || (p["byteCount"] as? NSNumber)?.intValue == count, try F.hash(url) == revision else { throw fail("이전 자료의 원본 해시가 일치하지 않습니다.") }
                file = File(target:target,source:url,bytes:nil,hash:revision)
            }
            files.append(file)
            add("materials_index", ["id":id,"course_id":course,"rel_path":relative,"kind":kind == "file" ? "other" : kind,"size":count,"mtime":milliseconds,"created_at":p["createdAt"] ?? now,"updated_at":now,"deleted_at":null])
        }
        for file in files { try publish(file,c) }
        var recordingCount = 0
        for p in of("recording") {
            let id = try uuid(p["id"]), course = try uuid(p["courseID"])
            guard let folder = courses[course], p["fileName"] as? String == "Recordings/\(id).wav" else { throw fail("이전 녹음 경로가 잘못되었습니다.") }
            let source = try c.resolve(in:c.legacyRoot,relativePath:"Recordings/\(id).wav"), hash = try F.hash(source)
            let size = try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard p["assetRevision"] == nil || p["assetRevision"] as? String == hash, p["byteCount"] == nil || (p["byteCount"] as? NSNumber)?.intValue == size else { throw fail("이전 녹음 원본이 변경되었습니다.") }
            let relative = try available(course,"녹음",name(p["title"])) + "/audio.wav"
            let samples = try NativeLegacyAudio.copy(source:source,target:c.resolve(in:folder,relativePath:relative),context:c)
            let segments = (p["segments"] as? [[String:Any]] ?? []).sorted { ($0["time"] as? NSNumber)?.doubleValue ?? 0 < ($1["time"] as? NSNumber)?.doubleValue ?? 0 }
            let session: [String:Any] = ["id":id,"courseId":course,"title":p["title"] ?? "녹음","modelId":"zipformer-ko","createdAt":p["createdAt"] ?? now,"status":p["state"] as? String == "completed" ? "complete" : "interrupted","audioRelPath":relative,"samples":samples,"transcribedSamples":segments.isEmpty ? 0 : samples,"nextSequence":0,"error":null]
            add("recording_sessions",["id":id,"course_id":course,"created_at":session["createdAt"]!,"payload":try NativeValue.json(session)])
            func sample(_ value: Any?) throws -> Int { let time = try V.number(value,"recording time",min:0); return time >= Double(samples)/16000 ? samples : Int(floor(time * 16000 + 0.5)) }
            for (index,segment) in segments.enumerated() {
                let start = try sample(segment["time"]), end = index+1 < segments.count ? try sample(segments[index+1]["time"]) : samples
                add("recording_segments",["session_id":id,"start_sample":start,"end_sample":max(start,end),"text":try V.string(segment["text"],"transcript")])
            }
            for anchor in p["anchors"] as? [[String:Any]] ?? [] {
                guard let target = materials[try uuid(anchor["materialID"])], target.payload["courseID"] as? String == course else { throw fail("이전 녹음의 자료 연결을 찾지 못했습니다.") }
                let anchorID = try uuid(anchor["id"]), value: [String:Any] = ["id":anchorID,"sample":try sample(anchor["time"]),"label":target.payload["title"] ?? target.relative,"relPath":target.relative,"page":anchor["page"] ?? null]
                add("recording_anchors",["id":anchorID,"session_id":id,"payload":try NativeValue.json(value)])
            }
            recordingCount += 1
        }
        var objectCount = 0, highlightCount = 0, historicalPages = 0, used = Set<String>()
        for wrapper in of("drawing") {
            guard let encoded = wrapper["data"] as? String, let bytes = Data(base64Encoded:encoded), let page = try DesktopJSON.decode(bytes) as? [String:Any], let id = page["materialID"] as? String, let material = materials[id], (page["schemaVersion"] as? NSNumber)?.intValue == 1, page["coordinateSpace"] as? String == F.coordinateSpace else { throw fail("이전 필기 형식이나 자료를 찾지 못했습니다.") }
            let number = try V.integer(page["page"],"page")
            guard wrapper["materialID"] as? String == id, wrapper["documentRevision"] as? String == page["documentRevision"] as? String, (wrapper["page"] as? NSNumber)?.intValue == number else { throw fail("이전 필기 페이지 식별자가 일치하지 않습니다.") }
            guard material.payload["revision"] as? String == page["documentRevision"] as? String else { historicalPages += 1; continue }
            let geometry = try NativeSyncInkGeometry.validate(page["geometry"]), whiteboard = material.payload["kind"] as? String == "whiteboard"
            if !whiteboard {
                let pages = try NativeSyncInkGeometry.pages(material.target)
                guard number <= pages.count, NativeSyncInkGeometry.matches(geometry,pages[number-1]) else { throw fail("이전 PDF의 페이지 크기 또는 회전이 변경되었습니다.") }
            }
            let deleted = Set(page["deletedObjectIDs"] as? [String] ?? []), deletedHighlights = Set(page["deletedHighlightIDs"] as? [String] ?? [])
            guard let objects = page["objects"] as? [[String:Any]] else { throw fail("이전 필기 객체가 없습니다.") }
            for original in objects {
                let objectID = try V.id(original["id"])
                if deleted.contains(objectID) { continue }
                guard used.insert(objectID).inserted else { throw fail("이전 필기의 객체 식별자가 중복됩니다.") }
                var shape = try NativeSyncInkGeometry.shape(original,geometry:geometry,inverse:true)
                var data = try V.object(shape["data"],"shape data")
                for key in ["image", "clip"] {
                if var image = data[key] as? [String:Any], let assetID = image["assetId"] as? String {
                    guard let asset = materials[assetID], asset.payload["courseID"] as? String == material.payload["courseID"] as? String else { throw fail("이전 필기의 이미지 원본이 없습니다.") }
                    image["relPath"] = asset.relative; image.removeValue(forKey:"assetId"); image.removeValue(forKey:"storage"); data[key] = image; shape["data"] = data
                }
                }
                try NativeSyncInkGeometry.validateShape(shape)
                var value: [String:Any] = ["id":objectID,"kind":shape["kind"]!,"data_json":try NativeValue.json(data),"style_json":try NativeValue.json(shape["style"]!),"created_at":shape["createdAt"] ?? now,"updated_at":shape["updatedAt"] ?? now,"deleted_at":null,"page":number]
                if whiteboard { value["board_id"] = id } else { value["course_id"] = material.payload["courseID"]!; value["rel_path"] = material.relative }
                add(whiteboard ? "whiteboard_local_shapes" : "pdf_drawings",value); objectCount += 1
            }
            for highlight in page["highlights"] as? [[String:Any]] ?? [] {
                let id = try V.id(highlight["id"]); if deletedHighlights.contains(id) { continue }
                guard !whiteboard, let rects = highlight["rects"] as? [[String:Any]], used.insert(id).inserted else { throw fail("이전 강조 표시의 형식을 확인해 주세요.") }
                let transformed = try rects.map { try NativeSyncInkGeometry.box($0,rotation:geometry["rotation"] as! Int,inverse:true) }
                let anchor: [String:Any] = ["quote":highlight["quote"] ?? "","prefix":highlight["prefix"] ?? "","suffix":highlight["suffix"] ?? ""]
                add("annotations",["id":id,"course_id":material.payload["courseID"]!,"rel_path":material.relative,"page":number,"color":highlight["color"] ?? "yellow","rects_json":try NativeValue.json(transformed),"anchor_json":try NativeValue.json(anchor),"comment":highlight["comment"] ?? null,"created_at":highlight["createdAt"] ?? now,"updated_at":highlight["updatedAt"] ?? highlight["createdAt"] ?? now,"deleted_at":null]); highlightCount += 1
            }
        }
        for p in of("task") {
            let course = try uuid(p["courseID"]); guard courses[course] != nil else { throw fail("이전 일정의 과목이 없습니다.") }
            add("board_tasks",["id":try uuid(p["id"]),"course_id":course,"title":try V.string(p["title"],"task title"),"notes":"","status":(p["completed"] as? NSNumber)?.boolValue == true ? "done" : "todo","due_at":p["due"] ?? null,"start_at":null,"all_day":0,"kind":"task","color":"none","sort_order":0,"created_at":now,"updated_at":now,"deleted_at":null])
        }
        let projected: Set<String> = ["course","material","note","drawing","task","workspace","recording"]
        let archivedKinds = Set(live.compactMap { record -> String? in
            let kind = record["kind"] as! String, p = record["payload"] as! [String:Any]
            return projected.contains(kind) || kind == "artifact" && p["recordType"] as? String == "material-folder" ? nil : kind
        }).sorted()
        let report: [String:Any] = ["version":version,"sourceHash":sourceHash,"recoveryPath":recovery.path,"records":records.count,"courses":courses.count,"materials":materials.count,"objects":objectCount,"highlights":highlightCount,"recordings":recordingCount,"historicalPages":historicalPages,"archivedKinds":archivedKinds]
        try c.transaction {
            for record in records { try c.run("INSERT INTO ipad_legacy_archive VALUES(?,?,?,?)",[record["id"]!,record["kind"]!,try NativeValue.json(record["payload"]!),try NativeValue.json(record)]) }
            for row in rows {
                let keys = row.values.keys.sorted()
                try c.run("INSERT INTO \(row.table)(\(keys.joined(separator:","))) VALUES(\(keys.map { _ in "?" }.joined(separator:",")))",keys.map { row.values[$0]! })
            }
            guard (try c.query("SELECT COUNT(*) n FROM ipad_legacy_archive").first?["n"] as? NSNumber)?.intValue == records.count else { throw fail("이전 기록의 보존 검증에 실패했습니다.") }
            try c.run("INSERT INTO ipad_legacy_migrations VALUES(?,?)",[version,try NativeValue.json(report)])
        }
    }

    private static func publish(_ file: File, _ c: C) throws {
        try c.files.createDirectory(at: file.target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !c.files.fileExists(atPath: file.target.path) {
            // A crash during a large copy must never leave a partial final file
            // which would block a safe, identical retry forever.
            let temporary = file.target.deletingLastPathComponent().appendingPathComponent(".migration-" + UUID().uuidString)
            defer { try? c.files.removeItem(at: temporary) }
            if let source = file.source { try c.files.copyItem(at: source, to: temporary) }
            else { try file.bytes!.write(to: temporary, options: .withoutOverwriting) }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize(); try handle.close()
            guard try F.hash(temporary) == file.hash else { throw fail("이전 중 원본 파일이 변경되어 원본과 복사본을 보존했습니다.") }
            if !c.files.fileExists(atPath: file.target.path) { try c.files.moveItem(at: temporary, to: file.target); try c.syncDirectory(file.target.deletingLastPathComponent()) }
        }
        _ = try C.identity(file.target)
        guard try F.hash(file.target) == file.hash else { throw fail("이전 중 대상 파일이 변경되어 두 원본을 보존했습니다.") }
    }
    private static func uuid(_ value: Any?) throws -> String { try V.uuid(value,"legacy UUID") }
    private static func name(_ value: Any?) throws -> String {
        let name = try V.string(value,"legacy filename")
        guard name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { $0.value < 32 }) else { throw fail("이전 파일 이름이 안전하지 않습니다.") }; return name
    }
    private static func fail(_ message: String) -> DesktopRuntimeError { DesktopRuntimeError(message,code:"MIGRATION_REQUIRED") }
}

private extension NativeLegacyMigration {
    private static func restoreNavigation(_ c: C) throws {
        let navigation = c.root.appendingPathComponent("native-workspace.json"), selection = c.root.appendingPathComponent("native-workspace-selection.json")
        guard !c.files.fileExists(atPath:navigation.path) || !c.files.fileExists(atPath:selection.path) else { return }
        var documents: [[String:Any]] = [], ids: [String:String] = [:], active: String?, companion: String?, course: String?
        if let raw = try c.query("SELECT payload_json FROM ipad_legacy_archive WHERE record_id='workspace:ipad'").first?["payload_json"] as? String,
           let workspace = try DesktopJSON.decode(Data(raw.utf8)) as? [String:Any] {
            course = workspace["selectedCourseID"] as? String
            for tab in workspace["tabs"] as? [[String:Any]] ?? [] {
                guard let materialID = tab["materialID"] as? String, let row = try c.query("SELECT * FROM materials_index WHERE id=? AND deleted_at IS NULL",[materialID]).first,
                      let courseID = row["course_id"] as? String, courseID == tab["courseID"] as? String, let path = row["rel_path"] as? String else { continue }
                let id = courseID + ":" + path
                if !documents.contains(where: { $0["courseID"] as? String == courseID && $0["relativePath"] as? String == path }) { documents.append(["courseID":courseID,"relativePath":path,"title":(path as NSString).lastPathComponent,"kind":row["kind"] ?? "other"]) }
                if let tabID = tab["id"] as? String { ids[tabID] = id }
            }
            active = (workspace["primaryID"] as? String).flatMap { ids[$0] }
            if workspace["splitEnabled"] as? Bool == true { companion = (workspace["secondaryID"] as? String).flatMap { ids[$0] } }
            if workspace["focusedPane"] as? String == "secondary", companion != nil { swap(&active,&companion) }
        }
        if course == nil, let bytes = try? Data(contentsOf:c.root.appendingPathComponent("settings.json")),
           let settings = try? DesktopJSON.decode(bytes) as? [String:Any] { course = settings["lastActiveCourseId"] as? String }
        if !documents.isEmpty && !c.files.fileExists(atPath:navigation.path) {
            try c.atomicWrite(Data(try NativeValue.json(["documents":documents,"activeID":active as Any? ?? NSNull(),"companionID":companion as Any? ?? NSNull()]).utf8),to:navigation)
        }
        if let course, try !c.query("SELECT id FROM courses WHERE id=? AND deleted_at IS NULL",[course]).isEmpty, !c.files.fileExists(atPath:selection.path) {
            try c.atomicWrite(Data(try NativeValue.json(["courseID":course]).utf8),to:selection)
        }
        // Reading positions are restored only for the exact PDF revision.
        for row in try c.query("SELECT payload_json FROM ipad_legacy_archive WHERE kind='artifact'") {
            guard let text = row["payload_json"] as? String, let p = try DesktopJSON.decode(Data(text.utf8)) as? [String:Any], p["recordType"] as? String == "reading-position", let id = p["materialID"] as? String,
                  let material = try c.query("SELECT * FROM materials_index WHERE id=? AND kind='pdf' AND deleted_at IS NULL",[id]).first, let courseID = material["course_id"] as? String, courseID == p["courseID"] as? String, let path = material["rel_path"] as? String,
                  let number = (p["page"] as? NSNumber)?.intValue, number > 0 else { continue }
            let url = try c.materialURL(courseID:courseID,relativePath:path)
            guard try F.hash(url) == p["documentRevision"] as? String, let pdf = PDFDocument(url:url), number <= pdf.pageCount else { continue }
            try c.run("INSERT OR IGNORE INTO pdf_view_state(course_id,rel_path,page,updated_at) VALUES(?,?,?,?)",[courseID,path,number,NativeValue.now()])
        }
    }
}
