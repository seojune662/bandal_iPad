import Foundation

/// Markdown page sections and navigation references publish in the same file
/// journal as the PDF. Deleted sections remain readable in the appendix.
enum NativePDFPageLinks {
    struct Result { var files: [[String: Any]] = []; var before: [String: [[String: Any]]] = [:]; var after: [String: [[String: Any]]] = [:] }
    static func plan(context: NativeRepositoryContext, course: String, path: String, revision: String, pageMap: [[Int]], fingerprint: String, sizes: [[String: Double]]) throws -> Result {
        typealias F = NativeSyncFormat
        var result = Result()
        func remap(_ raw: [String: Any]) -> [String: Any] {
            var value = raw
            if let page = value["page"] as? Int, page > 0, page <= pageMap.count {
                if let next = pageMap[page - 1].first { value["page"] = next }
                else { value["page"] = NSNull(); value["removedPage"] = page; value["originalRevision"] = revision }
            }
            return value
        }
        let anchors = try context.query("SELECT a.* FROM recording_anchors a JOIN recording_sessions s ON s.id=a.session_id WHERE s.course_id=?", [course])
        for row in anchors {
            let value = try F.object(row["payload"])
            guard value["relPath"] as? String == path, value["page"] is NSNumber else { continue }
            var next = row; next["payload"] = try F.canonical(remap(value))
            result.before["recording_anchors", default: []].append(row); result.after["recording_anchors", default: []].append(next)
        }
        var noteTargets = Set<String>()
        for row in try context.query("SELECT * FROM material_links") {
            let source = try F.object(row["source_json"]), target = try F.object(row["target_json"])
            func matches(_ value: [String: Any]) -> Bool { let p = value["payload"] as? [String: Any] ?? [:]; return p["courseId"] as? String == course && p["relPath"] as? String == path }
            guard matches(source) || matches(target) else { continue }
            var next = row
            for (key, value) in [("source_json", source), ("target_json", target)] where matches(value) {
                var updated = value; updated["payload"] = remap(value["payload"] as? [String: Any] ?? [:]); next[key] = try F.canonical(updated)
            }
            if matches(source), row["kind"] as? String == "pdf-page-note", target["kind"] as? String == "note", let payload = target["payload"] as? [String: Any], let noteCourse = payload["courseId"] as? String, let notePath = payload["relPath"] as? String {
                let key = noteCourse + ":" + notePath
                guard noteTargets.insert(key).inserted else { throw NativeRepositoryContext.conflict("중복된 PDF 페이지 노트 연결을 먼저 정리해 주세요.") }
                // A note deleted behind the link table must not block page edits;
                // its link row still remaps so a restored note lines up again.
                let url = try context.materialURL(courseID: noteCourse, relativePath: notePath, allowMissing: true)
                if context.files.fileExists(atPath: url.path) {
                    let bytes = try Data(contentsOf: url)
                    guard let text = String(data: bytes, encoding: .utf8) else { throw NativeRepositoryContext.validation("PDF 연결 노트를 읽지 못했습니다.") }
                    let rewritten = try rewrite(text, source: path, pageMap: pageMap, fingerprint: fingerprint, sizes: sizes)
                    result.files.append(["courseId": noteCourse, "relPath": notePath, "before": text, "after": rewritten])
                    var metadata = try (row["metadata_json"] as? String).map { try F.object($0) } ?? [:]
                    metadata["version"] = 1; metadata["fingerprint"] = fingerprint; metadata["pageSizes"] = sizes
                    next["metadata_json"] = try F.canonical(metadata)
                }
            }
            result.before["material_links", default: []].append(row); result.after["material_links", default: []].append(next)
        }
        return result
    }
    static func rewrite(_ markdown: String, source: String, pageMap: [[Int]], fingerprint: String, sizes: [[String: Double]]) throws -> String {
        let prefix = "<!-- bandal:pdf-page-note ", suffix = " -->", appendixMarker = "<!-- bandal:appendix -->"
        let text = markdown as NSString, lines = markdown.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix(prefix), first.hasSuffix(suffix), var manifest = try DesktopJSON.decode(Data(first.dropFirst(prefix.count).dropLast(suffix.count).utf8)) as? [String: Any], (manifest["version"] as? Int) == 1, let encoded = manifest["source"] as? String, encoded.removingPercentEncoding == source || encoded == source, let oldSizes = manifest["pages"] as? [[String: Any]], oldSizes.count == pageMap.count else { throw NativeRepositoryContext.conflict("연결된 페이지 노트의 원본 정보가 다릅니다. 노트를 보존했으며 PDF는 변경하지 않았습니다.") }
        let expression = try NSRegularExpression(pattern: #"^<!-- bandal:page (\d+) -->[ \t]*$"#, options: .anchorsMatchLines), matches = expression.matches(in: markdown, range: NSRange(location: 0, length: text.length))
        guard matches.count == pageMap.count else { throw NativeRepositoryContext.conflict("연결된 페이지 노트의 경계가 손상되었습니다. 원문을 보존했습니다.") }
        let appendixRange = text.range(of: appendixMarker), appendixStart = appendixRange.location == NSNotFound ? text.length : appendixRange.location
        var content: [String] = []
        for (index, match) in matches.enumerated() {
            guard Int(text.substring(with: match.range(at: 1))) == index + 1 else { throw NativeRepositoryContext.conflict("연결된 페이지 노트의 순서를 확인하지 못했습니다.") }
            let start = NSMaxRange(match.range), end = index + 1 < matches.count ? matches[index + 1].range.location : appendixStart
            guard end >= start else { throw NativeRepositoryContext.conflict("연결된 페이지 노트가 손상되었습니다.") }
            content.append(NativePDFPageNoteDocument.content(fromSection: text.substring(with: NSRange(location: start, length: end - start)), followedBySection: end < text.length))
        }
        var ordered = [String](repeating: "", count: sizes.count), removed: [String] = []
        for index in pageMap.indices {
            if let target = pageMap[index].first, ordered.indices.contains(target - 1) { ordered[target - 1] = content[index] }
            else if !content[index].isEmpty { removed.append("### 기존 PDF \(index + 1)쪽\n\n" + content[index]) }
        }
        manifest["fingerprint"] = fingerprint; manifest["pages"] = sizes
        let headerEnd = first.utf16.count, heading = text.substring(with: NSRange(location: headerEnd, length: matches[0].range.location - headerEnd)).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = prefix + (try NativeSyncFormat.canonical(manifest)) + suffix + "\n" + heading + "\n\n"
        result += ordered.enumerated().map { "<!-- bandal:page \($0.offset + 1) -->" + ($0.element.isEmpty ? "" : "\n\n" + $0.element) }.joined(separator: "\n\n")
        var appendix = appendixRange.location == NSNotFound ? "" : NativePDFPageNoteDocument.content(fromSection: text.substring(from: NSMaxRange(appendixRange)), followedBySection: false)
        if !removed.isEmpty { if !appendix.isEmpty { appendix += "\n\n" }; appendix += "## 연결 제외된 페이지\n\n" + removed.joined(separator: "\n\n") }
        if !appendix.isEmpty { result += "\n\n" + appendixMarker + "\n\n" + appendix }; return result + "\n"
    }
}
