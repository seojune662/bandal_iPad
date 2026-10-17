import AVFoundation
import Combine
import SwiftUI

struct NativeRecordingSession: Decodable, Identifiable {
  let id: String
  let courseId: String
  let title: String
  let modelId: String
  let status: String
  let samples: Int
  let audioRelPath: String
  let error: String?
  var duration: String { Self.time(Double(samples) / 16_000) }
  var statusTitle: String {
    switch status {
    case "ready": "준비됨"
    case "recording": "녹음 중"
    case "paused": "일시 정지"
    case "processing": "전사 중"
    case "complete": "완료"
    case "interrupted": "중단됨"
    default: status
    }
  }
  static func time(_ seconds: Double) -> String {
    let seconds = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
}

private struct NativeTranscriptSegment: Decodable, Identifiable {
  let id: Int
  let startSample: Int
  let endSample: Int
  let text: String
}
struct NativeRecordingAnchor: Decodable, Identifiable {
  let id: String
  let sample: Int
  let label: String
  let relPath: String?
  let page: Int?
  let removedPage: Int?
  let originalRevision: String?

  var canOpenDocument: Bool { relPath?.isEmpty == false && removedPage == nil }
  var locationTitle: String {
    if removedPage != nil { return "삭제된 PDF 페이지" }
    guard let relPath else { return "중요한 순간" }
    let name = (relPath as NSString).lastPathComponent
    return page.map { name + " · \($0)쪽" } ?? name
  }
}
private struct NativeRecordingDetail: Decodable {
  let session: NativeRecordingSession
  let segments: [NativeTranscriptSegment]
  let anchors: [NativeRecordingAnchor]?
}
private struct NativeSpeechModel: Decodable, Identifiable {
  let id: String
  let name: String
  let description: String
  let bytes: Int64
  let downloadedBytes: Int64
  let status: String
  let error: String?
  let unavailableReason: String?
}

@MainActor
final class NativeRecordingPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published var playing = false
  @Published var position = 0.0
  @Published var duration = 0.0
  private var player: AVAudioPlayer?
  private var timer: Timer?
  private var currentID: String?
  private var generation = 0
  private var visible = false
  private(set) var playbackRate = 1.0
  func setRate(_ value: Double) {
    playbackRate = [0.75, 1, 1.25, 1.5, 1.75, 2].contains(value) ? value : 1
    player?.enableRate = true; player?.rate = Float(playbackRate)
  }
  func activate() { visible = true }
  func deactivate() {
    visible = false
    stop()
  }
  func prepare(id: String, resolvingURL: @MainActor () async throws -> URL) async throws {
    guard visible else { throw CancellationError() }
    generation += 1
    let expectedGeneration = generation
    let url = try await resolvingURL()
    guard visible, generation == expectedGeneration, !Task.isCancelled else {
      throw CancellationError()
    }
    try open(id: id, url: url)
  }
  private func open(id: String, url: URL) throws {
    guard currentID != id else { return }
    clearPlayer()
    let player = try AVAudioPlayer(contentsOf: url)
    player.delegate = self
    player.enableRate = true; player.rate = Float(playbackRate)
    player.prepareToPlay()
    self.player = player
    currentID = id
    duration = player.duration
  }
  func toggle() throws {
    guard let player else { return }
    if player.isPlaying {
      player.pause()
      playing = false
      timer?.invalidate()
      timer = nil
    } else {
      guard player.play() else { throw DesktopRuntimeError("녹음 파일을 재생하지 못했습니다.") }
      playing = true
      timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
      }
    }
  }
  func seek(_ value: Double) {
    player?.currentTime = min(duration, max(0, value))
    position = player?.currentTime ?? 0
  }
  func stop() {
    generation += 1
    clearPlayer()
  }
  private func clearPlayer() {
    timer?.invalidate()
    timer = nil
    player?.stop()
    player = nil
    playing = false
    currentID = nil
    position = 0
    duration = 0
  }
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor [weak self] in
      self?.playing = false
      self?.timer?.invalidate()
      self?.timer = nil
      self?.position = self?.duration ?? 0
    }
  }
}

struct NativeRecordingWorkspace: View {
  @ObservedObject var store: NativeWorkspaceStore
  let workspaceID: String?
  let courseID: String?
  private var effectiveCourseID: String? { courseID ?? store.selectedCourseID }
  init(store: NativeWorkspaceStore, workspaceID: String? = nil, courseID: String? = nil) { self.store = store; self.workspaceID = workspaceID; self.courseID = courseID }
  private var selectionKey: String { NativeToolSelection.recordingKey(workspaceID: workspaceID, courseID: effectiveCourseID) }
  @StateObject private var playback = NativeRecordingPlayback()
  @State private var sessions: [NativeRecordingSession] = []
  @State private var models: [NativeSpeechModel] = []
  @State private var selectedID: String?
  @State private var detail: NativeRecordingDetail?
  @State private var loading = false
  @State private var busy = false
  @State private var error: String?
  @State private var title = ""
  @State private var modelID = "zipformer-ko"
  @State private var deviceID = "default"
  @State private var followTranscript = true
  @State private var defaultSidebarOpen = true
  @State private var preferencesLoaded = false
  @State private var requestID = UUID()
  @State private var level = 0.0
  @State private var exportNotice: String?
  @State private var anchorPath = ""
  @State private var anchorPage = ""
  @State private var anchorLabel = ""
  private var active: NativeRecordingSession? {
    sessions.first { $0.status == "recording" || $0.status == "paused" }
  }
  private var selected: NativeRecordingSession? { sessions.first { $0.id == selectedID } }
  @State private var sidebarVisible = true
  private var displayed: NativeRecordingSession? { selected ?? active }
  var body: some View {
    GeometryReader { workspaceSize in
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Label("녹음", systemImage: "waveform").font(.system(size: 13, weight: .medium))
          if workspaceSize.size.width >= 470 {
            Text("기기에서 처리").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
              .padding(.horizontal, 8).padding(.vertical, 3).overlay(
                Capsule().strokeBorder(NativeDesktopTheme.border))
          }
          Spacer()
          Button(sidebarVisible ? "설정·자료 접기" : "설정·자료 펼치기") {
            sidebarVisible.toggle()
          }.buttonStyle(
            NativeToolButtonStyle(compact: true)
          ).accessibilityIdentifier("native-recording-sidebar")
          Button("새 녹음", systemImage: "plus") {
            selectedID = nil
            detail = nil
            title = ""
            playback.stop()
          }
          .buttonStyle(NativeToolButtonStyle(compact: true)).disabled(
            effectiveCourseID == nil || active != nil
          )
          .accessibilityIdentifier("native-recording-add")
        }.padding(.horizontal, workspaceSize.size.width < 470 ? 16 : 24).padding(.vertical, 12)
          .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
        if let error { NativeToolError(message: error) }
        if effectiveCourseID == nil {
          NativeToolEmptyState(
            title: "과목을 선택하세요", message: "녹음과 전사를 과목별로 보관합니다.", symbol: "waveform")
        } else {
          GeometryReader { geometry in
            HStack(spacing: 0) {
              ScrollViewReader { scroll in
              ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                  recordingIntro
                  recordingConsole
                  if let displayed { transcript(displayed) }
                  Color.clear.frame(height: 1).id("transcript-end")
                }.padding(.vertical, 24).padding(
                  .horizontal, max(20, min(56, geometry.size.width * 0.04)))
              }.refreshable { await load() }.frame(maxWidth: .infinity)
                .onChange(of: detail?.segments.last?.id) { _, _ in if followTranscript, displayed?.status == "recording" { withAnimation { scroll.scrollTo("transcript-end", anchor: .bottom) } } }
              }
              if sidebarVisible && geometry.size.width >= 660 {
                NativeDesktopTheme.border.frame(width: 1)
                ScrollView { recordingSidebar.padding(16) }.frame(width: 284).background(
                  NativeDesktopTheme.surface)
              }
            }.overlay(alignment: .trailing) {
              if sidebarVisible && geometry.size.width < 660 {
                HStack(spacing: 0) {
                  Color.black.opacity(0.08).onTapGesture { sidebarVisible = false }
                  ScrollView { recordingSidebar.padding(16) }
                    .frame(width: min(300, geometry.size.width)).frame(maxHeight: .infinity)
                    .background(NativeDesktopTheme.surface).shadow(
                      color: .black.opacity(0.12), radius: 8, x: -3)
                }
              }
            }
          }
        }
      }.font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.text).background(
        NativeDesktopTheme.bgApp
      )
      .overlay { if loading && sessions.isEmpty { ProgressView() } }
      .task(id: effectiveCourseID) {
        selectedID = UserDefaults.standard.string(forKey: selectionKey)
        detail = nil
        anchorPath = ""
        anchorPage = ""
        anchorLabel = ""
        playback.stop()
        if !preferencesLoaded {
          do {
            let settings = try await store.invoke("settings:get") as? [String: Any] ?? [:]
            let tabs = settings["tabs"] as? [String: Any] ?? [:]
            modelID = tabs["recordingModel"] as? String ?? "zipformer-ko"
            deviceID = tabs["recordingDeviceId"] as? String ?? "default"
            followTranscript = tabs["recordingFollowTranscript"] as? Bool ?? true
            defaultSidebarOpen = tabs["recordingSidebarOpen"] as? Bool ?? true
            sidebarVisible = workspaceSize.size.width >= 660 && defaultSidebarOpen
            playback.setRate((tabs["recordingPlaybackRate"] as? NSNumber)?.doubleValue ?? 1)
            preferencesLoaded = true
          } catch { self.error = error.localizedDescription }
        }
        await load()
      }
      .onChange(of: selectedID) { _, value in UserDefaults.standard.set(value, forKey: selectionKey) }
      .onAppear { playback.activate() }
      .onDisappear { playback.deactivate() }
      .onReceive(store.events) { event in receive(event) }
      .onChange(of: workspaceSize.size.width < 660, initial: true) { _, narrow in
        sidebarVisible = narrow ? false : defaultSidebarOpen
      }
    }
  }
  private var recordingIntro: some View {
    VStack(alignment: .leading, spacing: 12) {
      if displayed == nil {
        Text("LECTURE NOTES").font(.system(size: 12)).tracking(0.18).foregroundStyle(
          NativeDesktopTheme.muted)
      }
      Text(displayed?.title ?? "듣는 순간, 기록이 됩니다.").font(.system(size: 24, weight: .semibold))
        .tracking(-0.36)
      if displayed == nil {
        Text("강의는 자막으로 남기고, 중요한 순간은 자료에 연결하세요.").font(.system(size: 13)).foregroundStyle(
          NativeDesktopTheme.secondary)
      }
    }.padding(.top, 12)
  }
  private var recordingConsole: some View {
    NativeToolCard(padding: 24) {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          HStack(spacing: 8) {
            Circle().fill(active?.status == "recording" ? Color.red : NativeDesktopTheme.muted)
              .frame(width: 7, height: 7)
            Text(displayed?.statusTitle ?? "시작할 준비가 되셨나요?").foregroundStyle(
              NativeDesktopTheme.secondary)
          }
          Spacer()
          Text(displayed?.duration ?? "00:00:00").font(.system(size: 24, design: .monospaced))
            .monospacedDigit()
        }
        if displayed == nil || active != nil {
          HStack(spacing: 4) {
            ForEach(0..<48) { index in
              RoundedRectangle(cornerRadius: 2).fill(NativeDesktopTheme.accent.opacity(0.65))
                .frame(maxWidth: 4).frame(
                  height: active?.status == "recording"
                    ? max(3, min(1, level) * 70 * (0.4 + 0.6 * abs(sin(Double(index) * 0.72)))) : 3)
            }
          }.frame(maxWidth: .infinity).frame(height: 74).accessibilityElement(children: .ignore)
            .accessibilityLabel("마이크 입력")
        }
        if displayed == nil {
          TextField("강의 제목을 입력하세요", text: $title).nativeToolField().accessibilityIdentifier(
            "native-recording-title")
          Button("녹음 시작", systemImage: "record.circle") { create() }
            .buttonStyle(NativeToolButtonStyle(primary: true))
            .disabled(
              busy || !models.contains(where: { $0.id == modelID && $0.status == "installed" })
            )
            .accessibilityIdentifier("native-recording-start")
          Text(
            models.contains(where: { $0.id == modelID && $0.status == "installed" })
              ? "마이크에서 강의를 듣고 자막으로 기록합니다." : "녹음 설정에서 음성 모델을 먼저 다운로드해 주세요."
          )
          .font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
        } else if let active {
          HStack(spacing: 8) {
            Button(
              active.status == "recording" ? "일시 정지" : "이어 녹음",
              systemImage: active.status == "recording" ? "pause.fill" : "play.fill"
            ) { control(active, action: active.status == "recording" ? "pause" : "start") }
            .buttonStyle(NativeToolButtonStyle())
            Button("녹음 종료", systemImage: "stop.fill") { control(active, action: "stop") }
              .buttonStyle(NativeToolButtonStyle(primary: true)).accessibilityIdentifier(
                "native-recording-stop")
          }.disabled(busy)
          Text("원음 자동 저장 중 · 다른 탭에서도 녹음이 계속됩니다.").font(.system(size: 12)).foregroundStyle(
            NativeDesktopTheme.muted)
        } else if let displayed {
          HStack(spacing: 12) {
            Button(
              playback.playing ? "일시 정지" : "재생",
              systemImage: playback.playing ? "pause.fill" : "play.fill"
            ) { play(displayed) }.buttonStyle(NativeToolIconStyle()).disabled(
              displayed.samples == 0)
            Slider(
              value: Binding(get: { playback.position }, set: { playback.seek($0) }),
              in: 0...max(1, playback.duration)
            ).tint(NativeDesktopTheme.accent)
              .disabled(playback.duration == 0).accessibilityLabel("재생 위치")
            Text(NativeRecordingSession.time(playback.position)).font(
              .system(size: 12, design: .monospaced))
          }
          HStack(spacing: 8) {
            if ["ready", "interrupted"].contains(displayed.status) {
              Button("녹음 계속") { control(displayed, action: "start") }.buttonStyle(
                NativeToolButtonStyle(primary: true))
            }
            if displayed.samples > 0 && displayed.status != "processing" {
              Button("자막 다시 생성") { control(displayed, action: "retry") }.buttonStyle(
                NativeToolButtonStyle())
            }
            Spacer(minLength: 0)
            Button("원음 공유", systemImage: "square.and.arrow.up") { share(displayed) }.buttonStyle(
              NativeToolIconStyle()
            ).disabled(displayed.samples == 0)
          }.disabled(busy)
        }
      }
    }
  }
  private func transcript(_ session: NativeRecordingSession) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("실시간 자막").font(.system(size: 14, weight: .medium))
        Spacer()
        Button("전사 노트 만들기", systemImage: "doc.badge.plus") { exportTranscript(session) }
          .buttonStyle(NativeToolButtonStyle(compact: true)).disabled(
            detail?.session.id != session.id || detail?.segments.isEmpty != false || busy)
      }
      if let message = session.error { NativeToolError(message: message) }
      if let exportNotice {
        Text(exportNotice).font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted)
      }
      if let detail, detail.session.id == session.id, !detail.segments.isEmpty {
        ForEach(detail.segments) { segment in
          HStack(alignment: .top, spacing: 16) {
            Button(NativeRecordingSession.time(Double(segment.startSample) / 16_000)) {
              seek(session, sample: segment.startSample)
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(NativeDesktopTheme.muted)
            .buttonStyle(.plain).disabled(session.status == "recording")
            Text(segment.text).textSelection(.enabled).font(.system(size: 14)).lineSpacing(7).frame(
              maxWidth: .infinity, alignment: .leading)
          }.padding(.vertical, 8)
        }
      } else {
        Text("녹음을 시작하면 여기에 자막이 나타납니다.\n말소리가 있는 구간을 인식해 차곡차곡 저장해요.")
          .font(.system(size: 13)).lineSpacing(8).foregroundStyle(NativeDesktopTheme.muted).frame(
            maxWidth: .infinity, alignment: .center
          ).padding(.vertical, 48)
      }
    }
  }
  private var recordingSidebar: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("녹음 설정").fontWeight(.medium)
        Spacer()
        Text("음성 모델").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
      }
      Picker("음성 모델", selection: $modelID) {
        ForEach(models.filter { $0.status == "installed" }) { Text($0.name).tag($0.id) }
      }.pickerStyle(.menu).disabled(active != nil)
      modelRows
      NativeDesktopTheme.border.frame(height: 1)
      materialLinks
      NativeDesktopTheme.border.frame(height: 1)
      HStack {
        Text("지난 녹음").fontWeight(.medium)
        Spacer()
        Text(String(sessions.count)).foregroundStyle(NativeDesktopTheme.muted)
      }
      if sessions.isEmpty {
        Text("이 과목의 첫 강의를 남겨 보세요.").font(.system(size: 12)).foregroundStyle(
          NativeDesktopTheme.muted)
      }
      ForEach(sessions) { session in
        Button {
          playback.stop()
          selectedID = session.id
          Task { await loadDetail(session.id) }
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(session.title).font(.system(size: 13)).lineLimit(2)
            Text(session.duration + " · " + session.statusTitle).font(.system(size: 11))
              .foregroundStyle(NativeDesktopTheme.muted)
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(
              selectedID == session.id ? NativeDesktopTheme.accentMuted : .clear,
              in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityIdentifier("native-recording-\(session.id)")
      }
    }
  }
  private var linkableMaterials: [NativeMaterial] {
    func flatten(_ items: [NativeMaterial]) -> [NativeMaterial] {
      items.flatMap { item in item.isDirectory ? flatten(item.children ?? []) : [item] }
    }
    return flatten(store.materials).filter { $0.kind == "pdf" || $0.kind == "note" }
  }
  private var materialLinks: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("자료 연결").fontWeight(.medium)
        Spacer()
        Image(systemName: "link").foregroundStyle(NativeDesktopTheme.muted)
      }
      Text("중요한 순간을 자료와 함께 남겨 보세요.").font(.system(size: 12)).foregroundStyle(
        NativeDesktopTheme.muted)
      Picker("연결할 자료", selection: $anchorPath) {
        Text("시간만 기록").tag("")
        ForEach(linkableMaterials) { item in Text(item.name).tag(item.relPath) }
      }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier(
        "native-recording-anchor-material")
      if (anchorPath as NSString).pathExtension.lowercased() == "pdf" {
        TextField("페이지 (선택)", text: $anchorPage).keyboardType(.numberPad).nativeToolField()
          .accessibilityIdentifier("native-recording-anchor-page")
      }
      TextField("기록할 내용 (선택)", text: $anchorLabel).nativeToolField().accessibilityIdentifier(
        "native-recording-anchor-label")
      Button("이 순간 기록", systemImage: "bookmark") { if let displayed { addAnchor(displayed) } }
        .buttonStyle(NativeToolButtonStyle()).disabled(displayed == nil || busy)
        .accessibilityIdentifier("native-recording-anchor-add")
      if let session = displayed, let detail, detail.session.id == session.id {
        ForEach(detail.anchors ?? []) { anchor in
          VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
              Button(NativeRecordingSession.time(Double(anchor.sample) / 16_000)) {
                seek(session, sample: anchor.sample)
              }
              .font(.system(size: 11, design: .monospaced)).buttonStyle(.plain).foregroundStyle(
                NativeDesktopTheme.muted
              ).disabled(active != nil)
              Text(anchor.label).font(.system(size: 12)).frame(
                maxWidth: .infinity, alignment: .leading)
            }
            if anchor.relPath != nil || anchor.removedPage != nil {
              Button {
                openAnchor(anchor, session: session)
              } label: {
                Label(
                  anchor.locationTitle,
                  systemImage: anchor.canOpenDocument ? "doc" : "exclamationmark.circle"
                ).font(.system(size: 11)).lineLimit(2)
              }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary).disabled(
                !anchor.canOpenDocument)
            }
          }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(
            NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 6))
        }
      }
    }.onChange(of: anchorPath) { _, _ in anchorPage = "" }
  }
  private var modelRows: some View {
    ForEach(models) { model in
      VStack(alignment: .leading, spacing: 7) {
        HStack {
          VStack(alignment: .leading) {
            Text(model.name).font(.system(size: 13, weight: .medium))
            Text(model.description).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if model.status == "installed" {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(
              "설치됨")
          } else if model.status == "downloading" || model.status == "verifying" {
            Button("취소") { modelAction(model.id, channel: "recordings:cancelDownload") }
          } else {
            Button("다운로드") { modelAction(model.id, channel: "recordings:downloadModel") }.disabled(
              model.unavailableReason != nil)
          }
        }
        if model.status == "downloading" || model.status == "verifying" {
          ProgressView(value: Double(model.downloadedBytes), total: Double(max(1, model.bytes)))
        }
        if let message = model.error ?? model.unavailableReason {
          Text(message).font(.caption).foregroundStyle(.red)
        }
      }.font(.system(size: 12)).buttonStyle(NativeToolButtonStyle(compact: true)).padding(
        .vertical, 4)
    }
  }
  private func load() async {
    let request = UUID()
    requestID = request
    loading = true
    defer { if request == requestID { loading = false } }
    do {
      let models: [NativeSpeechModel] = try NativeToolJSON.decode(
        try await store.invoke("recordings:models"))
      let course = effectiveCourseID
      let sessions: [NativeRecordingSession] =
        course == nil
        ? []
        : try NativeToolJSON.decode(
          try await store.invoke("recordings:list", ["courseId": course!]))
      guard request == requestID else { return }
      self.models = models
      self.sessions = sessions
      error = nil
      if !models.contains(where: { $0.id == modelID && $0.status == "installed" }),
        let installed = models.first(where: { $0.status == "installed" })
      {
        modelID = installed.id
      }
      if selectedID == nil, let active { selectedID = active.id }
      if let id = displayed?.id { await loadDetail(id) }
    } catch { if request == requestID { self.error = error.localizedDescription } }
  }
  private func loadDetail(_ id: String) async {
    do {
      let value: NativeRecordingDetail = try NativeToolJSON.decode(
        try await store.invoke("recordings:read", ["id": id]))
      if displayed?.id == id { detail = value }
    } catch { self.error = error.localizedDescription }
  }
  private func create() {
    guard !busy, let course = effectiveCourseID else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let created: NativeRecordingSession = try NativeToolJSON.decode(
          try await store.invoke(
            "recordings:create",
            ["courseId": course, "title": name.isEmpty ? "새 녹음" : name, "modelId": modelID]))
        if effectiveCourseID == course { selectedID = created.id }
        _ = try await store.invoke("recordings:control", ["id": created.id, "action": "start"])
        await load()
      } catch {
        let message = error.localizedDescription
        await load()
        self.error = message
      }
    }
  }
  private func control(_ session: NativeRecordingSession, action: String) {
    guard !busy else { return }
    busy = true
    playback.stop()
    Task {
      defer { busy = false }
      do {
        _ = try await store.invoke(
          "recordings:control", ["id": session.id, "action": action, "modelId": modelID, "deviceId": deviceID])
        error = nil
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }
  private func modelAction(_ id: String, channel: String) {
    Task {
      do {
        _ = try await store.invoke(channel, ["modelId": id])
        await load()
      } catch { self.error = error.localizedDescription }
    }
  }
  private func preparePlayback(_ session: NativeRecordingSession) async throws {
    try await playback.prepare(id: session.id) {
      guard
        let path = try await store.invokePrivate("nativeRecording:audioPath", ["id": session.id])
          as? String
      else { throw RecordingError.invalidAudio }
      return URL(fileURLWithPath: path)
    }
  }
  private func play(_ session: NativeRecordingSession) {
    Task {
      do {
        try await preparePlayback(session)
        try playback.toggle()
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  private func seek(_ session: NativeRecordingSession, sample: Int) {
    Task {
      do {
        try await preparePlayback(session)
        playback.seek(Double(sample) / 16_000)
        if !playback.playing { try playback.toggle() }
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  private func share(_ session: NativeRecordingSession) {
    Task {
      do {
        _ = try await store.invoke(
          "materials:share", ["courseId": session.courseId, "relPath": session.audioRelPath])
      } catch { self.error = error.localizedDescription }
    }
  }
  private func exportTranscript(_ session: NativeRecordingSession) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        guard
          let result = try await store.invoke("recordings:export", ["id": session.id])
            as? [String: Any], let path = result["relPath"] as? String
        else { throw DesktopRuntimeError("전사 노트의 저장 결과를 확인하지 못했습니다.") }
        exportNotice = "자료실에 \((path as NSString).lastPathComponent)을 저장했어요."
        await store.refreshMaterials()
      } catch { self.error = error.localizedDescription }
    }
  }
  private func addAnchor(_ session: NativeRecordingSession) {
    guard !busy else { return }
    var request: [String: Any] = [
      "id": session.id,
      "label": anchorLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "중요한 순간" : anchorLabel,
    ]
    if active?.id != session.id {
      request["sample"] = min(session.samples, max(0, Int(playback.position * 16_000)))
    }
    if !anchorPath.isEmpty { request["relPath"] = anchorPath }
    if (anchorPath as NSString).pathExtension.lowercased() == "pdf",
      !anchorPage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      guard let page = Int(anchorPage), page > 0 else {
        error = "페이지는 1 이상의 숫자로 입력해 주세요."
        return
      }
      request["page"] = page
    }
    busy = true
    Task {
      defer { busy = false }
      do {
        _ = try await store.invoke("recordings:anchor", request)
        anchorLabel = ""
        error = nil
        await loadDetail(session.id)
      } catch { self.error = error.localizedDescription }
    }
  }
  private func openAnchor(_ anchor: NativeRecordingAnchor, session: NativeRecordingSession) {
    guard anchor.canOpenDocument, let path = anchor.relPath else { return }
    var request: [String: Any] = [
      "courseId": session.courseId, "relPath": path,
      "title": (path as NSString).lastPathComponent,
      "kind": (path as NSString).pathExtension.lowercased() == "pdf" ? "pdf" : "note",
    ]
    if let page = anchor.page, page > 0 { request["page"] = page }
    store.events.send(
      NativeWorkspaceEvent(channel: "nativeWorkspace:openDocument", payload: request))
  }
  private func receive(_ event: NativeWorkspaceEvent) {
    if event.channel == "recordings:modelsChanged",
      let result = try? NativeToolJSON.decode(event.payload, as: [NativeSpeechModel].self)
    {
      models = result
    }
    if event.channel == "runtime:recordingLevel", let value = event.payload as? [String: Any],
      value["id"] as? String == active?.id
    {
      level = (value["level"] as? NSNumber)?.doubleValue ?? 0
    }
    guard event.channel == "recordings:event", let value = event.payload as? [String: Any],
      let raw = value["session"],
      let session = try? NativeToolJSON.decode(raw, as: NativeRecordingSession.self),
      session.courseId == effectiveCourseID
    else { return }
    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
      sessions[index] = session
    } else {
      sessions.insert(session, at: 0)
    }
    if displayed?.id == session.id, value["segment"] is [String: Any] {
      Task { await loadDetail(session.id) }
    }
  }
}
