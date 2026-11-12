import SwiftUI
import UIKit

struct NativeWorkspaceView: View {
    @StateObject private var storeHolder: NativeObservableHolder<NativeWorkspaceStore>
    private var store: NativeWorkspaceStore { storeHolder.model }
    @StateObject private var navigation = NativeWorkspaceNavigation()
    @StateObject private var previews = NativeWorkspacePreviewController()
    @State private var windowsOverviewOpen = false
    /// The pane a new handwriting note was asked for; set while the 새 노트 sheet is up.
    @State private var newNoteGroupID: String?
    @State private var pdfPalette = NativePDFPaletteHost()
    @StateObject private var services: NativePlatformServices
    @ObservedObject private var annotation: NativeAnnotationCoordinator
    @StateObject private var librarySources = NativeLibrarySourceTrayModel()
    @State private var shareInbox = NativeShareInboxCoordinator()
    @State private var shareCatalogRefresh: Task<Void, Never>?
    @State private var contextRefresh: Task<Void, Never>?
    @State private var pendingContextRefresh = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("native.appearance") private var appearance = "system"
    @AppStorage(NativeDecor.paletteKey) private var decorPalette = NativeDecorPalette.default.id
    @AppStorage(NativeDecor.intensityKey) private var decorIntensity = NativeDecor.defaultIntensity
    @State private var section: NativeWorkspaceSection = .library
    @AppStorage("native.desktop.courseRail") private var courseRailOpen = true
    @AppStorage("native.desktop.materialsRail") private var materialsRailOpen = true
    @AppStorage("native.desktop.courseRailWidth") private var courseRailWidth = 240.0
    @AppStorage("native.inspector.width") private var materialsRailWidth = 360.0
    @AppStorage("native.desktop.aiRail") private var aiRailOpen = false
    /// The sidebar was open when AI took its slot, and comes back when AI closes.
    @State private var windowWidth: CGFloat = 1200
    @State private var markdownEditing = false
    /// A PDF text box is open: the window keeps its size under the keyboard, the page makes room itself.
    @State private var pdfTextEditing = false
    @State private var shareNotice: String?
    @State private var railsBeforeKeyboard: (Bool, Bool)?
    @State private var hasWindowWidth = false
    @State private var restoreInspectorAfterAnnotation = true
    @State private var pendingAttachments: [String: [NativeAssistantAttachment]] = [:]
    @State private var auxiliary: NativeAuxiliaryDestination?
    @State private var learningHome = false
    @State private var boardOverlayOpen = false
    @State private var settingsCategory = "appearance"
    @State private var compactCourseRail = false
    @State private var compactMaterialsRail = false
    @State private var compactAIRail = false
    @AppStorage("native.openAdjacentTab") private var openAdjacentTab = false
    @AppStorage("native.restoreLastCourse") private var restoreLastCourse = true
    @AppStorage("native.fontScale") private var fontScale = 1.0
    @AppStorage("native.density") private var density = "comfortable"
    @State private var showingNewTabMenu = false
    @State private var workspaceSettings: [String: Any] = [:]
    @State private var busy = false
    @State private var showBusy = false
    @State private var restored = false
    @State private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// First launch: open until the store says whether this is a new user.
    @State private var onboarding: NativeOnboardingGate.Stage

    init(store: NativeWorkspaceStore) {
        _storeHolder = StateObject(wrappedValue: NativeObservableHolder(store))
        _services = StateObject(wrappedValue: NativePlatformServices(store: store))
        _annotation = ObservedObject(wrappedValue: store.annotation)
        _onboarding = State(initialValue: NativeOnboardingGate.initialStage(root: store.root))
    }

    private var navigationURL: URL { store.root.appendingPathComponent("native-workspace.json") }
    private var workspaceContext: NativeWorkspaceContext? {
        guard restored else { return nil }
        return navigation.activeWorkspace ?? store.courses.first { $0.id == store.selectedCourseID }.map(NativeWorkspaceContext.course)
    }
    private var courseTitle: String { workspaceContext?.title ?? "자료실" }
    /// The UI test suite drives the side panels while a markdown note has the keyboard, so it runs with
    /// folding off unless a test asks for it.
    private static let keyboardFoldsPanels: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return !arguments.contains("--native-ui-testing") || arguments.contains("--native-keyboard-folds-panels")
    }()
    private static var foldsPanelsOnKeyboard: Bool { keyboardFoldsPanels && NativeLocalPreferences.bool(NativeLocalPreferences.keyboardFoldsPanels) }
    private var showsWorkspace: Bool { section == .library && auxiliary == nil }
    /// Settings is a sheet over the workspace: the panels stay where they were behind it.
    private var settingsOpen: Bool { section == .settings && auxiliary == nil && !windowsOverviewOpen }
    private var showsWorkspaceChrome: Bool { showsWorkspace || settingsOpen }

    private var windowsOverview: some View {
        let scope = navigation.currentWindowRef?.workspaceID ?? ""
        return NativeWorkspaceWindowsOverview(windows: navigation.windows, activeID: navigation.currentWindowRef?.windowID,
            image: { previews.image(root: store.root, workspaceID: scope, windowID: $0) },
            caption: { id in NativeWorkspaceWindowsOverview.caption(course: courseTitle, titles: (navigation.window(.init(workspaceID: scope, windowID: id))?.layout.groups ?? []).compactMap { navigation.document($0.activeID)?.title }) },
            select: { id in changeWindow { _ = navigation.selectWindow(.init(workspaceID: scope, windowID: id)) } },
            add: { changeWindow { _ = navigation.createWindow() } },
            rename: { id, name in persistWindowMetadata { _ = navigation.renameWindow(.init(workspaceID: scope, windowID: id), name: name) } },
            move: { id, index in persistWindowMetadata { _ = navigation.moveWindow(.init(workspaceID: scope, windowID: id), to: index) } },
            close: { closeWindow(.init(workspaceID: scope, windowID: $0)) },
            dismiss: { windowsOverviewOpen = false })
    }

    private func syncNavigationInstances() {
        store.documentDuplicateSourceIDs.merge(navigation.documentDuplicateSourceIDs) { _, latest in latest }
        store.pageNoteSourceTabIDs = navigation.pageNoteSourceTabIDs
    }

    private func persistWindowMetadata(_ change: () -> Void) {
        do { try navigation.performPersistedChange(to: navigationURL, change) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func setChromeMode(_ mode: NativeWorkspaceChromeMode) {
        // A removed address/formatting row must not retain keyboard focus.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        previews.invalidate()
        persistWindowMetadata { _ = navigation.setChromeMode(mode) }
    }

    private func toggleInspectorFromControls(width: CGFloat) {
        guard annotation.request == nil else { return }
        if !showsWorkspace || boardOverlayOpen {
            section = .library; auxiliary = nil; boardOverlayOpen = false
            openMaterialsRail(width: width)
        } else { toggleMaterialsRail(width: width) }
    }

    private func captureCurrentWindow() async {
        guard !windowsOverviewOpen, showsWorkspace, let ref = navigation.currentWindowRef else { return }
        _ = await previews.capture(root: store.root, workspaceID: ref.workspaceID, windowID: ref.windowID)
    }

    private func toggleWindowsOverview() {
        if windowsOverviewOpen { windowsOverviewOpen = false; return }
        guard !refused("toggleWindowsOverview"), navigation.currentWindowRef != nil else { return }
        busy = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                await captureCurrentWindow()
                section = .library; auxiliary = nil; boardOverlayOpen = false
                windowsOverviewOpen = true
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    /// The folder's windows as the sidebar lists them. Choosing or adding one there also leaves a tool screen,
    /// settings or the study board: the window asked for is the one on screen afterwards.
    private var sidebarWindowActions: NativeSidebarWindowActions {
        let scope = navigation.currentWindowRef?.workspaceID ?? ""
        return .init(
            select: { id in changeWindow(reveal: true) { _ = navigation.selectWindow(.init(workspaceID: scope, windowID: id)) } },
            add: { changeWindow(reveal: true) { _ = navigation.createWindow() } },
            rename: { id, name in persistWindowMetadata { _ = navigation.renameWindow(.init(workspaceID: scope, windowID: id), name: name) } },
            move: { id, index in persistWindowMetadata { _ = navigation.moveWindow(.init(workspaceID: scope, windowID: id), to: index) } },
            close: { closeWindow(.init(workspaceID: scope, windowID: $0)) })
    }

    private func changeWindow(reveal: Bool = false, _ change: @escaping () -> Void) {
        guard !refused("changeWindow") else { return }
        busy = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                await captureCurrentWindow()
                try navigation.performPersistedChange(to: navigationURL, change)
                syncNavigationInstances()
                windowsOverviewOpen = false
                if reveal { section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false }
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func closeWindow(_ ref: NativeWorkspaceWindowRef) {
        guard !refused("closeWindow"), let close = navigation.prepareWindowClose(ref) else { return }
        busy = true
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                var browserPlans: [NativeBrowserScopeClosePlan] = []
                for document in close.documents where document.kind == "browser" {
                    guard let plan = try await NativeBrowserSession.prepareScope(workspaceID: document.relativePath, host: services.browser, store: store) else { return }
                    browserPlans.append(plan)
                }
                try await store.flushDocuments()
                guard navigation.canCommitWindowClose(close) else {
                    throw DesktopRuntimeError("작업 화면이 변경되었습니다. 윈도우 닫기를 다시 시도해 주세요.")
                }
                let before = navigation.checkpoint()
                // Persist the proposed layout before destroying native browser pages.
                // There is no suspension between the atomic write and browser commit.
                do {
                    try navigation.performPersistedChange(to: navigationURL) {
                        guard navigation.commitWindowClose(close) else { throw DesktopRuntimeError("윈도우를 닫지 못했습니다.") }
                    }
                    guard try NativeBrowserSession.commitScopes(browserPlans, host: services.browser, store: store) else {
                        throw DesktopRuntimeError("웹페이지가 변경되었습니다. 닫기를 다시 시도해 주세요.")
                    }
                } catch {
                    navigation.restoreCheckpoint(before)
                    try navigation.save(to: navigationURL)
                    throw error
                }
                for id in close.documentIDs {
                    store.documentSelections[id] = nil; store.documentDuplicateSourceIDs[id] = nil
                    store.assistantDocumentIDs.remove(id)
                }
                syncNavigationInstances()
                try previews.remove(root: store.root, workspaceID: ref.workspaceID, windowID: ref.windowID)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }


    // Split from `body`: as one expression it exceeds the type checker's time limit in Release archives.
    private var workspaceChrome: some View {
        GeometryReader { geometry in
            let chrome = chromeLayout(width: geometry.size.width)
            // AI chat stays on screen while annotating so the document does not jump sideways.
            let aiVisible = showsWorkspaceChrome && navigation.active?.kind != "assistant" &&
                (chrome.aiPinned || !NativeWorkspaceChromeLayout.fitsAI(geometry.size.width) && compactAIRail)
            let aiHostWidth = chrome.aiPinned ? chrome.aiWidth : chrome.compactAIWidth
            let aiLeading = NativeDesktopTheme.navigationWidth + (chrome.leftPinned ? chrome.leftWidth + 1 : 0)
            let minimum = NativeWorkspaceChromeLayout.editorMinimum
            let rightVisible = showsWorkspaceChrome && annotation.request == nil &&
                (chrome.rightPinned || !NativeWorkspaceChromeLayout.fitsRight(geometry.size.width) && compactMaterialsRail)
            HStack(spacing: 0) {
                globalNavigation(width: geometry.size.width).zIndex(2)
                // The slot is cut at its sides, so the sidebar slides out of its own column and never passes
                // under the rail: rail glass over panel glass reads as a flat grey band for the whole slide.
                HStack(spacing: 0) {
                    if chrome.leftPinned {
                        HStack(spacing: 0) { courseSidebar.frame(width: chrome.leftWidth); railDivider }
                            .transition(.move(edge: .leading))
                    }
                }
                .mask { Rectangle().padding(.vertical, -400) }
                .zIndex(1)
                // Always mounted so a draft or streaming reply survives closing the column;
                // the width animates and the clipped content slides with it.
                HStack(spacing: 0) { aiRail.frame(width: aiHostWidth); railDivider }
                    .frame(width: aiVisible ? aiHostWidth + 1 : 0, alignment: .trailing)
                    // Cut at the sides only: the input capsule reaches below the home-indicator line.
                    .mask { Rectangle().padding(.bottom, -40) }
                    // Outside the clip, so the glass reaches under the home indicator like the other panels.
                    .background(NativeGlass.panel)
                    .allowsHitTesting(aiVisible && annotation.request == nil).accessibilityHidden(!aiVisible)
                // Editors and the inspector remain mounted while covered. Navigation
                // and opening a keyboard must not discard an in-progress draft.
                let covered = section != .library || auxiliary != nil || windowsOverviewOpen
                ZStack {
                    NativeWorkspacePreviewContainer(controller: previews, isInteractive: !covered) {
                    NativeDockWorkspace(navigation: navigation, store: store, content: { workspace($0) }, empty: { emptyWorkspace },
                        perform: transition, persist: saveNavigation, closeDocuments: closeDocuments,
                        materialsOpen: rightVisible,
                        toggleMaterials: { toggleMaterialsRail(width: geometry.size.width) },
                        openNewTab: openNewTab, covered: covered, select: selectTab,
                        chromeMode: navigation.chromeMode, controlInset: chrome.rightPinned ? 0 : NativeWorkspaceWindowControls.width + NativeWorkspaceWindowControls.trailing)
                        .environment(\.nativeWorkspacePreviewController, previews)
                        .environment(\.nativePDFPaletteHost, pdfPalette)
                    }
                        .opacity(covered && !settingsOpen ? 0 : 1).allowsHitTesting(!covered).accessibilityHidden(covered)
                    if windowsOverviewOpen || section == .settings {
                        EmptyView()
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
                // The page, note or web view runs to the window's bottom edge, under the home indicator.
                // The dock lays its documents out as cards on the glass; a tool screen over it keeps the plain paper.
                }.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea(.container, edges: .bottom)
                    .background(covered ? AnyShapeStyle(NativeGlass.paper) : AnyShapeStyle(NativeGlass.panel))
                if chrome.rightPinned {
                    railDivider
                    Color.clear.frame(width: chrome.rightWidth)
                }
            }
            .overlay {
                if chrome.leftPinned {
                    NativeDockRailResizer(side: .left, width: Binding(get: { chrome.leftWidth }, set: { courseRailWidth = $0 }), maximum: min(360, geometry.size.width - 48 - chrome.aiWidth - chrome.rightWidth - minimum - 3))
                        .frame(width: NativeDockRailResizer.hitWidth, height: geometry.size.height)
                        .position(x: NativeDockRailResizer.center(seam: 48 + chrome.leftWidth + 0.5, side: .left), y: geometry.size.height / 2)
                }
            }
            .overlay(alignment: .leading) {
                if compactCourseRail && !NativeWorkspaceChromeLayout.fitsLeft(geometry.size.width) && showsWorkspace && annotation.request == nil {
                    HStack(spacing: 0) {
                        courseSidebar.frame(width: min(320, geometry.size.width - 48))
                            // Over the paper, not the wallpaper: carry the window's stretch of the backdrop along, so the glass matches the pinned panel.
                            .background { NativeBackdropUnderlay(windowSize: geometry.size, safeArea: geometry.safeAreaInsets, leadingInset: NativeDesktopTheme.navigationWidth) }
                            .mask { Rectangle().padding(.vertical, -60) }
                            .nativeWorkspacePreviewExcluded(occludesContent: true)
                            .overlay(alignment: .trailing) { railDivider }
                            .transition(.move(edge: .leading))
                        Color.black.opacity(0.12).onTapGesture { setCourseRail(false, width: geometry.size.width) }
                    }.padding(.leading, NativeDesktopTheme.navigationWidth).clipped()
                }
            }
            .overlay(alignment: .trailing) {
                // A concrete stack keeps the drawer's drawing and hit region
                // aligned to the trailing edge when the backdrop appears.
                ZStack(alignment: .trailing) {
                    if rightVisible && !chrome.rightPinned {
                        Color.black.opacity(0.12).onTapGesture { setRail(.materials, open: false, width: geometry.size.width) }.transition(.opacity)
                    }
                    // One stable host, including while hidden, for file browsing.
                    inspectorSidebar
                        .frame(width: chrome.rightPinned ? chrome.rightWidth : chrome.compactRightWidth,
                               height: max(0, geometry.size.height - NativeWorkspaceWindowControls.inspectorTop))
                        .padding(.top, NativeWorkspaceWindowControls.inspectorTop)
                        .nativeWorkspacePreviewExcluded(occludesContent: !chrome.rightPinned && rightVisible, enabled: rightVisible)
                        .background(NativeGlass.panel)
                        // The drawer may float over the paper; the window's own stretch of backdrop keeps its glass the pinned panel's.
                        .background { NativeBackdropUnderlay(windowSize: geometry.size, safeArea: geometry.safeAreaInsets) }
                        .mask { Rectangle().padding(.vertical, -60) }
                        .overlay(alignment: .leading) { if rightVisible && !chrome.rightPinned { railDivider } }
                        // Off the window's edge while closed, and opaque on the way: a fade would show the wallpaper through the glass.
                        // It turns clear only once the slide is over, which is what takes its UIKit host out of the accessibility tree.
                        .offset(x: rightVisible ? 0 : (chrome.rightPinned ? chrome.rightWidth : chrome.compactRightWidth) + 1)
                        .animation(rightVisible ? nil : .linear(duration: 0.01).delay(0.45)) { $0.opacity(rightVisible ? 1 : 0) }
                        .allowsHitTesting(rightVisible).accessibilityHidden(!rightVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .overlay {
                if chrome.rightPinned {
                    NativeDockRailResizer(side: .right, width: Binding(get: { chrome.rightWidth }, set: { materialsRailWidth = max(320, $0) }), maximum: min(520, geometry.size.width - 48 - chrome.leftWidth - chrome.aiWidth - minimum - 3), resetWidth: 360)
                        .frame(width: NativeDockRailResizer.hitWidth, height: geometry.size.height)
                        .position(x: NativeDockRailResizer.center(seam: geometry.size.width - chrome.rightWidth - 0.5, side: .right), y: geometry.size.height / 2)
                }
            }
            // The PDF palette floats over the side panels; under a drawer, or beside another pane (whose bar it would cover), it stays inside its pane.
            .overlay { NativePDFPaletteLayer(host: pdfPalette, covered: compactCourseRail && !NativeWorkspaceChromeLayout.fitsLeft(geometry.size.width) || rightVisible && !chrome.rightPinned || navigation.groups.count > 1) }
            // Over the rail and both panels: the overview is the whole window (Figma 132:2517).
            .overlay { if windowsOverviewOpen { windowsOverview } }
            .overlay(alignment: .topTrailing) {
                NativeWorkspaceWindowControls(mode: navigation.chromeMode, overview: windowsOverviewOpen,
                    rightVisible: rightVisible, enabled: showsWorkspace && !boardOverlayOpen && workspaceContext != nil && !busy && annotation.request == nil,
                    changeMode: setChromeMode, toggleOverview: toggleWindowsOverview,
                    toggleInspector: { toggleInspectorFromControls(width: geometry.size.width) },
                    store: store, shareDocument: section == .library && auxiliary == nil ? navigation.active : nil)
                    .padding(.trailing, NativeWorkspaceWindowControls.trailing)
                    .padding(.top, NativeWorkspaceWindowControls.top)
                    .nativeWorkspacePreviewExcluded()
            }
            .overlay(alignment: .top) {
                if showBusy { ProgressView().padding(10).background(.regularMaterial, in: Capsule()).padding(.top, 48) }
            }
            .overlay(alignment: .bottom) { NativeSyncMoveNotice(store: store) { openSettings("sync") } }
            .overlay { NativeDocumentPreviewLayer(store: store) }
            // 새 노트: over the whole window, as the desktop app shows it; a tap outside or Esc cancels.
            .overlay { newNoteLayer(width: geometry.size.width) }
            .animation(.easeOut(duration: 0.16), value: newNoteGroupID != nil)
            // @AppStorage writes reach the view outside withAnimation's transaction,
            // so the slide is keyed on what is visible rather than on the toggles.
            // The left slot counts as one: the home sidebar and AI trade places at once, only opening and folding slide.
            .animation(Self.railAnimation, value: [chrome.leftPinned || aiVisible, rightVisible, chrome.rightPinned,
                                                   compactCourseRail && !NativeWorkspaceChromeLayout.fitsLeft(geometry.size.width)])
            .blur(radius: settingsOpen ? 4 : boardOverlayOpen ? 3 : 0)
            // Its own reader, clear of the keyboard: typing a task must not squeeze the popup.
            .overlay {
                if boardOverlayOpen {
                    GeometryReader { full in academicBoardOverlay(size: full.size, keyboard: max(0, full.size.height - geometry.size.height)) }
                        .ignoresSafeArea(.keyboard)
                }
            }
            .overlay {
                if settingsOpen {
                    // Figma Sheet/설정: 940 × 760, radius 20, the sheet glass; behind it black 18% over the blurred workspace.
                    let shape = RoundedRectangle(cornerRadius: 20)
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea().contentShape(Rectangle())
                            .onTapGesture { transition { section = .library } }.accessibilityHidden(true)
                        NativeSettingsWorkspace(store: store, initialCategory: settingsCategory) { transition { section = .library } }
                            .frame(maxWidth: 940, maxHeight: 760)
                            .clipShape(shape).contentShape(shape).bandalGlass(in: shape, fill: NativeGlass.sheet)
                            .padding(24)
                    // Centred in the window as drawn, not in what the home indicator leaves.
                    }.ignoresSafeArea(.container, edges: .vertical).transition(.opacity)
                }
            }
            .onAppear { updateWindowWidth(geometry.size.width) }
            // Typing a markdown note on the software keyboard: both side panels fold, and come back with the keyboard gone.
            .onReceive(NotificationCenter.default.publisher(for: NativeRichTextEditor.editingChanged)) { markdownEditing = $0.object as? Bool ?? false }
            .onReceive(NotificationCenter.default.publisher(for: NativePDFWorkspaceModel.textEditingChanged)) {
                pdfTextEditing = $0.object as? Bool ?? false; NativeKeyboardInset.shared.ignored = pdfTextEditing
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                guard Self.foldsPanelsOnKeyboard, markdownEditing, railsBeforeKeyboard == nil else { return }
                railsBeforeKeyboard = (courseRailOpen, materialsRailOpen)
                withAnimation(Self.railAnimation) { courseRailOpen = false; materialsRailOpen = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                guard let saved = railsBeforeKeyboard else { return }
                railsBeforeKeyboard = nil
                // The home sidebar and AI share the left slot: AI opened meanwhile keeps it.
                withAnimation(Self.railAnimation) { courseRailOpen = saved.0 && !aiRailOpen; materialsRailOpen = saved.1 }
            }
            .onChange(of: geometry.size.width) { _, width in updateWindowWidth(width) }
            .task(id: busy) {
                showBusy = false
                guard busy else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if busy { showBusy = true }
            }
        }
        // A keyboard that resized the window squeezed the whole workspace and exposed the backdrop behind it.
        .ignoresSafeArea(pdfTextEditing ? .keyboard : [], edges: .bottom)
        .font(NativeDesktopTheme.font(14))
        .foregroundStyle(NativeDesktopTheme.text)
        .background(NativeWorkspaceBackdrop())
        // The decor reaches every glass region from here, so the settings slider repaints the window as it moves.
        .environment(\.nativeDecor, NativeDecor(palette: .named(decorPalette), intensity: NativeDecor.clamp(decorIntensity)))
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        // Controls take the decor's accent (모노 keeps black and white).
        .tint(Color(uiColor: UIColor { [decorPalette] traits in NativeDecorPalette.named(decorPalette).accent(dark: traits.userInterfaceStyle == .dark) }))
        .toggleStyle(BandalToggleStyle())
        .environment(\.nativeWorkspacePreviewController, previews)
        .disabled(store.isApplyingExternalChanges)
        .modifier(NativeOnboardingCover(stage: onboarding, store: store, finish: closeOnboarding))
        .onReceive(NotificationCenter.default.publisher(for: NativeAccountRailButton.restartOnboarding)) { _ in onboarding = .showing }
        .overlay { NativeLongPressDimLayer() }
        .background(NativeWorkspaceKeyboardBridge(store: store))
        .background(NativePresentationAnchor(services: services).allowsHitTesting(false))
        .onAppear { NativeInputTrace.start(root: store.root) }
        .onChange(of: busy) { _, value in NativeInputTrace.record("workspace.busy", value ? "on" : "off") }
        .onChange(of: store.isApplyingExternalChanges) { _, value in NativeInputTrace.record("workspace.externalMutation", value ? "on (whole window disabled)" : "off") }
    }

    var body: some View {
        workspaceChrome
        .bandalToast(Binding(get: { store.errorMessage }, set: { store.errorMessage = $0 }))
        .bandalToast($shareNotice, symbol: "checkmark.circle.fill")
        .modifier(NativeReferralHost(referral: store.referral, ready: restored && onboarding == .closed, openSettings: openSettings))
        .task {
            await store.start()
            if onboarding == .pending || onboarding == .deciding { await decideOnboarding() }
            // Sync, auth and settings can wait for the restored tabs; the first screen cannot.
            defer { Task { @MainActor in
                await services.start()
                workspaceSettings = (try? await store.invoke("settings:get")) as? [String: Any] ?? [:]
            } }
            guard store.isReady, !restored else { return }
            navigation.openAdjacentTab = openAdjacentTab
            let catalog = (try? await store.invoke("learning:list", ["includeDeleted": false])) as? [String: Any] ?? [:]
            let projects: [NativeLearningSummary] = (try? NativeToolJSON.decode(catalog["projects"] ?? [])) ?? []
            var projectBindings: [String: NativeLearningBinding] = [:]
            for project in projects { if let id = project.projectId { projectBindings[id] = project.binding } }
            let existingCourseIDs = Set(store.courses.map(\.id))
            // The preference controls the initial selection, never whether the
            // persisted window collections and overwrite protection are loaded.
            await navigation.restore(from: navigationURL, projectBindings: projectBindings) { item in
                guard existingCourseIDs.contains(item.courseID) else { return false }
                if let target = item.learningTarget {
                    let channel = target.kind == .overview ? "learning:get" : target.kind == .article ? "learning:getArticle" : "learning:getArtifact"
                    return (try? await store.invoke(channel, ["binding": target.binding.request, "id": target.entityID])) != nil
                }
                if item.kind == "learning" { return (try? await store.invoke("learning:get", ["binding": ["courseId": item.courseID, "rootRelPath": item.relativePath]])) != nil }
                if item.isWorkspaceTool { return true }
                if item.kind == "whiteboard" { return (try? await store.invoke("canvas:get",["courseId":item.courseID,"id":item.relativePath])) != nil }
                return (try? await store.invokePrivate("nativeMaterial:path", ["courseId": item.courseID, "relPath": item.relativePath])) != nil
            }
            // Commit migrated window identities before previews or per-panel
            // state can be saved under them. The legacy bytes are backed up first.
            do { try navigation.persistPendingMigration(to: navigationURL) }
            catch { store.errorMessage = error.localizedDescription }
            if !restoreLastCourse { navigation.deactivateWorkspace() }
            syncNavigationInstances()
            if let error = navigation.persistenceError { store.errorMessage = error }
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
            openAIRail()
            store.assistantDocumentIDs.removeAll()
        }
        .onChange(of: section) { old, new in
            if old == .settings && new != .settings {
                store.events.send(NativeWorkspaceEvent(channel: "agent:changed", payload: [:]))
            }
        }
        .onChange(of: navigation.activeID) { _, _ in annotation.cancel() }
        .onChange(of: navigation.currentWindowRef) { _, _ in previews.invalidate(); syncNavigationInstances() }
        .onChange(of: navigation.documentDuplicateSourceIDs) { _, _ in syncNavigationInstances() }
        .onChange(of: windowsOverviewOpen) { _, value in
            services.browser.setPresentation(blocked: value, inputBlocked: value, overlays: [])
        }
        .onChange(of: annotation.completed?.id) { _, _ in receiveAnnotation() }
        .onChange(of: annotation.request?.id) { old, new in
            if old != nil && new == nil && restoreInspectorAfterAnnotation && showsWorkspace && !boardOverlayOpen { openAIRail() }
        }
        .onChange(of: openAdjacentTab) { _, value in navigation.openAdjacentTab = value }
        .onChange(of: store.courses) { _, _ in refreshShareDestinations(); refreshWorkspaceContext() }
        .onChange(of: store.materials) { _, _ in refreshShareDestinations() }
        .onReceive(store.events) { event in
            receive(event)
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if store.isReady { _ = try? await store.invokePrivate("nativeRuntime:active", ["active": phase == .active]) }
                if phase == .background { await flushInBackground() }
                if phase == .active { await importSharedMaterials(); store.referral.resume() }
            }
        }
        .onOpenURL(perform: receiveURL)
    }

    /// A file handed to the app is imported. A web address is a universal link, never a file, and
    /// only an invite link does anything.
    private func receiveURL(_ url: URL) {
        if url.scheme?.lowercased() == "https" { store.referral.open(url); return }
        Task {
            do { try await store.importFiles([url], parentPath: workspaceContext?.rootRelPath ?? "") }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    /// Onboarding for a new user; someone who already has a school or a course never sees it.
    private func decideOnboarding() async {
        // Storage did not open: nothing is known about this user, so ask again on the next launch.
        guard store.isReady, let settings = try? await store.invoke("settings:get") as? [String: Any] else { onboarding = .closed; return }
        guard NativeOnboardingGate.shouldShow(settings: settings, hasCourses: !store.courses.isEmpty) else { closeOnboarding(); return }
        // The first screen is already in the language it offers.
        let language = NativeOnboardingGate.language(saved: settings["locale"])
        UserDefaults.standard.set(language, forKey: NativeAppLocale.key)
        if settings["locale"] as? String != language {
            do { _ = try await store.invoke("settings:set", ["locale": language]) }
            catch { store.errorMessage = error.localizedDescription }
        }
        onboarding = .showing
    }
    private func closeOnboarding() {
        UserDefaults.standard.set(true, forKey: NativeOnboardingGate.doneKey)
        onboarding = .closed
    }

    private func importSharedMaterials() async {
        let report = await shareInbox.synchronize(using: store)
        if !report.failures.isEmpty { store.errorMessage = report.failures.joined(separator: "\n") }
        // Arrived quietly before: say what came in.
        else if report.importedCount > 0 { shareNotice = String(format: NativeAppLocale.string("공유한 자료 %lld개를 추가했어요", Locale.current), report.importedCount) }
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
                NativeLearningDocumentWorkspace(store: store, document: document, onOpenDocument: { openCapturedDocument($0, target: navigation.target(containing: document.id)) }, onOpenBrowser: openBrowserURL)
            } else if document.kind == "assistant" {
                // AI as a full tab: one centred column on the paper glass, no side panel.
                NativeAssistantWorkspace(store: store, workspaceID: document.relativePath, courseID: document.courseID, sourceDocument: nil, fullTab: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain).accessibilityIdentifier("native-ai-tab")
            } else if document.kind == "learning-home" {
                // A tab saved by an older version: the folders it listed are in the sidebar now.
                VStack(spacing: 14) {
                    Text("폴더 목록은 왼쪽 사이드바에 있어요").font(NativeDesktopTheme.font(15)).foregroundStyle(NativeDesktopTheme.secondary)
                    Button("사이드바 열기") { setCourseRail(true, width: windowWidth) }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if document.kind == "learning" {
                NativeLearningWorkspace(store: store, binding: NativeLearningBinding(courseID: document.courseID, rootRelPath: document.relativePath), onOpenDocument: { openCapturedDocument($0, target: navigation.target(containing: document.id)) }, onOpenBrowser: openBrowserURL, panelID: document.id)
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
        }.environment(\.nativeWorkspaceTarget, navigation.target(containing: document.id))
            .allowsHitTesting(annotation.request == nil || annotation.request?.documentID == document.id)
            .id(store.reloadIdentity(for:document))
    }

    /// The line sits on the panel's glass; alone it would show the raw backdrop.
    private var railDivider: some View { NativeGlass.hairline.frame(width: 1).background(NativeGlass.panel) }
    private static let railAnimation = Animation.spring(response: 0.32, dampingFraction: 0.88)
    private enum Rail { case course, ai, materials }
    private func chromeLayout(width: CGFloat) -> NativeWorkspaceChromeLayout {
        NativeWorkspaceChromeLayout(width: width, leftOpen: courseRailOpen, rightOpen: materialsRailOpen && annotation.request == nil,
            aiOpen: aiRailOpen, leftRequested: courseRailWidth, rightRequested: materialsRailWidth,
            showsWorkspace: showsWorkspaceChrome)
    }
    private func fitsAlone(_ rail: Rail, width: CGFloat) -> Bool {
        switch rail {
        case .course: NativeWorkspaceChromeLayout.fitsLeft(width)
        case .ai: NativeWorkspaceChromeLayout.fitsAI(width)
        case .materials: NativeWorkspaceChromeLayout.fitsRight(width)
        }
    }
    private func railIsOpen(_ rail: Rail) -> Bool {
        switch rail { case .course: courseRailOpen; case .ai: aiRailOpen; case .materials: materialsRailOpen }
    }
    /// Pinned rails push the editor. Opening one closes the others, in this
    /// order, until the editor keeps its minimum width; narrow windows use drawers.
    private func setRail(_ rail: Rail, open: Bool, width: CGFloat) {
        // The home sidebar and AI trading the left slot is a swap, not a fold.
        let swap = fitsAlone(rail, width: width) && open && (rail == .ai && courseRailOpen || rail == .course && aiRailOpen)
        withAnimation(swap ? nil : Self.railAnimation) {
            guard fitsAlone(rail, width: width) else {
                compactCourseRail = rail == .course && open
                compactAIRail = rail == .ai && open
                compactMaterialsRail = rail == .materials && open
                return
            }
            compactCourseRail = false; compactAIRail = false; compactMaterialsRail = false
            switch rail { case .course: courseRailOpen = open; case .ai: aiRailOpen = open; case .materials: materialsRailOpen = open }
            // The home sidebar and AI share the left slot: opening one replaces the other,
            // and closing the open one folds the slot.
            if open { if rail == .ai { courseRailOpen = false } else if rail == .course { aiRailOpen = false } }
            guard open else { return }
            let minimum: [Rail: Double] = [.course: NativeWorkspaceChromeLayout.leftMinimum, .ai: NativeWorkspaceChromeLayout.aiMinimum,
                                           .materials: NativeWorkspaceChromeLayout.rightMinimum]
            let closeOrder: [Rail] = switch rail { case .course: [.materials, .ai]; case .ai: [.materials, .course]; case .materials: [.ai, .course] }
            var opened = [Rail.course, .ai, .materials].filter(railIsOpen)
            for other in closeOrder where !NativeWorkspaceChromeLayout.fits(opened.compactMap { minimum[$0] }, in: width) && opened.contains(other) {
                opened.removeAll { $0 == other }
                switch other { case .course: courseRailOpen = false; case .ai: aiRailOpen = false; case .materials: materialsRailOpen = false }
            }
        }
    }
    private func railVisible(_ rail: Rail, width: CGFloat) -> Bool {
        let chrome = chromeLayout(width: width)
        switch rail {
        case .course: return fitsAlone(.course, width: width) ? chrome.leftPinned : compactCourseRail
        case .ai: return fitsAlone(.ai, width: width) ? chrome.aiPinned : compactAIRail
        case .materials: return fitsAlone(.materials, width: width) ? chrome.rightPinned : compactMaterialsRail
        }
    }
    private func setCourseRail(_ open: Bool, width: CGFloat) { setRail(.course, open: open, width: width) }
    private func toggleCourseRail(width: CGFloat) { setRail(.course, open: !railVisible(.course, width: width), width: width) }
    private func toggleMaterialsRail(width: CGFloat) { setRail(.materials, open: !railVisible(.materials, width: width), width: width) }
    private func openMaterialsRail(width: CGFloat) { setRail(.materials, open: true, width: width) }
    private func toggleAIRail(width: CGFloat) { setRail(.ai, open: !railVisible(.ai, width: width), width: width) }
    private func updateWindowWidth(_ width: CGFloat) {
        if hasWindowWidth {
            let fitsRight = NativeWorkspaceChromeLayout.fitsRight
            if fitsRight(windowWidth) && !fitsRight(width) { compactMaterialsRail = materialsRailOpen; compactCourseRail = false; compactAIRail = false }
            if !fitsRight(windowWidth) && fitsRight(width) { materialsRailOpen = compactMaterialsRail; compactMaterialsRail = false }
            if NativeWorkspaceChromeLayout.fitsLeft(windowWidth) != NativeWorkspaceChromeLayout.fitsLeft(width) { compactCourseRail = false }
            if NativeWorkspaceChromeLayout.fitsAI(windowWidth) != NativeWorkspaceChromeLayout.fitsAI(width) { compactAIRail = false }
        }
        windowWidth = width; hasWindowWidth = true
    }
    /// AI chat lives in its own column right of the course rail.
    private func openAIRail() {
        section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false
        setRail(.ai, open: true, width: windowWidth)
    }
    private func globalNavigation(width: CGFloat) -> some View {
        VStack(spacing: Self.railSpacing) {
            NativeChromeButton(title: "홈", symbol: "house", selected: showsWorkspace && railVisible(.course, width: width),
                               selectedFill: Self.railSelected, selectedInset: 3, selectedRadius: 11, joinsPanel: chromeLayout(width: width).leftPinned) {
                if showsWorkspace { if NativeLocalPreferences.bool(NativeLocalPreferences.homeTogglesSidebar) || !railVisible(.course, width: width) { toggleCourseRail(width: width) } } else {
                    transition {
                        section = .library; auxiliary = nil; learningHome = false
                        setCourseRail(true, width: width)
                    }
                }
            }.accessibilityIdentifier("native-section-library").padding(.bottom, 3)
            NativeChromeButton(title: !railVisible(.ai, width: width) ? "AI 열기" : NativeLocalPreferences.bool(NativeLocalPreferences.homeTogglesSidebar) ? "AI 닫기" : "AI", symbol: "sparkles", selected: showsWorkspace && railVisible(.ai, width: width),
                               selectedFill: Self.railSelected, selectedInset: 3, selectedRadius: 11, joinsPanel: chromeLayout(width: width).aiPinned && !(chromeLayout(width: width).leftPinned && railVisible(.course, width: width))) {
                // The same rule as the home button: another panel in the slot is replaced, the open one folds.
                if showsWorkspace { if NativeLocalPreferences.bool(NativeLocalPreferences.homeTogglesSidebar) || !railVisible(.ai, width: width) { toggleAIRail(width: width) } } else { transition { openAIRail() } }
            }.accessibilityIdentifier("native-ai-rail-toggle")
            NativeChromeButton(title: "학업 보드", symbol: "rectangle.split.3x1", selected: boardOverlayOpen, selectedFill: Self.railSelected, selectedInset: 3, selectedRadius: 11) { toggleAcademicBoard() }.accessibilityIdentifier("native-section-planner")
            if NativeReleaseFlags.showsMarketplace {
                NativeChromeButton(title: "마켓플레이스", symbol: "storefront", selected: auxiliary == .marketplace, selectedFill: Self.railSelected, selectedInset: 3, selectedRadius: 11) { transition { section = .library; auxiliary = .marketplace; learningHome = false } }.accessibilityIdentifier("native-section-marketplace")
            }
            Spacer(minLength: 8)
            if NativeReleaseFlags.showsAccount {
                NativeAccountRailButton(store: store, openSettings: openSettings,
                    openHelp: { transition { section = .library; auxiliary = .help; learningHome = false } }).padding(.bottom, 1)
            }
            NativeChromeButton(title: "설정", symbol: "gearshape", selected: section == .settings, selectedFill: Self.railSelected, selectedInset: 3, selectedRadius: 11) { openSettings("general") }.accessibilityIdentifier("native-section-settings")
        }.padding(.top, Self.railTop).padding(.bottom, 10).frame(width: NativeDesktopTheme.navigationWidth)
            // The open panel's button is a tab of that panel: the rail's glass is cut away behind it.
            .background {
                let layout = chromeLayout(width: width)
                let home = showsWorkspace && layout.leftPinned && railVisible(.course, width: width)
                let ai = showsWorkspace && layout.aiPinned && railVisible(.ai, width: width) && !home
                NativeRailSurface(tabCenter: home ? Self.railTop + 22 : ai ? Self.railTop + 44 + 3 + Self.railSpacing + 22 : nil, reachesTop: home)
            }
    }
    /// Icon centres at 29 / 80 / 128 below the status bar: 44 pt buttons, the home button 3 pt further from the next.
    private static let railSpacing: CGFloat = 4
    private static var railTop: CGFloat { 7 + NativeDockHeaderMetrics.statusBand }
    /// A lit rail button with no panel beside it.
    private static let railSelected = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.12) : UIColor.white.withAlphaComponent(0.85) })
    private var courseSidebar: some View {
        VStack(spacing: 0) {
            NativeReferralBanner(store: store)
            // Sites as tiles: the school's essentials, then what the browser visits most; pinned ones first.
            NativeHomeSiteTiles(store: store, settings: workspaceSettings, onOpenURL: openBrowserURL, onOpenSettings: openSettings)
            NativeGlass.hairline.frame(height: 1)
            // 과목 and 프로젝트 are one list of folders.
            NativeCourseSidebar(store: store, navigation: navigation, settings: workspaceSettings, onSelect: changeCourse,
                onCreate: createCourse, onOpenSettings: openSettings,
                onOpenURL: openBrowserURL, onOpenAIWeb: openAIWeb, descriptor: favoriteDescriptor, onOpenFavorite: openFavorite,
                selectedContextID: workspaceContext?.id, onOpenProject: changeWorkspace, windowActions: sidebarWindowActions)
                .padding(.top, 12)
        // The glass runs to the top edge; what is on it starts under the status bar.
        }.padding(.top, NativeDockHeaderMetrics.statusBand).background(NativeGlass.panel)
    }
    private func toggleAcademicBoard() {
        transition {
            if section == .settings { section = .library }
            boardOverlayOpen.toggle()
        }
    }
    /// The study board as a popup over the blurred workspace: 1200 × 880 in a 13-inch landscape window, 940 × 1180 in portrait.
    /// `keyboard` is how far the keyboard reaches up into `size`.
    private func academicBoardOverlay(size: CGSize, keyboard: CGFloat) -> some View {
        let height = min(max(1, size.height - 144), 1180), shape = RoundedRectangle(cornerRadius: 28)
        // A window too short for the full height sits 6 pt low, clear of the top-trailing window controls.
        let drop: CGFloat = height < 1180 ? 6 : 0
        return ZStack {
            Color(uiColor: UIColor { UIColor.black.withAlphaComponent($0.userInterfaceStyle == .dark ? 0.45 : 0.22) }).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { transition { boardOverlayOpen = false } }.accessibilityHidden(true)
            NativePlannerWorkspace(store: store, keyboardInset: max(0, keyboard - (size.height - height) / 2 + drop), onClose: { transition { boardOverlayOpen = false } })
                .frame(width: min(max(1, size.width - 84), 1200), height: height)
                // The sheet is drawn 93% opaque: most of that is a fill, and the glass shows through the rest.
                .clipShape(shape).bandalGlass(in: shape, fill: NativeGlass.sheet)
                .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("native-board-overlay")
                .padding(.top, 2 * drop)
        }.frame(width: size.width, height: size.height)
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
            openAIRail()
        }
    }
    private func openSettings(_ category: String) {
        transition { windowsOverviewOpen = false; boardOverlayOpen = false; settingsCategory = category; section = .settings; auxiliary = nil }
        // Settings may already be open on that category and moved on; pick it again.
        store.events.send(.init(channel: "nativeSettings:select", payload: ["category": category]))
    }
    private func favoriteDescriptor(_ document: NativeDocumentReference) -> [String: Any]? {
        let url = document.kind == "browser" ? NativeBrowserSession.currentPage(workspaceID: document.relativePath, store: store, host: services.browser)?.url : nil
        return NativeSidebarDescriptor.document(document, browserURL: url, conversationID: NativeToolSelection.conversationID(workspaceID: document.relativePath, root: store.root), recordingID: NativeToolSelection.recordingID(workspaceID: document.relativePath, courseID: document.courseID))
    }
    private func openAIWeb(_ shortcut: NativeAIWebShortcut) {
        let candidates = (navigation.currentWindowRef.map { navigation.documents(in: $0) } ?? []).filter { document in
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
            let favoriteScope = payload["tabId"] as? String ?? ""
            if let existing = (navigation.currentWindowRef.map { navigation.documents(in: $0) } ?? []).first(where: { $0.kind == "browser" && $0.relativePath == favoriteScope }) { open(existing); return }
            let scope = UUID().uuidString
            guard let course else { openBrowserURL(url); return }
            let document = NativeDocumentReference(courseID: course, relativePath: scope, title: favorite.label, kind: "browser")
            store.pendingBrowserURLs[scope] = url; open(document); return
        }
        if favorite.kind == "learning", let course {
            if let root = payload["rootRelPath"] as? String { openLearning(.init(courseID: course, rootRelPath: root)) }
            else { open(.init(courseID: course, relativePath: "favorite-" + favorite.id, title: "학습 공간", kind: "learning-home")) }
            return
        }
        if favorite.kind == "recording", !NativeReleaseFlags.showsRecording { return }
        if favorite.kind == "chat", let course, let value = store.courses.first(where: { $0.id == course }) {
            Task { @MainActor in
                let context: NativeWorkspaceContext
                if let current = workspaceContext, current.courseID == course { context = current }
                else if value.workspaceKind == "study-space", let project = try? await NativeWorkspaceContext.loadProject(store: store, binding: .init(courseID: course, rootRelPath: "")) { context = project }
                else { context = .course(value) }
                if let conversation = payload["conversationId"] as? String { store.pendingAssistantConversationIDs[context.id] = conversation }
                if workspaceContext?.id != context.id { changeWorkspace(context) }
                openAIRail()
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
    /// Its own function, not written out in `workspaceChrome`: that expression is already near what the type
    /// checker gets through in a Release archive.
    @ViewBuilder private func newNoteLayer(width: CGFloat) -> some View {
        if let groupID = newNoteGroupID {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea().onTapGesture { newNoteGroupID = nil }.accessibilityHidden(true)
                NativeNewNoteSheet(cancel: { newNoteGroupID = nil }) { options in
                    newNoteGroupID = nil
                    openNewTab(.note, groupID, note: options)
                }
                .padding(24).frame(width: min(440, width - 32))
                .background(NativeGlass.sheet, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(NativeGlass.rim) }
                .shadow(color: .black.opacity(0.22), radius: 30, y: 14)
                .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("native-new-note-sheet")
            }.transition(.opacity)
        }
    }
    private func openNewTab(_ action: NativeNewTabAction, _ groupID: String) {
        // A handwriting note starts with its paper: the sheet asks first, then comes back with the answer.
        if action == .note {
            guard !refused("openNewTab") else { return }
            newNoteGroupID = groupID; return
        }
        openNewTab(action, groupID, note: nil)
    }
    private func openNewTab(_ action: NativeNewTabAction, _ groupID: String, note: NativeNewNoteOptions?) {
        guard !refused("openNewTab") else { return }; busy = true
        // AI as a tab takes the whole pane; the side panel would show the same conversation twice.
        if action == .assistant { setRail(.ai, open: false, width: windowWidth) }
        let context = workspaceContext
        let target = navigation.captureTarget(groupID: groupID.isEmpty ? nil : groupID)
        let courseID = context?.courseID ?? store.selectedCourseID
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                guard let courseID else { throw DesktopRuntimeError("먼저 폴더를 만들거나 선택해 주세요.") }
                let document: NativeDocumentReference
                switch action {
                case .markdown(let title): document = try await store.createMarkdown(title: title ?? ((workspaceSettings["tabs"] as? [String: Any])?["markdownTitlePrefix"] as? String ?? "새 마크다운"), courseID: courseID, parentPath: context?.rootRelPath ?? "")
                case .note:
                    // Notes are PDF notes, like the desktop: same paper, same palette, same sync.
                    let note = note ?? NativeNewNoteOptions(title: NativeNewNoteOptions.defaultTitle())
                    document = try await store.createNote(title: note.title, paper: note.paper.rawValue, orientation: note.orientation, courseID: courseID, parentPath: context?.rootRelPath ?? "")
                case .browser(let url):
                    document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "브라우저", kind: "browser")
                    if let url { store.pendingBrowserURLs[document.relativePath] = url }
                case .assistant: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "AI 대화", kind: "assistant")
                case .recording: document = .init(courseID: courseID, relativePath: UUID().uuidString, title: "녹음", kind: "recordings")
                }
                if let target {
                    guard navigation.open(document, target: target) != nil else { return }
                    syncNavigationInstances()
                    if navigation.currentWindowRef == target.ref { section = .library; auxiliary = nil; learningHome = false; windowsOverviewOpen = false }
                } else {
                    navigation.open(document, inGroup: groupID.isEmpty ? navigation.focusedGroupID : groupID, workspace: context)
                    section = .library; auxiliary = nil; learningHome = false
                }
                saveNavigation()
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func openBrowserURL(_ url: String) { openBrowserURL(url, destination: navigation.captureTarget()) }
    private func openBrowserURL(_ url: String, destination: NativeWorkspaceTarget?) {
        guard NativeSettingsSchema.webURL(url), let target = URL(string:url) else { return }
        if (workspaceSettings["browser"] as? [String: Any])?["linkRouting"] as? String == "system" {
            UIApplication.shared.open(target); return
        }
        if let destination {
            guard let course = navigation.courseID(for: destination.ref) else { return }
            let document = NativeDocumentReference(courseID: course, relativePath: UUID().uuidString, title: "브라우저", kind: "browser")
            store.pendingBrowserURLs[document.relativePath] = url
            openCapturedDocument(document, target: destination); return
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
    private var inspectorSidebar: some View {
        VStack(spacing: 0) {
            if let context = workspaceContext {
                NativeLibraryView(store: store, sourceTrayModel: librarySources, scope: context,
                    onOpenAI: openAIRail, selectedDocumentID: navigation.active?.storageID,
                    accessory: AnyView(NativeSettingsWidgetDock(store: store, services: services, availableHeight: 600)),
                    captureOpen: {
                        let target = navigation.captureTarget()
                        return { document in openCapturedDocument(document, target: target) }
                    }) { document in
                    compactMaterialsRail = false; open(document)
                }.id(context.id).frame(maxHeight: .infinity)
            } else { noWorkspacePlaceholder }
        }
    }
    private var aiRail: some View {
        VStack(spacing: 0) {
            if let context = workspaceContext {
                NativeAssistantPanel(store: store, context: context, sourceDocument: navigation.active,
                    attachments: pendingAttachments[context.id] ?? [],
                    onConsumeAttachments: { pendingAttachments[context.id] = nil },
                    onOpenDocument: openWorkspaceResult, onOpenSettings: openSettings, onAnnotate: beginAnnotation,
                    onClose: { setRail(.ai, open: false, width: windowWidth) }, surface: .clear)
                    .environment(\.nativeWorkspaceTarget, navigation.captureTarget())
                    .id(context.id)
            } else { noWorkspacePlaceholder }
        }.padding(.top, NativeDockHeaderMetrics.statusBand)
    }
    private var noWorkspacePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder").font(.largeTitle).foregroundStyle(NativeDesktopTheme.muted)
            Text("폴더를 선택하세요").font(NativeDesktopTheme.font(14))
            Text("자료와 AI 대화를 한 공간에서 이어가세요.").font(NativeDesktopTheme.font(12)).foregroundStyle(NativeDesktopTheme.muted)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if store.selectedCourseID == nil {
                // Nothing chosen yet: say what to do, and offer it.
                NativeBandalMark(size: 56, motion: .loop).foregroundStyle(NativeDecorMarkStyle())
                Text("폴더를 선택하거나 새로 만드세요").font(NativeDesktopTheme.font(15)).foregroundStyle(NativeDesktopTheme.secondary)
                Button { setCourseRail(true, width: windowWidth); NotificationCenter.default.post(name: NativeHomeTab.newCourse, object: nil) } label: {
                    Label("새 폴더 만들기", systemImage: "folder.badge.plus").font(NativeDesktopTheme.font(15, weight: .semibold))
                        .padding(.horizontal, 4).frame(minHeight: 44)
                }.buttonStyle(NativeThemedButtonStyle(prominent: true)).accessibilityIdentifier("native-empty-new-folder")
            }
            if store.selectedCourseID != nil {
                NativeHomeTab(store: store, courseTitle: courseTitle,
                    onOpen: open, onSelectCourse: changeCourse,
                    onNewNote: { openNewTab(UserDefaults.standard.string(forKey: NativeLocalPreferences.newDocumentKind) == "markdown" ? .markdown(title: nil) : .note, navigation.focusedGroupID ?? "") },
                    onNewCourse: { setCourseRail(true, width: windowWidth); NotificationCenter.default.post(name: NativeHomeTab.newCourse, object: nil) })
                    .bandalPopover(isPresented: $showingNewTabMenu, width: 300, radius: 18, padding: 0) {
                        NativeNewTabMenu(onAction: { action in
                            showingNewTabMenu = false
                            openNewTab(action, navigation.focusedGroupID ?? "")
                        }, onClose: { showingNewTabMenu = false })
                    }
            }
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func openTool(_ target: NativeWorkspaceSection, new: Bool = false) {
        if target == .assistant { openAIRail(); return }
        guard target != .library && target != .settings else { transition { section = target }; return }
        transition {
            guard let course = store.selectedCourseID else { section = target; return }
            if navigation.activeWorkspace == nil, let value = store.courses.first(where: { $0.id == course }) { navigation.activateWorkspace(.course(value)) }
            let document = (!new ? (navigation.currentWindowRef.map { navigation.documents(in: $0) } ?? []).first { $0.courseID == course && $0.kind == target.rawValue } : nil)
                ?? NativeDocumentReference(courseID: course, relativePath: UUID().uuidString, title: target.title, kind: target.rawValue)
            navigation.open(document, inGroup: navigation.focusedGroupID)
            section = .library; auxiliary = nil; learningHome = false
        }
    }
    private func openBeside(_ document: NativeDocumentReference, sourceID: String?) {
        guard let destination = sourceID.flatMap({ navigation.target(containing: $0) }) ?? (sourceID == nil ? navigation.captureTarget() : nil) else { return }
        Task { @MainActor in
            do {
                try await store.flushDocuments()
                guard navigation.window(destination.ref) != nil else { return }
                try navigation.performPersistedChange(to: navigationURL) {
                    var requested = document
                    if let sourceID, document.kind == "note" {
                        let matches = navigation.documents(in: destination.ref).filter { $0.storageID == document.storageID }
                        if let paired = matches.first(where: { navigation.pageNoteSourceTabIDs[$0.id] == sourceID }) { requested = paired }
                        else if let unpaired = matches.first(where: { navigation.pageNoteSourceTabIDs[$0.id] == nil }) { requested = unpaired }
                        else if let existing = matches.first {
                            requested = document.duplicated(); store.documentDuplicateSourceIDs[requested.id] = existing.id
                        }
                    }
                    if let opened = navigation.openBeside(requested, sourceID: sourceID, target: destination, reuseExisting: false), let sourceID, opened.kind == "note" {
                        navigation.pageNoteSourceTabIDs[opened.id] = sourceID
                    }
                    syncNavigationInstances()
                }
                if navigation.currentWindowRef == destination.ref {
                    section = .library; auxiliary = nil; learningHome = false; windowsOverviewOpen = false
                }
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    private func saveNavigation() {
        do { try navigation.save(to: navigationURL) }
        catch { store.errorMessage = error.localizedDescription }
    }

    private func createCourse(_ name: String) async throws {
        guard !busy else { throw DesktopRuntimeError("이전 작업을 마치는 중이에요. 잠시 뒤 다시 해 주세요.") }
        busy = true
        defer { finishWorkspaceTransition() }
        try await store.createCourse(name: name)
        if let course = store.courses.first(where: { $0.id == store.selectedCourseID }) { navigation.activateWorkspace(.course(course)) }
        section = .library; auxiliary = nil; learningHome = false; compactCourseRail = false; compactMaterialsRail = false
        try navigation.save(to: navigationURL)
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
            openAIRail()
            return
        }
        if document.kind == "learning-home" { setCourseRail(true, width: windowWidth); return }
        guard !refused("openInGroup") else { return }; busy = true
        let current = workspaceContext
        let target = navigation.captureTarget(groupID: groupID)
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
                if preserve, let target {
                    guard navigation.open(document, target: target) != nil else { return }
                } else { navigation.open(document, inGroup: groupID, workspace: context) }
                syncNavigationInstances()
                if !preserve || target?.ref == navigation.currentWindowRef {
                    section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false; windowsOverviewOpen = false
                }
                try navigation.save(to: navigationURL)
            } catch { store.errorMessage = error.localizedDescription }
        }
    }
    /// Long-running creation/import callbacks keep the window chosen at their start.
    private func openCapturedDocument(_ document: NativeDocumentReference, target: NativeWorkspaceTarget?) {
        guard let target else { open(document); return }
        Task { @MainActor in
            do {
                try await store.flushDocuments()
                guard navigation.window(target.ref) != nil else { return }
                try navigation.performPersistedChange(to: navigationURL) {
                    _ = navigation.open(document, target: target)
                    syncNavigationInstances()
                }
                if navigation.currentWindowRef == target.ref {
                    section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false; windowsOverviewOpen = false
                }
            } catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func changeCourse(_ id: String) {
        guard let course = store.courses.first(where: { $0.id == id }) else { return }
        changeWorkspace(.course(course))
    }
    private func changeWorkspace(_ context: NativeWorkspaceContext) {
        guard !refused("changeWorkspace") else { return }; busy = true
        restoreInspectorAfterAnnotation = false; annotation.cancel()
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do {
                try await store.flushDocuments()
                await captureCurrentWindow()
                windowsOverviewOpen = false
                await store.selectCourse(context.courseID)
                guard store.selectedCourseID == context.courseID else { return }
                navigation.activateWorkspace(context)
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
            } else {
                try await store.clearCourseSelection()
                navigation.deactivateWorkspace()
                setCourseRail(true, width: windowWidth)
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

    /// A request that arrives while another transition runs is dropped; the trace says which one.
    private func refused(_ request: String) -> Bool {
        if busy { NativeInputTrace.record("workspace.dropped", request) } else { NativeInputTrace.record("workspace.request", request) }
        return busy
    }
    private func finishWorkspaceTransition() {
        busy = false
        if pendingContextRefresh { refreshWorkspaceContext() }
    }

    /// The page already exists (window.opener must stay live), so it is placed
    /// directly rather than through a flushing transition that could refuse it.
    private func openBrowserChild(tabID: String, workspaceID: String, openerTabID: String, background: Bool) {
        let opener = navigation.documents.first { $0.kind == "browser" && openerTabID.hasPrefix(NativeBrowserSession.scopePrefix($0.relativePath)) }
        guard let opener, let child = navigation.openAfter(.init(courseID: opener.courseID, relativePath: workspaceID, title: "브라우저", kind: "browser"),
                                                          sourceID: opener.id, activate: !background) else { services.browser.destroy(tabID); return }
        syncNavigationInstances(); saveNavigation()
        if !background, navigation.target(containing: child.id)?.ref == navigation.currentWindowRef { section = .library; auxiliary = nil; learningHome = false }
    }
    private func closeDocuments(_ documentIDs: [String]) {
        guard !refused("closeDocuments") else { return }
        let windowRef = navigation.currentWindowRef
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
                guard navigation.currentWindowRef == windowRef else { return }
                let before = navigation.checkpoint()
                do {
                    try navigation.performPersistedChange(to: navigationURL) {
                        for document in documents { navigation.closeTab(document.id) }
                    }
                    guard try NativeBrowserSession.commitScopes(plans, host: services.browser, store: store) else {
                        throw DesktopRuntimeError("웹페이지가 변경되었습니다. 닫기를 다시 시도해 주세요.")
                    }
                } catch {
                    navigation.restoreCheckpoint(before); try navigation.save(to: navigationURL); throw error
                }
                for document in documents {
                    store.documentDuplicateSourceIDs[document.id] = nil
                    store.documentSelections[document.id] = nil
                    store.assistantDocumentIDs.remove(document.id)
                }
                syncNavigationInstances()
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
        guard !refused("transition") else { return }
        restoreInspectorAfterAnnotation = false; annotation.cancel()
        busy = true
        Task { @MainActor in
            defer { finishWorkspaceTransition() }
            do { try await store.flushDocuments(); compactCourseRail = false; compactMaterialsRail = false; compactAIRail = false; action(); try navigation.save(to: navigationURL) }
            catch { store.errorMessage = error.localizedDescription }
        }
    }

    private func receive(_ event: NativeWorkspaceEvent) {
        if ["learning:changed", "courses:changed"].contains(event.channel) { refreshWorkspaceContext() }
        if event.channel == "browser:open-url", let payload = event.payload as? [String: Any], let workspaceID = payload["workspaceId"] as? String,
           let tabID = payload["tabId"] as? String, let openerTabID = payload["openerTabId"] as? String {
            openBrowserChild(tabID: tabID, workspaceID: workspaceID, openerTabID: openerTabID, background: payload["background"] as? Bool == true); return
        }
        if event.channel == "nativeWorkspace:closeBrowserScope", let payload = event.payload as? [String: String], let workspaceID = payload["workspaceID"] {
            if let document = navigation.documents.first(where: { $0.kind == "browser" && $0.relativePath == workspaceID }) { closeDocuments([document.id]) }
            return
        }
        // A page closed itself (window.close). Handled here rather than in the
        // tab's session, which may not have started yet for a fast OAuth popup.
        if event.channel == "browser:close-tab", let payload = event.payload as? [String: Any], let tabID = payload["tabId"] as? String,
           let document = navigation.documents.first(where: { $0.kind == "browser" && tabID.hasPrefix(NativeBrowserSession.scopePrefix($0.relativePath)) }),
           !services.browser.pages.keys.contains(where: { NativeBrowserSession.owns($0, workspaceID: document.relativePath) }) {
            closeDocuments([document.id])
        }
        if event.channel == "nativeWorkspace:assistantRequest", let request = event.payload as? NativeAssistantRequest, let context = workspaceContext {
            store.pendingAssistantRequests[context.id] = request
            transition { openAIRail() }
            return
        }
        if event.channel == "nativeWorkspace:openSettings", let category = (event.payload as? [String: Any])?["category"] as? String { openSettings(category); return }
        if event.channel == "nativeWorkspace:openAssistantResult", let payload = event.payload as? [String: Any],
           let document = payload["document"] as? NativeDocumentReference {
            if let target = payload["nativeWorkspaceTarget"] as? NativeWorkspaceTarget { openCapturedDocument(document, target: target) }
            else { openWorkspaceResult(document) }; return
        }
        if event.channel == "nativeWorkspace:updateToolTitle", let payload = event.payload as? [String: Any],
           let workspaceID = payload["workspaceID"] as? String, let title = payload["title"] as? String {
            if navigation.updateToolTitle(workspaceID: workspaceID, title: title) { saveNavigation() }
            return
        }
        if event.channel == "settings:changed", let payload = event.payload as? [String: Any], let settings = payload["settings"] as? [String: Any] {
            workspaceSettings = settings
        }
        if event.channel == "nativeWorkspace:openBrowserURL", let payload = event.payload as? [String: Any], let url = payload["url"] as? String {
            openBrowserURL(url, destination: payload["nativeWorkspaceTarget"] as? NativeWorkspaceTarget ?? navigation.captureTarget()); return
        }
        if event.channel == "nativeWorkspace:openConversation", let value = event.payload as? [String: Any],
           let course = value["courseId"] as? String, let conversation = value["conversationId"] as? String, let listed = store.courses.first(where: { $0.id == course }) {
            // A conversation belongs to the course or project space it was held in.
            Task { @MainActor in
                let context: NativeWorkspaceContext
                if let root = value["rootRelPath"] as? String, let project = try? await NativeWorkspaceContext.loadProject(store: store, binding: .init(courseID: course, rootRelPath: root)) { context = project }
                else if let current = workspaceContext, current.courseID == course, current.kind != .project { context = current }
                else { context = .course(listed) }
                store.pendingAssistantMessageIDs[context.id] = value["messageId"] as? String
                store.pendingAssistantConversationIDs[context.id] = conversation
                if workspaceContext?.id != context.id { changeWorkspace(context) }
                openAIRail()
            }
            return
        }
        if event.channel == "nativeWorkspace:openDocument", let value = event.payload as? [String: Any],
           let course = value["courseId"] as? String, let path = value["relPath"] as? String {
            let document = NativeDocumentReference(courseID: course, relativePath: path, title: value["title"] as? String ?? (path as NSString).lastPathComponent, kind: value["kind"] as? String ?? "pdf")
            let sourceID = value["sourcePanelID"] as? String ?? value["besideTabID"] as? String
            let destination = value["nativeWorkspaceTarget"] as? NativeWorkspaceTarget ?? sourceID.flatMap { navigation.target(containing: $0) } ?? (sourceID == nil ? navigation.captureTarget() : nil)
            guard let destination else { return }
            Task { @MainActor in
                do {
                    try await store.flushDocuments()
                    guard navigation.window(destination.ref) != nil else { return }
                    let local = navigation.documents(in: destination.ref)
                    let requestedID = value["targetTabID"] as? String
                    let requested = local.first { $0.id == requestedID && $0.storageID == document.storageID }
                        ?? local.first { $0.storageID == document.storageID } ?? document
                    var opened: NativeDocumentReference?
                    try navigation.performPersistedChange(to: navigationURL) {
                        if let besideID = value["besideTabID"] as? String {
                            opened = navigation.openBeside(requested, sourceID: besideID, target: destination, reuseExisting: true)
                            if navigation.document(besideID)?.kind == "note", let opened, opened.kind == "pdf" {
                                navigation.pageNoteSourceTabIDs[besideID] = opened.id
                            }
                        } else { opened = navigation.open(requested, target: destination) }
                        syncNavigationInstances()
                    }
                    guard let opened else { return }
                    if let page = value["page"] as? Int, page > 0 {
                        if opened.kind == "pdf" {
                            var preferences = NativePDFWorkspacePreferences.load(root: store.root, documentID: opened.id)
                            preferences.pendingPage = page
                            preferences.save(root: store.root, documentID: opened.id)
                            if let highlight = value["highlight"] as? [String: Any] { store.pendingPDFHighlights[opened.id] = highlight.merging(["page": page]) { _, new in new } }
                        }
                        store.events.send(.init(channel: "nativeWorkspace:goToPage", payload: ["courseId": course, "relPath": path, "page": page, "tabID": opened.id]))
                    }
                    if navigation.currentWindowRef == destination.ref {
                        section = .library; auxiliary = nil; learningHome = false; boardOverlayOpen = false; windowsOverviewOpen = false
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
            if windowsOverviewOpen { return }
            let browserLocal = ["new-tab", "close-tab", "prev-tab", "previous-tab", "next-tab", "activate-last-tab"].contains(action) || action.hasPrefix("activate-tab-")
            if payload["webContentsId"] != nil && browserLocal { return }
            switch action {
            case "new-ai-tab": openTool(.assistant, new: true)
            case "new-recording-tab": if NativeReleaseFlags.showsRecording { openTool(.recordings, new: true) }
            case "open-study-board": toggleAcademicBoard()
            case "toggle-left-rail":
                toggleCourseRail(width: windowWidth)
            case "toggle-right-rail": toggleMaterialsRail(width: windowWidth)
            case "close-tab": if let id = navigation.activeID { closeDocuments([id]) }
            case "new-tab":
                if store.selectedCourseID == nil { openTool(.browser, new: true) }
                else if let group = navigation.focusedGroupID, !navigation.documents.isEmpty {
                    // The dock's + must be on screen to anchor its menu: come back to the workspace first.
                    if !showsWorkspace { transition { section = .library; auxiliary = nil; learningHome = false } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (showsWorkspace ? 0 : 0.4)) { store.events.send(.init(channel: "nativeDock:newTab", payload: ["groupID": group])) }
                }
                else { if !showsWorkspace { transition { section = .library; auxiliary = nil; learningHome = false } }; showingNewTabMenu = true }
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
