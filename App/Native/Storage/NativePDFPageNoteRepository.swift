import Foundation
import PDFKit

/// Creates a portable page note and its link in one crash-recoverable commit.
final class NativePDFPageNoteRepository {
    let context: NativeRepositoryContext
    let pdf: NativePDFRepository
    init(context: NativeRepositoryContext, pdf: NativePDFRepository) { self.context = context; self.pdf = pdf }

    func source(_ request: [String: Any]) throws -> Any {
        let course = try NativeRepositoryContext.requireID(request["courseId"])
        let path = try NativeRepositoryContext.requireString(request["relPath"], "relPath")
        _ = try context.materialURL(courseID: course, relativePath: path)
        for row in try context.query("SELECT source_json,target_json FROM material_links WHERE kind='pdf-page-note'") {
            let target = try NativeSyncFormat.object(row["target_json"])
            guard let payload = target["payload"] as? [String: Any], payload["courseId"] as? String == course, payload["relPath"] as? String == path else { continue }
            let source = try NativeSyncFormat.object(row["source_json"])
            guard source["kind"] as? String == "pdf", let payload = source["payload"] as? [String: Any],
                  let sourceCourse = payload["courseId"] as? String, let sourcePath = payload["relPath"] as? String else { continue }
            return ["courseId": sourceCourse, "relPath": sourcePath]
        }
        return NSNull()
    }

    func open(_ request: [String: Any]) throws -> [String: Any] {
        let course = try NativeRepositoryContext.requireID(request["courseId"])
        let path = try NativeRepositoryContext.requireString(request["relPath"], "relPath")
        return try context.withMaterialLock {
            let journal = try NativeSyncJournal(context: context)
            try journal.requireSettled()
            let binding = try pdf.checkBinding(request)
            let file = try context.materialURL(courseID: course, relativePath: path)
            guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0,
                  binding["documentRevision"] is String else { throw NativeRepositoryContext.validation("PDF 페이지 정보를 읽지 못했습니다.") }
            for row in try context.query("SELECT source_json,target_json FROM material_links WHERE course_id=? AND kind='pdf-page-note'", [course]) {
                let source = try NativeSyncFormat.object(row["source_json"])
                guard let payload = source["payload"] as? [String: Any], payload["courseId"] as? String == course, payload["relPath"] as? String == path else { continue }
                let target = try NativeSyncFormat.object(row["target_json"])
                guard target["kind"] as? String == "note", let payload = target["payload"] as? [String: Any], let targetCourse = payload["courseId"] as? String, let targetPath = payload["relPath"] as? String else { throw NativeRepositoryContext.conflict("페이지 필기 연결을 읽지 못했습니다.") }
                _ = try context.materialURL(courseID: targetCourse, relativePath: targetPath)
                return reference(course: targetCourse, path: targetPath)
            }
            let fingerprint = NativePDFPageDocument.fingerprint(try Data(contentsOf: file))
            let sizes = NativePDFPageDocument.sizes(document).map { NativePDFPageNoteDocument.Size(width: $0["width"]!, height: $0["height"]!) }
            let parent = (path as NSString).deletingLastPathComponent
            let basename = ((path as NSString).lastPathComponent as NSString).deletingPathExtension + " 페이지 필기"
            var destination = "", target: URL?
            for index in 1..<1000 {
                let name = basename + (index == 1 ? "" : " (\(index))") + ".md"
                destination = parent.isEmpty ? name : parent + "/" + name
                let candidate = try context.materialURL(courseID: course, relativePath: destination, allowMissing: true)
                if !context.files.fileExists(atPath: candidate.path) { target = candidate; break }
            }
            guard let target else { throw NativeRepositoryContext.conflict("페이지 필기 이름을 만들지 못했습니다.") }
            let note = NativePDFPageNoteDocument(source: path, fingerprint: fingerprint, sizes: sizes, title: basename)
            let source: [String: Any] = ["kind": "pdf", "payload": ["courseId": course, "relPath": path]]
            let descriptor: [String: Any] = ["kind": "note", "payload": ["courseId": course, "relPath": destination]]
            let metadata: [String: Any] = ["version": 1, "syncScroll": true, "fingerprint": fingerprint, "pageSizes": sizes.map { ["width": $0.width, "height": $0.height] }]
            let result = reference(course: course, path: destination)
            let plan = NativeSyncPlan(files: [.init(target: target, data: Data(try note.markdown().utf8), expectedMissing: true)], courseID: course, apply: {
                try self.context.run("INSERT INTO material_links(id,course_id,source_json,target_json,label,created_at,kind,metadata_json) VALUES(?,?,?,?,?,?,?,?)", [UUID().uuidString.lowercased(), course, try NativeSyncFormat.canonical(source), try NativeSyncFormat.canonical(descriptor), "페이지 필기", NativeRepositoryContext.nowISO, "pdf-page-note", try NativeSyncFormat.canonical(metadata)])
                try self.context.run("INSERT INTO material_added_state(course_id,rel_path,added_at,pending_children) VALUES(?,?,?,0) ON CONFLICT(course_id,rel_path) DO UPDATE SET added_at=excluded.added_at", [course, destination, Date().timeIntervalSince1970 * 1000])
            })
            try journal.apply(plan, commit: {})
            context.emit?("materials:changed", ["courseId": course])
            return result
        }
    }
    private func reference(course: String, path: String) -> [String: Any] {
        ["courseID": course, "courseId": course, "relativePath": path, "relPath": path, "title": (path as NSString).lastPathComponent, "kind": "note"]
    }
}
