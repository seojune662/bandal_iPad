import SwiftUI
import UIKit

struct NativeWorkspaceView: View {
    @StateObject private var store: NativeWorkspaceStore
    @StateObject private var navigation = NativeWorkspaceNavigation()
    @StateObject private var services: NativePlatformServices
    @ObservedObject private var annotation: NativeAnnotationCoordinator
    @StateObject private var librarySources = NativeLibrarySourceTrayModel()
    @State private var shareInbox = NativeShareInboxCoordinator()
    @State private var shareCatalogRefresh: Task<Void, Never>?
    @State private var contextRefresh: Task<Void, Never>?
    @State private var pendingContextRefresh = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("native.appearance") private var appearance = "system"
    @State private var section: NativeWorkspaceSection = .library
    @AppStorage("native.desktop.courseRail") private var courseRailOpen = true
    @AppStorage("native.desktop.materialsRail") private var materialsRailOpen = true
    @AppStorage("native.desktop.courseRailWidth") private var courseRailWidth = 240.0
    @AppStorage("native.inspector.width") private var materialsRailWidth = 360.0
    @AppStorage("native.home.section") private var leftPanel: NativeHomeSection = .courses
    @AppStorage("native.inspector.tab") private var inspectorTab: NativeInspectorTab = .materials
    @State private var windowWidth: CGFloat = 1200
    @State private var hasWindowWidth = false
    @State private var restoreInspectorAfterAnnotation = true
    @State private var pendingAttachments: [String: [NativeAssistantAttachment]] = [:]
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
    @State private var showBusy = false
    @State private var restored = false
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @State private var loginRequired = false

    init() {
        let store = NativeWorkspaceStore()
        _store = StateObject(wrappedValue: store)
        _services = StateObject(wrappedValue: NativePlatformServices(store: store))
        _annotation = ObservedObject(wrappedValue: store.annotation)
    }

    private var navigationURL: URL { store.root.appendingPathComponent("native-workspace.json") }
    private var workspaceContext: NativeWorkspaceContext? {
        guard restored else { return nil }
        return navigation.activeWorkspace ?? store.courses.first { $0.id == store.selectedCourseID }.map(NativeWorkspaceContext.course)
    }
    private var courseTitle: String { workspaceContext?.title ?? "자료실" }
    private var showsWorkspace: Bool { section == .library && auxiliary == nil }


    var body: some View {
        GeometryReader { geometry in
            let chrome = NativeWorkspaceChromeLayout(width: geometry.size.width,
                leftOpen: courseRailOpen, rightOpen: materialsRailOpen && annotation.request == nil,
                leftRequested: courseRailWidth, rightRequested: materialsRailWidth, showsWorkspace: showsWorkspace)
            let rightVisible = showsWorkspace && annotation.request == nil &&
                (chrome.rightPinned || geometry.size.width < 900 && compactMaterialsRail)
            HStack(spacing: 0) {
                globalNavigation(width: geometry.size.width)
                if chrome.leftPinned {
                    courseSidebar.frame(width: chrome.leftWidth)
                    railDivider
                }
                // Editors and the inspector remain mounted while covered. Navigation
                // and opening a keyboard must not discard an in-progress draft.
                let covered = section != .library || auxiliary != nil
                ZStack {
                    NativeDockWorkspace(navigation: navigation, store: store, content: { workspace($0) }, empty: { emptyWorkspace },
                        perform: transition, persist: saveNavigation, closeDocuments: closeDocuments,
                        materialsOpen: rightVisible,
                        toggleMaterials: { toggleMaterialsRail(width: geometry.size.width) },
                        openNewTab: openNewTab, covered: covered, select: selectTab)
                        .opacity(covered ? 0 : 1).allowsHitTesting(!covered).accessibilityHidden(covered)
                    if section == .settings {
                        NativeSettingsWorkspace(store: store, initialCategory: settingsCategory)
                    } else if let auxiliary {
                        switch auxiliary {
                        case .marketplace: NativeMarketplaceView(store: store)
                        case .help: NativeHelpView()
                        case .account: NativeAccountView(store: store)
                        }
                    } else if section != .library {
                        VStack(spacing: 0) {
                            toolTabs
                            NativeToolsWorkspace(section: section, store: store, services: services)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(NativeDesktopTheme.bgApp)
                if chrome.rightPinned {
                    railDivider
                    Color.clear.frame(width: chrome.rightWidth)
                }
            }
            .overlay {
                if chrome.leftPinned {
                    NativeDockRailResizer(side: .left, width: Binding(get: { chrome.leftWidth }, set: { courseRailWidth = $0 }), maximum: min(360, geometry.size.width - 48 - chrome.rightWidth - 480))
                        .frame(width: 44, height: geometry.size.height)
                        .position(x: 48 + chrome.leftWidth + 0.5, y: geometry.size.height / 2)
                }
            }
            .overlay(alignment: .leading) {
                if compactCourseRail && geometry.size.width < 1200 && showsWorkspace && annotation.request == nil {
                    HStack(spacing: 0) {
                        courseSidebar.frame(width: min(320, geometry.size.width - 48))
                            .background(NativeDesktopTheme.surface).shadow(color: .black.opacity(0.14), radius: 12, x: 4)
                        Color.black.opacity(0.12).onTapGesture { compactCourseRail = false }
                    }.padding(.leading, NativeDesktopTheme.navigationWidth)
                }
            }
            .overlay(alignment: .trailing) {
                // A concrete stack keeps the drawer's drawing and hit region
                // aligned to the trailing edge when the backdrop appears.
                ZStack(alignment: .trailing) {
                    if rightVisible && !chrome.rightPinned {
                        Color.black.opacity(0.12).onTapGesture { compactMaterialsRail = false }
                    }
                    // One stable host, including while hidden, for file browsing and AI.
                    inspectorSidebar
                        .frame(width: chrome.rightPinned ? chrome.rightWidth : chrome.compactRightWidth,
                               height: geometry.size.height)
                        .background(NativeDesktopTheme.surface)
                        .shadow(color: rightVisible && !chrome.rightPinned ? .black.opacity(0.14) : .clear, radius: 12, x: -4)
                        .opacity(rightVisible ? 1 : 0).allowsHitTesting(rightVisible).accessibilityHidden(!rightVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .overlay {
                if chrome.rightPinned {
                    NativeDockRailResizer(side: .right, width: Binding(get: { chrome.rightWidth }, set: { materialsRailWidth = max(320, $0) }), maximum: min(520, geometry.size.width - 48 - chrome.leftWidth - 480), resetWidth: 360)
                        .frame(width: 44, height: geometry.size.height)
                        .position(x: geometry.size.width - chrome.rightWidth - 0.5, y: geometry.size.height / 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsWorkspace && annotation.request == nil {
                    Button { toggleMaterialsRail(width: geometry.size.width) } label: {
                        Image(systemName: "sidebar.right").font(.system(size: 17))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(NativeDesktopTheme.surface)
                        .padding(.trailing, 4).padding(.top, 16)
                        .accessibilityLabel(rightVisible ? "오른쪽 패널 접기" : "오른쪽 패널 펼치기")
                        .accessibilityIdentifier("native-toggle-materials-rail")
                }
            }
            .overlay { if boardOverlayOpen { academicBoardOverlay(size: geometry.size) } }
            .overlay(alignment: .top) {
                if showBusy { ProgressView().padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 48) }
            }
            .onAppear { updateWindowWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in updateWindowWidth(width) }
            .task(id: busy) {
                showBusy = false
                guard busy else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if busy { showBusy = true }
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
            // Sync, auth and settings can wait for the restored tabs; the first screen cannot.
            defer { Task { @MainActor in
                await services.start()
                if store.isReady, let state = try? await store.invoke("auth:getState") as? [String: Any] { loginRequired = NativeLoginGate.requiresLogin(state) }
                workspaceSettings = (try? await store.invoke("settings:get")) as? [String: Any] ?? [:]
            } }
            guard store.isReady, !restored else { return }
            navigation.openAdjacentTab = openAdjacentTab
            let catalog = (try? await store.invoke("learning:list", ["includeDeleted": false])) as? [String: Any] ?? [:]
            let projects: [NativeLearningSummary] = (try? NativeToolJSON.decode(catalog["projects"] ?? [])) ?? []
            var projectBindings: [String: NativeLearningBinding] = [:]
            for project in projects { if let id = project.projectId { projectBindings[id] = project.binding } }
            let existingCourseIDs = Set(store.courses.map(\.id))
            if restoreLastCourse { await navigation.restore(from: navigationURL, projectBindings: projectBindings) { item in
                guard existingCourseIDs.contains(item.courseID) else { return false }
                if let target = item.learningTarget {
                    let channel = target.kind == .overview ? "learning:get" : target.kind == .article ? "learning:getArticle" : "learning:getArtifact"
                    return (try? await store.invoke(channel, ["binding": target.binding.request, "id": target.entityID])) != nil
                }
                if item.kind == "learning" { return (try? await store.invoke("learning:get", ["binding": ["courseId": item.courseID, "rootRelPath": item.relativePath]])) != nil }
                if item.isWorkspaceTool { return true }
                if item.kind == "whiteboard" { return (try? await store.invoke("canvas:get",["courseId":item.courseID,"id":item.relativePath])) != nil }
                return (try? await store.invokePrivate("nativeMaterial:path", ["courseId": item.courseID, "relPath": item.relativePath])) != nil
            } }
            store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
            if let saved = navigation.activeWorkspace {
                await restoreContext(saved)
            } else if let document = navigation.active, document.kind == "learning",
                      let context = try? await NativeWorkspaceContext.loadProject(store: store, binding: .init(courseID: document.courseID, rootRelPath: document.relativePath)) {
                await restoreContext(context)
            } else if let course = store.courses.first(where: { $0.id == store.selectedCourseID }) {
                if course.workspaceKind == "study-space", let context = try? await NativeWorkspaceContext.loadProject(store: store, binding: .init(courseID: course.id, rootRelPath: "")) {
                    await restoreContext(context)
                } else { navigation.activateWorkspace(.course(course)) }
            }
            restored = true
            if let document = navigation.active, document.kind == "assistant" {
                if let context = workspaceContext, let conversation = NativeToolSelection.conversationID(workspaceID: document.relativePath, root: store.root) {
                    store.pendingAssistantConversationIDs[context.id] = conversation
                }
                revealInspector(.assistant)
            }
            await importSharedMaterials()
        }
        .onChange(of: store.selectedCourseID) { _, courseID in
            if let courseID, restored, !busy, navigation.activeWorkspace?.courseID != courseID,
               let course = store.courses.first(where: { $0.id == courseID }) {
                navigation.activateWorkspace(.course(course)); saveNavigation()
            }
        }
        .onChange(of: store.assistantDocumentIDs) { _, ids in
            guard !ids.isEmpty else { return }
            revealInspector(.assistant)
            store.assistantDocumentIDs.removeAll()
        }
        .onChange(of: section) { old, new in
            if old == .settings && new != .settings {
                store.events.send(NativeWorkspaceEvent(channel: "agent:changed", payload: [:]))
            }
        }
        .onChange(of: navigation.activeID) { _, _ in annotation.cancel() }
        .onChange(of: annotation.completed?.id) { _, _ in receiveAnnotation() }
        .onChange(of: annotation.request?.id) { old, new in
            if old != nil && new == nil && restoreInspectorAfterAnnotation && showsWorkspace && !boardOverlayOpen { revealInspector(.assistant) }
        }
        .onChange(of: openAdjacentTab) { _, value in navigation.openAdjacentTab = value }
        .onChange(of: store.courses) { _, _ in refreshShareDestinations(); refreshWorkspaceContext() }
        .onChange(of: store.materials) { _, _ in refreshShareDestinations() }
        .onReceive(store.events) { event in
            if event.channel == "auth:changed", let state = event.payload as? [String: Any] { loginRequired = NativeLoginGate.requiresLogin(state) }
            receive(event)
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if store.isReady { _ = try? await store.invokePrivate("nativeRuntime:active", ["active": phase == .active]) }
                if phase == .background { await flushInBackground() }
                if phase == .active { await importSharedMaterials() }
            }
        }
        .onOpenURL { url in
            Task {
                do { try await store.importFiles([url], parentPath: workspaceContext?.rootRelPath ?? "") }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
    }

    private func importSharedMaterials() async {
        let report = await shareInbox.synchronize(using: store)
        if !report.failures.isEmpty { store.errorMessage = report.failures.joined(separator: "\n") }
    }

    private func refreshShareDestinations() {
        shareCatalogRefresh?.cancel()
        shareCatalogRefresh = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                try await shareInbox.publishCatalog(using: store)
            } catch is CancellationError { }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    @ViewBuilder private func workspace(_ document: NativeDocumentReference) -> some View {
        Group {
            if document.learningTarget != nil {
                NativeLearningDocumentWorkspace(store: store, document: document, onOpenDocument: open, onOpenBrowser: openBrowserURL)
            } else if document.kind == "assistant" {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.title)
                    Text("AI가 오른쪽 패널로 이동했어요")
                    Button("AI 열기", action: openActiveAssistant).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document.kind == "learning-home" {
                NativeProjectSidebar(store: store, selectedID: workspaceContext?.id, onOpen: changeWorkspace).frame(maxWidth: 420)
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
        }.allowsHitTesting(annotation.request == nil || annotation.request?.documentID == document.id)
            .id(store.reloadIdentity(for:document))
    }

    private var railDivider: some View { NativeDesktopTheme.border.frame(width: 1) }
    private func toggleMaterialsRail(width: CGFloat) {
        if width < 900 { compactMaterialsRail.toggle() } else { materialsRailOpen.toggle() }
        compactCourseRail = false
    }
    private func updateWindowWidth(_ width: CGFloat) {
        if hasWindowWidth {
            if windowWidth >= 900 && width < 900 { compactMaterialsRail = materialsRailOpen; compactCourseRail = false }
            if windowWidth < 900 && width >= 900 { materialsRailOpen = compactMaterialsRail; compactMaterialsRail = false }
            if windowWidth >= 1200 && width < 1200 { compactCourseRail = false }
            if width >= 1200 { compactCourseRail = false }
        }
        windowWidth = width; hasWindowWidth = true
    }
    private func revealInspector(_ tab: NativeInspectorTab) {
        inspectorTab = tab
        section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false
        compactCourseRail = false
        if windowWidth < 900 { compactMaterialsRail = true } else { materialsRailOpen = true }
    }
    private func globalNavigation(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            NativeChromeButton(title: "홈", symbol: "house.fill", selected: showsWorkspace && (courseRailOpen || compactCourseRail)) {
                if showsWorkspace {
                    if width < 1200 { compactCourseRail.toggle(); compactMaterialsRail = false }
                    else { courseRailOpen.toggle() }
                } else {
                    transition {
                        section = .library; auxiliary = nil; learningHome = false
                        courseRailOpen = true; compactCourseRail = width < 1200; compactMaterialsRail = false
                    }
                }
            }.accessibilityIdentifier("native-section-library")
            NativeChromeButton(title: "학업 보드", symbol: "rectangle.split.3x1", selected: boardOverlayOpen) { toggleAcademicBoard() }.accessibilityIdentifier("native-section-planner")
            if !NativeReleaseFlags.isLocalOnly {
                NativeChromeButton(title: "마켓플레이스", symbol: "storefront", selected: auxiliary == .marketplace) { transition { section = .library; auxiliary = .marketplace; learningHome = false } }.accessibilityIdentifier("native-section-marketplace")
            }
            NativeChromeButton(title: "도움말", symbol: "questionmark.circle", selected: auxiliary == .help) { transition { section = .library; auxiliary = .help; learningHome = false } }.accessibilityIdentifier("native-section-help")
            Spacer(minLength: 8)
            if !NativeReleaseFlags.isLocalOnly {
                NativeAccountRailButton(store: store, selected: auxiliary == .account,
                    openAccount: { transition { section = .library; auxiliary = .account; learningHome = false } },
                    openSettings: { openSettings("appearance") })
            }
            NativeChromeButton(title: "설정", symbol: "gearshape", selected: section == .settings) { openSettings("appearance") }.accessibilityIdentifier("native-section-settings")
        }.padding(.top, 12).padding(.bottom, 12).frame(width: NativeDesktopTheme.navigationWidth)
            .background(NativeDesktopTheme.surface).overlay(alignment: .trailing) { railDivider }
    }
    private var courseSidebar: some View {
        VStack(spacing: 0) {
            NativeHomeSectionPicker(selection: $leftPanel)
            switch leftPanel {
            case .courses:
                NativeCourseSidebar(store: store, navigation: navigation, settings: workspaceSettings, onSelect: changeCourse,
                    onCreate: { showingCourseSheet = true }, onManage: { showingCourseManager = true }, onOpenSettings: openSettings,
                    onOpenURL: openBrowserURL, onOpenAIWeb: openAIWeb, descriptor: favoriteDescriptor, onOpenFavorite: openFavorite)
            case .projects:
                NativeProjectSidebar(store: store, selectedID: workspaceContext?.id, onOpen: changeWorkspace)
            }
            NativeSidebarShortcuts(store: store, settings: workspaceSettings, onOpenSettings: openSettings, onOpenURL: openBrowserURL, onOpenAIWeb: openAIWeb)
        }.background(NativeDesktopTheme.surface)
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
        revealInspector(.assistant)
    }
    private func beginAnnotation() {
        guard let document = navigation.active, let context = workspaceContext,
              document.learningTarget == nil,
              (["pdf", "note", "browser", "whiteboard", "md", "markdown"].contains(document.kind) ||
               ["md", "markdown"].contains((document.relativePath as NSString).pathExtension.lowercased())) else { return }
        restoreInspectorAfterAnnotation = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        compactCourseRail = false
        annotation.begin(documentID: document.id, spaceID: context.id)
    }
    private func receiveAnnotation() {
        guard let capture = annotation.completed else { return }
        do {
            try NativeAssistantPendingCaptures.enqueue([capture.attachment], spaceID: capture.spaceID, root: store.root)
        } catch {
            store.errorMessage = "선택한 영역을 보관하지 못했습니다: \(error.localizedDescription)"
            return
        }
        var attachments = pendingAttachments[capture.spaceID] ?? []
        if !attachments.contains(where: { $0.id == capture.attachment.id }) { attachments.append(capture.attachment) }
        pendingAttachments[capture.spaceID] = attachments
        annotation.consumeCompleted()
        if workspaceContext?.id == capture.spaceID && restoreInspectorAfterAnnotation && showsWorkspace && !boardOverlayOpen {
            revealInspector(.assistant)
        }
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
        if favorite.kind == "chat", let course, let value = store.courses.first(where: { $0.id == course }) {
            Task { @MainActor in
                let context: NativeWorkspaceContext
                if let current = workspaceContext, current.courseID == course { context = current }
                else if value.workspaceKind == "study-space", let project = try? await NativeWorkspaceContext.loadProject(store: store, binding: .init(courseID: course, rootRelPath: "")) { context = project }
                else { context = .course(value) }
                if let conversation = payload["conversationId"] as? String { store.pendingAssistantConversationIDs[context.id] = conversation }
                if workspaceContext?.id != context.id { changeWorkspace(context) }
                revealInspector(.assistant)
            }
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
        Task { @MainActor in
            do { changeWorkspace(try await NativeWorkspaceContext.loadProject(store: store, binding: binding)) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func openNewTab(_ action: NativeNewTabAction, _ groupID: String) {
        if action == .assistant { revealInspector(.assistant); return }
        guard !busy else { return }; busy = true
        let context = workspaceContext
        let courseID = context?.courseID ?? store.selectedCourseID
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                guard let courseID else { throw DesktopRuntimeError("먼저 과목을 만들거나 선택해 주세요.") }
                let document: NativeDocumentReference
                switch action {
                case .markdown(let title): document = try await store.createMarkdown(title: title ?? ((workspaceSettings["tabs"] as? [String: Any])?["markdownTitlePrefix"] as? String ?? "새 마크다운"), courseID: courseID, parentPath: context?.rootRelPath ?? "")
                case .note:
                    // Notes are PDF notes, like the desktop: same paper, same palette, same sync.
                    document = try await store.createNote(title: "새 노트", paper: NativePaper.lines.rawValue, orientation: "portrait", parentPath: context?.rootRelPath ?? "")
                case .browser(let url):
                    document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "브라우저", kind: "browser")
                    if let url { store.pendingBrowserURLs[document.relativePath] = url }
                case .assistant: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "AI", kind: "assistant")
                case .recording: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "녹음", kind: "recordings")
                }
                guard workspaceContext?.id == context?.id else { return }
                navigation.open(document, inGroup: groupID.isEmpty ? navigation.focusedGroupID : groupID, workspace: context)
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
                if navigation.activeWorkspace == nil, let value = store.courses.first(where: { $0.id == course }) { navigation.activateWorkspace(.course(value)) }
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
    private var inspectorSidebar: some View {
        VStack(spacing: 0) {
            NativeInspectorHeader(selection: $inspectorTab)
            if let context = workspaceContext {
                ZStack {
                    VStack(spacing: 0) {
                        NativeLibraryView(store: store, sourceTrayModel: librarySources, scope: context,
                            onOpenAI: { revealInspector(.assistant) }, selectedDocumentID: navigation.active?.storageID) { document in
                            compactMaterialsRail = false; open(document)
                        }.id(context.id).frame(maxHeight: .infinity)
                        NativeSettingsWidgetDock(store: store, services: services, availableHeight: 600)
                    }.opacity(inspectorTab == .materials ? 1 : 0)
                        .allowsHitTesting(inspectorTab == .materials).accessibilityHidden(inspectorTab != .materials)
                    NativeAssistantPanel(store: store, context: context, sourceDocument: navigation.active,
                        attachments: pendingAttachments[context.id] ?? [],
                        onConsumeAttachments: { pendingAttachments[context.id] = nil },
                        onOpenDocument: openWorkspaceResult, onOpenSettings: { openSettings("ai") }, onAnnotate: beginAnnotation)
                        .id(context.id).opacity(inspectorTab == .assistant ? 1 : 0)
                        .allowsHitTesting(inspectorTab == .assistant).accessibilityHidden(inspectorTab != .assistant)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder").font(.largeTitle).foregroundStyle(NativeDesktopTheme.muted)
                    Text("과목이나 프로젝트를 선택하세요").font(NativeDesktopTheme.font(14))
                    Text("자료와 AI 대화를 한 공간에서 이어가세요.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(NativeDesktopTheme.surface)
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
        if target == .assistant { revealInspector(.assistant); return }
        guard target != .library && target != .settings else { transition { section = target }; return }
        transition {
            guard let course = store.selectedCourseID else { section = target; return }
            if navigation.activeWorkspace == nil, let value = store.courses.first(where: { $0.id == course }) { navigation.activateWorkspace(.course(value)) }
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
            defer { finishWorkspaceTransition() }
            do {
                try await store.createCourse(name: courseName)
                if let course = store.courses.first(where: { $0.id == store.selectedCourseID }) { navigation.activateWorkspace(.course(course)) }
                section = .library; auxiliary = nil; learningHome = false; leftPanel = .courses; compactCourseRail = false; compactMaterialsRail = false
                try navigation.save(to: navigationURL)
                courseName = ""; showingCourseSheet = false
            }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func open(_ document: NativeDocumentReference) { openInGroup(document, groupID: nil) }
    private func openWorkspaceResult(_ document: NativeDocumentReference) {
        openInGroup(document, groupID: nil, preservingWorkspace: true)
    }
    private func openInGroup(_ document: NativeDocumentReference, groupID: String?, preservingWorkspace: Bool = false) {
        if document.kind == "assistant" {
            if let context = workspaceContext,
               let conversation = NativeToolSelection.conversationID(workspaceID: document.relativePath, root: store.root) {
                store.pendingAssistantConversationIDs[context.id] = conversation
            }
            revealInspector(.assistant)
            return
        }
        if document.kind == "learning-home" { leftPanel = .projects; compactCourseRail = windowWidth < 1200; courseRailOpen = true; return }
        guard !busy else { return }; busy = true
        let current = workspaceContext
        let preserve = preservingWorkspace || document.learningTarget != nil || current?.courseID == document.courseID || current?.linkedCourseID == document.courseID
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                let context: NativeWorkspaceContext?
                if preserve { context = current }
                else {
                    await store.selectCourse(document.courseID)
                    guard store.selectedCourseID == document.courseID else { return }
                    context = store.courses.first(where: { $0.id == document.courseID }).map(NativeWorkspaceContext.course)
                }
                section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false
                navigation.open(document, inGroup: groupID, workspace: context)
                try navigation.save(to: navigationURL)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func changeCourse(_ id: String) {
        guard let course = store.courses.first(where: { $0.id == id }) else { return }
        changeWorkspace(.course(course))
    }
    private func changeWorkspace(_ context: NativeWorkspaceContext) {
        guard !busy else { return }; busy = true
        restoreInspectorAfterAnnotation = false; annotation.cancel()
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                await store.selectCourse(context.courseID)
                guard store.selectedCourseID == context.courseID else { return }
                navigation.activateWorkspace(context)
                leftPanel = context.kind == .project ? .projects : .courses
                section = .library; auxiliary = nil; learningHome = false; compactCourseRail = false
                try navigation.save(to: navigationURL)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func resolveContext(_ context: NativeWorkspaceContext) async throws -> NativeWorkspaceContext? {
        if context.kind == .course {
            return store.courses.first(where: { $0.id == context.courseID && $0.workspaceKind != "study-space" }).map(NativeWorkspaceContext.course)
        }
        let result = try await store.invoke("learning:list", ["includeDeleted": true]) as? [String: Any] ?? [:]
        let projects: [NativeLearningSummary] = try NativeToolJSON.decode(result["projects"] ?? [])
        guard let project = projects.first(where: {
            if let projectID = context.projectID { return $0.projectId == projectID }
            return $0.binding == context.binding
        }), project.deletedAt == nil else { return nil }
        return .project(project, courses: store.courses)
    }
    private func restoreContext(_ saved: NativeWorkspaceContext) async {
        do {
            let resolved = try await resolveContext(saved)
            let fallback = store.courses.first { $0.id == saved.linkedCourseID && $0.workspaceKind != "study-space" }
                ?? store.courses.first { $0.workspaceKind != "study-space" }
            if let context = resolved ?? fallback.map(NativeWorkspaceContext.course) {
                await store.selectCourse(context.courseID)
                guard store.selectedCourseID == context.courseID else { return }
                navigation.activateWorkspace(context)
                leftPanel = context.kind == .project ? .projects : .courses
            } else {
                try await store.clearCourseSelection()
                navigation.deactivateWorkspace()
                leftPanel = .projects; courseRailOpen = true; compactCourseRail = windowWidth < 1200
            }
        } catch { store.errorMessage = error.localizedDescription }
    }
    private func refreshWorkspaceContext() {
        guard restored, let current = navigation.activeWorkspace else { return }
        guard !busy else { pendingContextRefresh = true; return }
        pendingContextRefresh = false
        contextRefresh?.cancel()
        contextRefresh = Task { @MainActor in
            do {
                let refreshed = try await resolveContext(current)
                guard !Task.isCancelled, navigation.activeWorkspace?.id == current.id else { return }
                guard !busy else { pendingContextRefresh = true; return }
                if let refreshed { navigation.activateWorkspace(refreshed); saveNavigation() }
                else {
                    busy = true
                    await restoreContext(current)
                    saveNavigation()
                    finishWorkspaceTransition()
                }
            } catch { if !Task.isCancelled { store.errorMessage = error.localizedDescription } }
        }
    }

    private func finishWorkspaceTransition() {
        busy = false
        if pendingContextRefresh { refreshWorkspaceContext() }
    }

    private func closeDocuments(_ documentIDs: [String]) {
        guard !busy else { return }
        let scopeID = workspaceContext?.id
        let current = Set(navigation.groups.flatMap(\.tabs))
        var seen = Set<String>()
        let documents = documentIDs.filter { current.contains($0) && seen.insert($0).inserted }.compactMap { navigation.document($0) }
        guard !documents.isEmpty else { return }
        busy = true
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
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
                guard workspaceContext?.id == scopeID else { return }
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
    /// Switching to a tab whose outgoing editor is retained needs no global
    /// flush: nothing is torn down. Other kinds still take the flushing transition.
    private func selectTab(_ id: String, in groupID: String) {
        if let target = navigation.document(id), target.kind == "assistant" { open(target); return }
        let outgoing = navigation.layout?.groups.first { $0.id == groupID }?.activeID.flatMap(navigation.document)
        let retained = outgoing.map { $0.kind == "pdf" || $0.isWorkspaceTool || NativeDockWorkspace<EmptyView, EmptyView>.retainsEditor($0) } ?? true
        guard retained else { transition { navigation.select(id, in: groupID) }; return }
        navigation.select(id, in: groupID); compactCourseRail = false; compactMaterialsRail = false; saveNavigation()
    }
    private func transition(_ action: @escaping @MainActor () -> Void) {
        guard !busy else { return }
        restoreInspectorAfterAnnotation = false; annotation.cancel()
        busy = true
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do { try await store.flushDocuments(); compactCourseRail = false; compactMaterialsRail = false; action(); try navigation.save(to: navigationURL) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func receive(_ event: NativeWorkspaceEvent) {
        if ["learning:changed", "courses:changed"].contains(event.channel) { refreshWorkspaceContext() }
        if event.channel == "nativeWorkspace:openAssistantResult", let payload = event.payload as? [String: Any],
           let document = payload["document"] as? NativeDocumentReference { openWorkspaceResult(document); return }
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
            let current = workspaceContext
            Task { @MainActor in
                defer { finishWorkspaceTransition() }
                do {
                    try await store.flushDocuments()
                    let preserve = current?.courseID == course || current?.linkedCourseID == course
                    if !preserve, store.selectedCourseID != course { await store.selectCourse(course) }
                    guard preserve || store.selectedCourseID == course else { return }
                    let context = preserve ? current : store.courses.first(where: { $0.id == course }).map(NativeWorkspaceContext.course)
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
                    else { navigation.open(target, workspace: context) }
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
                    if let target = document.learningTarget {
                        let channel = target.kind == .overview ? "learning:get" : target.kind == .article ? "learning:getArticle" : "learning:getArtifact"
                        exists = (try? await store.invoke(channel, ["binding": target.binding.request, "id": target.entityID])) != nil
                    }
                    else if document.kind == "learning" { exists = (try? await store.invoke("learning:get", ["binding": ["courseId": document.courseID, "rootRelPath": document.relativePath]])) != nil }
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
            case "toggle-left-rail":
                if windowWidth < 1200 { compactCourseRail.toggle(); compactMaterialsRail = false } else { courseRailOpen.toggle() }
            case "toggle-right-rail": toggleMaterialsRail(width: windowWidth)
            case "close-tab": if let id = navigation.activeID { closeDocuments([id]) }
            case "new-tab": if store.selectedCourseID == nil { openTool(.browser, new: true) } else { showingNewTabMenu = true }
            case "new-markdown": openNewTab(.markdown(title: nil), navigation.focusedGroupID ?? "")
            case "new-whiteboard": openNewTab(.note, navigation.focusedGroupID ?? "")
            case "next-tab", "previous-tab", "prev-tab":
                if let group = navigation.layout?.focused, !group.tabs.isEmpty {
                    let index = group.tabs.firstIndex(of: group.activeID ?? "") ?? 0
                    let offset = action == "next-tab" ? 1 : group.tabs.count - 1
                    let target = group.tabs[(index + offset) % group.tabs.count]
                    selectTab(target, in: group.id)
                }
            case "activate-last-tab":
                if let group = navigation.layout?.focused, let target = group.tabs.last { selectTab(target, in: group.id) }
            default:
                if action.hasPrefix("activate-tab-"), let number = Int(action.dropFirst("activate-tab-".count)),
                   let group = navigation.layout?.focused, number > 0, number <= group.tabs.count {
                    selectTab(group.tabs[number - 1], in: group.id)
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

private enum NativeAuxiliaryDestination { case marketplace, help, account }
