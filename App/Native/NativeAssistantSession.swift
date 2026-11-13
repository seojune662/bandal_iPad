import Combine
import SwiftUI

/// A material the answer read through `read_material`: the chip under the answer.
struct NativeChatSource: Identifiable, Equatable {
    let courseID: String
    let relPath: String
    let page: Int?
    var id: String { courseID + ":" + relPath + "#\(page ?? 0)" }
    var title: String { ((relPath as NSString).lastPathComponent as NSString).deletingPathExtension + (page.map { " p.\($0)" } ?? "") }
    /// The `nativeWorkspace:openDocument` payload: the material, at the page when one was read.
    var request: [String: Any] {
        var value: [String: Any] = ["courseId": courseID, "relPath": relPath, "kind": NativeSidebarDescriptor.materialKind(relPath)]
        if let page { value["page"] = page }
        return value
    }
    init?(_ value: [String: Any]) {
        guard let course = value["courseId"] as? String, let path = value["relPath"] as? String, !path.isEmpty else { return nil }
        courseID = course; relPath = path; page = (value["page"] as? NSNumber)?.intValue
    }
}

struct NativeChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let attachments: [NativeAssistantAttachment]
    let artifacts: [NativeAssistantResult]
    let sources: [NativeChatSource]
    let interrupted: Bool
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let role = value["role"] as? String else { return nil }
        self.id = id; self.role = role
        let blocks = value["blocks"] as? [[String: Any]] ?? []
        interrupted = blocks.contains { ($0["payload"] as? [String: Any])?["interrupted"] as? Bool == true }
        text = blocks.compactMap { block -> String? in
            let payload = block["payload"] as? [String: Any]
            if block["kind"] as? String == "text" {
                let value = payload?["text"] as? String ?? block["payload"] as? String ?? ""
                return payload?["interrupted"] as? Bool == true ? value + "\n\n응답이 중단되었습니다." : value
            }
            if block["kind"] as? String == "tool" { return payload?["label"] as? String ?? payload?["summary"] as? String }
            return nil
        }.joined(separator: "\n\n")
        attachments = blocks.filter { $0["kind"] as? String == "attachment" }.compactMap { ($0["payload"] as? [String: Any]).flatMap(NativeAssistantAttachment.decode) }
        artifacts = blocks.filter { $0["kind"] as? String == "artifact" }.compactMap { ($0["payload"] as? [String: Any]).flatMap(NativeAssistantResult.init) }
        sources = blocks.filter { $0["kind"] as? String == "source" }.compactMap { ($0["payload"] as? [String: Any]).flatMap(NativeChatSource.init) }
    }
}

struct NativeAssistantResult: Identifiable, Equatable {
    let id: String
    let title: String
    let mode: String
    let document: NativeDocumentReference
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let project = value["projectId"] as? String,
              let raw = value["binding"] as? [String: Any], let course = raw["courseId"] as? String,
              let root = raw["rootRelPath"] as? String else { return nil }
        self.id = id; title = value["title"] as? String ?? "학습 자료"; mode = value["generationMode"] as? String ?? "quiz"
        document = NativeLearningDocumentTarget(projectID: project, binding: .init(courseID: course, rootRelPath: root), kind: value["kind"] as? String == "article" ? .article : .artifact, entityID: id).document(title: title)
    }
}

struct NativeChatConversation: Identifiable {
    let id: String
    let title: String
    let provider: String
}

struct NativeAssistantDraft: Codable, Equatable {
    var text = ""
    var mode = NativeAssistantMode.chat
    var attachments: [NativeAssistantAttachment] = []
    var document: NativeDocumentReference?
    var selection = ""
    var count = 10
    var difficulty = "보통"
    var scope = "선택한 자료 전체"
    var studyRunID: String?
    var studyBinding: NativeLearningBinding?
}

@MainActor
final class NativeAssistantSession: ObservableObject {
    let store: NativeWorkspaceStore
    var context: NativeWorkspaceContext
    @Published var conversations: [NativeChatConversation] = []
    @Published var messages: [NativeChatMessage] = []
    @Published var stream = ""
    @Published var activity = ""
    @Published var error: String? { didSet { if error == nil { errorCode = nil } } }
    /// The code behind `error` (e.g. TASK_CAP_REACHED), for the actions offered next to it.
    @Published var errorCode: String?
    @Published var running = false
    @Published var loading = false
    @Published var sending = false
    @Published var configured = false
    @Published var provider = NativeAIProvider.openAI.rawValue
    @Published var model = ""
    @Published var effort: String?
    /// The proxy's models (`native:aiConfig`), for the picker and the composer label.
    @Published var catalog = NativeAIModelCatalog()
    @Published var sessionID = UUID().uuidString
    @Published var draft = NativeAssistantDraft() { didSet { if restored { scheduleDraftSave() } } }
    @Published var legacyDrafts: [(name: String, text: String)] = []
    private var restored = false
    private var started = false
    private var draftSave: Task<Void,Never>?
    var ready: Bool { started && restored && !loading }
    private var sequence = 0
    private var generation = UUID()
    private var subscriptions = Set<AnyCancellable>()
    private var lastAttempt: NativeAssistantDraft? {
        didSet {
            guard restored, let lastAttempt else { return }
            do {
                try FileManager.default.createDirectory(at:draftURL.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONEncoder().encode(lastAttempt).write(to:attemptURL,options:.atomic)
            } catch { self.error = "요청 초안 저장 실패: \(error.localizedDescription)" }
        }
    }
    private var attemptURL: URL { store.root.appendingPathComponent("NativeAssistantState/attempt-\(sessionID).json") }
    /// `ephemeral` counts with a conversation's first message: one begun while 대화 기록 저장 is off stays off the list.
    var identity: [String: Any] { ["courseId":context.courseID,"sessionId":sessionID,"workspace":context.request,"surface":"app","provider":provider,"ephemeral":!NativeAIPreferences.savesHistory] }
    private var draftURL: URL { store.root.appendingPathComponent("NativeAssistantState/\(sessionID).json") }
    init(store: NativeWorkspaceStore, context: NativeWorkspaceContext) {
        self.store = store; self.context = context
        store.events.sink { [weak self] in self?.receive($0) }.store(in: &subscriptions)
    }
    func start() async {
        guard !started else { return }; started = true; loading = true
        defer { loading = false }
        do {
            try await reloadConversations()
            let selected = NativeToolSelection.conversationID(workspaceID:context.id,root:store.root)
            sessionID = selected ?? conversations.first?.id ?? sessionID
            let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
            provider = conversations.first(where: { $0.id == sessionID })?.provider ?? NativeAssistantPreferences.defaultProvider(settings)
            restoreDraft()
            try await open()
            #if DEBUG
            // UI tests have no signed-in AI: one stored answer with two sources stands in for a finished turn.
            if ProcessInfo.processInfo.arguments.contains("--native-ai-answer-fixture"), messages.isEmpty {
                _ = try await store.invokePrivate("nativeChat:begin",identity.merging(["content":"이 노트 핵심만 요약해 줘"]) { _,new in new })
                _ = try await store.invokePrivate("nativeChat:finish",["courseId":context.courseID,"sessionId":sessionID,"turnSeq":1,"text":NativeAnswerMarkdownFixture.enabled ? NativeAnswerMarkdownFixture.answer : "• 인터뷰 5명 중 4명이 ‘첫 화면이 복잡하다’고 답함\n• 다음 주: 팔레트 시안 2종 비교",
                    "sources":[["courseId":context.courseID,"relPath":"새 노트.pdf","page":2],["courseId":context.courseID,"relPath":"강의자료.pdf","page":12]]])
                try await open()
            }
            playMarkdownStreamFixture()
            #endif
            try restorePendingCaptures()
            await checkAvailability()
            let directory = store.root.appendingPathComponent("NativeToolState")
            legacyDrafts = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil))?.filter { $0.lastPathComponent.hasPrefix("draft-") && $0.pathExtension == "txt" }.compactMap { url in
                guard let text = try? String(contentsOf:url,encoding:.utf8), !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return nil }
                return (String(text.prefix(35)),text)
            } ?? []
        } catch { self.error = error.localizedDescription }
    }
    func reloadConversations() async throws {
        let result = try await store.invoke("chat:conversations",identity) as? [String: Any] ?? [:]
        conversations = (result["conversations"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return .init(id:id,title:$0["title"] as? String ?? "새 대화",provider:$0["provider"] as? String ?? "codex")
        }
    }
    func open() async throws {
        let id = sessionID, current = generation
        guard let result = try await store.invoke("chat:open",identity) as? [String: Any], current == generation, id == sessionID else { return }
        messages = (result["history"] as? [[String: Any]] ?? []).compactMap(NativeChatMessage.init)
        let info = result["sessionInfo"] as? [String: Any] ?? [:]
        provider = info["provider"] as? String ?? provider; model = info["model"] as? String ?? ""; effort = info["effort"] as? String
        running = info["status"] as? String == "running"
        sequence = (result["eventSeq"] as? NSNumber)?.intValue ?? sequence
        if running { stream = (result["activeBlock"] as? [String: Any])?["text"] as? String ?? "" }
        else { stream = ""; activity = ""; draft.studyRunID = nil; draft.studyBinding = nil }
        try NativeToolSelection.restoreConversation(id,workspaceID:context.id,root:store.root)
        if catalog.models.isEmpty { await loadCatalog() }
    }
    func select(_ conversation: NativeChatConversation?) async {
        guard !sending else { return }
        persistDraft(); restored = false; generation = UUID(); sequence = 0
        sessionID = conversation?.id ?? UUID().uuidString; provider = conversation?.provider ?? provider
        messages = []; stream = ""; activity = ""; error = nil; running = false; loading = true; lastAttempt = nil
        defer { loading = false }
        restoreDraft()
        do {
            if conversation == nil { provider = NativeAssistantPreferences.defaultProvider(try await store.invoke("settings:get") as? [String: Any] ?? [:]) }
            try await open(); try restorePendingCaptures(); await checkAvailability()
        } catch { self.error = error.localizedDescription }
    }
    func selectID(_ id: String) async {
        do {
            try await reloadConversations()
            if let conversation = conversations.first(where: { $0.id == id }) { await select(conversation) }
        } catch { self.error = error.localizedDescription }
    }
    func checkAvailability() async {
        do { configured = (try await store.invoke("agent:availability",["provider":provider]) as? [String: Any])?["loggedIn"] as? Bool == true }
        catch { configured = false }
    }
    func attach(_ captures: [NativeAssistantAttachment]) {
        do {
            try NativeAssistantPendingCaptures.enqueue(captures,spaceID:context.id,root:store.root)
            try restorePendingCaptures()
        }
        catch { self.error = error.localizedDescription }
    }
    private func restorePendingCaptures() throws {
        guard restored else { return }
        let captures = try NativeAssistantPendingCaptures.load(spaceID:context.id,root:store.root)
        guard !captures.isEmpty else { return }
        var merged = draft.attachments
        for capture in captures where !merged.contains(where:{ $0.id == capture.id }) { merged.append(capture) }
        _ = try NativeAssistantPayload.validatedAttachments(merged.map(\.request))
        draft.attachments = merged
        // An interrupted app can replay this delivery. IDs make that replay
        // idempotent while preserving the draft's text, mode and pinned source.
        try writeDraft()
        try NativeAssistantPendingCaptures.acknowledge(Set(captures.map(\.id)),spaceID:context.id,root:store.root)
    }
    func pin(_ document: NativeDocumentReference) async throws {
        if let target = document.learningTarget {
            let value = try await store.invoke(target.kind == .article ? "learning:getArticle" : "learning:getArtifact",["binding":target.binding.request,"id":target.entityID]) as? [String:Any] ?? [:]
            let text: String
            if target.kind == .article { text = (value["paragraphs"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator:"\n\n") }
            else { text = try NativeValue.json(value.filter { ["title","kind","markdown","questions","cards"].contains($0.key) }) }
            attach([NativeAssistantAttachment(title:document.title,text:String(text.prefix(80_000)),courseID:document.courseID,url:target.kind == .artifact ? NativeAssistantPayload.learningSourceURL(target) : value["sourceUrl"] as? String)])
        }
        draft.document = document
        draft.selection = String((store.documentSelections[document.id] ?? "").prefix(20_000))
    }
    func send() async throws {
        guard !sending, !running else { return }
        // Availability and document flushing can suspend while the user changes
        // workspaces. Keep the resource destination and conversation that began
        // this request; creating a result does not open a document automatically.
        let id = sessionID, current = generation, captured = draft
        let destination = context, requestIdentity = identity
        var text = captured.text.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.isEmpty { text = captured.mode.pack == nil ? "첨부한 내용을 설명해 주세요." : "\(captured.mode.title)를 만들어 주세요." }
        sending = true; error = nil; stream = ""; activity = ""
        defer { sending = false }
        await checkAvailability()
        guard configured else { throw DesktopRuntimeError("AI를 쓰려면 로그인이 필요해요. 초안은 그대로 있어요.",code:"SIGN_IN_REQUIRED") }
        // A new conversation starts on the last model picked anywhere; older ones keep theirs.
        if let inherited = inheritedModel { try await configure(model:inherited,effort:NativeAIPreferences.effort) }
        _ = try NativeAssistantPayload.validatedAttachments(captured.attachments.map(\.request))
        try await store.flushDocuments()
        var request = requestIdentity
        request["content"] = text; request["mode"] = captured.mode.rawValue; request["attachments"] = captured.attachments.map(\.request)
        request["referenceScope"] = NativeAIPreferences.referenceScope
        if let document = captured.document {
            request["documentContext"] = ["courseId":document.courseID,"relPath":document.relativePath,"title":document.title,"kind":document.kind,"selection":captured.selection]
        }
        lastAttempt = captured
        if let pack = captured.mode.pack {
            let source = try NativeAssistantPayload.generationSource(document:captured.document,selection:captured.selection,attachments:captured.attachments)
            let sourceCourse = captured.document?.courseID ?? destination.courseID
            var generationRequest: [String: Any] = ["courseId":sourceCourse,"packId":pack,"generationMode":captured.mode.rawValue,"questionCount":captured.count,"difficulty":captured.difficulty,"scope":captured.scope,"source":source,"prompt":text,"attachments":captured.attachments.map(\.request),"chat":requestIdentity,"ai":["provider":provider,"model":effectiveModel,"effort":effectiveEffort as Any? ?? NSNull()]]
            generationRequest["documentContext"] = request["documentContext"]
            if let binding = destination.binding { generationRequest["binding"] = binding.request }
            let result = try await store.invoke("study:generate",generationRequest) as? [String: Any] ?? [:]
            guard id == sessionID, current == generation else { return }
            draft.studyRunID = result["runId"] as? String
            if let raw = result["binding"] as? [String: Any], let course = raw["courseId"] as? String, let root = raw["rootRelPath"] as? String { draft.studyBinding = .init(courseID:course,rootRelPath:root) }
            activity = "\(captured.mode.title) 만드는 중"
        } else { _ = try await store.invoke("chat:send",request) }
        guard id == sessionID, current == generation else { return }
        if draft.text == captured.text { draft.text = "" }
        try await open(); try await reloadConversations()
    }
    func importArticle(_ rawURL: String) async throws {
        guard !sending, !running else { return }
        let trimmed = rawURL.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let components = URLComponents(string:trimmed), ["http","https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { throw DesktopRuntimeError("http 또는 https로 시작하는 기사 주소를 입력해 주세요.") }
        let url = try NativeBrowserSession.addressURL(trimmed)
        guard ["http","https"].contains(url.scheme?.lowercased() ?? "") else { throw DesktopRuntimeError("기사 주소를 확인해 주세요.") }
        let request = identity, id = sessionID, current = generation, destination = context
        sending = true; activity = "읽기 자료를 가져오는 중"; error = nil
        defer { sending = false; activity = "" }
        let project: [String: Any]
        if let binding = destination.binding { project = try await store.invoke("learning:get",["binding":binding.request]) as? [String:Any] ?? [:] }
        else { project = try await store.invoke("learning:ensureCourseReview",["courseId":destination.courseID]) as? [String:Any] ?? [:] }
        guard let binding = project["binding"] as? [String:Any], let projectID = project["projectId"] as? String else { throw DesktopRuntimeError("읽기 자료를 저장할 공간을 확인해 주세요.") }
        let prepared = try await store.invokePrivate("nativeChat:begin",request.merging(["content":"영어 읽기 자료 추가: " + url.absoluteString,"mode":"english"]) { _,new in new }) as? [String:Any] ?? [:]
        var completion = request; completion["turnSeq"] = prepared["turnSeq"]
        do {
            let result = try await store.invoke("learning:addArticle",["binding":binding,"url":url.absoluteString,"sourceCourseId":destination.courseID]) as? [String:Any] ?? [:]
            guard let articleID = result["addedArticleId"] as? String else { throw DesktopRuntimeError("기사 원문을 저장하지 못했습니다.") }
            let title = (result["articles"] as? [[String:Any]])?.first(where:{ $0["id"] as? String == articleID })?["title"] as? String ?? "영어 읽기 자료"
            completion["text"] = "원문을 보관했습니다. 읽으면서 표현을 저장하거나 질문해 보세요."
            let article = try await store.invoke("learning:getArticle",["binding":binding,"id":articleID]) as? [String:Any] ?? [:]
            let articleText = (article["paragraphs"] as? [[String:Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator:"\n\n")
            completion["artifacts"] = [["id":articleID,"kind":"article","projectId":projectID,"binding":binding,"title":title,"generationMode":"english","contentText":String(articleText.prefix(80_000))]]
            _ = try await store.invokePrivate("nativeChat:finish",completion)
        } catch {
            completion["text"] = "기사를 가져오지 못했습니다. " + error.localizedDescription; completion["interrupted"] = true
            _ = try? await store.invokePrivate("nativeChat:finish",completion)
            if id == sessionID, current == generation { try? await open() }
            throw error
        }
        if id == sessionID, current == generation { try await open(); try await reloadConversations() }
    }
    func cancel() async throws {
        if let run = draft.studyRunID, let binding = draft.studyBinding { _ = try await store.invoke("learning:runCancel",["binding":binding.request,"runId":run]) }
        else { _ = try await store.invoke("chat:cancel",identity) }
        try await open(); restoreAttempt()
    }
    /// A sent request that failed can be put back in the composer; nothing else can.
    var canRestoreAttempt: Bool { lastAttempt != nil && draft.text.isEmpty }
    func restoreAttempt() { if let lastAttempt, draft.text.isEmpty { draft = lastAttempt; draft.studyRunID = nil; draft.studyBinding = nil } }
    func loadCatalog() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ai-catalog-fixture") { catalog = NativeAIModelCatalog.fixture; return }
        #endif
        guard let config = try? await store.invokePrivate("native:aiConfig") as? [String: Any] else { return }
        catalog = NativeAIModelCatalog(config)
    }
    /// Auto is stored as "default"; a model keeps the provider the proxy lists it under.
    /// The remembered pick a conversation would start on: only before its first message, and only a listed model.
    private var inheritedModel: String? {
        guard model.isEmpty, messages.isEmpty, NativeAIPreferences.model != "default", catalog.contains(NativeAIPreferences.model) else { return nil }
        return NativeAIPreferences.model
    }
    /// What the pill shows and what generation uses: this conversation's model, else the inherited one, else Auto.
    var effectiveModel: String { inheritedModel ?? (model.isEmpty || (model != "default" && !catalog.contains(model)) ? "default" : model) }
    var effectiveEffort: String? { effectiveModel == "default" ? nil : (inheritedModel != nil ? NativeAIPreferences.effort : effort) }
    func configure(model: String, effort: String?) async throws {
        let choice = catalog.models.first { $0.id == model }
        if let provider = choice?.appProvider, self.provider != provider { _ = try await store.invoke("chat:setProvider",identity.merging(["provider":provider]) { _,new in new }) }
        _ = try await store.invoke("chat:setConfiguration",identity.merging(["model":choice == nil ? "default" : model,"effort":choice == nil ? NSNull() : (effort as Any? ?? NSNull())]) { _,new in new })
        try await open(); await checkAvailability()
    }
    func renameCurrent(_ title: String) async throws {
        _ = try await store.invoke("chat:rename",identity.merging(["title":title]) { _,new in new })
        try await reloadConversations()
    }
    func deleteCurrent() async throws {
        _ = try await store.invoke("chat:deleteConversation",identity)
        conversations.removeAll { $0.id == sessionID }; await select(conversations.first)
    }
    private func restoreDraft() {
        draft = (try? Data(contentsOf:draftURL)).flatMap { try? JSONDecoder().decode(NativeAssistantDraft.self,from:$0) } ?? NativeAssistantDraft()
        lastAttempt = (try? Data(contentsOf:attemptURL)).flatMap { try? JSONDecoder().decode(NativeAssistantDraft.self,from:$0) }
        restored = true
    }
    private func scheduleDraftSave() {
        draftSave?.cancel()
        draftSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.milliseconds(250)); try Task.checkCancellation() }
            catch { return }
            self?.persistDraft()
        }
    }
    func flushDraft() { draftSave?.cancel(); draftSave = nil; persistDraft() }
    private func persistDraft() {
        guard restored else { return }
        do { try writeDraft() }
        catch { self.error = "초안 저장 실패: \(error.localizedDescription)" }
    }
    private func writeDraft() throws {
        try FileManager.default.createDirectory(at:draftURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(draft).write(to:draftURL,options:.atomic)
    }
    private func receive(_ event: NativeWorkspaceEvent) {
        guard let value = event.payload as? [String: Any] else { return }
        if event.channel == "nativeWorkspace:openAssistant" {
            if let id = value["conversationID"] as? String ?? value["conversationId"] as? String { Task { await selectID(id) } }
            else if let workspace = value["workspaceID"] as? String, let id = NativeToolSelection.conversationID(workspaceID:workspace,root:store.root) { Task { await selectID(id) } }
            return
        }
        if ["settings:changed","agent:changed","auth:changed"].contains(event.channel) {
            Task { await checkAvailability(); if configured { await loadCatalog() } else if event.channel == "auth:changed" { catalog = NativeAIModelCatalog() } }; return
        }
        guard value["sessionId"] as? String == sessionID else { return }
        if event.channel == "nativeAssistant:studyFinished" {
            Task { do { try await open(); try await reloadConversations(); if messages.last?.interrupted == true { restoreAttempt() } } catch { self.error = error.localizedDescription } }; return
        }
        if event.channel == "chat:message", let raw = value["message"] as? [String: Any], let message = NativeChatMessage(raw) {
            if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message } else { messages.append(message) }
            return
        }
        guard event.channel == "chat:event-batch", value["courseId"] as? String == context.courseID else { return }
        let next = (value["seq"] as? NSNumber)?.intValue ?? sequence + 1
        guard next > sequence else { return }; sequence = next
        for event in value["events"] as? [[String: Any]] ?? [] {
            switch event["type"] as? String {
            case "text-delta": stream += event["text"] as? String ?? ""; running = true
            case "text-final": stream = event["text"] as? String ?? ""
            case "session-started": running = true
            case "tool-start": activity = event["label"] as? String ?? "자료 읽는 중"
            case "tool-end": activity = ""
            case "turn-complete":
                running = false; activity = ""
                Task { do { try await open(); if messages.last?.interrupted == true { restoreAttempt() } } catch { self.error = error.localizedDescription } }
            case "error": error = event["message"] as? String; errorCode = event["code"] as? String; running = false; restoreAttempt()
            default: break
            }
        }
    }
}

enum NativeAssistantPreferences {
    static func defaultProvider(_ settings: [String: Any]) -> String {
        NativeAIProvider(rawValue:settings["agentProvider"] as? String ?? "")?.rawValue ?? NativeAIProvider.anthropic.rawValue
    }
}

/// The models the ai-proxy offers (`native:aiConfig`), as the chat's model picker shows them.
struct NativeAIModelCatalog {
    struct Model: Identifiable, Equatable {
        let id: String, provider: String, label: String, badge: Int
        /// The chat session's provider id for this model.
        var appProvider: String {
            switch provider { case "anthropic": NativeAIProvider.anthropic.rawValue; case "google": NativeAIProvider.google.rawValue; default: NativeAIProvider.openAI.rawValue }
        }
    }
    var models: [Model] = []
    init() {}
    init(_ config: [String: Any]) {
        models = (config["models"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let provider = $0["provider"] as? String else { return nil }
            return Model(id: id, provider: provider, label: $0["label"] as? String ?? id, badge: ($0["badge"] as? NSNumber)?.intValue ?? 1)
        }
    }
    /// UI tests only: the live list as of 1.4.0, without a signed-in account.
    static let fixture = NativeAIModelCatalog(["models": [
        ["id": "claude-haiku-5-5", "provider": "anthropic", "label": "Haiku 5.5", "badge": 1],
        ["id": "claude-sonnet-5-5", "provider": "anthropic", "label": "Sonnet 5.5", "badge": 4],
        ["id": "gpt-6-luna", "provider": "openai", "label": "GPT-6 Luna", "badge": 1],
        ["id": "gpt-6-sol", "provider": "openai", "label": "GPT-6 Sol", "badge": 4],
        ["id": "gpt-6-astra", "provider": "openai", "label": "GPT-6 Astra", "badge": 20]]])
    var providers: [String] { models.reduce(into: []) { if !$0.contains($1.provider) { $0.append($1.provider) } } }
    func contains(_ id: String) -> Bool { models.contains { $0.id == id } }
    /// What the composer shows: the model's name, or Auto for anything else (old BYOK names included).
    func label(_ id: String) -> String { models.first { $0.id == id }?.label ?? NativeAppLocale.string("자동", Locale.current) }
}
