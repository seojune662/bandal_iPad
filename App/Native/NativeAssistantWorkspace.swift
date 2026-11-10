import Combine
import SwiftUI

struct NativeChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let attachments: [NativeAssistantAttachment]
    let artifacts: [NativeAssistantResult]
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

private struct NativeChatConversation: Identifiable {
    let id: String
    let title: String
    let provider: String
}

private struct NativeAssistantDraft: Codable, Equatable {
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
private final class NativeAssistantSession: ObservableObject {
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
    var identity: [String: Any] { ["courseId":context.courseID,"sessionId":sessionID,"workspace":context.request,"surface":"app","provider":provider] }
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

struct NativeAssistantPanel: View {
    var store: NativeWorkspaceStore
    let context: NativeWorkspaceContext
    let sourceDocument: NativeDocumentReference?
    let attachments: [NativeAssistantAttachment]
    let onConsumeAttachments: () -> Void
    let onOpenDocument: (NativeDocumentReference) -> Void
    /// Opens Settings at a section ("subscription" for 사용량).
    let onOpenSettings: (String) -> Void
    let onAnnotate: () -> Void
    var onClose: (() -> Void)? = nil
    @State private var toast: String?
    /// The note the user removed from the composer: it is not attached again on its own.
    @State private var detachedDocumentID: String?
    @StateObject private var session: NativeAssistantSession
    @State private var showingSignIn = false
    @State private var signInError: String?
    @State private var showingOptions = false
    @State private var showingDelete = false
    @State private var renamingConversation = false
    @ObservedObject private var usage = AIUsage.shared
    /// "<message or draft>:<attachment id>": the same capture can sit in a message and in the draft.
    @State private var previewKey: String?
    @State private var showingArticleImport = false
    @Environment(\.scenePhase) private var scenePhase
    init(store: NativeWorkspaceStore, context: NativeWorkspaceContext, sourceDocument: NativeDocumentReference?, attachments: [NativeAssistantAttachment] = [], onConsumeAttachments: @escaping () -> Void = {}, onOpenDocument: @escaping (NativeDocumentReference) -> Void, onOpenSettings: @escaping (String) -> Void, onAnnotate: @escaping () -> Void, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        self.store = store; self.context = context; self.sourceDocument = sourceDocument; self.attachments = attachments
        self.onConsumeAttachments = onConsumeAttachments; self.onOpenDocument = onOpenDocument; self.onOpenSettings = onOpenSettings; self.onAnnotate = onAnnotate
        _session = StateObject(wrappedValue:NativeAssistantSession(store:store,context:context))
    }
    private var canAnnotate: Bool {
        guard let document = sourceDocument, document.learningTarget == nil else { return false }
        return ["pdf","note","browser","whiteboard","md","markdown"].contains(document.kind) || ["md","markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())
    }
    var body: some View {
        VStack(spacing:0) {
            header
            modeTabs
            if let error = session.error {
                HStack(alignment:.top,spacing:8) {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                    if session.errorCode == "TASK_CAP_REACHED" || session.errorCode == "BUDGET_EXHAUSTED" && AIUsage.shared.plan == "pro" {
                        AICreditButton(opensOnLimit:true,identifier:"native-ai-task-cap-credit").font(.caption).frame(minHeight:44)
                    }
                    if session.errorCode == "TASK_CAP_REACHED" {
                        Button("Auto로 바꾸기") { perform { try await session.configure(model:"default",effort:nil); session.error = nil } }.font(.caption).frame(minHeight:44)
                    }
                    Button("초안 복원") { session.restoreAttempt(); session.error = nil }.font(.caption).frame(minHeight:44)
                }.padding(.horizontal,16).padding(.vertical,4)
            }
            messages
        }.background(Color(uiColor:.systemBackground))
            .task { await session.start(); await consumePendingConversation(); consumeAttachments() }
            .onDisappear { session.flushDraft() }
            .bandalToast($toast)
            .task(id:sourceDocument?.id) { attachCurrentNote() }
            .onChange(of:attachments) { _,_ in consumeAttachments() }
            .onChange(of:context) { _,value in session.context = value }
            .onChange(of:store.pendingAssistantConversationIDs[context.id]) { _,_ in Task { await consumePendingConversation() } }
            .onChange(of:scenePhase) { _,phase in if phase == .active { Task { await session.checkAvailability() } } else { session.flushDraft() } }
            .onReceive(store.events) { event in
                // Signed in from the prompt: back to the same panel with the draft untouched.
                if event.channel == "auth:changed", showingSignIn { Task { await session.checkAvailability(); if session.configured { showingSignIn = false } } }
            }
    }
    private var insertableDocument: NativeDocumentReference? { sourceDocument.flatMap { $0.kind == "pdf" && $0.learningTarget == nil ? $0 : nil } }
    /// The note on screen rides along with the next question until the user removes it.
    private func attachCurrentNote() {
        guard let document = sourceDocument, !document.isWorkspaceTool, document.learningTarget == nil, session.draft.document == nil,
              detachedDocumentID != document.id, canAnnotate else { return }
        perform { try await session.pin(document) }
    }
    private func insertIntoNote(_ text: String) {
        guard let document = insertableDocument else { return }
        store.events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:insertAINote",payload:["courseId":document.courseID,"relPath":document.relativePath,"tabID":document.id,"text":text]))
        toast = "노트에 넣었어요 · 되돌리기로 취소할 수 있어요"
    }
    private var header: some View {
        HStack(spacing:4) {
            VStack(alignment:.leading,spacing:3) {
                Label("AI 도우미",systemImage:"sparkle").font(.system(size:16,weight:.semibold)).lineLimit(1)
                BandalInlineEditor(text:session.conversations.first(where:{ $0.id == session.sessionID })?.title ?? "새 대화",isEditing:$renamingConversation,font:.caption,identifier:"native-ai-conversation-rename") { title in perform { try await session.renameCurrent(title) } }
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength:4)
            Menu {
                ForEach(session.conversations) { conversation in Button(conversation.title) { Task { await session.select(conversation) } } }
                if !session.legacyDrafts.isEmpty {
                    Section("이전 문서의 초안") {
                        ForEach(Array(session.legacyDrafts.enumerated()),id:\.offset) { _, item in
                            Button(item.name) { Task { await session.select(nil); session.draft.text = item.text } }
                        }
                    }
                }
                Divider()
                Button("대화 이름 변경",systemImage:"pencil") { renamingConversation = true }.disabled(session.running || !session.conversations.contains { $0.id == session.sessionID })
                Button("현재 대화 삭제",role:.destructive) { showingDelete = true }.disabled(session.running)
            } label: { Image(systemName:"clock.arrow.circlepath").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("대화 기록")
                .bandalConfirm("이 대화를 삭제할까요?",isPresented:$showingDelete,action:"삭제",destructive:true) { perform { try await session.deleteCurrent() } }
            Button { Task { await session.select(nil) } } label: { Image(systemName:"square.and.pencil").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("새 대화")
            if let onClose { Button(action:onClose) { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("AI 닫기").accessibilityIdentifier("native-ai-close") }
        }.buttonStyle(.plain).padding(.horizontal,12).padding(.top,8)
    }
    private var modeTabs: some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:3) {
                ForEach(NativeAssistantMode.primary) { mode in
                    Button { session.draft.mode = mode } label: {
                        Text(mode.title).font(.system(size:13,weight:session.draft.mode == mode ? .semibold : .regular))
                            .padding(.horizontal,11).frame(height:44).contentShape(Rectangle())
                            .background(session.draft.mode == mode ? Color.primary.opacity(0.075) : .clear,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).accessibilityIdentifier("native-ai-mode-" + mode.rawValue)
                }
                Menu {
                    Button("요약") { session.draft.mode = .summary }
                    Button("영어 읽기") { session.draft.mode = .english }
                } label: {
                    HStack(spacing:4) { if [.summary,.english].contains(session.draft.mode) { Text(session.draft.mode.title) }; Image(systemName:"ellipsis") }.frame(minWidth:44,minHeight:44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("다른 AI 모드")
            }.padding(.horizontal,12)
        }.padding(.vertical,6).overlay(alignment:.bottom) { Divider() }
    }
    private var messages: some View {
        VStack(spacing:0) {
        GeometryReader { viewport in
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:24) {
                    if session.messages.isEmpty && !session.loading { welcome }
                    ForEach(session.messages) { message in messageRow(message) }
                    if !session.stream.isEmpty { Text(.init(session.stream)).font(.system(size:15)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading) }
                    if session.running || session.sending {
                        HStack(spacing:8) { ProgressView().controlSize(.small); Text(session.activity.isEmpty ? "답변을 정리하고 있어요" : session.activity).font(.caption).foregroundStyle(.secondary) }
                    }
                    Color.clear.frame(height:1).id("bottom")
                }.frame(width:max(0,viewport.size.width - 36),alignment:.leading).padding(18)
            }.scrollDismissesKeyboard(.interactively)
                .onChange(of:session.messages.count) { _,_ in withAnimation { proxy.scrollTo("bottom",anchor:.bottom) } }
        }
        }
        composer
        }
    }
    private var welcome: some View {
        VStack(spacing:12) {
            Image(systemName:"sparkle").font(.system(size:20)).frame(width:44,height:44)
                .background(Color(uiColor:.systemBackground),in:RoundedRectangle(cornerRadius:12)).shadow(color:.black.opacity(0.08),radius:6,y:2).padding(.top,48)
            Text("무엇을 도와드릴까요?").font(.system(size:20,weight:.semibold))
            Text("지금 노트와 과목 자료를 읽고 답해요").font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ForEach(["이 노트 핵심만 요약해 줘","시험에 나올 문제 3개","강의자료에서 찾아 줘"],id:\.self) { prompt in
                Button { session.draft.text = prompt } label: {
                    Text(prompt).font(.system(size:13)).padding(.horizontal,14).frame(minHeight:36)
                        .background(Color(uiColor:.systemBackground),in:Capsule()).overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth:.infinity).padding(.vertical,16)
    }
    private func messageRow(_ message: NativeChatMessage) -> some View {
        VStack(alignment:.leading,spacing:10) {
            if message.role == "assistant" { Label("반달 AI",systemImage:"sparkle").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(message.attachments) { attachment in attachmentChip(attachment,removable:false,owner:"message-\(message.id)") }
            if !message.text.isEmpty {
                Text(.init(message.text)).font(.system(size:15)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    .padding(.horizontal,message.role == "user" ? 14 : 0).padding(.vertical,message.role == "user" ? 10 : 0)
                    .foregroundStyle(message.role == "user" ? NativeDesktopTheme.onAccent : NativeDesktopTheme.text)
                    .background(message.role == "user" ? NativeDesktopTheme.accent : .clear,in:RoundedRectangle(cornerRadius:17))
                    .frame(maxWidth:.infinity,alignment:message.role == "user" ? .trailing : .leading)
            }
            ForEach(message.artifacts) { artifact in
                Button { onOpenDocument(artifact.document) } label: {
                    HStack(spacing:12) {
                        Image(systemName:artifact.mode == "flashcards" ? "rectangle.on.rectangle" : "doc.text").font(.title3)
                        VStack(alignment:.leading,spacing:4) { Text(artifact.title).font(.system(size:14,weight:.semibold)).lineLimit(2).fixedSize(horizontal:false,vertical:true); Text(artifact.mode == "expected-exam" ? "AI 생성 예상문제" : artifact.mode == "english" ? "영어 읽기 · 표현 저장" : "저장된 학습 자료").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }.frame(maxWidth:.infinity,alignment:.leading)
                        Text("열기").font(.caption.weight(.semibold)).fixedSize()
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:14))
                }.buttonStyle(.plain)
            }
            // Actions sit on the last answer only.
            if message.role == "assistant", !message.text.isEmpty, message.id == session.messages.last?.id, !session.running {
                HStack(spacing:8) {
                    if insertableDocument != nil {
                        Button { insertIntoNote(message.text) } label: { answerAction("노트에 넣기","plus") }.accessibilityIdentifier("native-ai-insert-note")
                    }
                    Button { UIPasteboard.general.string = message.text; toast = "복사했어요" } label: { answerAction("복사","doc.on.doc") }.accessibilityIdentifier("native-ai-copy-answer")
                }.buttonStyle(.plain)
            }
            if message.interrupted { Button("요청 다시 준비") { session.restoreAttempt() }.font(.caption).frame(minHeight:44) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func answerAction(_ title: String, _ symbol: String) -> some View {
        Label(title,systemImage:symbol).font(.system(size:13,weight:.medium)).padding(.horizontal,12).frame(minHeight:36)
            .background(Color(uiColor:.systemBackground),in:Capsule()).overlay(Capsule().strokeBorder(Color.primary.opacity(0.08))).contentShape(Rectangle())
    }
    private var composer: some View {
        VStack(alignment:.leading,spacing:8) {
            if session.draft.mode == .english {
                Button { showingArticleImport = true } label: { Label("기사 주소 추가",systemImage:"link").font(.system(size:13,weight:.medium)).frame(minHeight:44) }.buttonStyle(.plain).disabled(session.running || session.sending).accessibilityIdentifier("native-ai-import-article")
                    .bandalPopover(isPresented:$showingArticleImport,width:320) {
                        BandalTextEntry(title:"기사 주소",prompt:"https://…",actionTitle:"가져오기",keyboard:.URL,identifier:"native-ai-article-url") { url in
                            showingArticleImport = false; perform { try await session.importArticle(url) }
                        }
                    }
            }
            if session.draft.mode.pack != nil {
                Button { showingOptions = true } label: {
                    HStack { Text(session.draft.mode.title); Text("· \(session.draft.count)개 · \(session.draft.difficulty)").foregroundStyle(.secondary); Spacer(); Image(systemName:"slider.horizontal.3") }.font(.caption).frame(minHeight:44)
                }.buttonStyle(.plain).accessibilityIdentifier("native-ai-mode-options")
                    .bandalPopover(isPresented:$showingOptions,width:300) { options }
            }
            if let document = session.draft.document {
                HStack(spacing:8) {
                    Image(systemName:"doc.text"); Text(document.title).lineLimit(1); Spacer()
                    Button { detachedDocumentID = document.id; session.draft.document = nil; session.draft.selection = "" } label: { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("문서 첨부 제거")
                }.font(.caption).padding(.leading,10).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
            }
            if !session.draft.attachments.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) { HStack { ForEach(session.draft.attachments) { attachmentChip($0,removable:true) } } }
            }
            VStack(spacing:4) {
                TextField("\(session.draft.mode.title == "대화" ? "무엇이든 물어보세요" : "원하는 내용을 알려 주세요")",text:$session.draft.text,axis:.vertical)
                    .font(.system(size:15)).lineLimit(2...6).textFieldStyle(.plain).padding(.horizontal,14).padding(.top,13).accessibilityIdentifier("native-chat-input")
                HStack(spacing:2) {
                    Menu {
                        if let document = sourceDocument, document.learningTarget?.kind != .overview { Button("현재 문서 첨부") { perform { try await session.pin(document) } } }
                        Button("지목해서 질문",action:onAnnotate).disabled(!canAnnotate)
                    } label: { Image(systemName:"plus").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("자료 첨부")
                    Button(action:onAnnotate) { Image(systemName:"scope").frame(width:44,height:44).contentShape(Rectangle()) }.disabled(!canAnnotate).accessibilityLabel("지목해서 질문").accessibilityIdentifier("native-ai-annotate")
                    NativeAIModelPill(catalog:session.catalog,model:session.effectiveModel,effort:session.effectiveEffort,disabled:session.running || session.loading || session.sending,
                                      onSelect:{ model,effort in
                                          perform { try await session.configure(model:model,effort:effort); NativeAIPreferences.remember(model:model,effort:effort) }
                                      },
                                      onOpenUsage:{ onOpenSettings("subscription") },
                                      onAppear:{ await session.loadCatalog() })
                    Spacer(minLength:0)
                    do {
                        Button {
                            if session.running { perform { try await session.cancel() } } else { submit() }
                        } label: {
                            Image(systemName:session.running ? "stop.fill" : "arrow.up").font(.system(size:16,weight:.semibold)).foregroundStyle(Color(uiColor:.systemBackground)).frame(width:34,height:34).background(Color.primary,in:Circle()).frame(width:44,height:44).contentShape(Rectangle())
                        }.disabled(!session.running && (session.loading || session.sending || (session.draft.mode.pack == nil && session.draft.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && session.draft.attachments.isEmpty)))
                            .accessibilityLabel(session.running ? "응답 중지" : "보내기").accessibilityIdentifier("native-chat-send")
                            .bandalPopover(isPresented:$showingSignIn,arrowEdge:.bottom,width:264) { signInPrompt }
                    }
                }.padding(.horizontal,5).padding(.bottom,4).buttonStyle(.plain)
            }.background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).strokeBorder(Color.primary.opacity(0.065)))
            HStack {
                Text("첨부한 자료를 바탕으로 답해요").font(.system(size:10)).foregroundStyle(.tertiary)
                Spacer(minLength:4)
                if let percent = usage.percent {
                    Text("AI \(percent)%").font(.system(size:10)).foregroundStyle(percent >= 90 ? .orange : .secondary).accessibilityIdentifier("native-ai-usage-compact")
                }
            }
        }.padding(.horizontal,12).padding(.top,8).background(Color(uiColor:.systemBackground))
    }
    private func attachmentChip(_ attachment: NativeAssistantAttachment, removable: Bool, owner: String = "draft") -> some View {
        let key = owner + ":" + attachment.id
        return HStack(spacing:7) {
            Button { previewKey = key } label: {
                HStack(spacing:7) { Image(systemName:attachment.imageDataURL == nil ? "text.quote" : "viewfinder"); Text(attachment.title + (attachment.page.map { " · \($0)p" } ?? "")).lineLimit(1).frame(maxWidth:180,alignment:.leading) }.frame(minHeight:44)
            }.buttonStyle(.plain).accessibilityIdentifier("native-ai-attachment-" + attachment.id)
                .bandalPopover(isPresented:Binding(get:{ previewKey == key },set:{ if !$0 && previewKey == key { previewKey = nil } }),width:360) { attachmentPreview(attachment) }
            if removable { Button { session.draft.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("첨부 제거") }
        }.font(.caption).padding(.leading,10).padding(.trailing,removable ? 0 : 10).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:11))
    }
    private func attachmentPreview(_ attachment: NativeAssistantAttachment) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:10) {
                Text(attachment.title).font(.system(size:BandalMetrics.bodySize,weight:.semibold)).lineLimit(2)
                if let image = attachment.imageInput, let value = image["dataBase64"], let bytes = Data(base64Encoded:value), let uiImage = UIImage(data:bytes) { Image(uiImage:uiImage).resizable().scaledToFit().accessibilityLabel("지목한 영역 이미지").accessibilityIdentifier("native-ai-attachment-preview-image") }
                if let text = attachment.text { Text(text).font(.system(size:12)).textSelection(.enabled).accessibilityIdentifier("native-ai-attachment-preview-text") }
                Text(attachment.url ?? attachment.relativePath ?? "선택한 영역").font(.system(size:11)).foregroundStyle(NativeDesktopTheme.muted)
            }
        }.frame(maxHeight:420)
    }
    /// Signed out: ask right where the button was pressed; the draft stays as typed.
    private var signInPrompt: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("AI를 쓰려면 로그인이 필요해요").font(.system(size:BandalMetrics.bodySize,weight:.semibold))
            NativeSignInButtons(store:store,error:$signInError,identifierPrefix:"native-ai-sign-in")
            if let signInError { Text(signInError).font(.system(size:11)).foregroundStyle(.red) }
        }.accessibilityElement(children:.contain).accessibilityIdentifier("native-ai-sign-in-prompt")
    }
    private func signedOut() async -> Bool {
        ((try? await store.invoke("auth:getState")) as? [String: Any])?["phase"] as? String != "signed-in"
    }
    /// Send, quiz, flashcards, expected exam: signed out opens the sign-in prompt instead of an error.
    private func submit() {
        Task {
            if !session.configured { await session.checkAvailability() }
            if !session.configured, await signedOut() { signInError = nil; showingSignIn = true; return }
            do { try await session.send() }
            catch let error as DesktopRuntimeError where error.code == "SIGN_IN_REQUIRED" {
                // Signed in but AI unavailable (offline, proxy down): say so instead of asking to sign in.
                if await signedOut() { showingSignIn = true } else { session.error = "지금은 AI에 연결할 수 없어요. 잠시 뒤 다시 해 주세요." }
            }
            catch { session.error = error.localizedDescription }
        }
    }
    /// Quiz / flashcards / expected exam options: applied as they change.
    private var options: some View {
        VStack(alignment:.leading,spacing:8) {
            BandalSectionHeader(session.draft.mode.title)
            TextField("범위 (예: 3장, 행렬식)",text:$session.draft.scope).font(.system(size:BandalMetrics.bodySize)).textFieldStyle(.plain)
                .padding(.horizontal,8).frame(minHeight:32).background(NativeDesktopTheme.bgApp,in:RoundedRectangle(cornerRadius:BandalMetrics.radiusSmall))
                .overlay { RoundedRectangle(cornerRadius:BandalMetrics.radiusSmall).stroke(NativeDesktopTheme.border) }
            Stepper("\(session.draft.count)개",value:$session.draft.count,in:1...30).font(.system(size:BandalMetrics.bodySize))
            Picker("난이도",selection:$session.draft.difficulty) { ForEach(["쉬움","보통","어려움"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            if session.draft.mode == .expectedExam { Text("범위를 종합한 시험지를 만들고, 제출하면 정답과 해설을 보여 줘요.").font(.system(size:11)).foregroundStyle(NativeDesktopTheme.muted) }
        }
    }
    private func consumePendingConversation() async {
        guard session.ready, let id = store.pendingAssistantConversationIDs[context.id] else { return }
        await session.selectID(id)
        if store.pendingAssistantConversationIDs[context.id] == id { store.pendingAssistantConversationIDs.removeValue(forKey:context.id) }
    }
    private func consumeAttachments() { guard !attachments.isEmpty, session.ready else { return }; session.attach(attachments); onConsumeAttachments() }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action() } catch { session.error = error.localizedDescription } } }
}

/// Compatibility for saved tool tabs. New workspace chrome opens the global panel.
struct NativeAssistantWorkspace: View {
    var store: NativeWorkspaceStore
    var workspaceID: String? = nil
    var courseID: String? = nil
    var sourceDocument: NativeDocumentReference? = nil
    var body: some View {
        if let course = store.courses.first(where:{ $0.id == (courseID ?? store.selectedCourseID) }) {
            NativeAssistantPanel(store:store,context:.course(course),sourceDocument:sourceDocument,onOpenDocument:{ store.events.send(.init(channel:"nativeWorkspace:openAssistantResult",payload:["document":$0])) },onOpenSettings:{ store.events.send(.init(channel:"nativeWorkspace:openSettings",payload:["category":$0])) },onAnnotate:{ store.events.send(.init(channel:"nativeWorkspace:annotate",payload:[:])) })
                .id(course.id)
        } else { NativeToolEmptyState(title:"공간을 선택하세요",message:"자료와 함께 대화를 시작하세요.",symbol:"bubble.left.and.bubble.right") }
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
        var appProvider: String { provider == "anthropic" ? NativeAIProvider.anthropic.rawValue : NativeAIProvider.openAI.rawValue }
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
    func label(_ id: String) -> String { models.first { $0.id == id }?.label ?? "Auto" }
}
