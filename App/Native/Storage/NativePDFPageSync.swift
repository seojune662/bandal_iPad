import Foundation

/// CommonSync keeps stable material IDs across approved page revisions. A
/// sender supplies both immutable PDF assets and the exact page recipe; the
/// receiver verifies actual content and its pre-edit ink before publishing.
enum NativePDFPageSync {
    private typealias C = NativeRepositoryContext
    private typealias F = NativeSyncFormat
    private typealias D = NativePDFPageDocument
    static func inkDigest(context: NativeRepositoryContext, pdf: NativePDFRepository, material: String) throws -> String {
        let records = try NativeSyncDrawings(context: context, pdf: pdf).snapshot(onlyMaterialID: material).records
        return try F.digest(records.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }.map { try F.comparable($0) })
    }
    static func export(context: NativeRepositoryContext, material: String) throws -> (proofs: [[String: Any]], assets: [[String: Any]]) {
        guard try context.tableExists("native_pdf_revision_lineage") else { return ([], []) }
        var proofs: [[String: Any]] = [], assets: [[String: Any]] = [], hashes = Set<String>()
        for row in try context.query("SELECT * FROM native_pdf_revision_lineage WHERE material_id=? ORDER BY from_sha,to_sha", [material]) {
            var proof = try F.object(row["pages_json"]); proof["fromSHA"] = row["from_sha"]; proof["toSHA"] = row["to_sha"]; proofs.append(proof)
            for hash in [row["from_sha"], row["to_sha"]].compactMap({ $0 as? String }) where hashes.insert(hash).inserted {
                let url = context.root.appendingPathComponent("PDFOriginals/\(hash).pdf")
                guard try F.hash(url) == hash else { throw C.conflict("PDF 페이지 변경의 원본 백업이 손상되었습니다.") }
                assets.append(try F.asset(materialID: material, url: url))
            }
        }
        return (proofs, assets)
    }
    static func plan(context: NativeRepositoryContext, material: String, course: String, path: String, from: String?, to: String, proofs: [[String: Any]], assets: [String: URL]) throws -> NativeSyncPlan {
        guard proofs.count <= 1000 else { throw C.validation("PDF page history is too large") }
        let pdf = try NativePDFRepository(context: context), repository = try NativePDFPageRepository(context: context, pdf: pdf)
        var bytes: [String: Data] = [:], byEdge: [String: [String: Any]] = [:]
        func load(_ hash: String) throws -> Data {
            guard hash.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw C.validation("Invalid PDF history asset") }
            if let data = bytes[hash] { return data }
            let url = assets[hash] ?? context.root.appendingPathComponent("PDFOriginals/\(hash).pdf"), data = try Data(contentsOf: url)
            guard F.hash(data) == hash else { throw C.conflict("PDF page history asset checksum mismatch") }
            bytes[hash] = data; return data
        }
        for proof in proofs {
            guard let source = proof["sourceSHA"] as? String, let target = proof["targetSHA"] as? String, let inverse = proof["inverse"] as? Bool, let edgeFrom = proof["fromSHA"] as? String, let edgeTo = proof["toSHA"] as? String, edgeFrom == (inverse ? target : source), edgeTo == (inverse ? source : target), let digest = proof["inkDigest"] as? String, digest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw C.validation("Invalid approved PDF page transition") }
            let original = try load(source), rewritten = try load(target), count = try D.open(original).pageCount, pages = try D.recipe(proof["pages"], count: count)
            try D.validate(source: original, target: rewritten, pages: pages)
            let key = edgeFrom + ":" + edgeTo
            if let previous = byEdge[key], try F.canonical(previous) != F.canonical(proof) { throw C.conflict("Conflicting PDF page lineage") }
            byEdge[key] = proof
        }
        // Retaining verified immutable assets is append-only; it is safe even
        // when a later conflict prevents this material from being published.
        for data in bytes.values { _ = try repository.retain(data) }
        var chain: [[String: Any]] = []
        if let from, from != to {
            var pending: [(String, [[String: Any]])] = [(from, [])], visited = Set<String>(), found = false
            while !pending.isEmpty {
                let item = pending.removeFirst(); guard visited.insert(item.0).inserted else { continue }
                if item.0 == to { chain = item.1; found = true; break }
                for proof in byEdge.values.sorted(by: { ($0["toSHA"] as! String) < ($1["toSHA"] as! String) }) where proof["fromSHA"] as? String == item.0 { pending.append((proof["toSHA"] as! String, item.1 + [proof])) }
            }
            guard found, let first = chain.first else { throw C.conflict("PDF replacement has no verified page history; the existing original and ink were preserved") }
            guard try inkDigest(context: context, pdf: pdf, material: material) == first["inkDigest"] as? String else { throw C.conflict("다른 기기의 페이지 변경 이후 이 기기에서 필기가 변경되었습니다. 두 원본과 필기를 충돌 사본으로 보존했습니다.") }
        }
        if chain.isEmpty {
            return NativeSyncPlan(courseID: course, apply: {
                for proof in byEdge.values { try repository.lineage(material: material, from: proof["fromSHA"] as! String, to: proof["toSHA"] as! String, proof: proof) }
            })
        }
        let from = from!, output = try load(to), before = try repository.state(course: course, path: path)
        var after = before, combinedMap = (1...(try D.open(load(from)).pageCount)).map { [$0] }, currentCount = combinedMap.count
        for proof in chain {
            let source = try load(proof["sourceSHA"] as! String), pages = try D.recipe(proof["pages"], count: D.open(source).pageCount), inverse = proof["inverse"] as! Bool
            let map = inverse ? pages.map { [$0] } : D.map(pages, count: currentCount), nextCount = try D.open(load(proof["toSHA"] as! String)).pageCount
            after = try repository.remap(after, map: map, count: nextCount)
            combinedMap = combinedMap.map { values in values.flatMap { map.indices.contains($0 - 1) ? map[$0 - 1] : [] } }; currentCount = nextCount
        }
        let links = try NativePDFPageLinks.plan(context: context, course: course, path: path, revision: from, pageMap: combinedMap, fingerprint: D.fingerprint(output), sizes: D.sizes(D.open(output)))
        var beforeWithLinks = before; beforeWithLinks.merge(links.before) { _, new in new }; after.merge(links.after) { _, new in new }
        var files: [NativeSyncFileChange] = [.init(target: try context.materialURL(courseID: course, relativePath: path), data: output, expectedHash: from)]
        for file in links.files { files.append(.init(target: try context.materialURL(courseID: file["courseId"] as! String, relativePath: file["relPath"] as! String), data: Data((file["after"] as! String).utf8), expectedHash: F.hash(Data((file["before"] as! String).utf8)))) }
        let token = UUID().uuidString.lowercased()
        // Imported multi-step history is recoverable as a copy. In-place undo
        // is only enabled for locally authored, single-operation snapshots.
        return NativeSyncPlan(files: files, courseID: course, affectedCourseIDs: Set(links.files.compactMap { $0["courseId"] as? String }), apply: {
            try repository.applyState(after, course: course, path: path); try repository.invalidate(course: course, path: path, revision: to, material: material, size: output.count)
            for proof in byEdge.values { try repository.lineage(material: material, from: proof["fromSHA"] as! String, to: proof["toSHA"] as! String, proof: proof) }
            try context.run("INSERT INTO native_pdf_page_history(id,material_id,course_id,rel_path,before_sha,after_sha,before_json,after_json,files_json,recipe_json,parent_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,NULL,?)", [token, material, course, path, from, to, F.canonical(beforeWithLinks), F.canonical(after), F.canonical(links.files), "[]", C.nowISO])
            try repository.setCursor(material, undo: nil, redo: [])
        })
    }
}
