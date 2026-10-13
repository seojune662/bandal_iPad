import SwiftUI

struct RecordingWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: RecordingController
    @State private var title = ""
    @State private var selectedID: String?
    @State private var query = ""
    @State private var anchorMaterialID = ""
    @State private var anchorPage = ""
    @State private var showsAnchor = false
    @State private var showsModels = false

    private var recordings: [RecordingMetadata] { model.recordings.filter { $0.courseID == model.courseID } }
    private var selected: RecordingMetadata? {
        recordings.first { $0.id == selectedID } ?? recordings.first { $0.id == controller.current?.id } ?? recordings.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("강의 녹음", systemImage: "waveform").font(.title2.bold())
                    Spacer()
                    Button { showsModels = true } label: { Image(systemName: "waveform.badge.magnifyingglass").frame(width: 44, height: 44) }
                        .accessibilityLabel("기기 내 음성 모델 관리")
                }
                VStack(spacing: 16) {
                    if controller.isRecording || controller.isPaused {
                        Text(controller.current?.title ?? "강의 녹음").font(.headline)
                        HStack(spacing: 12) {
                            Circle().fill(controller.isRecording ? .red : .orange).frame(width: 10, height: 10)
                            Text(RecordingController.timestamp(controller.elapsed)).font(.system(size: 40, weight: .light, design: .monospaced))
                        }
                        Text(controller.isRecording ? "원음을 기기에 저장하고 있습니다" : "녹음 일시정지됨").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button { controller.isPaused ? controller.resume() : controller.pause() } label: {
                                Label(controller.isPaused ? "다시 시작" : "일시정지", systemImage: controller.isPaused ? "record.circle" : "pause.fill")
                                    .frame(minHeight: 44)
                            }.buttonStyle(.bordered)
                            Button { controller.stop() } label: { Label("녹음 완료", systemImage: "stop.fill").frame(minHeight: 44) }
                                .buttonStyle(.borderedProminent)
                            Button { showsAnchor = true } label: { Image(systemName: "bookmark").frame(width: 44, height: 44) }
                                .accessibilityLabel("이 시간에 자료 연결")
                        }
                    } else {
                        Image(systemName: "mic.circle.fill").font(.system(size: 52)).foregroundStyle(.tint)
                        TextField("강의 이름", text: $title).textFieldStyle(.roundedBorder)
                        Button {
                            Task { await controller.start(courseID: model.courseID, title: title); selectedID = controller.current?.id }
                        } label: { Label("녹음 시작", systemImage: "record.circle").frame(maxWidth: .infinity, minHeight: 44) }
                            .buttonStyle(.borderedProminent)
                    }
                }.padding(20).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
                if let error = controller.error { Text(error).font(.callout).foregroundStyle(.red) }
                Text(controller.speechStatus).font(.caption).foregroundStyle(.secondary)
                if !recordings.isEmpty {
                    Picker("녹음 선택", selection: Binding(get: { selected?.id ?? "" }, set: { selectedID = $0 })) {
                        ForEach(recordings) { item in Text(item.title).tag(item.id) }
                    }.pickerStyle(.menu)
                }
                if let selected {
                    recordingDetail(selected)
                } else {
                    ContentUnavailableView("아직 녹음이 없어요", systemImage: "waveform",
                                           description: Text("강의를 녹음하고 PDF나 노트의 위치를 시간과 함께 남겨 보세요."))
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemBackground))
        .task { controller.recover() }
        .sheet(isPresented: $showsModels) { SpeechModelsView(store: controller.models, selection: $controller.selectedModel) }
        .sheet(isPresented: $showsAnchor) {
            NavigationStack {
                Form {
                    Picker("연결할 자료", selection: $anchorMaterialID) {
                        Text("자료를 선택하세요").tag("")
                        ForEach(model.courseMaterials) { item in Text(item.title).tag(item.id) }
                    }
                    if model.material(anchorMaterialID)?.kind == .pdf {
                        TextField("페이지 번호 (선택)", text: $anchorPage).keyboardType(.numberPad)
                    }
                    Text("현재 녹음 시간에 이 자료를 연결합니다.").font(.caption)
                }.navigationTitle("녹음과 자료 연결")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("취소") { showsAnchor = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("연결") {
                                let page = Int(anchorPage).flatMap { $0 > 0 ? $0 : nil }
                                controller.addAnchor(materialID: anchorMaterialID, page: page); showsAnchor = false
                            }.disabled(anchorMaterialID.isEmpty)
                        }
                    }
            }.presentationDetents([.medium])
        }
    }

    @ViewBuilder private func recordingDetail(_ item: RecordingMetadata) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.title).font(.headline)
                    Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(RecordingController.timestamp(item.duration))")
                        .font(.caption).foregroundStyle(.secondary)
                    if item.state == "recovered" { Text("중단된 녹음의 원음을 복구했습니다").font(.caption).foregroundStyle(.orange) }
                }
                Spacer()
                if let url = try? controller.audioURL(item) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                        .accessibilityLabel("녹음 원음 공유")
                }
            }
            HStack {
                Button {
                    if controller.playingID == item.id && controller.isPlaying { controller.pausePlayback() }
                    else { controller.play(item, at: controller.playingID == item.id ? controller.playbackTime : 0) }
                } label: {
                    Image(systemName: controller.playingID == item.id && controller.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("녹음 재생 또는 일시정지")
                Slider(value: Binding(get: { controller.playingID == item.id ? controller.playbackTime : 0 },
                                      set: { controller.play(item, at: $0) }), in: 0...max(1, item.duration))
                    .accessibilityLabel("재생 위치")
                Text(RecordingController.timestamp(controller.playingID == item.id ? controller.playbackTime : 0)).font(.caption.monospacedDigit())
            }
            if !item.anchors.isEmpty {
                Text("자료 연결").font(.subheadline.weight(.semibold))
                ForEach(item.anchors) { anchor in
                    HStack {
                        Button(RecordingController.timestamp(anchor.time)) { controller.play(item, at: anchor.time) }
                            .font(.caption.monospacedDigit()).frame(minWidth: 50, minHeight: 44)
                        Button {
                            if let material = model.material(anchor.materialID) {
                                if let page = anchor.page { PendingPDFNavigation.request(materialID: material.id, page: page) }
                                model.openMaterial(material, beside: true)
                            }
                        } label: {
                            Label((model.material(anchor.materialID)?.title ?? "자료를 찾을 수 없음") + (anchor.page.map { " · \($0)쪽" } ?? ""), systemImage: "doc.text")
                                .font(.callout)
                        }.disabled(model.material(anchor.materialID) == nil)
                    }
                }
            }
            Divider()
            HStack {
                Text("전사").font(.headline)
                Spacer()
                if controller.transcribingID == item.id {
                    ProgressView()
                    Button("전사 취소") { controller.cancelTranscription() }.frame(minHeight: 44)
                } else {
                    Button(item.segments.isEmpty ? "기기에서 전사" : "재전사") { controller.retranscribe(item) }
                        .frame(minHeight: 44).disabled(controller.isRecording || controller.isPaused)
                }
            }
            TextField("자막에서 검색", text: $query).textFieldStyle(.roundedBorder)
            if item.segments.isEmpty {
                Text("아직 전사한 내용이 없습니다. 음성 모델을 설치한 뒤 전사할 수 있습니다.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(item.segments.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }) { segment in
                HStack(alignment: .top, spacing: 12) {
                    Button(RecordingController.timestamp(segment.time)) { controller.play(item, at: segment.time) }
                        .font(.caption.monospacedDigit()).frame(minWidth: 50, minHeight: 44)
                    Text(segment.text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                }
            }
        }
    }
}

private struct SpeechModelsView: View {
    @ObservedObject var store: SpeechModelStore
    @Binding var selection: LocalSpeechModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("기기 내 음성 인식") {
                    Text("모델을 한 번 내려받으면 인터넷 없이 전사할 수 있습니다. 녹음 파일을 음성 인식 서버로 보내지 않습니다.")
                        .font(.callout)
                    if !LocalSpeechEngine.available { Text(RecordingError.runtimeUnavailable.localizedDescription).foregroundStyle(.orange) }
                    ForEach(LocalSpeechModel.allCases) { model in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) { Text(model.title); Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if store.installed.contains(model) {
                                    Button(selection == model ? "사용 중" : "선택") { selection = model }
                                        .disabled(selection == model)
                                } else if store.downloading == model { ProgressView() }
                                else { Button("다운로드") { store.install(model) }.disabled(store.downloading != nil) }
                            }
                            if model == .senseVoice { Text("한국어·영어·일본어·중국어·광둥어 자동 감지").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                    }
                    if !store.status.isEmpty { Text(store.status).font(.caption) }
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if store.downloading != nil { Button("다운로드 취소", role: .cancel) { store.cancel() } }
                }
            }.navigationTitle("음성 모델")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}
