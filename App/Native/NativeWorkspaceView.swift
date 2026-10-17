import SwiftUI
import UIKit

struct NativeWorkspaceView: View {
    @StateObject private var store: NativeWorkspaceStore
    @StateObject private var navigation = NativeWorkspaceNavigation()
    @StateObject private var services: NativePlatformServices
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("native.appearance") private var appearance = "system"
    @State private var section: NativeWorkspaceSection = .library
    @AppStorage("native.desktop.courseRail") private var courseRailOpen = true
    @AppStorage("native.desktop.materialsRail") private var materialsRailOpen = true
    @AppStorage("native.desktop.courseRailWidth") private var courseRailWidth = 240.0
    @AppStorage("native.desktop.materialsRailWidth") private var materialsRailWidth = 288.0
    @State private var leftPanel: NativeSidebarPanel = .courses
    @State private var auxiliary: NativeAuxiliaryDestination?
    @State private var learningHome = false
    @State private var boardOverlayOpen = false
    @State private var settingsCategory = "appearance"
    @State private var compactCourseRail = false
    @State private var compactMaterialsRail = false
    @AppStorage("native.openAdjacentTab") private var openAdjacentTab = false
    @AppStorage("native.restoreLastCourse") private var restoreLastCourse = true
    @AppStorage("native.fontScale") private var fontScale = 1.0
    @AppStorage("native.density") private var density = "comfortable"
    @State private var showingCourseSheet = false
    @State private var showingNewTabMenu = false
    @State private var workspaceSettings: [String: Any] = [:]
    @State private var showingCourseManager = false
    @State private var courseName = ""
    @State private var busy = false
    @State private var restored = false
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var loginRequired = false

    init() {
        let store = NativeWorkspaceStore()
        _store = StateObject(wrappedValue: store)
        _services = StateObject(wrappedValue: NativePlatformServices(store: store))
    }

    private var navigationURL: URL { store.root.appendingPathComponent("native-workspace.json") }
    private var courseTitle: String { store.courses.first { $0.id == store.selectedCourseID }?.name ?? "자료실" }

    var body: some View {
        GeometryReader { geometry in
            let showLeft = courseRailOpen && geometry.size.width >= 1100 && section != .settings
            let showRight = materialsRailOpen && geometry.size.width >= 900 && section == .library && !learningHome && auxiliary == nil && !["learning", "learning-home"].contains(navigation.active?.kind ?? "")
            let railWidths = NativeDockRailWidths.resolve(windowWidth: geometry.size.width, leftRequested: courseRailWidth, rightRequested: materialsRailWidth, showLeft: showLeft, showRight: showRight)
            HStack(spacing: 0) {
                globalNavigation(width: geometry.size.width)
                if showLeft {
                    courseSidebar.frame(width: railWidths.left)
                    railDivider
                }
                VStack(spacing: 0) {
                    if section == .settings {
                        NativeSettingsWorkspace(store: store, initialCategory: settingsCategory)
                    } else if let auxiliary {
                        switch auxiliary {
                        case .marketplace: NativeMarketplaceView(store: store)
                        case .help: NativeHelpView()
                        case .account: NativeAccountView(store: store)
                        }
                    } else if learningHome {
                        NativeLearningHome(store: store, onOpen: openLearning)
                    } else if section != .library {
                        toolTabs
                        NativeToolsWorkspace(section: section, store: store, services: services)
                    } else {
                        NativeDockWorkspace(navigation: navigation, store: store, content: { workspace($0) }, empty: { emptyWorkspace },
                            perform: transition, persist: saveNavigation, closeDocuments: closeDocuments,
                            openMaterials: { materialsRailOpen = true; compactMaterialsRail = true },
                            openNewTab: openNewTab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NativeDesktopTheme.bgApp)
                if showRight {
                    railDivider
                    materialsSidebar.frame(width: railWidths.right)
                }
            }
            .overlay {
                if showLeft {
                    NativeDockRailResizer(side: .left, width: Binding(get: { railWidths.left }, set: { courseRailWidth = $0 }), maximum: min(400, geometry.size.width - 48 - railWidths.right - 282))
                        .frame(width: 44, height: geometry.size.height)
                        .position(x: 48 + railWidths.left + 0.5, y: geometry.size.height / 2)
                }
                if showRight {
                    NativeDockRailResizer(side: .right, width: Binding(get: { railWidths.right }, set: { materialsRailWidth = $0 }), maximum: min(520, geometry.size.width - 48 - railWidths.left - 282))
                        .frame(width: 44, height: geometry.size.height)
                        .position(x: geometry.size.width - railWidths.right - 0.5, y: geometry.size.height / 2)
                }
            }
            .overlay(alignment: .leading) {
                if compactCourseRail && geometry.size.width < 1100 && section != .settings {
                    HStack(spacing: 0) {
                        courseSidebar.frame(width: min(NativeDockRailSide.left.clamp(courseRailWidth), geometry.size.width - 88))
                            .background(NativeDesktopTheme.surface).compositingGroup().shadow(color: .black.opacity(0.14), radius: 12, x: 4)
                        Color.black.opacity(0.12).onTapGesture { compactCourseRail = false }
                    }.padding(.leading, NativeDesktopTheme.navigationWidth)
                }
            }
            .overlay(alignment: .trailing) {
                if compactMaterialsRail && geometry.size.width < 900 && section != .settings {
                    HStack(spacing: 0) {
                        Color.black.opacity(0.12).onTapGesture { compactMaterialsRail = false }
                        materialsSidebar.frame(width: min(NativeDockRailSide.right.clamp(materialsRailWidth), geometry.size.width - 88))
                            .background(NativeDesktopTheme.surface).compositingGroup().shadow(color: .black.opacity(0.14), radius: 12, x: -4)
                    }
                }
            }
            .overlay {
                if boardOverlayOpen { academicBoardOverlay(size: geometry.size) }
            }
            .overlay(alignment: .top) {
                if busy { ProgressView().padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 48) }
            }
        }
        .font(NativeDesktopTheme.font(14))
        .foregroundStyle(NativeDesktopTheme.text)
        .background(NativeDesktopTheme.surface.ignoresSafeArea())
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .tint(NativeDesktopTheme.accent)
        .disabled(store.isApplyingExternalChanges)
        .background(NativeWorkspaceKeyboardBridge(store: store))
        .background(NativePresentationAnchor(services: services).allowsHitTesting(false))
        .sheet(isPresented: $showingNewTabMenu) {
            NativeNewTabMenu(store: store, courseID: store.selectedCourseID ?? "", onAction: { action in
                showingNewTabMenu = false
                openNewTab(action, navigation.focusedGroupID ?? "")
            }, onClose: { showingNewTabMenu = false }).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingCourseSheet) { courseSheet }
        .sheet(isPresented: $showingCourseManager) { NativeCourseManager(store: store) }
        .fullScreenCover(isPresented: $loginRequired) { NativeLoginGate(store: store).interactiveDismissDisabled() }
        .alert("작업을 완료하지 못했어요", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .task {
            await store.start()
            await services.start()
            if store.isReady, let state = try? await store.invoke("auth:getState") as? [String: Any] { loginRequired = NativeLoginGate.requiresLogin(state) }
            workspaceSettings = (try? await store.invoke("settings:get")) as? [String: Any] ?? [:]
            guard store.isReady, !restored else { return }
            restored = true
            navigation.openAdjacentTab = openAdjacentTab
            if restoreLastCourse { await navigation.restore(from: navigationURL) { item in
                guard store.courses.contains(where: { $0.id == item.courseID }) else { return false }
                if item.kind == "learning" { return (try? await store.invoke("learning:get", ["binding": ["courseId": item.courseID, "rootRelPath": item.relativePath]])) != nil }
                if item.isWorkspaceTool { return true }
                if item.kind == "whiteboard" { return (try? await store.invoke("canvas:get",["courseId":item.courseID,"id":item.relativePath])) != nil }
                return (try? await store.invokePrivate("nativeMaterial:path", ["courseId": item.courseID, "relPath": item.relativePath])) != nil
            } }
            store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
            if let course = store.selectedCourseID { navigation.activateCourse(course) }
        }
        .onChange(of: store.selectedCourseID) { _, courseID in
            if let courseID, restored { navigation.activateCourse(courseID); saveNavigation() }
        }
        .onChange(of: openAdjacentTab) { _, value in navigation.openAdjacentTab = value }
        .onReceive(store.events) { event in
            if event.channel == "auth:changed", let state = event.payload as? [String: Any] { loginRequired = NativeLoginGate.requiresLogin(state) }
            receive(event)
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if store.isReady { _ = try? await store.invokePrivate("nativeRuntime:active", ["active": phase == .active]) }
                if phase == .background { await flushInBackground() }
            }
        }
        .onOpenURL { url in
            Task {
                do { try await store.importFiles([url]) }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private func workspace(_ document: NativeDocumentReference) -> some View {
        NativeDocumentAssistantHost(store: store, document: document) {
            if document.kind == "learning-home" {
                NativeLearningHome(store: store, courseID: document.courseID, onOpen: openLearning)
            } else if document.kind == "learning" {
                NativeLearningWorkspace(store: store, binding: NativeLearningBinding(courseID: document.courseID, rootRelPath: document.relativePath), onOpenDocument: open, onOpenBrowser: openBrowserURL)
            } else if document.isWorkspaceTool, let tool = NativeWorkspaceSection(rawValue: document.kind) {
                NativeToolsWorkspace(section: tool, store: store, services: services, workspaceID: document.relativePath, courseID: document.courseID)
            } else if document.kind == "pdf" {
                NativePDFWorkspace(document: document, store: store, onOpenDocument: { openBeside($0, sourceID: document.id) })
            } else if document.kind == "whiteboard" {
                NativeWhiteboardWorkspace(document:document,store:store)
            } else if document.kind == "note" || ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased()) {
                NativeMarkdownWorkspace(document: document, store: store)
            } else if ["video","audio"].contains(document.kind) || ["mp4","mov","m4v","mp3","m4a","wav","aac"].contains((document.relativePath as NSString).pathExtension.lowercased()) {
                NativeMediaWorkspace(document: document, store: store)
            } else {
                ContentUnavailableView {
                    Label(document.title, systemImage: "doc")
                } actions: {
                    Button("미리보기 열기") {
                        Task {
                            do { _ = try await store.invoke("materials:preview", ["courseId": document.courseID, "relPath": document.relativePath]) }
                            catch { store.errorMessage = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.id(store.reloadIdentity(for:document))
    }

    private var railDivider: some View { NativeDesktopTheme.border.frame(width: 1) }

    private func globalNavigation(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            NativeChromeButton(title: "과목", symbol: "folder", selected: section == .library && !learningHome && auxiliary == nil && leftPanel == .courses && (courseRailOpen || compactCourseRail)) {
                if section == .library && !learningHome && auxiliary == nil && leftPanel == .courses {
                    if width < 1100 { compactCourseRail.toggle() } else { courseRailOpen.toggle() }
                } else { transition { section = .library; auxiliary = nil; learningHome = false; leftPanel = .courses; courseRailOpen = true; compactCourseRail = width < 1100 } }
            }.accessibilityIdentifier("native-section-library")
            NativeChromeButton(title: "학습", symbol: "book", selected: learningHome && section != .settings && auxiliary == nil) {
                transition { section = .library; auxiliary = nil; learningHome = true; leftPanel = .learning; courseRailOpen = true; compactCourseRail = width < 1100 }
            }.accessibilityIdentifier("native-section-learning")
            NativeChromeButton(title: "학업 보드", symbol: "rectangle.split.3x1", selected: boardOverlayOpen) { toggleAcademicBoard() }.accessibilityIdentifier("native-section-planner")
            NativeChromeButton(title: "AI", symbol: "sparkle", selected: navigation.active?.kind == "assistant") { openActiveAssistant() }.accessibilityIdentifier("native-section-assistant")
            NativeChromeButton(title: "도구", symbol: "puzzlepiece", selected: leftPanel == .tools && courseRailOpen && section != .settings && auxiliary == nil) {
                transition {
                    if leftPanel == .tools && courseRailOpen { courseRailOpen = false; compactCourseRail = false }
                    else { leftPanel = .tools; courseRailOpen = true; compactCourseRail = width < 1100 }
                    section = .library; auxiliary = nil; learningHome = false
                }
            }.accessibilityIdentifier("native-section-tools")
            NativeChromeButton(title: "마켓플레이스", symbol: "storefront", selected: auxiliary == .marketplace) { transition { section = .library; auxiliary = .marketplace; learningHome = false } }.accessibilityIdentifier("native-section-marketplace")
            NativeChromeButton(title: "도움말", symbol: "questionmark.circle", selected: auxiliary == .help) { transition { section = .library; auxiliary = .help; learningHome = false } }.accessibilityIdentifier("native-section-help")
            Spacer(minLength: 8)
            NativeChromeButton(title: "계정", symbol: "person.crop.circle", selected: auxiliary == .account) { transition { section = .library; auxiliary = .account; learningHome = false } }.accessibilityIdentifier("native-section-account")
            NativeChromeButton(title: "설정", symbol: "gearshape", selected: section == .settings) { openSettings("appearance") }.accessibilityIdentifier("native-section-settings")
        }.padding(.top, 12).padding(.bottom, 12).frame(width: NativeDesktopTheme.navigationWidth)
            .background(NativeDesktopTheme.surface).overlay(alignment: .trailing) { railDivider }
    }
    @ViewBuilder private var courseSidebar: some View {
        switch leftPanel {
        case .courses:
            NativeCourseSidebar(store: store, navigation: navigation, settings: workspaceSettings, onSelect: changeCourse,
                onCreate: { showingCourseSheet = true }, onManage: { showingCourseManager = true }, onOpenSettings: openSettings,
                onOpenURL: openBrowserURL, onOpenAIWeb: openAIWeb, descriptor: favoriteDescriptor, onOpenFavorite: openFavorite)
        case .learning:
            NativeLearningSidebar(store: store, onOpen: openLearning)
        case .tools:
            NativeFeatureLauncherPanel(store: store, source: navigation.active, onOpen: openLearning, onOpenSettings: openSettings)
        }
    }
    private func toggleAcademicBoard() {
        transition {
            if section == .settings { section = .library }
            boardOverlayOpen.toggle()
        }
    }
    private func academicBoardOverlay(size: CGSize) -> some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea().onTapGesture { transition { boardOverlayOpen = false } }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    NativeChromeButton(title: "학업 보드 닫기", symbol: "xmark") { transition { boardOverlayOpen = false } }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("native-board-overlay-close")
                }.padding(.horizontal, 6).frame(height: 36)
                NativeToolsWorkspace(section: .planner, store: store, services: services)
            }
            .frame(width: min(max(1, size.width - 32), 1280), height: min(max(1, size.height - 32), 768))
            .background(NativeDesktopTheme.bgApp, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("native-board-overlay")
        }
    }
    private func openActiveAssistant() {
        if let document = navigation.active, !document.isWorkspaceTool, document.kind != "learning-home", section == .library, !learningHome, auxiliary == nil {
            store.assistantDocumentIDs.insert(document.id)
        } else { openTool(.assistant) }
    }
    private func openSettings(_ category: String) { transition { boardOverlayOpen = false; settingsCategory = category; section = .settings; auxiliary = nil } }
    private func favoriteDescriptor(_ document: NativeDocumentReference) -> [String: Any]? {
        let url = document.kind == "browser" ? NativeBrowserSession.currentPage(workspaceID: document.relativePath, store: store, host: services.browser)?.url : nil
        return NativeSidebarDescriptor.document(document, browserURL: url, conversationID: NativeToolSelection.conversationID(workspaceID: document.relativePath, root: store.root), recordingID: NativeToolSelection.recordingID(workspaceID: document.relativePath, courseID: document.courseID))
    }
    private func openAIWeb(_ shortcut: NativeAIWebShortcut) {
        let candidates = navigation.documents.filter { document in
            guard document.kind == "browser", let page = NativeBrowserSession.currentPage(workspaceID: document.relativePath, store: store, host: services.browser),
                  let host = URL(string: page.url)?.host?.lowercased() else { return false }
            return shortcut.hosts.contains(host)
        }
        if let existing = candidates.first(where: { $0.id == navigation.activeID }) ?? candidates.last { open(existing) }
        else { openBrowserURL(shortcut.url) }
    }
    private func openFavorite(_ favorite: NativeSidebarFavorite) {
        let payload = favorite.payload
        let course = payload["courseId"] as? String ?? favorite.courseID ?? store.selectedCourseID
        if favorite.kind == "browser", let url = payload["initialUrl"] as? String, NativeSettingsSchema.webURL(url) {
            let scope = payload["tabId"] as? String ?? UUID().uuidString
            if let existing = navigation.documents.first(where: { $0.kind == "browser" && $0.relativePath == scope }) { open(existing); return }
            guard let course else { openBrowserURL(url); return }
            let document = NativeDocumentReference(courseID: course, relativePath: scope, title: favorite.label, kind: "browser")
            store.pendingBrowserURLs[scope] = url; open(document); return
        }
        if favorite.kind == "learning", let course {
            if let root = payload["rootRelPath"] as? String { openLearning(.init(courseID: course, rootRelPath: root)) }
            else { open(.init(courseID: course, relativePath: "favorite-" + favorite.id, title: "학습 공간", kind: "learning-home")) }
            return
        }
        if ["board", "chat", "recording"].contains(favorite.kind) {
            let kind = favorite.kind == "board" ? "planner" : favorite.kind == "chat" ? "assistant" : "recordings"
            guard let course else { openTool(kind == "planner" ? .planner : kind == "assistant" ? .assistant : .recordings); return }
            let scope = UUID().uuidString
            do {
                if kind == "assistant", let conversation = payload["conversationId"] as? String { try NativeToolSelection.restoreConversation(conversation, workspaceID: scope, root: store.root) }
                if kind == "recordings", let recording = payload["recordingId"] as? String { NativeToolSelection.restoreRecording(recording, workspaceID: scope, courseID: course) }
                open(NativeDocumentReference(courseID: course, relativePath: scope, title: favorite.label, kind: kind))
            } catch { store.errorMessage = error.localizedDescription }
            return
        }
        guard let course, let path = (favorite.kind == "whiteboard" ? payload["boardId"] : payload["relPath"]) as? String else { store.errorMessage = "즐겨찾기 자료 연결을 확인해 주세요."; return }
        open(NativeDocumentReference(courseID: course, relativePath: path, title: favorite.label, kind: favorite.kind == "file" ? NativeSidebarDescriptor.materialKind(path) : favorite.kind))
    }
    private func openLearning(_ binding: NativeLearningBinding) {
        let document = NativeDocumentReference(courseID: binding.courseID, relativePath: binding.rootRelPath, title: "학습 공간", kind: "learning")
        open(document)
    }
    private func openNewTab(_ action: NativeNewTabAction, _ groupID: String) {
        if case .material(let document) = action { openInGroup(document, groupID: groupID.isEmpty ? nil : groupID); return }
        guard !busy else { return }; busy = true
        let courseID = navigation.activeCourseID ?? store.selectedCourseID
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.flushDocuments()
                guard let courseID else { throw DesktopRuntimeError("먼저 과목을 만들거나 선택해 주세요.") }
                let document: NativeDocumentReference
                switch action {
                case .markdown(let title): document = try await store.createMarkdown(title: title ?? ((workspaceSettings["tabs"] as? [String: Any])?["markdownTitlePrefix"] as? String ?? "새 마크다운"), courseID: courseID)
                case .note:
                    // Notes are PDF notes, like the desktop: same paper, same palette, same sync.
                    document = try await store.createNote(title: "새 노트", paper: NativePaper.lines.rawValue, orientation: "portrait")
                case .browser(let url):
                    document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "브라우저", kind: "browser")
                    if let url { store.pendingBrowserURLs[document.relativePath] = url }
                case .assistant: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "AI", kind: "assistant")
                case .recording: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "녹음", kind: "recordings")
                case .planner: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "학업 보드", kind: "planner")
                case .learning: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "학습 공간", kind: "learning-home")
                case .material: return
                }
                guard navigation.activeCourseID == courseID else { return }
                navigation.open(document, inGroup: groupID.isEmpty ? navigation.focusedGroupID : groupID)
                section = .library; auxiliary = nil; learningHome = false; saveNavigation()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func openBrowserURL(_ url: String) {
        guard NativeSettingsSchema.webURL(url), let target = URL(string:url) else { return }
        if (workspaceSettings["browser"] as? [String: Any])?["linkRouting"] as? String == "system" {
            UIApplication.shared.open(target); return
        }
        transition {
            if let course = store.selectedCourseID {
                navigation.activateCourse(course)
                let document = NativeDocumentReference(courseID: course, relativePath: UUID().uuidString, title: "브라우저", kind: "browser")
                store.pendingBrowserURLs[document.relativePath] = url
                navigation.open(document, inGroup: navigation.focusedGroupID); section = .library; auxiliary = nil; learningHome = false
            } else { store.pendingBrowserURLs["global"] = url; section = .browser }
        }
    }
    private func shortcut(_ title: String, _ symbol: String, _ target: NativeWorkspaceSection) -> some View {
        Button { openTool(target, new: true) } label: {
            Label(title, systemImage: symbol).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.secondary)
    }
    private func courseColor(_ value: String) -> Color {
        switch value { case "red": .red; case "orange": .orange; case "yellow", "gold": .yellow; case "green": .green; case "purple": .purple; case "pink": .pink; default: .blue }
    }
    private var materialsSidebar: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                NativeLibraryView(store: store, selectedDocumentID: navigation.active?.id) { document in
                    compactMaterialsRail = false; open(document)
                }.frame(maxHeight: .infinity)
                NativeSettingsWidgetDock(store: store, services: services, availableHeight: geometry.size.height)
            }
        }
    }
    private var toolTabs: some View {
        HStack(spacing: 4) {
            Button { transition { section = .library } } label: { Label(courseTitle, systemImage: "folder").lineLimit(1) }.buttonStyle(.plain)
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted)
            Text(section.title).fontWeight(.medium)
            Spacer()
            NativeChromeButton(title: "닫기", symbol: "xmark") { transition { section = .library } }
        }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 44).background(NativeDesktopTheme.surface)
            .overlay(alignment: .bottom) { NativeDesktopTheme.border.frame(height: 1) }
    }
    private var emptyWorkspace: some View {
        VStack(spacing: 18) {
            Spacer()
            NativeBandalMark(size: store.selectedCourseID == nil ? 56 : 48).foregroundStyle(NativeDesktopTheme.muted.opacity(0.4))
            if store.selectedCourseID != nil {
                Text(courseTitle).font(NativeDesktopTheme.font(24, weight: .semibold))
                Text("읽고, 기록하고, 연결하는 나만의 학습 공간").font(NativeDesktopTheme.font(13)).foregroundStyle(NativeDesktopTheme.muted)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { emptyActions }.frame(minWidth: 530)
                    VStack(spacing: 8) { emptyActions }.frame(maxWidth: 280)
                }.padding(.top, 12)
                Button("새 탭 열기", systemImage: "plus") { showingNewTabMenu = true }.font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.secondary).padding(.top, 8)
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var emptyActions: some View {
        emptyAction("새 필기", "생각을 기록하세요", "square.and.pencil", .markdown(title: nil))
        emptyAction("웹 탐색", "자료를 찾아보세요", "globe", .browser(url: nil))
        emptyAction("AI와 공부", "질문에서 시작하세요", "sparkle", .assistant)
    }
    private func emptyAction(_ title: String, _ subtitle: String, _ icon: String, _ action: NativeNewTabAction) -> some View {
        Button { openNewTab(action, navigation.focusedGroupID ?? "") } label: {
            VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).font(.system(size: 20)); Text(title).font(NativeDesktopTheme.font(14, weight: .medium)); Text(subtitle).font(NativeDesktopTheme.font(11)).foregroundStyle(NativeDesktopTheme.muted) }
                .padding(18).frame(maxWidth: 180, alignment: .leading).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private func documentIcon(_ document: NativeDocumentReference) -> String {
        switch document.kind { case "browser": "globe"; case "assistant": "sparkle"; case "recordings": "waveform"; case "planner": "checklist"; case "pdf": "doc.richtext"; case "whiteboard": "rectangle.and.pencil.and.ellipsis"; case "video": "play.rectangle"; case "audio": "waveform"; default: "doc.text" }
    }
    private func openTool(_ target: NativeWorkspaceSection, new: Bool = false) {
        guard target != .library && target != .settings else { transition { section = target }; return }
        transition {
            guard let course = store.selectedCourseID else { section = target; return }
            navigation.activateCourse(course)
            let document = (!new ? navigation.documents.first { $0.courseID == course && $0.kind == target.rawValue } : nil)
                ?? NativeDocumentReference(courseID: course, relativePath: UUID().uuidString, title: target.title, kind: target.rawValue)
            navigation.open(document, inGroup: navigation.focusedGroupID)
            section = .library; auxiliary = nil; learningHome = false
        }
    }
    private func openBeside(_ document: NativeDocumentReference, sourceID: String?) {
        transition {
            var target = document
            if let sourceID, document.kind == "note" {
                let matches = navigation.documents.filter { $0.storageID == document.storageID }
                if let paired = matches.first(where: { navigation.pageNoteSourceTabIDs[$0.id] == sourceID }) { target = paired }
                else if let unpaired = matches.first(where: { navigation.pageNoteSourceTabIDs[$0.id] == nil }) { target = unpaired }
                else if let existing = matches.first {
                    target = document.duplicated(); store.documentDuplicateSourceIDs[target.id] = existing.id
                }
                navigation.pageNoteSourceTabIDs[target.id] = sourceID
                store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
            }
            navigation.openBeside(target, sourceID: sourceID, reuseExisting: false)
            section = .library; auxiliary = nil; learningHome = false
        }
    }
    private func saveNavigation() {
        do { try navigation.save(to: navigationURL) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private var courseSheet: some View {
        NavigationStack {
            Form {
                TextField("과목 이름", text: $courseName)
                    .accessibilityIdentifier("native-course-name")
                    .submitLabel(.done)
                    .onSubmit(createCourse)
            }
            .navigationTitle("새 과목")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { showingCourseSheet = false }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기", action: createCourse)
                        .disabled(courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                        .accessibilityIdentifier("native-create-course")
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(busy)
    }

    private func createCourse() {
        guard !busy, !courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await store.createCourse(name: courseName)
                if let courseID = store.selectedCourseID { navigation.activateCourse(courseID) }
                section = .library; auxiliary = nil; learningHome = false; leftPanel = .courses; compactCourseRail = false; compactMaterialsRail = false
                try navigation.save(to: navigationURL)
                courseName = ""; showingCourseSheet = false
            }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func open(_ document: NativeDocumentReference) { openInGroup(document, groupID: nil) }
    private func openInGroup(_ document: NativeDocumentReference, groupID: String?) {
        guard !busy else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.flushDocuments()
                if store.selectedCourseID != document.courseID { await store.selectCourse(document.courseID) }
                guard store.selectedCourseID == document.courseID else { return }
                section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false; navigation.open(document, inGroup: groupID); try navigation.save(to: navigationURL)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func changeCourse(_ id: String) {
        guard !busy else { return }; busy = true
        Task { @MainActor in
            defer { busy = false }
            await store.selectCourse(id)
            guard store.selectedCourseID == id else { return }
            navigation.activateCourse(id); section = .library; auxiliary = nil; learningHome = false; compactCourseRail = false
            do { try navigation.save(to: navigationURL) } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func closeDocuments(_ documentIDs: [String]) {
        guard !busy else { return }
        let course = navigation.activeCourseID
        let current = Set(navigation.groups.flatMap(\.tabs))
        var seen = Set<String>()
        let documents = documentIDs.filter { current.contains($0) && seen.insert($0).inserted }.compactMap { navigation.document($0) }
        guard !documents.isEmpty else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.flushDocuments()
                var plans: [NativeBrowserScopeClosePlan] = []
                for document in documents where document.kind == "browser" {
                    guard let plan = try await NativeBrowserSession.prepareScope(workspaceID: document.relativePath, host: services.browser, store: store) else { return }
                    plans.append(plan)
                }
                // beforeunload can wait for user input while another pane is edited.
                // Flush again before the synchronous all-or-nothing commit.
                try await store.flushDocuments()
                guard navigation.activeCourseID == course else { return }
                guard try NativeBrowserSession.commitScopes(plans, host: services.browser, store: store) else {
                    throw DesktopRuntimeError("웹페이지가 변경되었습니다. 닫기를 다시 시도해 주세요.")
                }
                for document in documents {
                    navigation.closeTab(document.id)
                    store.documentDuplicateSourceIDs[document.id] = nil
                    store.documentSelections[document.id] = nil
                    store.assistantDocumentIDs.remove(document.id)
                }
                store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
                try navigation.save(to: navigationURL)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func transition(_ action: @escaping @MainActor () -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await store.flushDocuments(); compactCourseRail = false; compactMaterialsRail = false; action(); try navigation.save(to: navigationURL) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func receive(_ event: NativeWorkspaceEvent) {
        if event.channel == "nativeWorkspace:updateToolTitle", let payload = event.payload as? [String: Any],
           let workspaceID = payload["workspaceID"] as? String, let title = payload["title"] as? String {
            if navigation.updateToolTitle(workspaceID: workspaceID, title: title) { saveNavigation() }
            return
        }
        if event.channel == "settings:changed", let payload = event.payload as? [String: Any], let settings = payload["settings"] as? [String: Any] {
            workspaceSettings = settings
        }
        if event.channel == "nativeWorkspace:openBrowserURL", let payload = event.payload as? [String: Any], let url = payload["url"] as? String {
            openBrowserURL(url); return
        }
        if event.channel == "nativeWorkspace:openDocument", let value = event.payload as? [String: Any],
           let course = value["courseId"] as? String, let path = value["relPath"] as? String {
            let document = NativeDocumentReference(courseID: course, relativePath: path, title: value["title"] as? String ?? (path as NSString).lastPathComponent, kind: value["kind"] as? String ?? "pdf")
            guard !busy else { return }; busy = true
            Task { @MainActor in
                defer { busy = false }
                do {
                    try await store.flushDocuments()
                    if store.selectedCourseID != course { await store.selectCourse(course) }
                    guard store.selectedCourseID == course else { return }
                    var target = document
                    if let targetID = value["targetTabID"] as? String, let existing = navigation.document(targetID), existing.storageID == document.storageID {
                        target = existing
                    } else if let existing = navigation.documents.first(where: { $0.storageID == document.storageID }) { target = existing }
                    if target.kind == "pdf", let page = value["page"] as? Int, page > 0, navigation.document(target.id) == nil {
                        _ = try await store.invoke("pdf:setViewState", ["courseId": course, "relPath": path, "page": page, "zoom": 1])
                    }
                    section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false
                    if let besideID = value["besideTabID"] as? String, let source = navigation.document(besideID) {
                        if source.kind == "note" && target.kind == "pdf" {
                            navigation.pageNoteSourceTabIDs[source.id] = target.id
                            store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
                        }
                        navigation.openBeside(target, sourceID: besideID, reuseExisting: false)
                    } else if let group = navigation.group(containing: target.id) { navigation.select(target.id, in: group.id) }
                    else { navigation.open(target) }
                    try navigation.save(to: navigationURL)
                    if let page = value["page"] as? Int, page > 0 {
                        store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:goToPage", payload: ["courseId": course, "relPath": path, "page": page, "tabID": target.id]))
                    }
                } catch { store.errorMessage = error.localizedDescription }
            }
            return
        }
        if event.channel == "nativeWorkspace:externalMutationFinished" {
            Task { @MainActor in
                for document in navigation.documents {
                    let exists: Bool
                    if document.kind == "learning" { exists = (try? await store.invoke("learning:get", ["binding": ["courseId": document.courseID, "rootRelPath": document.relativePath]])) != nil }
                    else if document.isWorkspaceTool { exists = store.courses.contains { $0.id == document.courseID } }
                    else if document.kind == "whiteboard" {
                        let board = try? await store.invoke("canvas:get",["courseId":document.courseID,"id":document.relativePath]) as? [String:Any]
                        exists = board != nil
                        if let title = board?["title"] as? String { navigation.updateTitle(title,for:document.id) }
                    }
                    else { exists = (try? await store.invokePrivate("nativeMaterial:path",["courseId":document.courseID,"relPath":document.relativePath])) != nil }
                    if !exists { navigation.close(document.id) }
                }
                do { try navigation.save(to:navigationURL) } catch { store.errorMessage = error.localizedDescription }
            }
            return
        }
        if event.channel == "shortcut:passthrough", let payload = event.payload as? [String:Any], let action = payload["action"] as? String {
            let browserLocal = ["new-tab", "close-tab", "prev-tab", "previous-tab", "next-tab", "activate-last-tab"].contains(action) || action.hasPrefix("activate-tab-")
            if payload["webContentsId"] != nil && browserLocal { return }
            switch action {
            case "new-ai-tab": openTool(.assistant, new: true)
            case "new-recording-tab": openTool(.recordings, new: true)
            case "open-study-board": toggleAcademicBoard()
            case "toggle-left-rail": courseRailOpen.toggle()
            case "close-tab": if let id = navigation.activeID { closeDocuments([id]) }
            case "new-tab": if store.selectedCourseID == nil { openTool(.browser, new: true) } else { showingNewTabMenu = true }
            case "new-markdown": openNewTab(.markdown(title: nil), navigation.focusedGroupID ?? "")
            case "new-whiteboard": openNewTab(.note, navigation.focusedGroupID ?? "")
            case "next-tab", "previous-tab", "prev-tab":
                if let group = navigation.layout?.focused, !group.tabs.isEmpty {
                    let index = group.tabs.firstIndex(of: group.activeID ?? "") ?? 0
                    let offset = action == "next-tab" ? 1 : group.tabs.count - 1
                    let target = group.tabs[(index + offset) % group.tabs.count]
                    transition { navigation.select(target, in: group.id) }
                }
            case "activate-last-tab":
                if let group = navigation.layout?.focused, let target = group.tabs.last { transition { navigation.select(target, in: group.id) } }
            default:
                if action.hasPrefix("activate-tab-"), let number = Int(action.dropFirst("activate-tab-".count)),
                   let group = navigation.layout?.focused, number > 0, number <= group.tabs.count {
                    transition { navigation.select(group.tabs[number - 1], in: group.id) }
                }
            }
            return
        }
        guard let payload = event.payload as? [String: Any], let course = payload["courseId"] as? String else { return }
        if event.channel == "nativeWorkspace:materialRenamed",
           let from = payload["fromRelPath"] as? String, let to = payload["toRelPath"] as? String {
            navigation.rename(courseID: course, from: from, to: to, isDirectory: payload["isDirectory"] as? Bool == true)
        } else if event.channel == "nativeWorkspace:materialDeleted", let path = payload["relPath"] as? String {
            navigation.remove(courseID: course, path: path, isDirectory: payload["isDirectory"] as? Bool == true)
        } else { return }
        store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
        do { try navigation.save(to: navigationURL) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func flushInBackground() async {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "자료 저장") {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        }
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        }
        do { try await store.flushDocuments(); try navigation.save(to: navigationURL) }
        catch { store.errorMessage = error.localizedDescription }
    }
}

private enum NativeSidebarPanel { case courses, learning, tools }
private enum NativeAuxiliaryDestination { case marketplace, help, account }
