import Foundation
import PDFKit
import os

/// A serial Swift storage engine. SQLite transactions, file publication and
/// recovery are ordered here; presentation and network operations run outside
/// the storage queue so a modal or AI response never blocks document saving.
final class DesktopRuntime: @unchecked Sendable {
    let root: URL
    let legacyRoot: URL
    let log: DesktopLog
    var onEmit: ((String, Any) -> Void)?
    var onNativeCall: ((String, [String: Any]) async throws -> Any)?
    /// Called on the storage queue after a channel wrote to the database (sync, design §1.6).
    var onLocalChange: (() -> Void)?
    /// Checked on the storage queue before each channel (the free allowance, design §8.2). Unset in tests.
    var limits: ((String, [String: Any], NativeLibraryRepository) throws -> Void)?
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
    private var handwriting: NativeHandwritingRepository?
    private var unifiedSearch: NativeUnifiedSearchRepository?
    /// When each course's text index was last compared with its folder.
    private var searchRefreshed: [String:Date] = [:]
    private var handwritingState = HandwritingState()
    private var learning: NativeLearningRepository?
    private var whiteboards: NativeWhiteboardRepository?
    private var initialization: Task<Void,Error>?
    private var watcher: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var watches: [String:String] = [:]
    private var snapshots: [String:String] = [:]
    private var workspaceSession = ""
    private var active = true

    init(root: URL, legacyRoot: URL) { self.root = root; self.legacyRoot = legacyRoot; log = DesktopLog(root:root) }
    deinit { watcher?.cancel(); memoryPressure?.cancel() }

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
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: self.queue)
            pressure.setEventHandler { [weak self] in self?.pdf?.releaseDecodedDrawings() }
            self.memoryPressure = pressure; pressure.resume()
            self.recordings = NativeRecordingRepository(context:context)
            self.preferences = NativePreferencesRepository(context:context)
            self.search = try NativeSearchRepository(context:context)
            // Search is an extra: a failure to prepare its tables must not keep documents from opening.
            do {
                self.handwriting = try NativeHandwritingRepository(context:context,pdf:pdf)
                self.unifiedSearch = try NativeUnifiedSearchRepository(context:context)
            } catch { self.log.record("search.index.unavailable",code:(error as? DesktopRuntimeError)?.code) }
            self.handwritingState.enabled = (try? self.preferences?.settings())?["handwritingSearch"] as? Bool != false
            let learning = NativeLearningRepository(context:context)
            self.learning = learning
            // Interrupted-run recovery walks every course folder; it runs after the UI is ready.
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
        if channel == "studyMarket:request" || channel == "native:extractArticle" || channel.hasPrefix("native:cloud") || Self.nativeChannels.contains(channel) || channel.hasPrefix("browser:") || channel.hasPrefix("credentials:") || channel.hasPrefix("auth:") || channel.hasPrefix("sync:") || channel.hasPrefix("cloudSync:") || channel.hasPrefix("native:ai") || (channel.hasPrefix("nativeSettings:") && channel != "nativeSettings:usage") {
            return try await native(Self.aliases[channel] ?? channel,object)
        }
        if let result = try await onQueue({
            let started = ProcessInfo.processInfo.systemUptime, changes = self.context?.db.totalChanges
            defer {
                if let changes, self.context?.db.totalChanges != changes { self.onLocalChange?() }
                switch channel {
                case "nativePDF:binding": DesktopSignpost.benchmark("storage.binding", startedAt: started)
                case "drawings:listForFile": DesktopSignpost.benchmark("storage.drawings", startedAt: started)
                case "annotations:listForFile": DesktopSignpost.benchmark("storage.annotations", startedAt: started)
                case "pdf:restructure": DesktopSignpost.benchmark("storage.pageRestructure", startedAt: started)
                case "pdf:pageHistory": DesktopSignpost.benchmark("storage.pageHistory", startedAt: started)
                default: break
                }
            }
            return try self.handle(channel,object)
        }) { return result }
        throw DesktopRuntimeError("이 작업은 Swift 앱에서 제공되지 않습니다: \(channel)",code:"UNSUPPORTED_CHANNEL")
    }
    private func native(_ channel: String,_ request: [String:Any]) async throws -> Any {
        guard let onNativeCall else { throw DesktopRuntimeError("기기 서비스를 연결하지 못했습니다: \(channel)",code:"ENOSYS") }; return try await onNativeCall(channel,request)
    }
    private static let aliases = ["agent:availability":"native:aiAvailability","agent:models":"native:aiModels"]
    private static let nativeChannels: Set<String> = ["chat:send","chat:cancel","chat:close","recordings:create","recordings:control","recordings:append","recordings:models","recordings:downloadModel","recordings:cancelDownload","runtime:recordingStart","runtime:recordingDevices","runtime:recordingAbandon","agent:availability","agent:models","native:configureAccount","native:saveFile","native:pickFiles","native:openLogs","materials:preview","materials:reveal","materials:share","materials:export","courses:pickFolder","chat:pickAttachments","chat:openArtifact","print:pdf","print:savePdfAs","clipboard:beginCopy","clipboard:writeImage"]
    private func handle(_ channel: String,_ request: [String:Any]) throws -> Any? {
        guard context != nil, let storage = library else { throw DesktopRuntimeError("자료 저장소를 시작하지 못했습니다.") }
        try limits?(channel, request, storage)
        switch channel {
        case "nativeMembership:usage":
            let usage = try FreeTier.usage(library: storage)
            return ["courses": usage.courses, "documents": usage.documents]
        case "nativeSettings:usage":
            guard let context else { throw DesktopRuntimeError("저장소가 준비되지 않았습니다.") }
            return try NativeSettingsUsageRepository.summary(context:context,request:request)
        case "nativeBrowser:shortcuts": return NativeBrowserShortcuts.resolve(try preferences?.settings() ?? [:])
        case "nativeRuntime:workspaceReady": workspaceSession = try NativeValue.string(request["workspaceSessionId"],"작업 공간"); watches.removeAll(); snapshots.removeAll(); return NativeValue.ok
        case "nativeRuntime:workspaceReset": watches.removeAll(); snapshots.removeAll(); return NativeValue.ok
        case "nativeRuntime:recoverDeferred":
            try learning?.recoverInterruptedRuns()
            // Notes written before this build, or synced in while the app was closed, are read in the background.
            scheduleHandwriting(after:handwritingTiming.launch); return NativeValue.ok
        case "handwriting:status": return handwritingStatus
        case "search:unified":
            let course = request["courseId"] as? String
            guard var result = try unifiedSearch?.query(text:try NativeValue.string(request["query"],"검색어"),courseID:course) else { return nil }
            result["handwritingIndexing"] = handwritingState.running
            refreshSearchIndexes(course)
            return result
        case "search:document":
            let course = try NativeValue.string(request["courseId"],"과목")
            let result = try unifiedSearch?.document(courseID:course,relativePath:try NativeValue.string(request["relPath"],"자료"),text:request["query"] as? String ?? "")
            // A PDF opened before its text was extracted gets it now; `search:changed` repeats the search.
            refreshSearchIndexes(course)
            return result
        case "nativeGuide:handwritingLines":
            guard let context else { throw DesktopRuntimeError("저장소가 준비되지 않았습니다.") }
            return try NativePDFGuideHandwriting.lines(context:context,request:request)
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
        if let result = try library?.handle(channel,request) {
            if channel == "materials:delete", let course = request["courseId"] as? String, let path = request["relPath"] as? String {
                try handwriting?.forget(courseID:course,relativePath:path)
                scheduleHandwriting(after:0)
            } else if ["materials:import","materials:importShared","materials:duplicate","materials:adoptFile","courses:restore","courses:relink"].contains(channel) {
                // A file that comes back, or a course that does, brings its ink pages with it.
                scheduleHandwriting(after:handwritingTiming.debounce)
            }
            return result
        }
        if let result = try pdfPages?.handle(channel,request) {
            // Moving or deleting pages renumbers their ink.
            if ["pdf:restructure","pdf:restorePages"].contains(channel) { scheduleHandwriting(after:handwritingTiming.debounce) }
            return result
        }
        if let result = try pdf?.handle(channel:channel,request) { try inkChanged(channel,request,result); return result }
        if let result = try planner?.handle(channel,request) { return result }
        if let result = try recordings?.handle(channel,request) { return result }
        if let result = try preferences?.handle(channel,request) {
            if channel == "settings:set" || channel == "settings:reset" { try handwritingSettingChanged(result) }
            return result
        }
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
    /// Opens in flight. Background indexing and sync yield while this is non-zero.
    private let foregroundWork = OSAllocatedUnfairLock(initialState: 0)
    func beginForegroundWork() { foregroundWork.withLock { $0 += 1 } }
    func endForegroundWork() { foregroundWork.withLock { $0 = max(0, $0 - 1) } }
    var isForegroundBusy: Bool { foregroundWork.withLock { $0 > 0 } }
    private func schedulePDFSearch(_ course: String, delay: TimeInterval = 3) {
        guard !indexingCourses.contains(course) else { return }
        // Text extraction of every PDF in the course is background work: never
        // during launch or while a document is opening.
        guard delay <= 0 else { queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.schedulePDFSearch(course, delay: 0) }; return }
        guard !isForegroundBusy else { queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.schedulePDFSearch(course, delay: 0) }; return }
        do {
            let jobs = try search?.preparePDFJobs(courseID:course) ?? []
            guard !jobs.isEmpty else { return }; indexingCourses.insert(course)
            Task.detached(priority:.utility) { [weak self] in
                for job in jobs {
                    guard let self, !Task.isCancelled else { return }
                    while self.isForegroundBusy { try? await Task.sleep(for: .seconds(1)) }
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
    /// The query above reads the index as it is. Folders are compared and new PDFs extracted afterwards,
    /// one course per queue turn so a save never waits behind a whole library; `search:changed` re-runs the query.
    private func refreshSearchIndexes(_ course: String?) {
        let courses = course.map { [$0] } ?? ((try? context?.query("SELECT id FROM courses WHERE deleted_at IS NULL"))?.compactMap { $0["id"] as? String } ?? [])
        for course in courses where Date().timeIntervalSince(searchRefreshed[course] ?? .distantPast) > 15 {
            searchRefreshed[course] = Date()
            queue.async { [weak self] in
                guard let self, let search = self.search, let db = self.context?.db else { return }
                let changes = db.totalChanges
                do { try search.refresh(courseID:course) } catch { self.log.record("search.refresh.skipped",code:(error as? DesktopRuntimeError)?.code); return }
                if db.totalChanges != changes { self.onEmit?("search:changed",["courseId":course]) }
                self.schedulePDFSearch(course)
            }
        }
    }

    // MARK: Handwriting index

    private struct HandwritingState {
        var enabled = true
        var due: DispatchWorkItem?
        var running = false
        /// Ink changed while a pass was running: plan again when it ends.
        var again = false
        var done = 0, total = 0
        var emitted = ""
        /// Pages that could not be read this session (a missing or replaced original). Retried on the next launch.
        var skipped = Set<String>()
        var lastInk = Date.distantPast
    }
    /// `debounce`: after the pen lifts; a new stroke restarts it. `idle`: the same wait in Low Power Mode.
    var handwritingTiming = (debounce: 2.0, launch: 5.0, idle: 30.0)
    private var handwritingStatus: [String:Any] {
        ["enabled":handwritingState.enabled,"active":handwritingState.running,"done":handwritingState.done,"total":handwritingState.total]
    }
    private func emitHandwritingProgress() {
        let state = "\(handwritingState.enabled):\(handwritingState.running):\(handwritingState.done):\(handwritingState.total)"
        guard state != handwritingState.emitted else { return }
        handwritingState.emitted = state; onEmit?("handwriting:progress",handwritingStatus)
    }
    private func inkChanged(_ channel: String,_ request: [String:Any],_ result: Any) throws {
        guard handwritingState.enabled, ["drawings:create","drawings:update","drawings:replace","drawings:delete"].contains(channel) else { return }
        handwritingState.lastInk = Date()
        if channel == "drawings:update" || channel == "drawings:replace" {
            let value = result as? [String:Any], drawing = value?["after"] as? [String:Any] ?? value
            if let course = drawing?["courseId"] as? String, let path = drawing?["relPath"] as? String, let page = drawing?["page"] as? Int {
                try handwriting?.invalidate(courseID:course,relativePath:path,page:page)
            }
        }
        scheduleHandwriting(after:handwritingTiming.debounce)
    }
    private func handwritingSettingChanged(_ settings: Any) throws {
        let enabled = (settings as? [String:Any])?["handwritingSearch"] as? Bool != false
        guard enabled != handwritingState.enabled else { return }
        handwritingState.enabled = enabled
        if enabled { scheduleHandwriting(after:0); return }
        handwritingState.due?.cancel(); handwritingState.due = nil
        handwritingState.done = 0; handwritingState.total = 0
        try handwriting?.clear()
        emitHandwritingProgress()
    }
    /// Storage queue only. Each call restarts the wait, so recognition follows the last change.
    private func scheduleHandwriting(after delay: TimeInterval) {
        guard handwritingState.enabled, handwriting != nil else { return }
        handwritingState.due?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startHandwriting() }
        handwritingState.due = work
        queue.asyncAfter(deadline:.now()+delay,execute:work)
    }
    /// Seconds still to wait: a document is opening, or the pen was down too recently.
    private var handwritingWait: TimeInterval {
        let quiet = ProcessInfo.processInfo.isLowPowerModeEnabled ? handwritingTiming.idle : handwritingTiming.debounce
        return max(isForegroundBusy ? 1 : 0, quiet - Date().timeIntervalSince(handwritingState.lastInk))
    }
    private func startHandwriting() {
        handwritingState.due = nil
        guard handwritingState.enabled, let handwriting else { return }
        if handwritingState.running { handwritingState.again = true; return }
        let wait = handwritingWait
        if wait > 0 { scheduleHandwriting(after:wait); return }
        do {
            let plan = try handwriting.plan()
            let jobs = plan.jobs.filter { !handwritingState.skipped.contains($0.key + ":" + $0.digest) }
            handwritingState.total = plan.total - (plan.jobs.count - jobs.count)
            handwritingState.done = handwritingState.total - jobs.count
            handwritingState.running = !jobs.isEmpty; handwritingState.again = false
            emitHandwritingProgress()
            guard !jobs.isEmpty else { return }
            Task.detached(priority:.utility) { [weak self] in
                await self?.recognizeHandwriting(jobs)
                guard let self else { return }
                _ = try? await self.onQueue {
                    self.handwritingState.running = false
                    self.emitHandwritingProgress()
                    if self.handwritingState.again { self.scheduleHandwriting(after:0) }
                }
            }
        } catch {
            log.record("handwriting.plan.failed",code:(error as? DesktopRuntimeError)?.code)
            // A busy database now is not a reason to stay unindexed until the next stroke.
            scheduleHandwriting(after:handwritingTiming.idle)
        }
    }
    /// One page at a time on a utility task. Only the short reads and writes run on the storage queue.
    private func recognizeHandwriting(_ jobs: [NativeHandwritingJob]) async {
        var opened: (url: URL, document: PDFDocument)?
        for job in jobs {
            while let wait = try? await onQueue({ self.handwritingWait }), wait > 0 { try? await Task.sleep(for:.seconds(wait)) }
            do {
                guard let source = try await onQueue({ self.handwritingState.enabled ? try self.handwriting?.source(job) : nil }) else { return }
                var lines: [NativeHandwritingLine]?
                if !source.unchanged {
                    if opened?.url != source.url { opened = PDFDocument(url:source.url).map { (source.url,$0) } }
                    // An original that cannot be opened right now is skipped, not recorded as a page without writing.
                    guard let size = opened.flatMap({ NativeHandwritingRecognizer.pageSize(of:$0.document,page:job.page) }) else { throw DesktopRuntimeError("PDF page is unavailable",code:"NOT_FOUND") }
                    let started = ProcessInfo.processInfo.systemUptime
                    lines = try NativeHandwritingRecognizer.lines(rows:source.rows,pageSize:size)
                    DesktopSignpost.benchmark("handwriting.page",startedAt:started)
                }
                let recognized = lines
                try await onQueue {
                    guard self.handwritingState.enabled, try self.handwriting?.commit(job,inkKey:source.inkKey,lines:recognized) == true else { self.handwritingState.again = true; return }
                    self.handwritingState.done += 1
                    self.emitHandwritingProgress()
                }
            } catch {
                log.record("handwriting.page.skipped",code:(error as? DesktopRuntimeError)?.code)
                // Skipped for this session while its ink stays as it is; an edit makes it a new job.
                _ = try? await onQueue { self.handwritingState.skipped.insert(job.key + ":" + job.digest); self.handwritingState.total = max(self.handwritingState.done,self.handwritingState.total - 1) }
            }
        }
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
    /// Sync engine work (design §1.1): its store, outbox and apply run here like every repository.
    func withSyncStorage<T>(_ work: @escaping (NativeRepositoryContext, NativeLibraryRepository) throws -> T) async throws -> T {
        try await onQueue {
            guard let context = self.context, let library = self.library else { throw DesktopRuntimeError("자료 저장소를 시작하지 못했습니다.") }
            let changes = context.db.totalChanges
            // Ink pulled from another device is recognised here too: each device builds its own index.
            defer { if context.db.totalChanges != changes { self.scheduleHandwriting(after:self.handwritingTiming.debounce) } }
            return try work(context, library)
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
