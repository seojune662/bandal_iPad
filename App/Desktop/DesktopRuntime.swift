import Foundation

/// A serial Swift storage engine. SQLite transactions, file publication and
/// recovery are ordered here; presentation and network operations run outside
/// the storage queue so a modal or AI response never blocks document saving.
final class DesktopRuntime: @unchecked Sendable {
    let root: URL
    let legacyRoot: URL
    let log: DesktopLog
    var onEmit: ((String, Any) -> Void)?
    var onNativeCall: ((String, [String: Any]) async throws -> Any)?
    private let queue = DispatchQueue(label:"app.bandal.swift-storage",qos:.userInitiated)
    private var context: NativeRepositoryContext?
    private var library: NativeLibraryRepository?
    private var pdf: NativePDFRepository?
    private var pdfPages: NativePDFPageRepository?
    private var planner: NativePlannerRepository?
    private var recordings: NativeRecordingRepository?
    private var preferences: NativePreferencesRepository?
    private var chat: NativeChatRepository?
    private var sync: NativeSyncRepository?
    private var search: NativeSearchRepository?
    private var indexingCourses = Set<String>()
    private var learning: NativeLearningRepository?
    private var whiteboards: NativeWhiteboardRepository?
    private var initialization: Task<Void,Error>?
    private var watcher: DispatchSourceTimer?
    private var watches: [String:String] = [:]
    private var snapshots: [String:String] = [:]
    private var workspaceSession = ""
    private var active = true

    init(root: URL, legacyRoot: URL) { self.root = root; self.legacyRoot = legacyRoot; log = DesktopLog(root:root) }
    deinit { watcher?.cancel() }

    @MainActor func start() async throws {
        if let initialization { return try await initialization.value }
        let task = Task { try await self.load() }; initialization = task
        do { try await task.value } catch { initialization = nil; throw error }
    }
    private func load() async throws {
        try await onQueue {
            guard self.context == nil else { return }
            let context = try NativeRepositoryContext(root:self.root,legacyRoot:self.legacyRoot)
            try NativeSyncRepository.recoverFiles(context:context)
            context.emit = { [weak self] channel,payload in self?.onEmit?(channel,payload) }
            let library = NativeLibraryRepository(context:context)
            try library.recoverPathChanges()
            let pdf = try NativePDFRepository(context:context)
            context.beforeMaterialRename = { [weak pdf] course,from,to,directory in try pdf?.prepareRename(courseID:course,from:from,to:to,isDirectory:directory) }
            self.library = library
            self.pdfPages = try NativePDFPageRepository(context:context,pdf:pdf)
            self.pdf = pdf; self.planner = NativePlannerRepository(context:context)
            self.recordings = NativeRecordingRepository(context:context)
            self.preferences = NativePreferencesRepository(context:context)
            self.search = try NativeSearchRepository(context:context)
            let learning = NativeLearningRepository(context:context)
            self.learning = learning
            try learning.recoverInterruptedRuns()
            context.planMaterialRenameFiles = { [weak learning] course,from,to,directory,operation in
                try learning?.planPathChanges(courseID:course,from:from,to:to,isDirectory:directory,operationID:operation) ?? []
            }
            self.whiteboards = NativeWhiteboardRepository(context:context)
            self.chat = NativeChatRepository(context:context)
            try NativeLegacyMigration.apply(context:context,library:library,pdf:pdf)
            let sync = try NativeSyncRepository(context:context,library:library,checkPDFBinding:{ try pdf.checkBinding($0) })
            let artifacts = NativeSyncArtifacts(context:context)
            sync.registerProjection(snapshot:artifacts.snapshot,plan:{ try artifacts.plan($0,assets:$1) })
            let drawings = NativeSyncDrawings(context:context,pdf:pdf)
            sync.registerProjection(snapshot:drawings.snapshot,plan:{ try drawings.plan($0,assets:$1) })
            self.sync = sync
            try self.recordings?.recover(); try self.chat?.recover()
            self.context = context
            let timer = DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now()+2,repeating:5) // ponytail: a folder walk per tick; 2 s was constant background heat
            timer.setEventHandler { [weak self] in self?.poll() }; self.watcher = timer; timer.resume()
        }
        log.record("runtime.swift.started")
    }
    func invoke(_ channel: String, request: Any = [:]) async throws -> Any {
        guard !channel.hasPrefix("native") else { throw DesktopRuntimeError("비공개 저장 작업입니다.",code:"UNSUPPORTED_CHANNEL") }
        return try await dispatch(channel,request:request)
    }
    func invokePrivate(_ channel: String, request: Any = [:]) async throws -> Any { try await dispatch(channel,request:request) }
    private func dispatch(_ channel: String, request: Any) async throws -> Any {
        guard let object = request as? [String:Any] else { throw DesktopRuntimeError("작업 형식을 확인해 주세요.",code:"VALIDATION_ERROR") }
        if channel == "chat:open", onNativeCall != nil { return try await native("nativeChat:open",object) }
        if channel == "pdf:exportAnnotated" || channel == "pdf:export" {
            guard let output = try await invokePrivate("nativePDF:exportBytes",request:object) as? [String:Any] else { throw DesktopRuntimeError("PDF를 내보내지 못했습니다.") }
            let result = try await native("native:saveFile",output) as? [String:Any]
            return ["savedPath":result?["path"] ?? NativeValue.null]
        }
        if channel == "studyMarket:request" || channel == "native:extractArticle" || channel.hasPrefix("native:cloud") || Self.nativeChannels.contains(channel) || channel.hasPrefix("browser:") || channel.hasPrefix("credentials:") || channel.hasPrefix("auth:") || channel.hasPrefix("sync:") || channel.hasPrefix("native:ai") || (channel.hasPrefix("nativeSettings:") && channel != "nativeSettings:usage") {
            return try await native(Self.aliases[channel] ?? channel,object)
        }
        if let result = try await onQueue({ try self.handle(channel,object) }) { return result }
        throw DesktopRuntimeError("이 작업은 Swift 앱에서 제공되지 않습니다: \(channel)",code:"UNSUPPORTED_CHANNEL")
    }
    private func native(_ channel: String,_ request: [String:Any]) async throws -> Any {
        guard let onNativeCall else { throw DesktopRuntimeError("기기 서비스를 연결하지 못했습니다: \(channel)",code:"ENOSYS") }; return try await onNativeCall(channel,request)
    }
    private static let aliases = ["agent:availability":"native:aiAvailability","agent:apiKey":"native:aiKeyStatus","agent:setApiKey":"native:aiSetKey","agent:models":"native:aiModels"]
    private static let nativeChannels: Set<String> = ["chat:send","chat:cancel","chat:close","recordings:create","recordings:control","recordings:append","recordings:models","recordings:downloadModel","recordings:cancelDownload","runtime:recordingStart","runtime:recordingDevices","runtime:recordingAbandon","agent:availability","agent:apiKey","agent:setApiKey","agent:models","native:configureAccount","native:saveFile","native:pickFiles","native:openLogs","materials:preview","materials:reveal","materials:share","materials:export","courses:pickFolder","chat:pickAttachments","chat:openArtifact","print:pdf","print:savePdfAs","clipboard:beginCopy","clipboard:writeImage"]
    private func handle(_ channel: String,_ request: [String:Any]) throws -> Any? {
        guard context != nil else { throw DesktopRuntimeError("자료 저장소를 시작하지 못했습니다.") }
        switch channel {
        case "nativeSettings:usage":
            guard let context else { throw DesktopRuntimeError("저장소가 준비되지 않았습니다.") }
            return try NativeSettingsUsageRepository.summary(context:context,request:request)
        case "nativeBrowser:shortcuts": return NativeBrowserShortcuts.resolve(try preferences?.settings() ?? [:])
        case "nativeRuntime:workspaceReady": workspaceSession = try NativeValue.string(request["workspaceSessionId"],"작업 공간"); watches.removeAll(); snapshots.removeAll(); return NativeValue.ok
        case "nativeRuntime:workspaceReset": watches.removeAll(); snapshots.removeAll(); return NativeValue.ok
        case "nativeRuntime:active": active = request["active"] as? Bool == true; if active { poll() }; return NativeValue.ok
        case "pdf:openPageNote":
            guard let context, let pdf else { throw DesktopRuntimeError("PDF 저장소가 준비되지 않았습니다.") }
            return try NativePDFPageNoteRepository(context:context,pdf:pdf).open(request)
        case "nativePDF:pageNoteSource":
            guard let context, let pdf else { throw DesktopRuntimeError("PDF 저장소가 준비되지 않았습니다.") }
            return try NativePDFPageNoteRepository(context:context,pdf:pdf).source(request)
        case "recordings:export":
            guard let note = try recordings?.handle("nativeRecording:markdown",request) as? [String:Any], let title = note["title"] as? String else { throw DesktopRuntimeError("전사 내용을 읽지 못했습니다.") }
            let name = title.components(separatedBy:CharacterSet(charactersIn:"/\\:*?\"<>|\n\r")).joined().trimmingCharacters(in:.whitespacesAndNewlines)
            guard let file = try library?.handle("materials:writeFile",["courseId":note["courseId"]!,"dirRelPath":"","fileName":(name.isEmpty ? "강의 녹음" : name)+".md","encoding":"utf8","data":note["markdown"]!]) as? [String:Any] else { throw DesktopRuntimeError("전사 노트를 만들지 못했습니다.") }
            return ["courseId":note["courseId"]!,"relPath":file["relPath"] ?? NativeValue.null]
        case "materials:watch", "materials:unwatch":
            guard request["workspaceSessionId"] as? String == workspaceSession else { throw DesktopRuntimeError("작업 공간이 변경되었습니다.") }
            let id = try NativeValue.string(request["subscriptionId"],"구독"), course = try NativeValue.string(request["courseId"],"과목")
            if channel == "materials:watch" {
                _ = try context?.courseFolder(course); watches[id] = course
                if let tree = try library?.handle("materials:tree",["courseId":course]) { snapshots[course] = try NativeValue.json(tree) }
                schedulePDFSearch(course)
            } else if watches[id] == course { watches.removeValue(forKey:id) }
            return NativeValue.ok
        default:break
        }
        if let result = try library?.handle(channel,request) { return result }
        if let result = try pdfPages?.handle(channel,request) { return result }
        if let result = try pdf?.handle(channel:channel,request) { return result }
        if let result = try planner?.handle(channel,request) { return result }
        if let result = try recordings?.handle(channel,request) { return result }
        if let result = try preferences?.handle(channel,request) { return result }
        if let result = try chat?.handle(channel == "nativeChat:open" ? "chat:open" : channel,request) { return result }
        if let result = try sync?.handle(channel,request) { return result }
        if let result = try learning?.handle(channel,request) { return result }
        if let result = try whiteboards?.handle(channel,request) { return result }
        if let result = try search?.handle(channel,request) {
            if channel == "search:query", let course = request["courseId"] as? String { schedulePDFSearch(course) }
            return result
        }
        return nil
    }
    private func schedulePDFSearch(_ course: String) {
        guard !indexingCourses.contains(course) else { return }
        do {
            let jobs = try search?.preparePDFJobs(courseID:course) ?? []
            guard !jobs.isEmpty else { return }; indexingCourses.insert(course)
            Task.detached(priority:.utility) { [weak self] in
                for job in jobs {
                    guard let self, !Task.isCancelled else { return }
                    do {
                        let text = try NativeSearchRepository.extract(job)
                        try await self.onQueue { try self.search?.commit(text) }
                    } catch { self.log.record("search.pdf.skipped",code:(error as? DesktopRuntimeError)?.code) }
                }
                guard let self else { return }
                _ = try? await self.onQueue { self.indexingCourses.remove(course) }
            }
        } catch { log.record("search.pdf.unavailable",code:(error as? DesktopRuntimeError)?.code) }
    }
    private func poll() {
        guard active else { return }
        for course in Set(watches.values) {
            do {
                guard let tree = try library?.handle("materials:tree",["courseId":course]) else { continue }
                let current = try NativeValue.json(tree)
                if let old = snapshots[course], old != current { onEmit?("materials:changed",["courseId":course]) }
                snapshots[course] = current
            } catch { onEmit?("backend:error",["operation":"materials.watch","message":error.localizedDescription]) }
        }
    }
    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in queue.async { do { continuation.resume(returning:try work()) } catch { continuation.resume(throwing:error) } } }
    }
    func readMaterial(courseID: String, relativePath: String) async throws -> Data {
        let response = try await invoke("materials:readFile",request:["courseId":courseID,"relPath":relativePath])
        if let bytes = response as? Data { return bytes }
        if let object = response as? [String:Any] {
            if let encoded = object["__bandalBytes"] as? String, let data = Data(base64Encoded:encoded) { return data }
            if let data = object["data"] as? String { if object["encoding"] as? String == "base64", let bytes = Data(base64Encoded:data) { return bytes }; return Data(data.utf8) }
        }
        throw DesktopRuntimeError("자료 내용을 읽지 못했습니다.")
    }
}
