import Foundation
import BandalCore

struct ExchangeAsset: Codable {
    var materialID: String
    var sha256: String
    var byteCount: Int64
    var fileName: String
    var data: Data
}
struct ExchangePackage: Codable {
    var format = "bandal-exchange"
    var version = 1
    var records: [StoredRecord]
    var assets: [ExchangeAsset]
}

extension AppModel {
    func exportExchange() async throws -> URL {
        try await flushChecked()
        var records: [StoredRecord] = []
        func append<T: Encodable>(_ value: T, kind: String, id: String) throws {
            records.append(StoredRecord(id: id, kind: kind, payload: try Self.encoder.encode(value)))
        }
        guard let course = selectedCourse else { throw AIError.message("내보낼 과목이 없습니다.") }
        let sourceFiles = courseMaterials.filter { $0.kind != .note }.map(fileURL) + recordings.filter { $0.courseID == course.id && $0.hasSafePath }.map { root.appendingPathComponent($0.fileName) }
        let totalBytes = try sourceFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard totalBytes <= 64 * 1024 * 1024 else { throw AIError.message("교환 파일은 원본 합계 64MB까지 지원합니다. 큰 PDF와 장시간 녹음은 계정 동기화로 이어 사용해 주세요.") }
        try append(course, kind: "course", id: "course:\(course.id)")
        var assets: [ExchangeAsset] = []
        for var item in courseMaterials {
            let file = fileURL(item)
            if item.kind != .note && FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file); let hash = Self.hash(data); item.byteCount = Int64(data.count)
                if item.kind != .note && hash != item.revision { throw AIError.message("\(item.title)의 원본 파일이 바뀌었습니다.") }
                assets.append(ExchangeAsset(materialID: item.id, sha256: hash, byteCount: Int64(data.count), fileName: item.fileName, data: data))
            }
            try append(item, kind: "material", id: "material:\(item.id)")
            if item.kind == .note { try append(NoteContent(materialID: item.id, markdown: notes[item.id] ?? ""), kind: "note", id: "note:\(item.id)") }
            records.append(contentsOf: inkRecords(for: item))
        }
        for item in tasks where item.courseID == course.id { try append(item, kind: "task", id: "task:\(item.id)") }
        for item in cards where item.courseID == course.id { try append(item, kind: "flashcard", id: "flashcard:\(item.id)") }
        for item in vocabulary where item.courseID == course.id { try append(item, kind: "vocabulary", id: "vocabulary:\(item.id)") }
        for item in conversations.values where item.courseID == course.id { try append(item, kind: "chat", id: "chat:\(item.id)") }
        let exportedIDs = Set(records.map(\.id))
        for record in try await store?.list() ?? [] where !exportedIDs.contains(record.id) && record.kind != "workspace" {
            if let object = try? JSONSerialization.jsonObject(with: record.payload) as? [String: Any], object["courseID"] as? String == course.id, record.kind != "recording" { records.append(record) }
        }
        for var item in recordings where item.courseID == course.id && ["completed", "recovered", "interrupted"].contains(item.state) {
            let file = root.appendingPathComponent(item.fileName)
            guard item.hasSafePath else { continue }
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file); let hash = Self.hash(data)
                item.assetRevision = hash; item.byteCount = Int64(data.count)
                assets.append(ExchangeAsset(materialID: "recording:\(item.id)", sha256: hash, byteCount: Int64(data.count), fileName: item.fileName, data: data))
            }
            try append(item, kind: "recording", id: "recording:\(item.id)")
        }
        let package = ExchangePackage(records: records, assets: assets)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Bandal-Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Bandal-\(UUID().uuidString.prefix(8)).bandalpack")
        let encoded = try JSONEncoder().encode(package)
        guard encoded.count <= 100 * 1024 * 1024 else { throw AIError.message("자료와 필기의 합계가 교환 파일 한도를 넘었습니다. 과목을 나누거나 계정 동기화를 이용해 주세요.") }
        try encoded.write(to: url, options: .atomic); return url
    }

    func importExchange(_ url: URL) throws {
        guard !isImporting, !sync.busy, !audio.isRecording, !audio.isPaused, audio.transcribingID == nil else {
            throw AIError.message("저장·동기화·녹음 작업이 끝난 뒤 자료를 가져와 주세요.")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1024 * 1024 else { throw AIError.message("교환 파일이 너무 큽니다. 과목을 나누거나 계정 동기화를 이용해 주세요.") }
        let data = try Data(contentsOf: url)
        let package = try JSONDecoder().decode(ExchangePackage.self, from: data)
        try Self.validateExchange(package)
        guard store != nil else { throw AIError.message("저장소가 준비되지 않았습니다.") }
        // Take the lock before yielding. Existing journal writes drain before the import.
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                try await importValidatedExchange(package, original: data)
                notice = "자료를 가져왔습니다. 이전 내용과 교환 파일은 Recovery 폴더에 보관했습니다."
            } catch { self.error = "가져오기를 완료하지 못했습니다: \(error.localizedDescription)" }
        }
    }

    static func validateExchange(_ package: ExchangePackage) throws {
        guard package.format == "bandal-exchange", package.version == 1 else { throw AIError.message("지원하지 않는 반달 교환 파일입니다.") }
        var ids = Set<String>()
        for record in package.records {
            guard !record.id.isEmpty, record.id.utf8.count <= 512, !record.kind.isEmpty, record.kind.utf8.count <= 64,
                  record.payload.count <= 4 * 1024 * 1024, ids.insert(record.id).inserted,
                  SyncPolicy.allowedKinds.contains(record.kind), record.formatVersion == 1,
                  (try? JSONSerialization.jsonObject(with: record.payload)) != nil else {
                throw AIError.message("교환 파일에 중복·초과 용량 또는 지원하지 않는 데이터가 있습니다.")
            }
            if record.deleted { continue }
            if record.kind == "material" {
                let item = try decoder.decode(Material.self, from: record.payload)
                guard item.hasSafePath, record.id == "material:\(item.id)" else { throw AIError.message("자료 식별자나 경로가 올바르지 않습니다.") }
            } else if record.kind == "recording" {
                let item = try decoder.decode(RecordingMetadata.self, from: record.payload)
                guard item.hasSafePath, record.id == "recording:\(item.id)", ["completed", "recovered", "interrupted"].contains(item.state) else {
                    throw AIError.message("녹음 식별자나 상태가 올바르지 않습니다.")
                }
            } else if record.kind == "note" {
                let item = try decoder.decode(NoteContent.self, from: record.payload)
                guard UUID(uuidString: item.materialID) != nil, record.id == "note:\(item.materialID)" else { throw AIError.message("노트 식별자가 올바르지 않습니다.") }
            } else if record.kind == "drawing" {
                let wrapper = try decoder.decode(InkPageRecord.self, from: record.payload)
                let page = try JSONDecoder().decode(PortableInkPageRecord.self, from: wrapper.data)
                guard record.id == "drawing:\(wrapper.materialID):\(wrapper.documentRevision):\(wrapper.page)",
                      UUID(uuidString: wrapper.materialID) != nil, wrapper.page >= 0,
                      page.geometry.width.isFinite, page.geometry.width > 0, page.geometry.height.isFinite, page.geometry.height > 0,
                      Set(page.objects.map(\.id)).count == page.objects.count,
                      Set(page.highlights.map(\.id)).count == page.highlights.count else { throw AIError.message("필기 식별자나 페이지 정보가 올바르지 않습니다.") }
                try page.validate(materialID: wrapper.materialID, revision: wrapper.documentRevision, page: wrapper.page, geometry: page.geometry)
            }
        }
        let materials = try package.records.filter { $0.kind == "material" && !$0.deleted }.map { try decoder.decode(Material.self, from: $0.payload) }
        let recordings = try package.records.filter { $0.kind == "recording" && !$0.deleted }.map { try decoder.decode(RecordingMetadata.self, from: $0.payload) }
        let notes = try package.records.filter { $0.kind == "note" && !$0.deleted }.map { try decoder.decode(NoteContent.self, from: $0.payload) }
        guard Set(materials.map { $0.id.lowercased() }).count == materials.count,
              Set(recordings.map { $0.id.lowercased() }).count == recordings.count else { throw AIError.message("자료 식별자가 중복되어 있습니다.") }
        for item in materials where item.kind == .note {
            guard notes.contains(where: { $0.materialID == item.id }) else { throw AIError.message("노트의 편집 내용이 교환 파일에 없습니다.") }
        }
        var assetIDs = Set<String>()
        var destinations = Set<String>()
        for asset in package.assets {
            guard assetIDs.insert(asset.materialID).inserted, asset.byteCount == asset.data.count, hash(asset.data) == asset.sha256 else {
                throw AIError.message("자료 파일의 무결성 검증에 실패했습니다.")
            }
            let destination: String
            if asset.materialID.hasPrefix("recording:") {
                guard let item = recordings.first(where: { "recording:\($0.id)" == asset.materialID }), item.fileName == asset.fileName,
                      item.assetRevision == asset.sha256, item.byteCount == nil || item.byteCount == asset.byteCount else { throw AIError.message("녹음 파일이 자료 정보와 일치하지 않습니다.") }
                destination = item.fileName
            } else {
                guard let item = materials.first(where: { $0.id == asset.materialID }), asset.fileName == item.fileName,
                      item.kind == .note || item.revision == asset.sha256,
                      item.kind == .note || item.byteCount == nil || item.byteCount == asset.byteCount else { throw AIError.message("원본 파일이 자료 버전과 일치하지 않습니다.") }
                if item.kind == .note {
                    guard let note = notes.first(where: { $0.materialID == item.id }), String(data: asset.data, encoding: .utf8) == note.markdown else {
                        throw AIError.message("노트 파일과 편집 내용이 일치하지 않습니다.")
                    }
                }
                destination = item.relativePath
            }
            guard destinations.insert(destination.lowercased()).inserted else { throw AIError.message("같은 파일 경로가 두 번 포함되어 있습니다.") }
        }
    }

    // Only immutable, hash-verified files are installed before the database commit.
    // A failed/terminated import can leave unreferenced files, never overwrite live bytes.
    // All metadata and its outbox operations are committed in one SQLite transaction.
    func importValidatedExchange(_ package: ExchangePackage, original: Data) async throws {
        try Self.validateExchange(package)
        guard let store else { throw AIError.message("저장소가 준비되지 않았습니다.") }
        try await flushChecked()
        let existing = try await store.list(includeDeleted: true)
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for record in package.records {
            guard byID[record.id] == nil || byID[record.id]?.kind == record.kind else { throw AIError.message("기존 자료와 데이터 종류가 충돌합니다.") }
        }
        let incomingMaterials = try package.records.filter { $0.kind == "material" && !$0.deleted }.map { try Self.decoder.decode(Material.self, from: $0.payload) }
        let incomingRecordings = try package.records.filter { $0.kind == "recording" && !$0.deleted }.map { try Self.decoder.decode(RecordingMetadata.self, from: $0.payload) }
        var writes: [(ExchangeAsset, URL)] = []
        for asset in package.assets {
            let destination: URL
            if let item = incomingRecordings.first(where: { "recording:\($0.id)" == asset.materialID }) { destination = root.appendingPathComponent(item.fileName) }
            else if let item = incomingMaterials.first(where: { $0.id == asset.materialID }) {
                if item.kind == .note { continue } // The note record is authoritative; materialize after commit.
                destination = fileURL(item)
            } else { throw AIError.message("파일에 대응하는 자료가 없습니다.") }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try AssetHasher.revision(of: destination).sha256 == asset.sha256 else { throw AIError.message("기존 원본과 다른 파일이 같은 위치를 사용합니다. 기존 자료는 보존했습니다.") }
            } else { writes.append((asset, destination)) }
        }
        for item in incomingMaterials where item.kind != .note && item.kind != .whiteboard {
            guard package.assets.contains(where: { $0.materialID == item.id }) || (FileManager.default.fileExists(atPath: fileURL(item).path) && (try? AssetHasher.revision(of: fileURL(item)).sha256) == item.revision) else {
                throw AIError.message("\(item.title)의 원본 파일이 교환 파일에 없습니다.")
            }
        }
        for item in incomingRecordings {
            let file = root.appendingPathComponent(item.fileName)
            guard let revision = item.assetRevision,
                  package.assets.contains(where: { $0.materialID == "recording:\(item.id)" }) || (FileManager.default.fileExists(atPath: file.path) && (try? AssetHasher.revision(of: file).sha256) == revision) else {
                throw AIError.message("\(item.title)의 녹음 원본이 교환 파일에 없습니다.")
            }
        }
        let recovery = root.appendingPathComponent("Recovery/import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try original.write(to: recovery.appendingPathComponent("incoming.bandalpack"), options: .atomic)
        let replaced = existing.filter { old in package.records.contains { $0.id == old.id } }
        try JSONEncoder().encode(replaced).write(to: recovery.appendingPathComponent("previous-records.json"), options: .atomic)
        for (asset, destination) in writes {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: destination, options: .atomic)
        }
        _ = try await store.importLocalRecords(package.records)
        await reload()
        for item in incomingMaterials where item.kind == .note {
            if let markdown = notes[item.id] { try write(Data(markdown.utf8), for: item) }
        }
        if let record = package.records.first(where: { $0.kind == "course" && !$0.deleted }), let item = try? Self.decoder.decode(Course.self, from: record.payload) {
            workspace.selectedCourseID = item.id
        }
    }
}
