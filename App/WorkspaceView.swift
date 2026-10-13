import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import PDFKit

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @State private var sidebar = true
    @State private var importing = false
    @State private var settings = false
    @State private var newCourse = false
    @State private var courseName = ""
    @State private var search = ""
    @State private var rename: Material?
    @State private var renamedTitle = ""
    @State private var shareURL: URL?
    @State private var selectedFolderID: String?
    @State private var newFolder = false
    @State private var folderName = ""

    var body: some View {
        GeometryReader { geometry in
            let regularSidebar = geometry.size.width >= 1120
            HStack(spacing: 0) {
                if sidebar && regularSidebar { sidebarView.frame(width: 248); Divider() }
                VStack(spacing: 0) {
                    topBar
                    tabStrip
                    if model.loading { ProgressView("학습 공간을 여는 중…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else { panes }
                    statusBar
                }
            }
            .background(BandalTheme.background)
            .overlay(alignment: .leading) {
                if sidebar && !regularSidebar {
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.2).ignoresSafeArea().onTapGesture { sidebar = false }
                        sidebarView.frame(width: min(300, geometry.size.width * 0.8)).background(BandalTheme.panel).shadow(radius: 24)
                    }
                }
            }
            .onAppear { if !regularSidebar { sidebar = false } }
        }
        .disabled(model.isImporting)
        .overlay {
            if model.isImporting {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView("자료를 안전하게 가져오는 중…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): urls.forEach(model.importURL); case .failure(let error): model.error = error.localizedDescription }
        }
        .sheet(isPresented: $settings) { SettingsView().environmentObject(model) }
        .sheet(item: Binding(get: { shareURL.map(SharedURL.init) }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        .alert("새 과목", isPresented: $newCourse) {
            TextField("과목 이름", text: $courseName)
            Button("만들기") { model.addCourse(courseName); courseName = "" }
            Button("취소", role: .cancel) {}
        }
        .alert("자료 이름", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("이름", text: $renamedTitle)
            Button("저장") { if let item = rename { model.renameMaterial(item.id, to: renamedTitle) }; rename = nil }
            Button("취소", role: .cancel) { rename = nil }
        }
        .alert("새 폴더", isPresented: $newFolder) {
            TextField("폴더 이름", text: $folderName)
            Button("만들기") { model.addFolder(folderName); folderName = "" }
            Button("취소", role: .cancel) {}
        }
        .onChange(of: model.courseID) { _, _ in selectedFolderID = nil }
        .alert("확인이 필요해요", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("확인") { model.error = nil } } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.handleMemoryWarning() }
        .onChange(of: phase) { _, phase in
            if phase == .active { Task { await model.sync.synchronize() } }
            if phase != .active { model.saveWorkspace(); Task { await model.flush() } }
        }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(10)); if phase == .active { await model.sync.synchronize() } } }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { sidebar.toggle() } } label: { Image(systemName: "sidebar.left").frame(width: 44, height: 44) }.accessibilityLabel("사이드바")
            Text(model.selectedCourse?.name ?? "반달").font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            if model.audio.isRecording {
                Button { model.open(.recording) } label: { Label("녹음 중", systemImage: "record.circle.fill").font(.caption).foregroundStyle(.red).padding(10).background(.red.opacity(0.08), in: Capsule()) }
            }
            Button { model.toggleSplit() } label: { Image(systemName: model.workspace.splitEnabled ? "rectangle.split.2x1.fill" : "rectangle.split.2x1").frame(width: 44, height: 44) }.accessibilityLabel("화면 분할")
            newTabMenu
            Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("설정")
        }
        .padding(.horizontal, 12).padding(.vertical, 3).background(BandalTheme.panel)
    }

    private var newTabMenu: some View {
        Menu {
            Button("자료 가져오기", systemImage: "square.and.arrow.down") { importing = true }
            ForEach([TabKind.note, .browser, .chat, .whiteboard, .board, .calendar, .recording, .learning], id: \.self) { kind in
                Button(kind.title, systemImage: kind.icon) { model.open(kind) }.accessibilityIdentifier("new-tab-\(kind.rawValue)")
            }
            Divider()
            Button("비공개 브라우저", systemImage: "eye.slash") { model.open(.browser, isPrivate: true) }
        } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
        .accessibilityLabel("새 탭")
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(model.courseTabs) { tab in
                    let active = tab.id == model.workspace.primaryID || (model.workspace.splitEnabled && tab.id == model.workspace.secondaryID)
                    HStack(spacing: 8) {
                        Button { model.selectTab(tab.id) } label: {
                            HStack(spacing: 8) { Image(systemName: tab.isPrivate ? "eye.slash" : tab.kind.icon); Text(tab.title).lineLimit(1) }
                                .font(.system(size: 13, weight: active ? .semibold : .regular)).frame(minWidth: 80, maxWidth: 200, minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 44, height: 44) }
                            .buttonStyle(.plain).accessibilityLabel("\(tab.title) 닫기")
                    }
                    .padding(.leading, 12)
                    .background(active ? BandalTheme.panel : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottom) { if active { Capsule().fill(BandalTheme.accent).frame(height: 2).padding(.horizontal, 10) } }
                    .contextMenu {
                        Button("옆에서 열기", systemImage: "rectangle.split.2x1") { model.selectTab(tab.id, beside: true) }
                        Button("왼쪽으로 이동", systemImage: "arrow.left") { model.moveTab(tab.id, offset: -1) }
                        Button("오른쪽으로 이동", systemImage: "arrow.right") { model.moveTab(tab.id, offset: 1) }
                        Button("닫기", systemImage: "xmark", role: .destructive) { model.closeTab(tab.id) }
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.frame(height: 58)
    }

    private var panes: some View {
        GeometryReader { geometry in
            let split = model.workspace.splitEnabled && geometry.size.width >= 732
            VStack(spacing: 0) {
                if model.workspace.splitEnabled && !split {
                    Picker("작업 영역", selection: $model.workspace.focusedPane) {
                        Text(model.tab(model.workspace.primaryID)?.title ?? "왼쪽 영역").tag(0)
                        Text(model.tab(model.workspace.secondaryID)?.title ?? "오른쪽 영역").tag(1)
                    }.pickerStyle(.segmented).padding(8)
                }
                HStack(spacing: 8) {
                    if split || model.workspace.focusedPane == 0 || !model.workspace.splitEnabled { pane(model.workspace.primaryID, index: 0) }
                    if split || (model.workspace.splitEnabled && model.workspace.focusedPane == 1) { pane(model.workspace.secondaryID, index: 1) }
                }
            }
        }.padding(.horizontal, 8).padding(.bottom, 6)
    }

    private func pane(_ id: String?, index: Int) -> some View {
        VStack(spacing: 0) {
            if let tab = model.tab(id) {
                HStack {
                    Label(tab.title, systemImage: tab.kind.icon).font(.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    if let material = model.material(tab.materialID), material.kind == .note {
                        Button { renamedTitle = material.title; rename = material } label: { Image(systemName: "pencil").frame(width: 44, height: 36) }.accessibilityLabel("노트 이름 변경")
                    }
                    if model.workspace.splitEnabled { Button { model.workspace.focusedPane = index; model.workspace.splitEnabled = false; model.workspace.primaryID = id; model.workspace.focusedPane = 0; model.saveWorkspace() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 36) }.accessibilityLabel("크게 보기") }
                }.padding(.horizontal, 14).frame(height: 36).background(BandalTheme.panel)
                Divider()
                tabContent(tab).id(tab.id)
            } else {
                ContentUnavailableView { Label("학습을 이어가세요", systemImage: "moonphase.first.quarter") } description: { Text("자료를 가져오거나 새 탭을 열어 보세요.") } actions: {
                    Button("자료 가져오기") { importing = true }.buttonStyle(.borderedProminent)
                    Button("새 노트") { model.createNote() }.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BandalTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.workspace.focusedPane == index && model.workspace.splitEnabled ? BandalTheme.accent.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1))
        .simultaneousGesture(TapGesture().onEnded { model.workspace.focusedPane = index })
    }

    @ViewBuilder private func tabContent(_ tab: WorkspaceTab) -> some View {
        switch tab.kind {
        case .pdf:
            if let item = model.material(tab.materialID), FileManager.default.fileExists(atPath: model.fileURL(item).path) {
                PDFWorkspaceView(documentURL: model.fileURL(item), materialID: item.id, revision: item.revision,
                    loadPage: { model.ink(item, page: $0) }, savePage: { model.saveInk(item, page: $0, data: $1) }, onExport: { shareURL = $0 },
                    resolveImage: { source in model.material(source.assetId).map { model.fileURL($0) } }, saveImage: { model.saveInkImage($0) }, onPageNote: { model.openPageNote(item, page: $0) }, initialPage: model.readingPage(item), onPageChange: { model.saveReadingPage(item, page: $0) })
            } else { missingFile }
        case .note:
            if let item = model.material(tab.materialID) { MarkdownWorkspaceView(materialID: item.id, markdown: model.notes[item.id] ?? "", onSave: { model.saveNote(item.id, markdown: $0) }, onOpenLink: { url in
                if url.scheme == "bandal" { model.openLink(url) } else { model.open(.browser, url: url) }
            }) }
        case .browser:
            BrowserWorkspaceView(session: model.browser(for: tab), onOpenTab: { model.open(.browser, url: $0, isPrivate: $1) }, onDownload: { model.importURL($0) }, onCreateSession: { model.attachBrowser($0) })
        case .whiteboard:
            if let item = model.material(tab.materialID) { WhiteboardWorkspaceView(materialID: item.id, revision: item.revision, load: { model.ink(item, page: 1) }, save: { model.saveInk(item, page: 1, data: $0) }) }
        case .board: BoardView()
        case .calendar: CalendarWorkspaceView()
        case .learning: LearningHubView()
        case .recording: RecordingWorkspaceView(controller: model.audio)
        case .chat: ChatWorkspaceView(tab: tab)
        case .file:
            if let item = model.material(tab.materialID) {
                if item.fileName.lowercased().hasSuffix(".ppt") { LegacyPPTView(material: item, onExport: { shareURL = $0 }) }
                else { OfficeWorkspaceView(url: model.fileURL(item), materialID: item.id, revision: item.revision, loadPage: { model.ink(item, page: $0) }, savePage: { model.saveInk(item, page: $0, data: $1) }, onExport: { shareURL = $0 }) }
            } else { missingFile }
        }
    }
    private var missingFile: some View { ContentUnavailableView("자료를 다운로드해야 해요", systemImage: "icloud.and.arrow.down", description: Text("동기화 연결을 확인하거나 원본 파일을 가져와 주세요.")) }

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) { Image(systemName: "moonphase.first.quarter").font(.title); Text("반달").font(.title2.bold()); Spacer(); Button { newCourse = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("새 과목") }
                .foregroundStyle(BandalTheme.accent).padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("나의 과목").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                    ForEach(model.courses) { course in
                        Button { model.selectCourse(course.id) } label: {
                            HStack { Image(systemName: "folder"); Text(course.name).lineLimit(1); Spacer(); if course.id == model.courseID { Image(systemName: "chevron.right").font(.caption2) } }
                                .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                                .background(course.id == model.courseID ? BandalTheme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 12)
                    HStack { Text("자료").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { importing = true } label: { Image(systemName: "square.and.arrow.down").frame(width: 44, height: 44) }.accessibilityLabel("자료 가져오기") }.padding(.horizontal, 12)
                    TextField("자료 검색", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 6)
                    HStack {
                        Button { selectedFolderID = nil } label: { Label(selectedFolderID == nil ? "모든 자료" : "자료로 돌아가기", systemImage: "folder") }.font(.caption).frame(minHeight: 44)
                        Spacer()
                        Button { newFolder = true } label: { Image(systemName: "folder.badge.plus").frame(width: 44, height: 44) }.accessibilityLabel("새 폴더")
                    }.padding(.horizontal, 12)
                    if selectedFolderID == nil && search.isEmpty {
                        ForEach(model.folders.filter { $0.courseID == model.courseID }) { folder in
                            Button { selectedFolderID = folder.id } label: { Label(folder.title, systemImage: "folder.fill").font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12) }.buttonStyle(.plain)
                        }
                    }
                    ForEach(model.courseMaterials.filter { search.isEmpty ? (selectedFolderID == nil || $0.folderID == selectedFolderID) : $0.title.localizedCaseInsensitiveContains(search) }) { item in
                        Button { model.openMaterial(item) } label: {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: item.kind == .pdf ? "doc.richtext" : item.kind == .note ? "note.text" : item.kind == .whiteboard ? "scribble.variable" : "doc").foregroundStyle(BandalTheme.accent)
                                Text(item.title).font(.subheadline).lineLimit(2); Spacer(minLength: 0)
                            }.padding(.horizontal, 12).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain).contextMenu {
                            Button("옆에서 열기", systemImage: "rectangle.split.2x1") { model.openMaterial(item, beside: true) }
                            Button("이름 변경", systemImage: "pencil") { rename = item; renamedTitle = item.title }
                            Button("공유", systemImage: "square.and.arrow.up") { shareURL = model.fileURL(item) }
                            Button("자료 링크 복사", systemImage: "link") { UIPasteboard.general.string = "bandal://material/\(item.id)"; model.notice = "자료 링크를 복사했습니다." }
                            Menu("폴더로 이동") {
                                Button("폴더에서 꺼내기") { model.moveMaterial(item.id, to: nil) }
                                ForEach(model.folders.filter { $0.courseID == item.courseID }) { folder in Button(folder.title) { model.moveMaterial(item.id, to: folder.id) } }
                            }
                        }
                    }
                    if model.courseMaterials.isEmpty { Text("아직 자료가 없어요.\nPDF나 노트를 추가해 보세요.").font(.caption).foregroundStyle(.secondary).padding(12) }
                }.padding(.horizontal, 10)
            }
            Divider()
            VStack(spacing: 2) {
                quickLink("학업 보드", icon: "checklist", kind: .board)
                quickLink("학습과 복습", icon: "rectangle.on.rectangle", kind: .learning)
                quickLink("강의 녹음", icon: "waveform", kind: .recording)
            }.padding(10)
        }.background(BandalTheme.panel)
    }
    private func quickLink(_ title: String, icon: String, kind: TabKind) -> some View {
        Button { model.open(kind) } label: { Label(title, systemImage: icon).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12) }.buttonStyle(.plain)
    }
    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle").foregroundStyle(BandalTheme.accent)
            Text(model.notice ?? model.syncStatus).lineLimit(1)
            if model.notice != nil { Button { model.notice = nil } label: { Image(systemName: "xmark").frame(minWidth: 44, minHeight: 26) }.accessibilityLabel("알림 닫기") }
            Spacer()
            Text("\(model.courseTabs.count)개 탭")
            Text("·")
            Text("반달 for iPad")
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 26)
    }
}

struct SharedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct FileWorkspaceView: View {
    let material: Material
    let url: URL
    var body: some View {
        if FileManager.default.fileExists(atPath: url.path) { DocumentPreview(url: url) }
        else { ContentUnavailableView("원본 파일이 필요해요", systemImage: "doc.badge.arrow.up", description: Text("설정에서 동기화를 연결해 자료를 내려받으세요.")) }
    }
}
struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController { let c = QLPreviewController(); c.dataSource = context.coordinator; return c }
    func updateUIViewController(_ c: QLPreviewController, context: Context) { if context.coordinator.url != url { context.coordinator.url = url; c.reloadData() } }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL; init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
