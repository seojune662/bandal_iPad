import Combine
import SwiftUI

/// The AI conversation: the side panel (Figma A1–A6, 189:6991) or, with `style: .tab`, a whole tab (F1–F2, 195:7359).
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
    /// The panel's own background; the workspace's panel and paper glass pass `.clear`.
    var surface = Color(uiColor: .systemBackground)
    var style = NativeAssistantStyle.panel
    @State private var toast: String?
    /// The message a search result opened: scrolled to and tinted for a moment.
    @State private var revealedMessageID: String?
    @AppStorage(NativeAIPreferences.showsSourcesKey) private var showsSources = true
    /// The note the user removed from the composer: it is not attached again on its own.
    @State private var detachedDocumentID: String?
    @StateObject private var session: NativeAssistantSession
    @State private var showingSignIn = false
    @State private var signInError: String?
    @State private var showingOptions = false
    @State private var showingDelete = false
    @State private var renamingConversation = false
    /// "<message or draft>:<attachment id>": the same capture can sit in a message and in the draft.
    @State private var previewKey: String?
    @State private var showingArticleImport = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var scheme
    private static let panelPrompts = ["이 노트 핵심만 요약해 줘", "시험에 나올 문제 3개 만들어 줘", "강의자료에서 관련 내용 찾아 줘"]
    private static let tabPrompts = ["이 노트 핵심만 요약해 줘", "시험에 나올 문제 3개", "강의자료에서 찾아 줘"]
    private static let tabColumn: CGFloat = 720

    init(store: NativeWorkspaceStore, context: NativeWorkspaceContext, sourceDocument: NativeDocumentReference?, attachments: [NativeAssistantAttachment] = [], onConsumeAttachments: @escaping () -> Void = {}, onOpenDocument: @escaping (NativeDocumentReference) -> Void, onOpenSettings: @escaping (String) -> Void, onAnnotate: @escaping () -> Void, onClose: (() -> Void)? = nil, surface: Color = Color(uiColor: .systemBackground), style: NativeAssistantStyle = .panel) {
        self.onClose = onClose; self.surface = surface; self.style = style
        self.store = store; self.context = context; self.sourceDocument = sourceDocument; self.attachments = attachments
        self.onConsumeAttachments = onConsumeAttachments; self.onOpenDocument = onOpenDocument; self.onOpenSettings = onOpenSettings; self.onAnnotate = onAnnotate
        _session = StateObject(wrappedValue:NativeAssistantSession(store:store,context:context))
    }
    private var isTab: Bool { style == .tab }
    private var look: NativeAssistantLook { isTab ? .tab : .panel }
    private var canAnnotate: Bool {
        guard let document = sourceDocument, document.learningTarget == nil else { return false }
        return ["pdf","note","browser","whiteboard","md","markdown"].contains(document.kind) || ["md","markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())
    }
    private var attachableDocument: NativeDocumentReference? { sourceDocument.flatMap { $0.learningTarget?.kind != .overview ? $0 : nil } }
    private var isEmpty: Bool { session.messages.isEmpty && !session.loading && session.stream.isEmpty && !session.running && !session.sending }
    private var isTyping: Bool { !session.draft.text.isEmpty }

    var body: some View {
        VStack(spacing:0) {
            if isTab { tabBar } else { header }
            errorRow
            if isTab && isEmpty { tabWelcome } else { transcript; composerArea.frame(maxWidth:isTab ? Self.tabColumn : nil).padding(isTab ? EdgeInsets(top:24,leading:24,bottom:36,trailing:24) : EdgeInsets(top:14,leading:14,bottom:14,trailing:14)) }
        }
            // Figma measures the composer from the screen's edge (14 pt, the tab 36), not from the home-indicator inset.
            .ignoresSafeArea(.container,edges:.bottom)
            .background(surface)
            .task { await session.start(); await consumePendingConversation(); consumeAttachments() }
            .onDisappear { session.flushDraft() }
            .bandalToast($toast)
            .task(id:sourceDocument?.id) { attachCurrentNote() }
            .onChange(of:attachments) { _,_ in consumeAttachments() }
            .onChange(of:context) { _,value in session.context = value }
            .onChange(of:store.pendingAssistantConversationIDs[context.id]) { _,_ in Task { await consumePendingConversation() } }
            .onChange(of:store.pendingAssistantRequests[context.id]) { _,_ in consumePendingRequest() }
            .onChange(of:session.ready) { _,ready in if ready { consumePendingRequest() } }
            .onChange(of:scenePhase) { _,phase in if phase == .active { Task { await session.checkAvailability() } } else { session.flushDraft() } }
            .onReceive(store.events) { event in
                // Signed in from the prompt: back to the same panel with the draft untouched.
                if event.channel == "auth:changed", showingSignIn { Task { await session.checkAvailability(); if session.configured { showingSignIn = false } } }
            }
    }

    // MARK: Chrome

    /// A1 header: one 50 pt row. Figma's row overflows its 18 pt trailing padding by 7, so the close mark sits 11 from the edge.
    private var header: some View {
        HStack(spacing:8) {
            Image(systemName:"sparkles").font(.system(size:17)).foregroundStyle(NativeDesktopTheme.accent).accessibilityHidden(true)
            Text("AI 도우미").font(.system(size:17,weight:.semibold)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1).fixedSize()
            modelPill
            Spacer(minLength:1)
            newChatMenu { Image(systemName:"square.and.pencil").font(.system(size:15)).foregroundStyle(NativeDesktopTheme.secondary).assistantHitArea(10) }
            if let onClose {
                Button(action:onClose) { Image(systemName:"xmark").font(.system(size:15)).foregroundStyle(NativeDesktopTheme.secondary).assistantHitArea(10) }
                    .buttonStyle(NativeAssistantButtonStyle()).accessibilityLabel("AI 닫기").accessibilityIdentifier("native-ai-close")
            }
        }.padding(.leading,18).padding(.trailing,11).frame(height:50)
    }
    /// F1: no header, the model capsule top-left and 새 대화 top-right, straight on the paper.
    private var tabBar: some View {
        HStack(spacing:8) {
            modelPill
            Spacer(minLength:8)
            newChatMenu {
                HStack(spacing:6) { Image(systemName:"square.and.pencil").font(.system(size:15)); Text("새 대화").font(.system(size:14,weight:.medium)) }
                    .foregroundStyle(NativeDesktopTheme.text).padding(.horizontal,12).frame(height:35).contentShape(Capsule())
            }
        }.padding(.leading,24).padding(.trailing,27).padding(.top,20)
    }
    private var modelPill: some View {
        NativeAIModelPill(catalog:session.catalog,model:session.effectiveModel,effort:session.effectiveEffort,disabled:session.running || session.loading || session.sending,capsule:isTab,
                          onSelect:{ model,effort in perform { try await session.configure(model:model,effort:effort); NativeAIPreferences.remember(model:model,effort:effort) } },
                          onOpenUsage:{ onOpenSettings("subscription") },
                          onAppear:{ await session.loadCatalog() },
                          onAttachDocument:attachableDocument.map { document in { perform { try await session.pin(document) } } },
                          onAnnotate:onAnnotate,canAnnotate:canAnnotate)
    }
    /// 새 대화 on a tap. The history, rename and delete the design has no button for open on a long press (owner's decision 1).
    private func newChatMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
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
        } label: { label() } primaryAction: { Task { await session.select(nil) } }
            .menuStyle(.button).buttonStyle(NativeAssistantButtonStyle())
            .accessibilityLabel("새 대화").accessibilityHint("길게 누르면 대화 기록이 열려요").accessibilityIdentifier("native-ai-new-chat")
            .bandalConfirm("이 대화를 삭제할까요?",isPresented:$showingDelete,action:"삭제",destructive:true) { perform { try await session.deleteCurrent() } }
            .background {
                Color.clear.accessibilityHidden(true).bandalPopover(isPresented:$renamingConversation,width:300) {
                    BandalTextEntry(title:"대화 이름 변경",prompt:"대화 이름",initial:session.conversations.first(where:{ $0.id == session.sessionID })?.title ?? "",actionTitle:"변경",identifier:"native-ai-conversation-rename") { title in
                        try await session.renameCurrent(title); renamingConversation = false
                    }
                }
            }
    }
    @ViewBuilder private var errorRow: some View {
        if let error = session.error {
            HStack(alignment:.top,spacing:8) {
                Image(systemName:"exclamationmark.circle").foregroundStyle(.orange)
                BandalText(error).font(.caption).foregroundStyle(NativeDesktopTheme.text).frame(maxWidth:.infinity,alignment:.leading)
                if session.errorCode == "TASK_CAP_REACHED" || session.errorCode == "BUDGET_EXHAUSTED" && AIUsage.shared.plan == "pro" {
                    AICreditButton(opensOnLimit:true,identifier:"native-ai-task-cap-credit").font(.caption).frame(minHeight:44)
                }
                if session.errorCode == "TASK_CAP_REACHED" {
                    Button("자동으로 바꾸기") { perform { try await session.configure(model:"default",effort:nil); session.error = nil } }.font(.caption).frame(minHeight:44)
                }
                if session.canRestoreAttempt {
                    Button("초안 복원") { session.restoreAttempt(); session.error = nil }.font(.caption).frame(minHeight:44)
                }
                Button { session.error = nil } label: { Image(systemName:"xmark").font(.system(size:11,weight:.semibold)).frame(width:44,height:44).contentShape(Rectangle()) }
                    .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).accessibilityLabel("닫기").accessibilityIdentifier("native-ai-error-dismiss")
            }.padding(.horizontal,18).padding(.vertical,4).frame(maxWidth:isTab ? Self.tabColumn : nil)
        }
    }

    // MARK: Conversation

    private var transcript: some View {
        GeometryReader { viewport in
            let column = isTab ? min(Self.tabColumn,max(0,viewport.size.width - 48)) : max(0,viewport.size.width - 36)
            let top: CGFloat = 18, bottom: CGFloat = isTab ? 0 : 6, room = max(0,viewport.size.height - top - bottom)
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if isEmpty { welcome.frame(maxWidth:.infinity,minHeight:room) }
                        else {
                            LazyVStack(alignment:.leading,spacing:look.messageGap) {
                                ForEach(session.messages) { message in messageRow(message) }
                                if !session.stream.isEmpty { answer { answerText(session.stream) } }
                                if (session.running || session.sending) && (session.stream.isEmpty || !session.activity.isEmpty) { waitingRow }
                            }.id("bottom").frame(minHeight:isTab ? room : nil,alignment:.bottom)
                        }
                    }.frame(width:column,alignment:.leading).padding(.top,top).padding(.bottom,bottom).frame(maxWidth:.infinity)
                }.scrollDismissesKeyboard(.interactively)
                    .onChange(of:session.messages.count) { _,_ in if revealedMessageID == nil { withAnimation { proxy.scrollTo("bottom",anchor:.bottom) } } }
                    .task(id:revealedMessageID) {
                        guard let id = revealedMessageID else { return }
                        // The lazy stack lays the row out a turn after the conversation loads.
                        try? await Task.sleep(for:.milliseconds(80))
                        withAnimation { proxy.scrollTo(id,anchor:.center) }
                        try? await Task.sleep(for:.seconds(1.2))
                        if !Task.isCancelled, revealedMessageID == id { withAnimation(.easeOut(duration:0.3)) { revealedMessageID = nil } }
                    }
            }
        }
    }
    /// A1: mark, title, one line of what it reads, three questions. The questions leave while typing (A2).
    private var welcome: some View {
        VStack(spacing:12) {
            NativeAssistantTile(look:look)
            welcomeTitle
            Text("지금 노트와 폴더 자료를 참고해서 답해요").font(.system(size:14)).assistantLine(14).foregroundStyle(NativeDesktopTheme.secondary).multilineTextAlignment(.center)
            if !isTyping {
                // Figma draws these at 0.7 of the F1 pill (9.8 pt text): 13 pt text in a 34 pt pill reads at the panel's size.
                VStack(spacing:6) {
                    ForEach(Self.panelPrompts,id:\.self) { prompt in
                        suggestion(prompt) { NativeAssistantPill(title:Text(LocalizedStringKey(prompt)),size:13,color:NativeDesktopTheme.text,height:34,padding:13,stroke:0.7,width:212) }
                    }
                }.padding(.top,7).shadow(color:.black.opacity(scheme == .dark ? 0.5 : 0.1),radius:1,x:0.5,y:1)
            }
        }
    }
    private var welcomeTitle: some View {
        Text("무엇을 도와드릴까요?").font(.system(size:look.title,weight:.semibold)).assistantLine(look.title,look.titleLine).foregroundStyle(NativeDesktopTheme.text).multilineTextAlignment(.center)
    }
    /// F1: mark, title, the input, then the questions in one row. Figma centres the stack 46 pt above the paper's middle.
    private var tabWelcome: some View {
        VStack(spacing:18) {
            NativeAssistantTile(look:look)
            welcomeTitle
            composerArea
            if !isTyping {
                ViewThatFits(in:.horizontal) {
                    HStack(spacing:8) { tabSuggestions }
                    VStack(spacing:8) { tabSuggestions }
                }
            }
        }.frame(maxWidth:Self.tabColumn).padding(.horizontal,24).frame(maxWidth:.infinity,maxHeight:.infinity).offset(y:-81)
    }
    private var tabSuggestions: some View {
        ForEach(Self.tabPrompts,id:\.self) { prompt in
            suggestion(prompt) { NativeAssistantPill(title:Text(LocalizedStringKey(prompt)),size:14,color:NativeDesktopTheme.text,height:43,padding:16,stroke:1) }
        }
    }
    private func suggestion<Label: View>(_ prompt: String, @ViewBuilder label: () -> Label) -> some View {
        Button { session.draft.text = prompt } label: { label() }.buttonStyle(NativeAssistantButtonStyle())
    }
    private func messageRow(_ message: NativeChatMessage) -> some View {
        let isUser = message.role == "user", isLastAnswer = message.id == session.messages.last(where:{ $0.role == "assistant" })?.id
        return VStack(alignment:isUser ? .trailing : .leading,spacing:isUser ? 6 : look.answerGap) {
            if !isUser { answerLabel }
            ForEach(message.attachments) { attachment in attachmentChip(attachment,removable:false,owner:"message-\(message.id)") }
            if !message.text.isEmpty { if isUser { bubble(message.text) } else { answerText(message.text) } }
            // Sources and actions sit on the last answer only (A6).
            if showsSources, isLastAnswer, !message.sources.isEmpty { sources(message.sources) }
            ForEach(message.artifacts) { artifact in artifactCard(artifact) }
            if isLastAnswer, !message.text.isEmpty, !session.running { actions(message) }
            if message.interrupted { Button("요청 다시 준비") { session.restoreAttempt() }.font(.caption).frame(minHeight:44) }
        }.frame(maxWidth:.infinity,alignment:isUser ? .trailing : .leading)
            .padding(6).background(revealedMessageID == message.id ? NativeUnifiedSearchResults.matchTint.opacity(0.35) : .clear,in:RoundedRectangle(cornerRadius:10)).padding(-6)
            .accessibilityIdentifier("native-assistant-message-" + message.id)
    }
    private func bubble(_ text: String) -> some View {
        Text(.init(text)).font(.system(size:look.text)).assistantLine(look.text,look.lineHeight).foregroundStyle(NativeDesktopTheme.onAccent)
            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
            .padding(.horizontal,look.bubblePadding.width).padding(.vertical,look.bubblePadding.height)
            .background(NativeDesktopTheme.accent,in:NativeAssistantBubble(radius:look.bubbleRadius))
            .frame(maxWidth:look.bubbleWidth,alignment:.trailing)
    }
    private var answerLabel: some View {
        HStack(spacing:6) {
            Image(systemName:"sparkles").font(.system(size:look.label)).accessibilityHidden(true)
            Text("반달 AI").font(.system(size:look.label,weight:.semibold)).assistantLine(look.label,look.lineHeight)
        }.foregroundStyle(NativeDesktopTheme.text)
    }
    private func answer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment:.leading,spacing:look.answerGap) { answerLabel; content() }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func answerText(_ text: String) -> some View {
        Text(.init(text)).font(.system(size:look.text)).assistantLine(look.text,look.lineHeight).foregroundStyle(NativeDesktopTheme.text)
            .textSelection(.enabled).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
    }
    /// A3: the mark, three dots and what is being read.
    private var waitingRow: some View {
        HStack(spacing:8) {
            Image(systemName:"sparkles").font(.system(size:13)).foregroundStyle(NativeDesktopTheme.text).accessibilityHidden(true)
            NativeAssistantDots()
            Text(session.activity.isEmpty ? "답변을 정리하고 있어요" : session.activity).font(.system(size:13)).foregroundStyle(NativeDesktopTheme.secondary)
        }
    }
    private func sources(_ sources: [NativeChatSource]) -> some View {
        ScrollView(.horizontal,showsIndicators:false) {
            HStack(spacing:6) {
                ForEach(sources) { source in
                    Button { open(source) } label: {
                        NativeAssistantPill(symbol:"doc.text",title:Text(verbatim:source.title),size:look.sourceText,iconSize:look.sourceIcon,height:look.sourceHeight,padding:look.sourcePadding,fill:look.sourceFill)
                    }.buttonStyle(NativeAssistantButtonStyle()).accessibilityLabel("출처: " + source.title).accessibilityHint("자료를 엽니다").accessibilityIdentifier("native-ai-source")
                }
            }
        }
    }
    private func artifactCard(_ artifact: NativeAssistantResult) -> some View {
        Button { onOpenDocument(artifact.document) } label: {
            HStack(spacing:12) {
                Image(systemName:artifact.mode == "flashcards" ? "rectangle.on.rectangle" : "doc.text").font(.title3)
                VStack(alignment:.leading,spacing:4) { Text(artifact.title).font(.system(size:14,weight:.semibold)).lineLimit(2).fixedSize(horizontal:false,vertical:true); Text(artifact.mode == "expected-exam" ? "AI 생성 예상문제" : artifact.mode == "english" ? "영어 읽기 · 표현 저장" : "저장된 학습 자료").font(.caption).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal:false,vertical:true) }.frame(maxWidth:.infinity,alignment:.leading)
                Text("열기").font(.caption.weight(.semibold)).fixedSize()
            }.foregroundStyle(NativeDesktopTheme.text).padding(14).frame(maxWidth:.infinity,alignment:.leading).background(NativeDesktopTheme.bgApp,in:RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain)
    }
    private func actions(_ message: NativeChatMessage) -> some View {
        HStack(spacing:8) {
            if insertableDocument != nil {
                Button { insertIntoNote(message) } label: { actionPill(Text("노트에 넣기"),symbol:"plus") }.accessibilityIdentifier("native-ai-insert-note")
            }
            Button { UIPasteboard.general.string = message.text; toast = "복사했어요" } label: { actionPill(Text("복사"),asset:"IconCopy") }.accessibilityIdentifier("native-ai-copy-answer")
        }.buttonStyle(NativeAssistantButtonStyle())
    }
    private func actionPill(_ title: Text, symbol: String? = nil, asset: String? = nil) -> some View {
        NativeAssistantPill(symbol:symbol,asset:asset,title:title,size:look.actionText,iconSize:look.actionIcon,weight:.medium,color:NativeDesktopTheme.text,
                            height:look.actionHeight,padding:look.actionPadding,gap:6,stroke:look.actionStroke)
    }
    private var insertableDocument: NativeDocumentReference? { sourceDocument.flatMap { $0.kind == "pdf" && $0.learningTarget == nil ? $0 : nil } }
    /// The note on screen rides along with the next question until the user removes it.
    private func attachCurrentNote() {
        guard let document = sourceDocument, !document.isWorkspaceTool, document.learningTarget == nil, session.draft.document == nil,
              detachedDocumentID != document.id, canAnnotate else { return }
        perform { try await session.pin(document) }
    }
    /// The note draws the memo and its "노트에 넣었어요 | 되돌리기" toast on the paper (A5), next to the passage or
    /// area the question was asked about (its attachments), when there is one.
    private func insertIntoNote(_ message: NativeChatMessage) {
        guard let document = insertableDocument else { return }
        #if DEBUG
        // UI tests have no AI to call draw_diagram, or to write an answer longer than a page: these stand in.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--native-ai-diagram-fixture") {
            Task { _ = try? await NativeAIDiagram.draw(NativeAIDiagram.fixture,document:["courseId":document.courseID,"relPath":document.relativePath,"kind":"pdf"]) { store.events.send(NativeWorkspaceEvent(channel:$0,payload:$1)) } }
            return
        }
        let text = arguments.contains("--native-ai-long-answer-fixture") ? Array(repeating:message.text,count:60).joined(separator:"\n") : message.text
        #else
        let text = message.text
        #endif
        store.events.send(NativeWorkspaceEvent(channel:"nativeWorkspace:insertAINote",payload:["courseId":document.courseID,"relPath":document.relativePath,"tabID":document.id,"text":text,
            "model":session.catalog.label(session.effectiveModel),"sources":message.sources.count,"question":NativeAINoteTarget.question(for:message,in:session.messages)]))
    }
    /// A source that was renamed or deleted since the answer says so instead of opening an empty tab.
    private func open(_ source: NativeChatSource) {
        Task {
            guard (try? await store.invokePrivate("nativeMaterial:path",["courseId":source.courseID,"relPath":source.relPath])) != nil else {
                toast = "자료를 찾을 수 없어요. 이름을 바꿨거나 지웠을 수 있어요."; return
            }
            store.events.send(.init(channel:"nativeWorkspace:openDocument",payload:source.request))
        }
    }

    // MARK: Composer

    /// The input with what rides along above it: mode rows and the attachment chips (A2).
    private var composerArea: some View {
        VStack(alignment:.leading,spacing:8) {
            if session.draft.mode == .english {
                Button { showingArticleImport = true } label: { Label("기사 주소 추가",systemImage:"link").font(.system(size:13,weight:.medium)).foregroundStyle(NativeDesktopTheme.text).frame(minHeight:44) }.buttonStyle(.plain).disabled(session.running || session.sending).accessibilityIdentifier("native-ai-import-article")
                    .bandalPopover(isPresented:$showingArticleImport,width:320) {
                        BandalTextEntry(title:"기사 주소",prompt:"https://…",actionTitle:"가져오기",keyboard:.URL,identifier:"native-ai-article-url") { url in
                            showingArticleImport = false; perform { try await session.importArticle(url) }
                        }
                    }
            }
            if session.draft.mode.pack != nil {
                Button { showingOptions = true } label: {
                    HStack { Text(session.draft.mode.title).foregroundStyle(NativeDesktopTheme.text); Text("· \(session.draft.count)개 · \(session.draft.difficulty)").foregroundStyle(NativeDesktopTheme.secondary); Spacer(); Image(systemName:"slider.horizontal.3").foregroundStyle(NativeDesktopTheme.secondary) }.font(.caption).frame(minHeight:44)
                }.buttonStyle(.plain).accessibilityIdentifier("native-ai-mode-options")
                    .bandalPopover(isPresented:$showingOptions,width:300) { options }
            }
            draftChips
            composer
        }
    }
    /// The note in view shows once a question is being written (A2); captures the user made always show.
    @ViewBuilder private var draftChips: some View {
        let document = isTyping || session.draft.mode.pack != nil || !session.draft.attachments.isEmpty ? session.draft.document : nil
        if document != nil || !session.draft.attachments.isEmpty {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack(spacing:6) {
                    if let document {
                        draftChip("doc.text",document.title,removeLabel:"문서 첨부 제거") { detachedDocumentID = document.id; session.draft.document = nil; session.draft.selection = "" } label: { $0 }
                    }
                    ForEach(session.draft.attachments) { attachmentChip($0,removable:true) }
                }
            }
        }
    }
    /// A2 chip: 29 pt capsule, `doc.text` 12, the name 13 Medium, a 10 pt remove mark.
    private func draftChip<Label: View>(_ symbol: String, _ title: String, removeLabel: String, remove: @escaping () -> Void, @ViewBuilder label: (AnyView) -> Label) -> some View {
        HStack(spacing:6) {
            label(AnyView(HStack(spacing:6) {
                Image(systemName:symbol).font(.system(size:12)).foregroundStyle(NativeDesktopTheme.secondary)
                Text(verbatim:title).font(.system(size:13,weight:.medium)).foregroundStyle(NativeDesktopTheme.text).lineLimit(1).frame(maxWidth:180).fixedSize()
            }))
            Button(action:remove) { Image(systemName:"xmark").font(.system(size:10)).foregroundStyle(NativeDesktopTheme.muted).assistantHitArea(10) }
                .buttonStyle(NativeAssistantButtonStyle()).accessibilityLabel(removeLabel)
        }.padding(.horizontal,10).frame(height:29).background(NativeDesktopTheme.bgApp,in:Capsule())
    }
    private func attachmentChip(_ attachment: NativeAssistantAttachment, removable: Bool, owner: String = "draft") -> some View {
        let key = owner + ":" + attachment.id, symbol = attachment.imageDataURL == nil ? "doc.text" : "viewfinder"
        let title = attachment.title + (attachment.page.map { " · \($0)p" } ?? "")
        let preview = Binding(get:{ previewKey == key },set:{ if !$0 && previewKey == key { previewKey = nil } })
        return Group {
            if removable {
                draftChip(symbol,title,removeLabel:"첨부 제거") { session.draft.attachments.removeAll { $0.id == attachment.id } } label: { content in
                    Button { previewKey = key } label: { content }.buttonStyle(NativeAssistantButtonStyle()).accessibilityIdentifier("native-ai-attachment-" + attachment.id)
                        .bandalPopover(isPresented:preview,width:360) { attachmentPreview(attachment) }
                }
            } else {
                // A3: the sent chip is smaller and quieter, above the bubble.
                Button { previewKey = key } label: { NativeAssistantPill(symbol:symbol,title:Text(verbatim:title),weight:.medium) }
                    .buttonStyle(NativeAssistantButtonStyle()).accessibilityIdentifier("native-ai-attachment-" + attachment.id)
                    .bandalPopover(isPresented:preview,width:360) { attachmentPreview(attachment) }
            }
        }
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
    /// A1: one capsule row (text, mic, send). F1 adds ＋ in front, a 28 pt corner and a soft shadow.
    private var composer: some View {
        let shape = RoundedRectangle(cornerRadius:isTab ? 28 : 26.5)
        return HStack(spacing:isTab ? 12 : 8) {
            if isTab { attachMenu }
            TextField("",text:$session.draft.text,prompt:Text(LocalizedStringKey(session.draft.mode.title == "대화" ? "무엇이든 물어보세요" : "원하는 내용을 알려 주세요")).foregroundStyle(NativeDesktopTheme.muted),axis:.vertical)
                .font(.system(size:isTab ? 16 : 15)).foregroundStyle(NativeDesktopTheme.text).tint(NativeDesktopTheme.accent).lineLimit(1...6).textFieldStyle(.plain).accessibilityIdentifier("native-chat-input")
            // Voice input has no feature behind it yet (owner's decision 2).
            if NativeReleaseFlags.showsUnbuiltFeatures {
                Button { toast = "음성 입력은 준비 중이에요" } label: { Image(systemName:"mic").font(.system(size:isTab ? 18 : 17)).foregroundStyle(NativeDesktopTheme.secondary).assistantHitArea(4) }
                    .buttonStyle(NativeAssistantButtonStyle()).accessibilityLabel("음성 입력 (준비 중)").accessibilityIdentifier("native-ai-voice")
            }
            sendButton
        }.padding(.horizontal,isTab ? 20 : 14).padding(.vertical,isTab ? 12 : 10)
            .background(NativeDesktopTheme.bgApp,in:shape).overlay { shape.strokeBorder(NativeDesktopTheme.border,lineWidth:1) }
            .shadow(color:.black.opacity(isTab ? (scheme == .dark ? 0.4 : 0.06) : 0),radius:10,y:6)
    }
    /// F1's ＋. The panel has none: there the same actions sit in the model popover.
    private var attachMenu: some View {
        Menu {
            if let document = attachableDocument { Button("현재 문서 첨부") { perform { try await session.pin(document) } } }
            Button("지목해서 질문",action:onAnnotate).disabled(!canAnnotate)
        } label: { Image(systemName:"plus").font(.system(size:18)).foregroundStyle(NativeDesktopTheme.secondary).assistantHitArea(10) }
            .menuStyle(.button).buttonStyle(NativeAssistantButtonStyle()).accessibilityLabel("자료 첨부")
    }
    private var sendButton: some View {
        let blocked = session.loading || session.sending || (session.draft.mode.pack == nil && session.draft.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && session.draft.attachments.isEmpty)
        return Button {
            if session.running { perform { try await session.cancel() } } else { submit() }
        } label: {
            if session.running {
                // A3: a 28 pt disc with a 9 pt square.
                Circle().fill(NativeDesktopTheme.text).frame(width:28,height:28).overlay { RoundedRectangle(cornerRadius:2).fill(NativeDesktopTheme.bgApp).frame(width:9,height:9) }
            } else {
                // Figma draws the panel's empty send at 35 %; the tab's stays solid.
                Image(systemName:"arrowtriangle.up.circle.fill").font(.system(size:isTab ? 30 : 26)).foregroundStyle(isTab ? NativeDesktopTheme.text : NativeDesktopTheme.accent)
                    .opacity(blocked && !isTab ? 0.35 : 1).frame(height:isTab ? 36 : 31)
            }
        }.assistantHitArea(8).buttonStyle(NativeAssistantButtonStyle()).disabled(!session.running && blocked)
            .accessibilityLabel(session.running ? "응답 중지" : "보내기").accessibilityIdentifier("native-chat-send")
            .bandalPopover(isPresented:$showingSignIn,arrowEdge:.bottom,width:264) { signInPrompt }
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
        if session.sessionID != id { await session.selectID(id) }
        if store.pendingAssistantConversationIDs[context.id] == id { store.pendingAssistantConversationIDs.removeValue(forKey:context.id) }
        // Opened from a search result: show the message that matched.
        if let message = store.pendingAssistantMessageIDs.removeValue(forKey:context.id), session.messages.contains(where:{ $0.id == message }) { revealedMessageID = message }
    }
    /// A request from outside the panel: attach, fill the composer, send. Text the user was typing is kept (the prompt goes after it).
    private func consumePendingRequest() {
        guard session.ready, !session.running, !session.sending, let request = store.pendingAssistantRequests[context.id] else { return }
        store.pendingAssistantRequests.removeValue(forKey:context.id)
        session.attach([request.attachment])
        let typed = session.draft.text.trimmingCharacters(in:.whitespacesAndNewlines)
        session.draft.text = typed.isEmpty ? request.prompt : typed + "\n" + request.prompt
        if request.sends { submit() }
    }
    private func consumeAttachments() { guard !attachments.isEmpty, session.ready else { return }; session.attach(attachments); onConsumeAttachments() }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) { Task { do { try await action() } catch { session.error = error.localizedDescription } } }
}

/// Compatibility for saved tool tabs, and the AI tab (`fullTab`). New workspace chrome opens the global panel.
struct NativeAssistantWorkspace: View {
    var store: NativeWorkspaceStore
    var workspaceID: String? = nil
    var courseID: String? = nil
    var sourceDocument: NativeDocumentReference? = nil
    /// AI as a whole tab (Figma F1–F2): no header, one centred column, drawn straight on the paper glass.
    var fullTab = false
    var body: some View {
        if let course = store.courses.first(where:{ $0.id == (courseID ?? store.selectedCourseID) }) {
            NativeAssistantPanel(store:store,context:.course(course),sourceDocument:sourceDocument,onOpenDocument:{ store.events.send(.init(channel:"nativeWorkspace:openAssistantResult",payload:["document":$0])) },onOpenSettings:{ store.events.send(.init(channel:"nativeWorkspace:openSettings",payload:["category":$0])) },onAnnotate:{ store.events.send(.init(channel:"nativeWorkspace:annotate",payload:[:])) },
                                 surface:fullTab ? .clear : Color(uiColor:.systemBackground),style:fullTab ? .tab : .panel)
                .id(course.id)
        } else { NativeToolEmptyState(title:"공간을 선택하세요",message:"자료와 함께 대화를 시작하세요.",symbol:"bubble.left.and.bubble.right") }
    }
}
