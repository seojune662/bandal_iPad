import Foundation

/// CommonSync keeps stable material IDs across approved page revisions. A
/// material carries the desktop-shaped `pdfLineage` steps; the receiver
/// verifies the actual content of the chain it applies and its pre-edit ink.
enum NativePDFPageSync {
    private typealias C = NativeRepositoryContext
    private typealias F = NativeSyncFormat
    private typealias D = NativePDFPageDocument
    private static let digest = #"^[a-f0-9]{64}$"#
    /// `[{from, to, pages: [{source, rotate?}]}]`. Rows written before the
    /// desktop format still hold the former proof object and are converted.
    static func export(context: NativeRepositoryContext, material: String) throws -> (steps: [[String: Any]], assets: [[String: Any]]) {
        guard try context.tableExists("native_pdf_revision_lineage") else { return ([], []) }
        var steps: [[String: Any]] = [], assets: [[String: Any]] = [], hashes = Set<String>()
        func original(_ hash: String) throws -> URL {
            let url = context.root.appendingPathComponent("PDFOriginals/\(hash).pdf")
            guard try context.contentHash(url) == hash else { throw C.conflict("PDF 페이지 변경의 원본 백업이 손상되었습니다.") }
            if hashes.insert(hash).inserted { assets.append(try F.asset(materialID: material, url: url, hash: hash)) }
            return url
        }
        for row in try context.query("SELECT * FROM native_pdf_revision_lineage WHERE material_id=? ORDER BY rowid", [material]) {
            let from = row["from_sha"] as! String, to = row["to_sha"] as! String, target = try original(to); _ = try original(from)
            var pages = try DesktopJSON.decode(Data((row["pages_json"] as! String).utf8))
            if let proof = pages as? [String: Any] {
                let recipe = (proof["pages"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                pages = proof["inverse"] as? Bool == true ? try (1...D.open(Data(contentsOf: target)).pageCount).map { ["source": recipe.firstIndex(of: $0).map { $0 + 1 } ?? NSNull() as Any] } : recipe.map { ["source": $0] }
            }
            steps.append(["from": from, "to": to, "pages": pages])
        }
        return (steps, assets)
    }
    static func validated(_ value: Any?, target: String) throws -> [[String: Any]] {
        guard let steps = value as? [[String: Any]], steps.count <= 10_000 else { throw C.validation("Invalid PDF rewrite history") }
        for step in steps {
            guard let from = step["from"] as? String, from.range(of: digest, options: .regularExpression) != nil, let to = step["to"] as? String, to.range(of: digest, options: .regularExpression) != nil,
                  let pages = step["pages"] as? [[String: Any]], (1...2000).contains(pages.count) else { throw C.validation("Invalid PDF rewrite recipe") }
            for page in pages {
                guard page["source"] is NSNull || (page["source"] as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue == Double($0.intValue) && $0.intValue >= 1 }) == true,
                      page["rotate"] == nil || (page["rotate"] as? NSNumber).map({ $0.doubleValue == Double($0.intValue) && [0, 90, 180, 270].contains($0.intValue) }) == true else { throw C.validation("Invalid PDF rewrite recipe") }
            }
        }
        guard steps.isEmpty || steps.contains(where: { $0["to"] as? String == target }) else { throw C.validation("PDF rewrite history does not include target revision") }
        return steps
    }
    static func chain(_ steps: [[String: Any]], from: String, to: String) -> [[String: Any]]? {
        var parent: [String: [String: Any]] = [:], pending = [from], seen: Set<String> = [from]
        while !pending.isEmpty {
            let at = pending.removeFirst()
            if at == to {
                var path: [[String: Any]] = [], node = at
                while let step = parent[node] { path.insert(step, at: 0); node = step["from"] as! String }
                return path
            }
            for step in steps where step["from"] as? String == at {
                let next = step["to"] as! String
                if seen.insert(next).inserted { parent[next] = step; pending.append(next) }
            }
        }
        return nil
    }
    /// Old page envelopes stay in sync history after a structural edit.
    static func isHistorical(context: NativeRepositoryContext, material: String, revision: String) throws -> Bool {
        guard try context.tableExists("pdf_document_bindings"), try context.tableExists("native_pdf_revision_lineage"),
              let bound = try context.query("SELECT bound_sha FROM pdf_document_bindings WHERE material_id=?", [material]).first?["bound_sha"] as? String, bound != revision else { return false }
        let steps = try context.query("SELECT from_sha,to_sha FROM native_pdf_revision_lineage WHERE material_id=?", [material]).map { ["from": $0["from_sha"]!, "to": $0["to_sha"]!] }
        return chain(steps, from: revision, to: bound) != nil
    }
    static func plan(context: NativeRepositoryContext, material: String, course: String, path: String, from: String?, to: String, lineage: Any?, assets: [String: URL]) throws -> NativeSyncPlan {
        let steps = try validated(lineage, target: to)
        let pdf = try NativePDFRepository(context: context), repository = try NativePDFPageRepository(context: context, pdf: pdf)
        let record = { for step in steps { try repository.lineage(material: material, from: step["from"] as! String, to: step["to"] as! String, pages: step["pages"] as! [[String: Any]]) } }
        guard let from, from != to else { return NativeSyncPlan(courseID: course, apply: record) }
        guard let chain = chain(steps, from: from, to: to) else { throw C.conflict("PDF replacement has no verified page history; the existing original and ink were preserved") }
        for page in try NativeSyncDrawings(context: context, pdf: pdf).snapshot(onlyMaterialID: material).records where (page["payload"] as? [String: Any])?["documentRevision"] as? String == from {
            guard try context.tableExists("ipad_sync_projection"), let baseline = try context.query("SELECT baseline_json FROM ipad_sync_projection WHERE id=?", [page["id"]!]).first?["baseline_json"] as? String,
                  try F.comparable(page) == F.canonical(F.object(baseline)) else { throw C.conflict("다른 기기의 페이지 변경 이후 이 기기에서 필기가 변경되었습니다. 두 원본과 필기를 충돌 사본으로 보존했습니다.") }
        }
        var bytes: [String: Data] = [:]
        func load(_ hash: String) throws -> Data {
            if let data = bytes[hash] { return data }
            let url = assets[hash] ?? context.root.appendingPathComponent("PDFOriginals/\(hash).pdf"), data = try Data(contentsOf: url)
            guard F.hash(data) == hash else { throw C.conflict("PDF page history asset checksum mismatch") }
            bytes[hash] = data; return data
        }
        let output = try load(to), before = try repository.state(course: course, path: path)
        var after = before, currentCount = try D.open(load(from)).pageCount, combinedMap = (1...currentCount).map { [$0] }
        for step in chain {
            let source = try load(step["from"] as! String), target = try load(step["to"] as! String), pages = step["pages"] as! [[String: Any]]
            let sources = pages.map { ($0["source"] as? NSNumber)?.intValue }, nextCount = try D.open(target).pageCount
            guard nextCount == pages.count else { throw C.conflict("PDF 페이지 변경 이력이 원본과 다릅니다.") }
            if sources.allSatisfy({ $0 != nil }) { try D.validate(source: source, target: target, pages: D.recipe(pages, count: currentCount)) }
            else {
                // An undo restores pages the rewritten revision no longer has.
                // Verify the reverse edit so every kept page is proven content.
                let kept = try (1...currentCount).map { page -> Int in
                    guard let index = sources.firstIndex(of: page), sources.filter({ $0 == page }).count == 1 else { throw C.conflict("PDF 페이지 변경 이력이 원본과 다릅니다.") }; return index + 1
                }
                try D.validate(source: target, target: source, pages: kept)
            }
            let map = (1...currentCount).map { page in sources.indices.filter { sources[$0] == page }.map { $0 + 1 } }
            after = try repository.remap(after, map: map, count: nextCount)
            combinedMap = combinedMap.map { $0.flatMap { map[$0 - 1] } }; currentCount = nextCount
        }
        // Retaining verified immutable assets is append-only; it is safe even
        // when a later conflict prevents this material from being published.
        for data in bytes.values { _ = try repository.retain(data) }
        let links = try NativePDFPageLinks.plan(context: context, course: course, path: path, revision: from, pageMap: combinedMap, fingerprint: D.fingerprint(output), sizes: D.sizes(D.open(output)))
        var beforeWithLinks = before; beforeWithLinks.merge(links.before) { _, new in new }; after.merge(links.after) { _, new in new }
        var files: [NativeSyncFileChange] = [.init(target: try context.materialURL(courseID: course, relativePath: path), data: output, expectedHash: from)]
        for file in links.files { files.append(.init(target: try context.materialURL(courseID: file["courseId"] as! String, relativePath: file["relPath"] as! String), data: Data((file["after"] as! String).utf8), expectedHash: F.hash(Data((file["before"] as! String).utf8)))) }
        let token = UUID().uuidString.lowercased()
        // Imported multi-step history is recoverable as a copy. In-place undo
        // is only enabled for locally authored, single-operation snapshots.
        return NativeSyncPlan(files: files, courseID: course, affectedCourseIDs: Set(links.files.compactMap { $0["courseId"] as? String }), apply: {
            try repository.applyState(after, course: course, path: path); try repository.invalidate(course: course, path: path, revision: to, material: material, size: output.count)
            try record()
            try context.run("INSERT INTO native_pdf_page_history(id,material_id,course_id,rel_path,before_sha,after_sha,before_json,after_json,files_json,recipe_json,parent_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,NULL,?)", [token, material, course, path, from, to, F.canonical(beforeWithLinks), F.canonical(after), F.canonical(links.files), "[]", C.nowISO])
            try repository.setCursor(material, undo: nil, redo: [])
        })
    }
}
