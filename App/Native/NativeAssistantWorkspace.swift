import Combine
import SwiftUI

struct NativeChatMessage: Identifiable, Equatable {
  let id: String
  let role: String
  let text: String
  init?(_ value: [String: Any]) {
    guard let id = value["id"] as? String, let role = value["role"] as? String else { return nil }
    self.id = id
    self.role = role
    let blocks = value["blocks"] as? [[String: Any]] ?? []
    text = blocks.compactMap { block -> String? in
      let payload = block["payload"] as? [String: Any]
      if block["kind"] as? String == "text" {
        let text = payload?["text"] as? String ?? block["payload"] as? String ?? ""
        return payload?["interrupted"] as? Bool == true ? text + "\n\n응답이 중단되었습니다." : text
      }
      if block["kind"] as? String == "tool" {
        return payload?["label"] as? String ?? payload?["summary"] as? String
      }
      return nil
    }.joined(separator: "\n\n")
  }
}

private struct NativeChatConversation: Identifiable {
  let id: String
  let title: String
  let provider: String
}
private struct NativeChatPermission: Identifiable {
  let id: String
  let tool: String
  let detail: String
}

@MainActor
private final class NativeAssistantSession: ObservableObject {
  let store: NativeWorkspaceStore
  @Published var conversations: [NativeChatConversation] = []
  @Published var messages: [NativeChatMessage] = []
  @Published var stream = ""
  @Published var activity = ""
  @Published var error: String?
  @Published var running = false
  @Published var loading = false
  @Published var sending = false
  @Published var provider = NativeAIProvider.openAI.rawValue
  @Published var model = ""
  @Published var permissions: [NativeChatPermission] = []
  @Published var sessionID = UUID().uuidString
  private var courseID: String?
  private var sequence = 0
  private var generation = UUID()
  private var blocks: [String: String] = [:]
  private var blockOrder: [String] = []
  private var subscriptions = Set<AnyCancellable>()
  private let workspaceID: String?
  private let sourceDocument: NativeDocumentReference?
  private var selectionURL: URL? {
    workspaceID.map { NativeToolSelection.conversationURL(workspaceID: $0, root: store.root) }
  }
  init(store: NativeWorkspaceStore, workspaceID: String? = nil, sourceDocument: NativeDocumentReference? = nil) {
    self.store = store
    self.workspaceID = workspaceID
    self.sourceDocument = sourceDocument
    store.events.sink { [weak self] event in self?.receive(event) }.store(in: &subscriptions)
  }
  func start(courseID: String?) async {
    let current = UUID()
    generation = current
    self.courseID = courseID
    messages = []
    stream = ""
    permissions = []
    error = nil
    running = false
    sequence = 0
    blocks = [:]
    blockOrder = []
    activity = ""
    conversations = []
    sessionID = UUID().uuidString
    loading = false
    guard let courseID else { return }
    loading = true
    defer { if generation == current { loading = false } }
    do {
      let result =
        try await store.invoke("chat:conversations", ["courseId": courseID, "surface": "app"])
        as? [String: Any]
      guard generation == current, !Task.isCancelled else { return }
      conversations = (result?["conversations"] as? [[String: Any]] ?? []).compactMap {
        guard let id = $0["id"] as? String else { return nil }
        return NativeChatConversation(
          id: id, title: $0["title"] as? String ?? "새 대화",
          provider: $0["provider"] as? String ?? "codex")
      }
      let storedID = selectionURL.flatMap { try? Data(contentsOf:$0) }.flatMap { try? JSONDecoder().decode(String.self,from:$0) }
      let restored = workspaceID == nil ? conversations.first : conversations.first(where: { $0.id == storedID })
      if let first = restored {
        sessionID = first.id
        provider = first.provider
      } else {
        let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
        guard generation == current, !Task.isCancelled else { return }
        provider = NativeAssistantPreferences.defaultProvider(settings)
      }
      try await open()
    } catch { if generation == current { self.error = error.localizedDescription } }
  }
  func open() async throws {
    guard let courseID else { return }
    let id = sessionID
    let current = generation
    guard
      let result = try await store.invoke(
        "chat:open",
        ["courseId": courseID, "sessionId": id, "surface": "app", "provider": provider])
        as? [String: Any]
    else {
      throw DesktopRuntimeError("대화를 불러오지 못했습니다.")
    }
    guard current == generation, id == sessionID, !Task.isCancelled else { return }
    messages = (result["history"] as? [[String: Any]] ?? []).compactMap(NativeChatMessage.init)
    if let info = result["sessionInfo"] as? [String: Any] {
      provider = info["provider"] as? String ?? provider
      model = info["model"] as? String ?? ""
      running = info["status"] as? String == "running"
    } else {
      running = false
    }
    let snapshotSequence = (result["eventSeq"] as? NSNumber)?.intValue ?? sequence
    if snapshotSequence >= sequence {
      sequence = snapshotSequence
      if running, let active = result["activeBlock"] as? [String: Any],
        let blockID = active["id"] as? String, let text = active["text"] as? String
      {
        blocks = [blockID: text]
        blockOrder = [blockID]
        stream = text
      }
    }
    permissions = (result["pendingPermissions"] as? [[String: Any]] ?? []).compactMap(
      Self.permission)
    if !running {
      blocks = [:]
      blockOrder = []
      stream = ""
      activity = ""
    }
    if let url = selectionURL {
      try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
      try JSONEncoder().encode(sessionID).write(to:url,options:.atomic)
    }
  }
  func select(_ conversation: NativeChatConversation?) async {
    guard !sending else { return }
    let current = UUID()
    generation = current
    sessionID = conversation?.id ?? UUID().uuidString
    provider = conversation?.provider ?? provider
    sequence = 0
    messages = []
    blocks = [:]
    blockOrder = []
    stream = ""
    permissions = []
    activity = ""
    running = false
    loading = true
    defer { if generation == current { loading = false } }
    do {
      if conversation == nil {
        let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
        guard generation == current, !Task.isCancelled else { return }
        provider = NativeAssistantPreferences.defaultProvider(settings)
      }
      try await open()
      if generation == current { error = nil }
    } catch { if generation == current { self.error = error.localizedDescription } }
  }
  func send(_ text: String) async throws {
    guard !sending, !running, let courseID else {
      throw DesktopRuntimeError("진행 중인 응답을 마친 뒤 다시 보내세요.")
    }
    let id = sessionID
    let current = generation
    sending = true
    defer { sending = false }
    blocks = [:]
    blockOrder = []
    stream = ""
    activity = ""
    error = nil
    var request: [String: Any] = ["courseId": courseID, "sessionId": id, "content": text]
    if let document = sourceDocument {
      try await store.flushDocuments()
      request["documentContext"] = ["courseId": document.courseID, "relPath": document.relativePath, "title": document.title, "kind": document.kind, "selection": String((store.documentSelections[document.id] ?? "").prefix(20_000))]
    }
    _ = try await store.invoke("chat:send", request)
    guard current == generation, id == sessionID else { return }
    // Read the accepted user message and current status. A very short turn
    // can already be complete when the send acknowledgement arrives.
    try await open()
    if !conversations.contains(where: { $0.id == id }) {
      conversations.insert(.init(id: id, title: String(text.prefix(60)), provider: provider), at: 0)
    }
  }
  func cancel() async throws {
    guard let courseID else { return }
    _ = try await store.invoke("chat:cancel", ["courseId": courseID, "sessionId": sessionID])
    try await open()
  }
  func configure(provider: String, model: String) async throws {
    guard let courseID else { return }
    if self.provider != provider {
      _ = try await store.invoke(
        "chat:setProvider",
        ["courseId": courseID, "sessionId": sessionID, "provider": provider, "surface": "app"])
    }
    _ = try await store.invoke(
      "chat:setConfiguration",
      [
        "courseId": courseID, "sessionId": sessionID, "model": model.isEmpty ? "default" : model,
        "effort": NSNull(),
      ])
    try await open()
  }
  func respond(_ permission: NativeChatPermission, allow: Bool) async throws {
    guard let courseID else { return }
    _ = try await store.invoke(
      "chat:respondPermission",
      [
        "courseId": courseID, "sessionId": sessionID, "requestId": permission.id,
        "response": ["behavior": allow ? "allow" : "deny", "remember": false],
      ])
    permissions.removeAll { $0.id == permission.id }
  }
  func delete(_ conversation: NativeChatConversation) async throws {
    guard let courseID else { return }
    _ = try await store.invoke(
      "chat:deleteConversation", ["courseId": courseID, "sessionId": conversation.id])
    conversations.removeAll { $0.id == conversation.id }
    if sessionID == conversation.id { await select(conversations.first) }
  }
  private func receive(_ event: NativeWorkspaceEvent) {
    guard let value = event.payload as? [String: Any], value["sessionId"] as? String == sessionID
    else { return }
    if event.channel == "chat:message", let raw = value["message"] as? [String: Any],
      let message = NativeChatMessage(raw)
    {
      if let index = messages.firstIndex(where: { $0.id == message.id }) {
        messages[index] = message
      } else {
        messages.append(message)
      }
      return
    }
    guard event.channel == "chat:event-batch", value["courseId"] as? String == courseID else {
      return
    }
    let next = (value["seq"] as? NSNumber)?.intValue ?? sequence + 1
    guard next > sequence else { return }
    if sequence > 0, next > sequence + 1 {
      Task { do { try await open() } catch { self.error = error.localizedDescription } }
    }
    sequence = next
    for event in value["events"] as? [[String: Any]] ?? [] {
      switch event["type"] as? String {
      case "text-delta", "text-final":
        let id = event["blockId"] as? String ?? "answer"
        if blocks[id] == nil {
          blocks[id] = ""
          blockOrder.append(id)
        }
        if event["type"] as? String == "text-final" {
          blocks[id] = event["text"] as? String ?? ""
        } else {
          blocks[id, default: ""] += event["text"] as? String ?? ""
        }
        stream = blockOrder.compactMap { blocks[$0] }.joined(separator: "\n\n")
        running = true
      case "session-started": running = true
      case "tool-start":
        activity = event["label"] as? String ?? event["toolName"] as? String ?? "작업 중"
      case "tool-end": activity = ""
      case "permission-request":
        if let permission = Self.permission(event),
          !permissions.contains(where: { $0.id == permission.id })
        {
          permissions.append(permission)
        }
      case "turn-complete":
        running = false
        activity = ""
        Task { do { try await open() } catch { self.error = error.localizedDescription } }
      case "error":
        error = event["message"] as? String ?? "AI 응답을 완료하지 못했습니다."
        running = false
      default: break
      }
    }
  }
  private static func permission(_ event: [String: Any]) -> NativeChatPermission? {
    guard let id = event["requestId"] as? String else { return nil }
    let detail =
      event["input"].flatMap {
        try? JSONSerialization.data(
          withJSONObject: $0, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
      }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return NativeChatPermission(
      id: id, tool: event["toolName"] as? String ?? "도구 사용", detail: detail)
  }
}

struct NativeAssistantWorkspace: View {
  @ObservedObject var store: NativeWorkspaceStore
  @StateObject private var session: NativeAssistantSession
  @State private var draft = ""
  @State private var showingConfiguration = false
  @State private var provider = NativeAIProvider.openAI.rawValue
  @State private var model = ""
  @State private var deleting: NativeChatConversation?
  @State private var configuring = false
  private let workspaceID: String?
  private let scopedCourseID: String?
  private var effectiveCourseID: String? { scopedCourseID ?? store.selectedCourseID }
  private var draftURL: URL? {
    workspaceID.map { store.root.appendingPathComponent("NativeToolState/draft-\(Data($0.utf8).base64EncodedString().replacingOccurrences(of:"/",with:"_")).txt") }
  }
  init(store: NativeWorkspaceStore, workspaceID: String? = nil, courseID: String? = nil, sourceDocument: NativeDocumentReference? = nil) {
    self.store = store
    self.workspaceID = workspaceID
    self.scopedCourseID = courseID
    _session = StateObject(wrappedValue: NativeAssistantSession(store: store,workspaceID:workspaceID,sourceDocument:sourceDocument))
  }
  @Environment(\.colorScheme) private var colorScheme
  private var paper: Color {
    colorScheme == .dark ? Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255) : .white
  }
  private var chatRaised: Color {
    colorScheme == .dark
      ? Color(red: 44 / 255, green: 45 / 255, blue: 48 / 255) : Color(white: 245 / 255)
  }
  private var chatInk: Color {
    colorScheme == .dark
      ? Color(red: 236 / 255, green: 236 / 255, blue: 238 / 255)
      : Color(red: 37 / 255, green: 38 / 255, blue: 41 / 255)
  }
  private var chatLine: Color {
    colorScheme == .dark
      ? Color(red: 57 / 255, green: 58 / 255, blue: 62 / 255)
      : Color(red: 229 / 255, green: 229 / 255, blue: 231 / 255)
  }
  private let starters = ["이번 주 강의자료를 요약해줘", "내 필기에서 빠진 개념이 있는지 봐줘", "시험에 나올 만한 핵심 내용을 뽑아줘"]
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Menu {
          Button("새 대화", systemImage: "plus") { Task { await session.select(nil) } }
          ForEach(session.conversations) { conversation in
            Button(conversation.title) { Task { await session.select(conversation) } }
          }
          if let conversation = session.conversations.first(where: { $0.id == session.sessionID }) {
            Divider()
            Button("현재 대화 삭제", role: .destructive) { deleting = conversation }.disabled(
              session.running)
          }
        } label: {
          HStack(spacing: 6) {
            Text(
              session.conversations.first(where: { $0.id == session.sessionID })?.title ?? "새 대화"
            ).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 10))
          }
        }.font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
        Spacer()
        Button("새 대화", systemImage: "square.and.pencil") { Task { await session.select(nil) } }
          .buttonStyle(NativeToolIconStyle())
      }.padding(.horizontal, 16).frame(height: 44)
      if let error = session.error { NativeToolError(message: error) }
      if effectiveCourseID == nil {
        NativeToolEmptyState(
          title: "과목을 선택하세요", message: "강의자료를 읽고 필기도 도와줘요.", symbol: "bubble.left.and.bubble.right")
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
              if session.messages.isEmpty && !session.loading && !session.running {
                emptyConversation
              }
              ForEach(session.messages) { message in
                HStack(alignment: .top) {
                  if message.role == "user" { Spacer(minLength: 56) }
                  Text(.init(message.text)).textSelection(.enabled).font(.system(size: 15))
                    .lineSpacing(9)
                    .padding(.horizontal, message.role == "user" ? 16 : 0).padding(
                      .vertical, message.role == "user" ? 10 : 0
                    )
                    .background(
                      message.role == "user" ? chatRaised : .clear,
                      in: RoundedRectangle(cornerRadius: 22)
                    )
                    .frame(maxWidth: message.role == "user" ? nil : .infinity, alignment: .leading)
                  if message.role != "user" { Spacer(minLength: 0) }
                }
              }
              if !session.stream.isEmpty {
                Text(.init(session.stream)).textSelection(.enabled).font(.system(size: 15))
                  .lineSpacing(9).frame(maxWidth: .infinity, alignment: .leading)
              }
              ForEach(session.permissions) { permission in
                NativeToolCard {
                  VStack(alignment: .leading, spacing: 10) {
                    Label(permission.tool, systemImage: "hand.raised").font(
                      .system(size: 13, weight: .medium))
                    Text(permission.detail).font(.system(size: 12, design: .monospaced))
                      .textSelection(.enabled)
                    HStack {
                      Button("거절") {
                        perform { try await session.respond(permission, allow: false) }
                      }.buttonStyle(NativeToolButtonStyle())
                      Button("이번만 허용") {
                        perform { try await session.respond(permission, allow: true) }
                      }.buttonStyle(NativeToolButtonStyle(primary: true))
                    }
                  }
                }
              }
              if session.running {
                HStack(spacing: 8) {
                  ProgressView().controlSize(.small)
                  Text(session.activity.isEmpty ? "답변하는 중" : session.activity).font(
                    .system(size: 12)
                  ).foregroundStyle(NativeDesktopTheme.muted)
                }
              }
              Color.clear.frame(height: 1).id("bottom")
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 32).frame(maxWidth: 800)
              .frame(maxWidth: .infinity)
          }
          .scrollDismissesKeyboard(.interactively)
          .onChange(of: session.messages.count) { _, _ in
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
          composer.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
            .frame(maxWidth: 792).frame(maxWidth: .infinity).background(paper)
        }
      }
    }.background(paper).foregroundStyle(chatInk)
      .sheet(isPresented: $showingConfiguration) { configurationSheet }
      .confirmationDialog(
        "이 대화를 삭제할까요?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
      ) {
        Button("삭제", role: .destructive) {
          guard let conversation = deleting else { return }
          deleting = nil
          perform { try await session.delete(conversation) }
        }
      }
      .task(id: effectiveCourseID) {
        draft = draftURL.flatMap { try? String(contentsOf:$0,encoding:.utf8) } ?? ""
        await session.start(courseID: effectiveCourseID)
      }
      .onChange(of:draft) { _, value in
        guard let url = draftURL else { return }
        do {
          try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
          try Data(value.utf8).write(to:url,options:.atomic)
        } catch { session.error = "작성 중인 대화를 저장하지 못했습니다: \(error.localizedDescription)" }
      }
  }
  private var emptyConversation: some View {
    VStack(spacing: 14) {
      NativeBandalMark(size: 56).padding(.bottom, 12)
      Text(
        store.courses.first(where: { $0.id == effectiveCourseID }).map {
          $0.name + ", 함께 공부해요"
        } ?? "무엇이 궁금한가요?"
      )
      .font(.system(size: 24, weight: .medium)).tracking(-0.96)
      Text("강의자료를 읽고 필기도 도와줘요.").font(.system(size: 13)).foregroundStyle(
        NativeDesktopTheme.secondary)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { starterButtons.fixedSize() }
        VStack(spacing: 8) { starterButtons }
      }
    }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(
      .vertical, 28)
  }
  private var starterButtons: some View {
    ForEach(starters, id: \.self) { prompt in
      Button {
        draft = prompt
      } label: {
        Text(prompt).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(
          .horizontal, 12
        ).padding(.vertical, 9)
          .background(chatRaised, in: Capsule()).overlay(Capsule().strokeBorder(chatLine))
      }.buttonStyle(.plain)
    }
  }
  private var composer: some View {
    VStack(spacing: 6) {
      HStack(alignment: .bottom, spacing: 6) {
        Menu {
          ForEach(starters, id: \.self) { prompt in Button(prompt) { draft = prompt } }
        } label: {
          Image(systemName: "plus").font(.system(size: 21, weight: .light)).frame(
            width: 36, height: 36)
        }.foregroundStyle(NativeDesktopTheme.secondary)
        TextField("무엇이든 물어보세요", text: $draft, axis: .vertical)
          .lineLimit(1...7).textFieldStyle(.plain).font(.system(size: 15)).padding(.vertical, 8)
          .frame(minWidth: 60)
          .accessibilityIdentifier("native-chat-input")
        Button {
          if session.running { perform { try await session.cancel() } } else { send() }
        } label: {
          Image(systemName: session.running ? "stop.fill" : "arrow.up").font(
            .system(size: 16, weight: .semibold)
          )
          .frame(width: 36, height: 36).foregroundStyle(chatRaised).background(
            chatInk, in: Circle())
        }.buttonStyle(.plain).accessibilityLabel(session.running ? "응답 중지" : "보내기")
          .disabled(
            !session.running
              && (session.loading || session.sending
                || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          )
          .accessibilityIdentifier("native-chat-send")
      }.padding(.horizontal, 12).padding(.vertical, 9).background(
        chatRaised, in: RoundedRectangle(cornerRadius: 24)
      )
      .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(chatLine))
      HStack(spacing: 8) {
        Text(store.courses.first(where: { $0.id == effectiveCourseID })?.name ?? "")
          .font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
        Spacer(minLength: 8)
        Button {
          provider = session.provider
          model = session.model
          showingConfiguration = true
        } label: {
          HStack(spacing: 5) {
            Text(
              session.model.isEmpty
                ? NativeAIProvider(rawValue: session.provider)?.title ?? "AI" : session.model
            ).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9))
          }
          .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).frame(maxWidth: 210)
          .frame(height: 32)
        }.buttonStyle(.plain).disabled(session.running || session.loading).accessibilityLabel(
          "모델 설정")
      }.padding(.horizontal, 2)
    }
  }
  private var configurationSheet: some View {
    NavigationStack {
      Form {
        Picker("제공자", selection: $provider) {
          ForEach(NativeAIProvider.allCases) { Text($0.title).tag($0.rawValue) }
        }
        TextField("모델 ID (비우면 기본 모델)", text: $model).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Text("설정에서 각 제공자의 API 키를 등록할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
        if let error = session.error { NativeToolError(message: error) }
      }.disabled(configuring)
        .navigationTitle("AI 선택")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("취소") { showingConfiguration = false }.disabled(configuring)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("적용") {
              configuring = true
              Task {
                defer { configuring = false }
                do {
                  try await session.configure(provider: provider, model: model)
                  showingConfiguration = false
                } catch { session.error = error.localizedDescription }
              }
            }.disabled(configuring)
          }
        }
    }.interactiveDismissDisabled(configuring)
  }
  private func send() {
    let text = draft
    Task {
      do {
        try await session.send(text)
        if draft == text { draft = "" }
      } catch { session.error = error.localizedDescription }
    }
  }
  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    Task { do { try await action() } catch { session.error = error.localizedDescription } }
  }
}

/// The stored desktop provider IDs are also the native cloud service IDs.
/// This preference only chooses a new conversation; saved conversations retain theirs.
enum NativeAssistantPreferences {
  static func defaultProvider(_ settings: [String: Any]) -> String {
    NativeAIProvider(rawValue: settings["agentProvider"] as? String ?? "")?.rawValue
      ?? NativeAIProvider.anthropic.rawValue
  }
}
