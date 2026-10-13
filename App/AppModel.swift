import SwiftUI
import BandalCore
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var courses: [Course] = []
    @Published var materials: [Material] = []
    @Published var folders: [MaterialFolder] = []
    @Published var tasks: [StudyTask] = []
    @Published var cards: [Flashcard] = []
    @Published var vocabulary: [VocabularyEntry] = []
    @Published var recordings: [RecordingMetadata] = []
    @Published var workspace = WorkspaceState()
    @Published var loading = true
    @Published var isImporting = false
    @Published var error: String?
    @Published var notice: String?
    @Published var syncStatus = "기기에 저장됨"
    @Published var notes: [String: String] = [:]
    @Published var conversations: [String: Conversation] = [:]
    let root: URL
    let store: RecordStore?
    private let journal: LocalSaveJournal?
    private var saveFailure: String?
    private var recordData: [String: Data] = [:]
    private var pendingSave: Task<Void, Never>?
    private var mutationVersion = 0
    var browserSessions: [String: BrowserSession] = [:]
    lazy var audio = RecordingController(root: root) { [weak self] metadata in self?.saveRecording(metadata) }
    lazy var sync = SyncController(model: self)

    init(storageRoot: URL? = nil, seedWelcome: Bool = true) {
        if let url = Bundle.main.url(forResource: "Configuration", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
            UserDefaults.standard.register(defaults: config)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = storageRoot ?? documents.appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "Bandal-UI-Tests" : "Bandal", isDirectory: true)
        do {
            if storageRoot == nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--reset-ui-testing"), FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let pending = try LocalSaveJournal(directory: root.appendingPathComponent("PendingEdits", isDirectory: true))
            let records = try RecordStore(url: root.appendingPathComponent("bandal.sqlite"))
            journal = pending; store = records
        } catch { store = nil; journal = nil; self.error = "저장소를 열 수 없습니다: \(error.localizedDescription)" }
        Task {
            if let store { do { try await journal?.recover(into: store) } catch { self.error = "저장 중이던 편집 복구: \(error.localizedDescription)"; if !(error is LocalSaveJournal.RecoveryNotice) { saveFailure = self.error } } }
            await reload(); if courses.isEmpty && store != nil && seedWelcome { self.seedWelcome() }; loading = false
        }
    }

    var courseID: String { workspace.selectedCourseID ?? courses.first?.id ?? "" }
    var selectedCourse: Course? { courses.first { $0.id == courseID } }
    var courseMaterials: [Material] { materials.filter { $0.courseID == courseID }.sorted { $0.createdAt > $1.createdAt } }
    var courseTabs: [WorkspaceTab] { workspace.tabs.filter { $0.courseID == courseID } }
    var focusedTab: WorkspaceTab? { tab(workspace.focusedPane == 1 ? workspace.secondaryID : workspace.primaryID) }
    func tab(_ id: String?) -> WorkspaceTab? { workspace.tabs.first { $0.id == id } }
    func material(_ id: String?) -> Material? { materials.first { $0.id == id } }
    func fileURL(_ material: Material) -> URL { root.appendingPathComponent(material.relativePath) }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date")
        }
        return decoder
    }

    func reload() async {
        guard let store else { return }
        do {
            await flush()
            let version = mutationVersion
            let records = try await store.list()
            guard version == mutationVersion else { await reload(); return }
            recordData = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.payload) })
            func values<T: Decodable>(_ kind: String, _: T.Type) -> [T] {
                records.filter { $0.kind == kind }.compactMap { try? Self.decoder.decode(T.self, from: $0.payload) }
            }
            courses = values("course", Course.self).sorted { $0.name < $1.name }
            let decodedMaterials = values("material", Material.self)
            folders = values("artifact", MaterialFolder.self).filter { $0.recordType == "material-folder" }
            materials = decodedMaterials.filter(\.hasSafePath)
            if materials.count != decodedMaterials.count { error = "일부 자료의 파일 경로가 올바르지 않습니다. 원본 레코드는 보존했습니다." }
            migrateLegacyMaterialFiles(materials)
            tasks = values("task", StudyTask.self)
            cards = values("flashcard", Flashcard.self)
            vocabulary = values("vocabulary", VocabularyEntry.self)
            recordings = values("recording", RecordingMetadata.self).filter(\.hasSafePath).sorted { $0.createdAt > $1.createdAt }
            notes = Dictionary(values("note", NoteContent.self).map { ($0.materialID, $0.markdown) }, uniquingKeysWith: { _, b in b })
            conversations = Dictionary(values("chat", Conversation.self).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
            if loading, let data = recordData["workspace:ipad"], let saved = try? Self.decoder.decode(WorkspaceState.self, from: data) { workspace = saved }
            if !courses.contains(where: { $0.id == workspace.selectedCourseID }) { workspace.selectedCourseID = courses.first?.id }
            workspace.tabs.removeAll { item in item.materialID != nil && !materials.contains { $0.id == item.materialID } }
            repairSelection()
            NotificationCenter.default.post(name: Notification.Name("app.bandal.records.changed"), object: nil)
        } catch { self.error = "자료를 불러오지 못했습니다: \(error.localizedDescription)" }
    }

    @discardableResult func persist<T: Encodable>(_ value: T, kind: String, id: String) -> Bool {
        guard !isImporting else { error = "자료를 가져오는 중입니다. 완료한 뒤 다시 저장해 주세요."; return false }
        guard let store else { error = "저장소가 준비되지 않아 저장할 수 없습니다."; saveFailure = error; return false }
        do {
            let data = try Self.encoder.encode(value)
            guard data.count <= 4 * 1024 * 1024, !id.isEmpty, id.utf8.count <= 512, !kind.isEmpty, kind.utf8.count <= 64 else {
                try preserveRejected(data, recordID: id)
                error = "편집 내용이 한 번에 저장할 수 있는 용량을 넘었습니다. 복구 사본을 보관했습니다. 내용을 다른 노트나 페이지로 나누어 주세요."
                return false
            }
            let pending = kind != "workspace" ? try journal?.append(id: id, kind: kind, payload: data) : nil
            mutationVersion += 1
            recordData[id] = data
            let previous = pendingSave
            pendingSave = Task { [weak self] in
                await previous?.value
                do {
                    if let (entry, file) = pending {
                        _ = try await store.applyLocalJournalEntry(mutationID: entry.mutationID, id: id, kind: kind, payload: data)
                        try FileManager.default.removeItem(at: file)
                    } else { _ = try await store.upsert(id: id, kind: kind, payload: data) }
                } catch { self?.error = "저장 실패: \(error.localizedDescription)"; self?.saveFailure = self?.error }
            }
            return true
        } catch { self.error = error.localizedDescription; saveFailure = self.error; return false }
    }
    func flush() async {
        while true {
            let version = mutationVersion
            await pendingSave?.value
            if version == mutationVersion { return }
        }
    }
    func flushChecked() async throws { await flush(); if let saveFailure { throw AIError.message(saveFailure) } }
    private func preserveRejected(_ data: Data, recordID: String) throws {
        let folder = root.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Keystrokes after the size limit update this record's recovery copy,
        // rather than creating another multi-megabyte file for every keystroke.
        try data.write(to: folder.appendingPathComponent("oversize-\(Self.hash(Data(recordID.utf8))).json"), options: .atomic)
    }
    func retryPendingSaves() async {
        await flush()
        guard let store else { return }
        do { try await journal?.recover(into: store); saveFailure = nil; await reload(); notice = "저장 대기 중인 편집을 복구했습니다." }
        catch { self.error = error.localizedDescription }
    }
    func deleteRecord(_ id: String) {
        guard !isImporting else { error = "자료를 가져오는 중에는 삭제할 수 없습니다."; return }
        guard let store else { return }
        mutationVersion += 1
        recordData.removeValue(forKey: id)
        let previous = pendingSave
        pendingSave = Task { [weak self] in
            await previous?.value
            do { try await store.delete(id: id) } catch { self?.error = error.localizedDescription }
        }
    }
    func saveWorkspace() {
        var saved = workspace
        saved.tabs.removeAll { $0.isPrivate }
        if !saved.tabs.contains(where: { $0.id == saved.primaryID }) { saved.primaryID = nil }
        if !saved.tabs.contains(where: { $0.id == saved.secondaryID }) { saved.secondaryID = nil }
        persist(saved, kind: "workspace", id: "workspace:ipad")
    }
    func selectCourse(_ id: String) {
        workspace.selectedCourseID = id
        workspace.primaryID = courseTabs.first?.id
        workspace.secondaryID = nil
        workspace.splitEnabled = false
        workspace.focusedPane = 0
        saveWorkspace()
    }
    func addCourse(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let item = Course(name: trimmed); courses.append(item)
        persist(item, kind: "course", id: "course:\(item.id)"); selectCourse(item.id)
    }
    func openMaterial(_ item: Material, beside: Bool = false) {
        if let existing = workspace.tabs.first(where: { $0.materialID == item.id }) { selectTab(existing.id, beside: beside); return }
        let kind: TabKind = switch item.kind { case .pdf: .pdf; case .note: .note; case .whiteboard: .whiteboard; default: .file }
        addTab(WorkspaceTab(courseID: item.courseID, kind: kind, title: item.title, materialID: item.id), beside: beside)
    }
    func open(_ kind: TabKind, beside: Bool = false, url: URL? = nil, isPrivate: Bool = false) {
        if kind == .note { createNote(beside: beside); return }
        if kind == .whiteboard { createWhiteboard(beside: beside); return }
        let title = isPrivate ? "비공개 브라우저" : kind.title
        addTab(WorkspaceTab(courseID: courseID, kind: kind, title: title, url: url?.absoluteString, isPrivate: isPrivate), beside: beside)
    }
    private func addTab(_ item: WorkspaceTab, beside: Bool) { workspace.tabs.append(item); selectTab(item.id, beside: beside) }
    func selectTab(_ id: String, beside: Bool = false) {
        if beside {
            if workspace.primaryID == id { workspace.primaryID = courseTabs.first { $0.id != id }?.id }
            workspace.secondaryID = id; workspace.splitEnabled = true; workspace.focusedPane = 1
        } else if workspace.focusedPane == 1 && workspace.splitEnabled {
            if workspace.primaryID == id { swapPanes() } else { workspace.secondaryID = id }
        } else {
            if workspace.secondaryID == id { swapPanes() } else { workspace.primaryID = id }
        }
        saveWorkspace()
    }
    func closeTab(_ id: String) {
        workspace.tabs.removeAll { $0.id == id }; browserSessions.removeValue(forKey: id)
        repairSelection(); saveWorkspace()
    }
    private func swapPanes() { let old = workspace.primaryID; workspace.primaryID = workspace.secondaryID; workspace.secondaryID = old }
    func moveTab(_ id: String, offset: Int) {
        guard let i = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(workspace.tabs.count - 1, i + offset)); workspace.tabs.swapAt(i, j); saveWorkspace()
    }
    func toggleSplit() {
        workspace.splitEnabled.toggle()
        if workspace.splitEnabled && workspace.secondaryID == nil { workspace.secondaryID = courseTabs.first { $0.id != workspace.primaryID }?.id }
        if !workspace.splitEnabled { workspace.focusedPane = 0 }
        saveWorkspace()
    }
    private func repairSelection() {
        if !courseTabs.contains(where: { $0.id == workspace.primaryID }) { workspace.primaryID = courseTabs.first?.id }
        if !courseTabs.contains(where: { $0.id == workspace.secondaryID }) { workspace.secondaryID = nil }
    }
    func browser(for tab: WorkspaceTab) -> BrowserSession {
        if let session = browserSessions[tab.id] { return session }
        let session = BrowserSession(id: UUID(uuidString: tab.id) ?? UUID(), url: tab.url.flatMap(URL.init(string:)), isPrivate: tab.isPrivate)
        observeBrowser(session, tabID: tab.id)
        browserSessions[tab.id] = session
        return session
    }
    func attachBrowser(_ session: BrowserSession) {
        let tab = WorkspaceTab(id: session.id.uuidString, courseID: courseID, kind: .browser, title: session.isPrivate ? "비공개 브라우저" : "브라우저", isPrivate: session.isPrivate)
        observeBrowser(session, tabID: tab.id); browserSessions[tab.id] = session; addTab(tab, beside: false)
    }
    private func observeBrowser(_ session: BrowserSession, tabID: String) {
        session.onClose = { [weak self] in self?.closeTab(tabID) }
        session.onStateChange = { [weak self] url, title in
            guard let self, let index = self.workspace.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            self.workspace.tabs[index].title = title
            if !self.workspace.tabs[index].isPrivate { self.workspace.tabs[index].url = url?.absoluteString; self.saveWorkspace() }
        }
    }
    func handleMemoryWarning() {
        let visible = Set([workspace.primaryID, workspace.splitEnabled ? workspace.secondaryID : nil].compactMap { $0 })
        for (id, session) in Array(browserSessions) where !visible.contains(id) && !session.hasActiveDownloads {
            if let i = workspace.tabs.firstIndex(where: { $0.id == id }), !workspace.tabs[i].isPrivate { workspace.tabs[i].url = session.webView.url?.absoluteString }
            browserSessions.removeValue(forKey: id)
        }
        saveWorkspace()
    }

    @discardableResult func createNote(title: String = "새 노트", markdown: String = "", beside: Bool = false, open: Bool = true) -> Material? {
        guard !isImporting else { error = "자료를 가져오는 중에는 노트를 만들 수 없습니다."; return nil }
        let data = Data(markdown.utf8)
        let item = Material(courseID: courseID, title: uniqueTitle(title), fileName: "note.md", revision: Self.hash(data), kind: .note)
        // Validate and journal the potentially large content before creating its
        // visible metadata. A failed journal append must not look like success.
        guard persist(NoteContent(materialID: item.id, markdown: markdown), kind: "note", id: "note:\(item.id)"),
              persist(item, kind: "material", id: "material:\(item.id)") else { return nil }
        materials.append(item); notes[item.id] = markdown
        cacheNote(markdown, for: item)
        if open { openMaterial(item, beside: beside) }
        return item
    }
    func openPageNote(_ source: Material, page: Int) {
        if let existing = materials.first(where: { $0.sourceMaterialID == source.id && $0.sourcePage == page && $0.kind == .note }) { openMaterial(existing, beside: true); return }
        let markdown = "# \(source.title) · \(page)쪽\n\n[원본 페이지 열기](bandal://material/\(source.id)?page=\(page))\n\n"
        guard var note = createNote(title: "\(source.title) · \(page)쪽 노트", markdown: markdown, open: false), let index = materials.firstIndex(where: { $0.id == note.id }) else { return }
        note.sourceMaterialID = source.id; note.sourcePage = page; materials[index] = note
        persist(note, kind: "material", id: "material:\(note.id)"); openMaterial(note, beside: true)
    }
    func addFolder(_ title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }
        let folder = MaterialFolder(courseID: courseID, title: value); folders.append(folder)
        persist(folder, kind: "artifact", id: "folder:\(folder.id)")
    }
    func moveMaterial(_ id: String, to folderID: String?) {
        guard let index = materials.firstIndex(where: { $0.id == id }), folderID == nil || folders.contains(where: { $0.id == folderID && $0.courseID == materials[index].courseID }) else { return }
        materials[index].folderID = folderID
        persist(materials[index], kind: "material", id: "material:\(id)")
    }
    func createWhiteboard(beside: Bool = false) {
        let item = Material(courseID: courseID, title: uniqueTitle("화이트보드"), fileName: "canvas.json", revision: UUID().uuidString, kind: .whiteboard)
        materials.append(item); persist(item, kind: "material", id: "material:\(item.id)"); openMaterial(item, beside: beside)
    }
    @discardableResult func saveNote(_ id: String, markdown: String) -> Bool {
        guard !isImporting else { error = "자료를 가져오는 중입니다. 완료한 뒤 다시 저장해 주세요."; return false }
        guard let item = material(id), item.kind == .note else { return false }
        guard notes[id] != markdown else { return true }
        guard persist(NoteContent(materialID: id, markdown: markdown), kind: "note", id: "note:\(id)") else { return false }
        notes[id] = markdown
        cacheNote(markdown, for: item)
        return true
    }
    private func cacheNote(_ markdown: String, for item: Material) {
        do { try write(Data(markdown.utf8), for: item) }
        catch { self.error = "노트 내용은 저장했지만 파일 캐시를 갱신하지 못했습니다: \(error.localizedDescription)" }
    }
    func renameMaterial(_ id: String, to title: String) {
        guard let i = materials.firstIndex(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !title.isEmpty else { return }
        materials[i].title = title
        persist(materials[i], kind: "material", id: "material:\(id)")
        for index in workspace.tabs.indices where workspace.tabs[index].materialID == id { workspace.tabs[index].title = title }
        saveWorkspace()
    }
    func importURL(_ url: URL) {
        guard !isImporting else { error = "자료 가져오기가 끝난 뒤 다시 시도해 주세요."; return }
        guard !courseID.isEmpty else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.lowercased()
            if ext == "bandalpack" || ext == "bandal" { try importExchange(url); return }
            let kind: MaterialKind = ext == "pdf" ? .pdf : (["md", "markdown"].contains(ext) ? .note : (["png", "jpg", "jpeg", "heic", "webp"].contains(ext) ? .image : .file))
            var item = Material(courseID: courseID, title: url.deletingPathExtension().lastPathComponent, fileName: url.lastPathComponent, revision: "", kind: kind)
            guard item.hasSafePath else { throw AIError.message("파일 이름을 확인해 주세요.") }
            let asset = try AssetHasher.revision(of: url)
            item.revision = asset.sha256; item.byteCount = asset.byteCount
            if kind == .note {
                guard asset.byteCount <= 3_000_000 else { throw AIError.message("노트는 3MB 이하로 나누어 가져와 주세요.") }
                let data = try Data(contentsOf: url)
                guard Self.hash(data) == item.revision else { throw AIError.message("가져오는 동안 파일이 변경되었습니다. 다시 시도해 주세요.") }
                guard let text = String(data: data, encoding: .utf8) else { throw AIError.message("UTF-8 형식의 Markdown 파일을 선택해 주세요. 원본은 변경하지 않았습니다.") }
                guard persist(NoteContent(materialID: item.id, markdown: text), kind: "note", id: "note:\(item.id)"),
                      persist(item, kind: "material", id: "material:\(item.id)") else { return }
                materials.append(item); notes[item.id] = text
                cacheNote(text, for: item); openMaterial(item)
                return
            }
            let destination = fileURL(item)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            guard try AssetHasher.revision(of: destination).sha256 == item.revision else { throw AIError.message("가져오는 동안 파일이 변경되었습니다. 다시 시도해 주세요.") }
            guard persist(item, kind: "material", id: "material:\(item.id)") else { return }
            materials.append(item)
            openMaterial(item)
        } catch { self.error = "자료 가져오기 실패: \(error.localizedDescription)" }
    }
    func write(_ data: Data, for item: Material) throws {
        guard item.hasSafePath else { throw AIError.message("자료 경로가 올바르지 않습니다.") }
        let url = fileURL(item); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if item.kind != .note && item.kind != .whiteboard {
            guard Self.hash(data) == item.revision else { throw AIError.message("자료 내용이 원본 버전과 일치하지 않습니다.") }
            if FileManager.default.fileExists(atPath: url.path) {
                guard try AssetHasher.revision(of: url).sha256 == item.revision else { throw AIError.message("기존 원본 파일의 버전이 다릅니다. 기존 파일은 보존했습니다.") }
                return
            }
        }
        try data.write(to: url, options: .atomic)
    }
    private func migrateLegacyMaterialFiles(_ items: [Material]) {
        for item in items where item.kind != .note && item.kind != .whiteboard {
            let destination = fileURL(item)
            let legacy = root.appendingPathComponent(item.legacyRelativePath)
            guard !FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: legacy.path) else { continue }
            do {
                guard try AssetHasher.revision(of: legacy).sha256 == item.revision else {
                    notice = "일부 자료는 현재 버전의 원본을 다시 내려받아야 합니다. 이전 원본은 보존했습니다."
                    continue
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: legacy, to: destination)
            } catch { self.error = "기존 원본의 버전별 보관에 실패했습니다: \(error.localizedDescription)" }
        }
    }
    func saveInkImage(_ data: Data) -> InkImageSource? {
        do {
            let item = Material(courseID: courseID, title: "필기 이미지", fileName: "image.png", revision: Self.hash(data), kind: .image, byteCount: Int64(data.count))
            try write(data, for: item); materials.append(item); persist(item, kind: "material", id: "material:\(item.id)")
            return InkImageSource(relPath: item.relativePath, label: item.title, assetId: item.id)
        } catch { self.error = error.localizedDescription; return nil }
    }
    func registerConvertedPDF(_ file: URL, source: Material) throws {
        let revision = try AssetHasher.revision(of: file, contentType: "application/pdf")
        let item = Material(courseID: source.courseID, title: source.title + " · PDF", fileName: "converted.pdf", revision: revision.sha256, kind: .pdf, byteCount: revision.byteCount, folderID: source.folderID, sourceMaterialID: source.id, sourceRevision: source.revision)
        let destination = fileURL(item)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: destination)
        materials.append(item); persist(item, kind: "material", id: "material:\(item.id)")
    }
    func openLink(_ url: URL) {
        guard url.scheme == "bandal", url.host == "material", let item = material(url.lastPathComponent) else { return }
        if courseID != item.courseID { selectCourse(item.courseID) }
        if let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init), page > 0 {
            PendingPDFNavigation.request(materialID: item.id, page: page)
        }
        openMaterial(item)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func uniqueTitle(_ title: String) -> String {
        let titles = Set(courseMaterials.map(\.title)); if !titles.contains(title) { return title }
        var n = 2; while titles.contains("\(title) \(n)") { n += 1 }; return "\(title) \(n)"
    }
    func ink(_ item: Material, page: Int) -> Data? {
        let key = "drawing:\(item.id):\(item.revision):\(page)"
        guard let data = recordData[key], let value = try? Self.decoder.decode(InkPageRecord.self, from: data) else { return nil }
        return value.documentRevision == item.revision ? value.data : nil
    }
    func saveInk(_ item: Material, page: Int, data: Data) {
        persist(InkPageRecord(materialID: item.id, documentRevision: item.revision, page: page, data: data), kind: "drawing", id: "drawing:\(item.id):\(item.revision):\(page)")
    }
    func readingPage(_ item: Material) -> Int? {
        guard let data = recordData["position:\(item.id)"], let value = try? Self.decoder.decode(MaterialReadingPosition.self, from: data), value.documentRevision == item.revision else { return nil }
        return value.page
    }
    func saveReadingPage(_ item: Material, page: Int) {
        guard page > 0, readingPage(item) != page else { return }
        persist(MaterialReadingPosition(courseID: item.courseID, materialID: item.id, documentRevision: item.revision, page: page), kind: "artifact", id: "position:\(item.id)")
    }
    func inkRecords(for item: Material) -> [StoredRecord] {
        recordData.filter { $0.key.hasPrefix("drawing:\(item.id):") }.map { StoredRecord(id: $0.key, kind: "drawing", payload: $0.value) }
    }
    func saveTask(_ item: StudyTask) {
        if let i = tasks.firstIndex(where: { $0.id == item.id }) { tasks[i] = item } else { tasks.append(item) }
        persist(item, kind: "task", id: "task:\(item.id)")
    }
    func saveCard(_ item: Flashcard) {
        if let i = cards.firstIndex(where: { $0.id == item.id }) { cards[i] = item } else { cards.append(item) }
        persist(item, kind: "flashcard", id: "flashcard:\(item.id)")
    }
    func reviewCard(_ item: Flashcard, remembered: Bool) {
        var card = item; card.reviews += 1; card.interval = remembered ? max(1, card.interval * 2) : 0
        card.due = Date().addingTimeInterval(remembered ? Double(card.interval) * 86400 : 600); saveCard(card)
        let event = LearningEvent(courseID: card.courseID, objectID: card.id, action: "review", value: remembered ? "remembered" : "again")
        persist(event, kind: "learningEvent", id: "learningEvent:\(event.id)")
    }
    func saveVocabulary(_ item: VocabularyEntry) { vocabulary.append(item); persist(item, kind: "vocabulary", id: "vocabulary:\(item.id)") }
    func saveConversation(_ item: Conversation) { conversations[item.id] = item; persist(item, kind: "chat", id: "chat:\(item.id)") }
    func saveRecording(_ item: RecordingMetadata) {
        var item = item
        if let i = recordings.firstIndex(where: { $0.id == item.id }) {
            if ["completed", "recovered", "interrupted"].contains(item.state), item.assetRevision == nil {
                item.assetRevision = recordings[i].assetRevision; item.byteCount = recordings[i].byteCount
            }
            recordings[i] = item
        } else { recordings.insert(item, at: 0) }
        persist(item, kind: "recording", id: "recording:\(item.id)")
    }
    private func seedWelcome() {
        addCourse("내 학습 공간")
        createNote(title: "반달 시작하기", markdown: "# 반달에 오신 것을 환영해요\n\nPDF, 노트, 웹을 한 작업 공간에서 열어 보세요.\n\n- **자료 가져오기**로 PDF를 추가합니다.\n- 탭 메뉴의 **옆에서 열기**로 두 자료를 나란히 봅니다.\n- Pencil로 쓰고, 손가락으로 페이지를 이동합니다.\n- 설정에서 AI API 키와 동기화 계정을 연결할 수 있습니다.\n\n이 노트와 안내 PDF는 편집해도 되는 시작 자료입니다.")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { context in
            context.beginPage()
            let title = "반달에서 시작하는\n나의 학습 공간"
            title.draw(in: CGRect(x: 52, y: 80, width: 490, height: 140), withAttributes: [.font: UIFont.systemFont(ofSize: 35, weight: .bold), .foregroundColor: UIColor(BandalTheme.accent)])
            "이 페이지 위에 Apple Pencil로 자유롭게 써 보세요.\n손가락으로 이동하고 두 손가락으로 확대할 수 있습니다.\n\n노트나 브라우저 탭을 옆에서 열어 함께 사용해 보세요.".draw(in: CGRect(x: 52, y: 240, width: 490, height: 150), withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.darkGray])
            UIColor.systemGray4.setStroke()
            for y in stride(from: 450, to: 780, by: 34) { let line = UIBezierPath(); line.move(to: CGPoint(x: 52, y: y)); line.addLine(to: CGPoint(x: 543, y: y)); line.lineWidth = 0.5; line.stroke() }
        }
        let item = Material(courseID: courseID, title: "Pencil 필기 시작하기", fileName: "welcome.pdf", revision: Self.hash(data), kind: .pdf)
        do { try write(data, for: item); materials.append(item); persist(item, kind: "material", id: "material:\(item.id)"); openMaterial(item, beside: true) }
        catch { self.error = error.localizedDescription }
        workspace.focusedPane = 0; saveWorkspace()
    }
}
