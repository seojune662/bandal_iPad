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
    @Published var error: String?
    @Published var running = false
    @Published var loading = false
    @Published var sending = false
    @Published var configured = false
    @Published var provider = NativeAIProvider.openAI.rawValue
    @Published var model = ""
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
        provider = info["provider"] as? String ?? provider; model = info["model"] as? String ?? ""
        running = info["status"] as? String == "running"
        sequence = (result["eventSeq"] as? NSNumber)?.intValue ?? sequence
        if running { stream = (result["activeBlock"] as? [String: Any])?["text"] as? String ?? "" }
        else { stream = ""; activity = ""; draft.studyRunID = nil; draft.studyBinding = nil }
        try NativeToolSelection.restoreConversation(id,workspaceID:context.id,root:store.root)
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
        let id = sessionID, current = generation, captured = draft
        var text = captured.text.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.isEmpty { text = captured.mode.pack == nil ? "첨부한 내용을 설명해 주세요." : "\(captured.mode.title)를 만들어 주세요." }
        sending = true; error = nil; stream = ""; activity = ""
        defer { sending = false }
        await checkAvailability()
        guard configured else { throw DesktopRuntimeError("설정에서 API 키를 연결해 주세요. 초안은 보관됩니다.") }
        _ = try NativeAssistantPayload.validatedAttachments(captured.attachments.map(\.request))
        try await store.flushDocuments()
        var request = identity
        request["content"] = text; request["mode"] = captured.mode.rawValue; request["attachments"] = captured.attachments.map(\.request)
        if let document = captured.document {
            request["documentContext"] = ["courseId":document.courseID,"relPath":document.relativePath,"title":document.title,"kind":document.kind,"selection":captured.selection]
        }
        lastAttempt = captured
        if let pack = captured.mode.pack {
            let source = try NativeAssistantPayload.generationSource(document:captured.document,selection:captured.selection,attachments:captured.attachments)
            let sourceCourse = captured.document?.courseID ?? context.courseID
            var generationRequest: [String: Any] = ["courseId":sourceCourse,"packId":pack,"generationMode":captured.mode.rawValue,"questionCount":captured.count,"difficulty":captured.difficulty,"scope":captured.scope,"source":source,"prompt":text,"attachments":captured.attachments.map(\.request),"chat":identity,"ai":["provider":provider,"model":model.isEmpty ? "default" : model]]
            generationRequest["documentContext"] = request["documentContext"]
            if let binding = context.binding { generationRequest["binding"] = binding.request }
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
    func configure(provider: String, model: String) async throws {
        if self.provider != provider { _ = try await store.invoke("chat:setProvider",identity.merging(["provider":provider]) { _,new in new }) }
        _ = try await store.invoke("chat:setConfiguration",identity.merging(["model":model.isEmpty ? "default" : model,"effort":NSNull()]) { _,new in new })
        try await open(); await checkAvailability()
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
        if event.channel == "settings:changed" || event.channel == "agent:changed" { Task { await checkAvailability() }; return }
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
            case "error": error = event["message"] as? String; running = false; restoreAttempt()
            default: break
            }
        }
    }
}

struct NativeAssistantPanel: View {
    @ObservedObject var store: NativeWorkspaceStore
    let context: NativeWorkspaceContext
    let sourceDocument: NativeDocumentReference?
    let attachments: [NativeAssistantAttachment]
    let onConsumeAttachments: () -> Void
    let onOpenDocument: (NativeDocumentReference) -> Void
    let onOpenSettings: () -> Void
    let onAnnotate: () -> Void
    @StateObject private var session: NativeAssistantSession
    @State private var showingConfiguration = false
    @State private var showingOptions = false
    @State private var showingDelete = false
    @State private var provider = "codex"
    @State private var model = ""
    @State private var preview: NativeAssistantAttachment?
    @State private var showingArticleImport = false
    @State private var articleURL = ""
    @Environment(\.scenePhase) private var scenePhase
    init(store: NativeWorkspaceStore, context: NativeWorkspaceContext, sourceDocument: NativeDocumentReference?, attachments: [NativeAssistantAttachment] = [], onConsumeAttachments: @escaping () -> Void = {}, onOpenDocument: @escaping (NativeDocumentReference) -> Void, onOpenSettings: @escaping () -> Void, onAnnotate: @escaping () -> Void) {
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
                    Button("초안 복원") { session.restoreAttempt(); session.error = nil }.font(.caption).frame(minHeight:44)
                }.padding(.horizontal,16).padding(.vertical,4)
            }
            messages
        }.background(Color(uiColor:.systemBackground))
            .task { await session.start(); await consumePendingConversation(); consumeAttachments() }
            .onDisappear { session.flushDraft() }
            .onChange(of:attachments) { _,_ in consumeAttachments() }
            .onChange(of:context) { _,value in session.context = value }
            .onChange(of:store.pendingAssistantConversationIDs[context.id]) { _,_ in Task { await consumePendingConversation() } }
            .onChange(of:scenePhase) { _,phase in if phase == .active { Task { await session.checkAvailability() } } else { session.flushDraft() } }
            .sheet(isPresented:$showingConfiguration,onDismiss:{ Task { await session.checkAvailability() } }) { configuration }
            .sheet(isPresented:$showingOptions) { options }
            .alert("기사 주소",isPresented:$showingArticleImport) {
                TextField("https://…",text:$articleURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("취소",role:.cancel) { }
                Button("가져오기") { perform { try await session.importArticle(articleURL); articleURL = "" } }
            } message: { Text("원문을 현재 공간에 보관하고 읽기·표현 수집을 이어갑니다.") }
            .sheet(item:$preview) { attachment in attachmentPreview(attachment) }
            .confirmationDialog("이 대화를 삭제할까요?",isPresented:$showingDelete) { Button("삭제",role:.destructive) { perform { try await session.deleteCurrent() } } }
    }
    private var header: some View {
        HStack(spacing:4) {
            VStack(alignment:.leading,spacing:3) {
                Text(context.title).font(.system(size:16,weight:.semibold)).lineLimit(1)
                Text(session.conversations.first(where:{ $0.id == session.sessionID })?.title ?? "새 대화").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                Button("현재 대화 삭제",role:.destructive) { showingDelete = true }.disabled(session.running)
            } label: { Image(systemName:"clock.arrow.circlepath").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("대화 기록")
            Button { Task { await session.select(nil) } } label: { Image(systemName:"square.and.pencil").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("새 대화")
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
        VStack(alignment:.leading,spacing:18) {
            Image(systemName:"sparkle").font(.system(size:28,weight:.light)).foregroundStyle(.secondary).padding(.top,12)
            Text("자료에서 시작하는\n나만의 공부").font(.system(size:25,weight:.medium)).tracking(-0.7).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
            Text("문서를 첨부하거나 궁금한 부분을 지목해 보세요. 대화하며 문제와 카드를 만들 수 있어요.").font(.system(size:14)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
            ForEach(["이 자료의 핵심 개념을 설명해 줘","내가 놓친 부분을 함께 확인해 줘"],id:\.self) { prompt in
                Button { session.draft.text = prompt } label: {
                    HStack { Text(prompt).font(.system(size:13)).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading); Spacer(minLength:0); Image(systemName:"arrow.up.left").font(.caption) }.padding(14).background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:14))
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,16)
    }
    private func messageRow(_ message: NativeChatMessage) -> some View {
        VStack(alignment:.leading,spacing:10) {
            if message.role == "assistant" { Label("반달",systemImage:"sparkle").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(message.attachments) { attachment in attachmentChip(attachment,removable:false) }
            if !message.text.isEmpty {
                Text(.init(message.text)).font(.system(size:15)).lineSpacing(6).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    .padding(message.role == "user" ? 13 : 0)
                    .background(message.role == "user" ? Color.primary.opacity(0.055) : .clear,in:RoundedRectangle(cornerRadius:17))
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
            if message.interrupted { Button("요청 다시 준비") { session.restoreAttempt() }.font(.caption).frame(minHeight:44) }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private var composer: some View {
        VStack(alignment:.leading,spacing:8) {
            if session.draft.mode == .english {
                Button { showingArticleImport = true } label: { Label("기사 주소 추가",systemImage:"link").font(.system(size:13,weight:.medium)).frame(minHeight:44) }.buttonStyle(.plain).disabled(session.running || session.sending).accessibilityIdentifier("native-ai-import-article")
            }
            if session.draft.mode.pack != nil {
                Button { showingOptions = true } label: {
                    HStack { Text(session.draft.mode.title); Text("· \(session.draft.count)개 · \(session.draft.difficulty)").foregroundStyle(.secondary); Spacer(); Image(systemName:"slider.horizontal.3") }.font(.caption).frame(minHeight:44)
                }.buttonStyle(.plain)
            }
            if let document = session.draft.document {
                HStack(spacing:8) {
                    Image(systemName:"doc.text"); Text(document.title).lineLimit(1); Spacer()
                    Button { session.draft.document = nil; session.draft.selection = "" } label: { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("문서 첨부 제거")
                }.font(.caption).padding(.leading,10).background(Color.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
            }
            if !session.draft.attachments.isEmpty {
                ScrollView(.horizontal,showsIndicators:false) { HStack { ForEach(session.draft.attachments) { attachmentChip($0,removable:true) } } }
            }
            VStack(spacing:4) {
                TextField("\(session.draft.mode.title == "대화" ? "무엇이 궁금한가요?" : "원하는 내용을 알려 주세요")",text:$session.draft.text,axis:.vertical)
                    .font(.system(size:15)).lineLimit(2...6).textFieldStyle(.plain).padding(.horizontal,14).padding(.top,13).accessibilityIdentifier("native-chat-input")
                HStack(spacing:2) {
                    Menu {
                        if let document = sourceDocument, document.learningTarget?.kind != .overview { Button("현재 문서 첨부") { perform { try await session.pin(document) } } }
                        Button("지목해서 질문",action:onAnnotate).disabled(!canAnnotate)
                    } label: { Image(systemName:"plus").frame(width:44,height:44).contentShape(Rectangle()) }.accessibilityLabel("자료 첨부")
                    Button(action:onAnnotate) { Image(systemName:"scope").frame(width:44,height:44).contentShape(Rectangle()) }.disabled(!canAnnotate).accessibilityLabel("지목해서 질문").accessibilityIdentifier("native-ai-annotate")
                    Spacer(minLength:0)
                    if !session.configured && !session.loading {
                        Button("AI 연결") { Task { await session.checkAvailability(); if !session.configured { onOpenSettings() } } }.font(.system(size:13,weight:.semibold)).frame(minHeight:44).padding(.horizontal,8).accessibilityIdentifier("native-ai-connect")
                    } else {
                        Button {
                            perform { if session.running { try await session.cancel() } else { try await session.send() } }
                        } label: {
                            Image(systemName:session.running ? "stop.fill" : "arrow.up").font(.system(size:16,weight:.semibold)).foregroundStyle(Color(uiColor:.systemBackground)).frame(width:34,height:34).background(Color.primary,in:Circle()).frame(width:44,height:44).contentShape(Rectangle())
                        }.disabled(!session.running && (session.loading || session.sending || (session.draft.mode.pack == nil && session.draft.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && session.draft.attachments.isEmpty)))
                            .accessibilityLabel(session.running ? "응답 중지" : "보내기").accessibilityIdentifier("native-chat-send")
                    }
                }.padding(.horizontal,5).padding(.bottom,4).buttonStyle(.plain)
            }.background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:20)).overlay(RoundedRectangle(cornerRadius:20).strokeBorder(Color.primary.opacity(0.065)))
            HStack {
                Text("첨부한 자료를 바탕으로 답해요").font(.system(size:10)).foregroundStyle(.tertiary)
                Spacer(minLength:4)
                Button { provider = session.provider; model = session.model; showingConfiguration = true } label: {
                    HStack(spacing:4) { Text(session.model.isEmpty || session.model == "default" ? NativeAIProvider(rawValue:session.provider)?.title ?? "AI" : session.model).lineLimit(1); Image(systemName:"chevron.down").font(.system(size:8)) }.font(.system(size:11)).foregroundStyle(.secondary).frame(minHeight:44)
                }.buttonStyle(.plain).disabled(session.running || session.loading).accessibilityLabel("AI 모델 설정")
            }
        }.padding(.horizontal,12).padding(.top,8).background(Color(uiColor:.systemBackground))
    }
    private func attachmentChip(_ attachment: NativeAssistantAttachment, removable: Bool) -> some View {
        HStack(spacing:7) {
            Button { preview = attachment } label: {
                HStack(spacing:7) { Image(systemName:attachment.imageDataURL == nil ? "text.quote" : "viewfinder"); Text(attachment.title + (attachment.page.map { " · \($0)p" } ?? "")).lineLimit(1).frame(maxWidth:180,alignment:.leading) }.frame(minHeight:44)
            }.buttonStyle(.plain).accessibilityIdentifier("native-ai-attachment-" + attachment.id)
            if removable { Button { session.draft.attachments.removeAll { $0.id == attachment.id } } label: { Image(systemName:"xmark").frame(width:44,height:44).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("첨부 제거") }
        }.font(.caption).padding(.leading,10).padding(.trailing,removable ? 0 : 10).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:11))
    }
    private func attachmentPreview(_ attachment: NativeAssistantAttachment) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if let image = attachment.imageInput, let value = image["dataBase64"], let bytes = Data(base64Encoded:value), let uiImage = UIImage(data:bytes) { Image(uiImage:uiImage).resizable().scaledToFit().accessibilityLabel("지목한 영역 이미지").accessibilityIdentifier("native-ai-attachment-preview-image") }
                    if let text = attachment.text { Text(text).textSelection(.enabled).accessibilityIdentifier("native-ai-attachment-preview-text") }
                    Text(attachment.url ?? attachment.relativePath ?? "선택한 영역").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle(attachment.title).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement:.confirmationAction) { Button("닫기") { preview = nil } } }
        }
    }
    private var configuration: some View {
        NavigationStack {
            Form {
                Picker("제공자",selection:$provider) { ForEach(NativeAIProvider.allCases) { Text($0.title).tag($0.rawValue) } }
                TextField("모델 ID (기본 모델)",text:$model).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("API 키 연결 설정") { showingConfiguration = false; onOpenSettings() }
                if let error = session.error { Text(error).foregroundStyle(.red).font(.caption) }
            }.navigationTitle("AI 선택").toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("취소") { showingConfiguration = false } }
                ToolbarItem(placement:.confirmationAction) { Button("적용") { perform { try await session.configure(provider:provider,model:model); showingConfiguration = false } } }
            }
        }
    }
    private var options: some View {
        NavigationStack {
            Form {
                TextField("범위",text:$session.draft.scope)
                Stepper("\(session.draft.count)개",value:$session.draft.count,in:1...30)
                Picker("난이도",selection:$session.draft.difficulty) { ForEach(["쉬움","보통","어려움"],id:\.self) { Text($0).tag($0) } }
                if session.draft.mode == .expectedExam { Text("선택한 범위를 종합한 시험지를 만들고 제출 후 정답과 해설을 확인합니다. 수정 요청은 새 시험지로 저장됩니다.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("\(session.draft.mode.title) 설정").toolbar { ToolbarItem(placement:.confirmationAction) { Button("완료") { showingOptions = false } } }
        }.presentationDetents([.medium,.large])
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
    @ObservedObject var store: NativeWorkspaceStore
    var workspaceID: String? = nil
    var courseID: String? = nil
    var sourceDocument: NativeDocumentReference? = nil
    var body: some View {
        if let course = store.courses.first(where:{ $0.id == (courseID ?? store.selectedCourseID) }) {
            NativeAssistantPanel(store:store,context:.course(course),sourceDocument:sourceDocument,onOpenDocument:{ store.events.send(.init(channel:"nativeWorkspace:openAssistantResult",payload:["document":$0])) },onOpenSettings:{ store.events.send(.init(channel:"nativeWorkspace:openAISettings",payload:[:])) },onAnnotate:{ store.events.send(.init(channel:"nativeWorkspace:annotate",payload:[:])) })
                .id(course.id)
        } else { NativeToolEmptyState(title:"공간을 선택하세요",message:"자료와 함께 대화를 시작하세요.",symbol:"bubble.left.and.bubble.right") }
    }
}

enum NativeAssistantPreferences {
    static func defaultProvider(_ settings: [String: Any]) -> String {
        NativeAIProvider(rawValue:settings["agentProvider"] as? String ?? "")?.rawValue ?? NativeAIProvider.anthropic.rawValue
    }
}
