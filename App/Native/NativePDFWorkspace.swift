import SwiftUI
import UIKit
import Combine

/// Native document chrome. The UIKit body below is the existing PDFKit/Metal
/// compositor; neither this view nor its persistence owner instantiates WKWebView.
struct NativePDFWorkspace: View {
    @StateObject private var model: NativePDFWorkspaceModel
    @Environment(\.nativeEditorVisible) private var visible
    @Environment(\.nativeWorkspaceChromeMode) private var chromeMode
    @Environment(\.nativeWorkspaceControlInset) private var controlInset
    @Environment(\.nativeWorkspaceTopInset) private var topInset
    private let tabID: String

    init(document: NativeDocumentReference, store: NativeWorkspaceStore, onOpenDocument: ((NativeDocumentReference) -> Void)? = nil) {
        tabID = document.id
        _model = StateObject(wrappedValue: NativePDFWorkspaceModel(document: document, store: store, onOpenDocument: onOpenDocument))
    }
    var body: some View {
        VStack(spacing: 0) {
            // A hidden retained tab keeps its model and UIKit body but no chrome:
            // its controls must not answer accessibility queries meant for the visible tab.
            if visible {
                if model.assistantAnnotation != nil {
                    NativeAnnotationToolbar(coordinator: model.annotationCoordinator,
                        regionMode: Binding(get: { model.assistantRegionMode }, set: { model.setAssistantRegionMode($0) }),
                        busy: model.assistantCapturing, attachText: model.attachAssistantText)
                        .padding(.trailing, controlInset).padding(.top, topInset)
                } else {
                    NativePDFToolbar(model: model, writingOnly: chromeMode == .toolsHidden)
                        .padding(.trailing, controlInset).padding(.top, topInset)
                }
            }
            if !model.sourceQuote.isEmpty, visible, model.assistantAnnotation == nil {
                HStack(spacing: 12) {
                    Text(model.sourceQuote).font(.callout).lineLimit(1)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(NativePDFWorkspaceModel.annotationColors, id: \.name) { item in
                            Button(item.label) { model.highlightSource(color: item.name) }.accessibilityIdentifier("native-pdf-highlight-" + item.name)
                        }
                    } label: { Label("형광 표시", systemImage: "highlighter").frame(minHeight: 44) }
                        .accessibilityIdentifier("native-pdf-highlight-source")
                    Button("메모") { model.commentSource() }.frame(minHeight: 44).accessibilityIdentifier("native-pdf-comment-source")
                    Button { model.clearSourceSelection() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("원문 선택 해제")
                }.padding(.horizontal, 16).background(.bar).disabled(model.isBusy || model.errorMessage != nil)
            }
            if let draft = model.textEditorDraft {
                NativePDFTextEditor(draft: draft, isBusy: model.isBusy, errorMessage: model.errorMessage, canCancel: !model.textSaveNeedsRecovery,
                    onSave: model.finishText, onCancel: model.cancelText, onDelete: model.deleteText)
            }
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if model.showPages && visible {
                        NativePDFPagesPanel(model: model).frame(width: geometry.size.width < 700 ? 128 : 160)
                        Divider()
                    }
                    ZStack {
                        NativePDFBody(model: model, visible: visible).accessibilityIdentifier(visible ? "native-pdf-workspace" : "").allowsHitTesting(!model.showStyle)
                            .nativeWorkspacePreviewSurface(id: tabID, capture: { try await model.workspacePreview() })
                        if model.isLoading {
                            ProgressView("문서 여는 중…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            if model.assistantAnnotation != nil, model.assistantRegionMode {
                                NativeAnnotationRegionOverlay(selected: model.captureAssistantViewport)
                            }
                        }
                        .overlay { if model.showStyle { NativePDFPaletteOverlay(model: model) } }
                        .overlay { if model.assistantAnnotation == nil, model.hasSelectionMenu, let frame = model.selectionFrame { NativePDFSelectionBar(model: model, frame: frame) } }
                    if model.showAnnotations && visible {
                        Divider()
                        NativePDFAnnotationRail(model: model).frame(width: geometry.size.width < 700 ? 220 : 280)
                    }
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in model.setAvailableWidth(width) }
            }
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button("다시 저장") { model.retry() }.buttonStyle(.bordered)
                        .disabled(model.isBusy).accessibilityIdentifier("native-pdf-retry")
                }
                .padding(12).background(.bar)
            }
        }
        .onChange(of: visible, initial: true) { _, value in model.setVisible(value) }
        .background(NativeDesktopTheme.bgApp)
        .accessibilityElement(children: .contain).accessibilityIdentifier(visible ? "native-pdf-pane-" + tabID : "")
        .sheet(isPresented: $model.showAnnotationEditor, onDismiss: { model.dismissAnnotation() }) {
            NavigationStack {
                Form {
                    Section("선택한 원문") { Text(model.annotationQuote).textSelection(.enabled) }
                    Section("형광 색") {
                        Picker("색", selection: $model.annotationColor) {
                            ForEach(NativePDFWorkspaceModel.annotationColors, id: \.name) { item in Text(item.label).tag(item.name) }
                        }.pickerStyle(.segmented)
                    }
                    Section("메모") {
                        TextEditor(text: $model.annotationComment).frame(minHeight: 140).accessibilityIdentifier("native-pdf-annotation-editor")
                    }
                    if model.editingAnnotation {
                        Section { Button("주석 삭제", role: .destructive) { model.deleteAnnotation() }.accessibilityIdentifier("native-pdf-delete-annotation") }
                    }
                }
                .disabled(model.isBusy)
                .onChange(of: model.annotationComment) { _, _ in model.markDraftChanged() }
                .onChange(of: model.annotationColor) { _, _ in model.markDraftChanged() }
                .navigationTitle("원문 메모").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { model.cancelAnnotation() } }
                    ToolbarItem(placement: .confirmationAction) { Button("저장") { model.commitAnnotation() }.accessibilityIdentifier("native-pdf-save-annotation") }
                }
            }.presentationDetents([.medium, .large])
        }
        .alert("\(model.pageDeleteConfirmation ?? 1)페이지를 삭제할까요?", isPresented: Binding(get: { model.pageDeleteConfirmation != nil }, set: { if !$0 { model.pageDeleteConfirmation = nil } }), presenting: model.pageDeleteConfirmation) { number in
            Button("취소", role: .cancel) { model.pageDeleteConfirmation = nil }
            Button("삭제", role: .destructive) { model.confirmDeletePage(number) }.accessibilityIdentifier("native-pdf-confirm-page-delete")
        } message: { _ in
            Text("이 페이지의 필기와 주석도 함께 제거됩니다. 페이지 변경을 되돌리거나 변경 전 복구 사본을 만들 수 있습니다.")
        }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { model.mediaImportError != nil }, set: { if !$0 { model.mediaImportError = nil } })) {
            Button("확인") { model.mediaImportError = nil }
        } message: { Text(model.mediaImportError ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.saveInBackground() }
    }

}

@MainActor
final class NativePDFWorkspaceModel: ObservableObject {
    struct InkColor { let name: String, label: String; let color: Color }
    static let colors: [InkColor] = zip(NativePDFPenPreset.colors, ["먹색", "빨강", "주황", "노랑", "초록", "파랑", "보라"]).map {
        InkColor(name: $0.0, label: $0.1, color: Color(uiColor: NativePDFInkSurface.color($0.0)))
    }
    static let annotationColors: [InkColor] = [.init(name: "yellow", label: "노랑", color: .yellow), .init(name: "green", label: "초록", color: .green), .init(name: "blue", label: "파랑", color: .blue), .init(name: "pink", label: "분홍", color: .pink)]
    struct AnnotationItem: Identifiable { let id: String, page: Int, quote: String, comment: String, color: String }
    @Published var annotationItems: [AnnotationItem] = []
    @Published var annotationCount = 0
    @Published var sourceQuote = ""
    @Published var showAnnotationEditor = false
    @Published var showAnnotations = false
    @Published var showPages = false
    @Published var toolsExpanded = true
    @Published var zoom = 1.0
    @Published var opacity = NativePDFPenPreset.pen.opacity
    @Published var pageDeleteConfirmation: Int?
    @Published private(set) var thumbnailSource: NativePDFPageThumbnailSource?
    /// Per page, so a stroke on one page restarts only that thumbnail's render.
    @Published private(set) var thumbnailRevisions: [Int: Int] = [:]
    private var thumbnailDirtyPages = Set<Int>(), thumbnailRefreshTask: Task<Void, Never>?, thumbnailPageCounts: [Int: Int] = [:]
    private var thumbnailRowCache: [Int: (revision: Int, rows: [[String: Any]])] = [:]
    func thumbnailRows(_ page: Int) -> [[String: Any]] {
        let revision = thumbnailRevisions[page] ?? 0
        if let cached = thumbnailRowCache[page], cached.revision == revision { return cached.rows }
        let rows = displayRowsByPage[page] ?? []
        thumbnailRowCache[page] = (revision, rows); return rows
    }
    private func scheduleThumbnailRefresh(pages: Set<Int>) {
        thumbnailDirtyPages.formUnion(pages)
        guard showPages, thumbnailRefreshTask == nil else { return }
        thumbnailRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            self.thumbnailRefreshTask = nil
            for page in self.thumbnailDirtyPages { self.thumbnailRevisions[page, default: 0] += 1 }
            self.thumbnailDirtyPages = []
        }
    }
    @Published private(set) var pageCanRestructure = true
    @Published private(set) var pageHistoryCanUndo = false
    @Published private(set) var pageHistoryCanRedo = false
    @Published private(set) var pageHistoryCanRecover = false
    @Published private(set) var pageHistoryReason: String?
    @Published var draggedPage: Int?
    @Published var pageDropSlot: Int?
    private var pageRevision = ""
    private var pageUndoToken: String?, pageRedoToken: String?, pageRecoverToken: String?
    private var pageOperation: Task<Void, Never>?
    private final class PendingPageOperation {
        let channel: String, request: [String: Any], goTo: Int?
        var committedResult: [String: Any]?
        var viewStateSaved = false
        init(channel: String, request: [String: Any], goTo: Int?) {
            self.channel = channel; self.request = request; self.goTo = goTo
        }
    }
    private var pendingPageOperation: PendingPageOperation?
    private var availableWidth: CGFloat = 1000
    var dragIdentity: String { surfaceID + ":" + generation }
    var hasPageNoteAction: Bool { onOpenDocument != nil }
    private let onOpenDocument: ((NativeDocumentReference) -> Void)?
    @Published var annotationComment = ""
    @Published var annotationColor = "yellow"
    @Published var annotationQuote = ""
    @Published var editingAnnotation = false
    private var sourceSelection: [String: Any]?
    private var annotationDraft: [String: Any]?
    @Published var tool = "pen"
    @Published var color = "ink"
    @Published var width = NativePDFPenPreset.pen.width
    @Published var showStyle = false { didSet { if showStyle != oldValue { restoreInput() } } }
    @Published private(set) var favorites = NativePDFPalettePreferences().favorites
    @Published private(set) var shapeRecognitionEnabled = true
    var isInkTool: Bool { ["pen", "ballpoint", "highlighter"].contains(tool) }
    /// Ballpoint shares the pen favourites; only its width model differs.
    var isPenLike: Bool { tool == "pen" || tool == "ballpoint" }
    var quickWidths: [Double] { tool == "highlighter" ? NativePDFPaletteStyle.highlighterWidths : NativePDFPaletteStyle.penWidths }
    var currentPageWidthPoints: Double? { pageWidths.indices.contains(page - 1) ? pageWidths[page - 1] : nil }
    var currentPreset: NativePDFPenPreset { .init(color: color, width: width, opacity: opacity) }
    func widthLabel(for width: Double, highlighter: Bool? = nil) -> String {
        NativePDFPaletteStyle.widthLabel(width, highlighter: highlighter ?? (tool == "highlighter"), pageWidthPoints: currentPageWidthPoints)
    }
    var styleAccessibilityValue: String { "\(tool) \(color) \(widthLabel(for: width)) \(Int((opacity * 100).rounded()))%" }
    func favoriteAccessibilityValue(_ index: Int) -> String {
        guard favorites.indices.contains(index) else { return "" }
        let value = favorites[index]
        return "pen \(value.color) \(widthLabel(for: value.width, highlighter: false)) \(Int((value.opacity * 100).rounded()))%"
    }
    @Published var page = 1
    @Published var pageCount = 1
    @Published var isLoading = true
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var mediaImportError: String?
    @Published var pendingCount = 0
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var drawingCount = 0
    @Published private(set) var selectionCount = 0
    @Published private(set) var selectedText = false
    /// Selection box in the PDF body's coordinates, for the floating action bar.
    @Published private(set) var selectionFrame: CGRect?
    @Published private(set) var lassoMode = "freeform"
    @Published private(set) var canPaste = false
    @Published private(set) var selectedRegion: CGRect?
    @Published private(set) var pasteAnchor: CGPoint?
    @Published private(set) var isCopyingRegion = false
    @Published private(set) var isCopyingSelection = false
    private var selectionCopyTask: Task<Void, Never>?
    var hasSelectionMenu: Bool { selectionCount > 0 || selectedRegion != nil || pasteAnchor != nil }
    private var clipboardEvents: AnyCancellable?
    private var regionCopyTask: Task<Void, Never>?
    static let pasteboardType = "com.bandal.pdf-objects"
    @Published private(set) var textEditorDraft: NativePDFTextDraft?
    private var textInput: NativePDFTextInput?
    private var textEditorPage: Int?
    private var textEditorPresentedAt = CFAbsoluteTime(0)
    var textSaveNeedsRecovery: Bool { pendingTextSave != nil }
    var isAdditionalTool: Bool { ["lasso", "line", "arrow", "rect", "ellipse", "text"].contains(tool) }
    var additionalToolSymbol: String { ["lasso": "lasso", "line": "line.diagonal", "arrow": "arrow.up.right", "rect": "rectangle", "ellipse": "oval", "text": "textformat"][tool] ?? "square.on.circle" }
    @Published private(set) var assistantAnnotation: NativeAnnotationCoordinator.Request?
    @Published private(set) var assistantRegionMode = true
    @Published private(set) var assistantCapturing = false
    var annotationCoordinator: NativeAnnotationCoordinator { store.annotation }
    private var assistantOriginalTool: (tool: String, lasso: String, previous: String)?
    private var assistantSelectionStart: CGPoint?
    private var assistantCaptureTask: Task<Void, Never>?
    private var assistantEvents: AnyCancellable?
    private let document: NativeDocumentReference
    private let store: NativeWorkspaceStore
    private let defaults: UserDefaults
    private var preferences: NativePDFWorkspacePreferences
    private var host: NativePDFHost?
    private var persistence: NativePDFPersistence?
    private let surfaceID = UUID().uuidString
    /// A page operation reopens the same surface under a new generation.
    private var generation = UUID().uuidString
    private var visible = true
    private var opening: Task<Void, Error>?
    private var flushing: Task<Void, Error>?
    private var historyTask: Task<Void, Error>?
    private var editorTask: Task<Void, Error>?
    private var closing: Task<Void, Never>?
    private var registration: UUID?
    private var annotations: [[String: Any]] = []
    private var pageAspects: [Double] = []
    private var pageWidths: [Double] = []
    private var viewport: [String: Any] = ["page": 1, "zoom": 1.0]
    private var pendingViewportRestore: [String: Any]?
    private var pendingPageToAcknowledge: Int?
    private var layoutRevision = 0
    private var bounds = CGRect.zero
    private var opened = false, retired = false, writesSuspended = false
    private var setupComplete = false, exposed = false, blockedForError = false, materialMutating = false
    private var storeEvents: AnyCancellable?
    private var previousTool = "pen"
    private var savedPenStyle = NativePDFPenPreset.pen, savedHighlighterStyle = NativePDFPenPreset.highlighter, savedBallpointStyle = NativePDFPenPreset.ballpoint
    private var paletteEvents: AnyCancellable?
    private var snapshotTask: Task<Void, Error>?
    private var snapshotRequested = false
    private var drawingRevision = 0, publishedDrawingRevision = -1
    private var displayRows: [[String: Any]] = []
    private var displayRowsByPage: [Int: [[String: Any]]] = [:]
    private var selectedRowCache: (revision: Int, rows: [[String: Any]])?
    private var selectedIDs = Set<String>(), selectionPage: Int?
    private var sceneEpoch = 1, sceneRevisions: [Int: Int] = [:], scenePages = Set<Int>(), dirtyScenes = Set<Int>()
    // Patch chains with the host: fingerprints of what it holds, revisions never rewind.
    private var drawingFingerprints: NativePDFScenePatch.Fingerprints?, drawingPatchRevision = 0
    private var sceneFingerprints: [Int: NativePDFScenePatch.Fingerprints] = [:], sceneTask: Task<Void, Never>?
    /// Eraser engaged by the Pencil double-tap; it lasts one contact.
    private var pencilEraser = false
    private struct Gesture {
        let page: Int, tool: String, start: CGPoint, id: String
        var points: [CGPoint], rows: [[String: Any]], preview: [[String: Any]]
        var box: CGRect?, corner: String?
        var destinationPage: Int?
    }
    private var gesture: Gesture?
    private var textObject: [String: Any]?
    private var editingExistingText = false
    private var pendingTextSave: [String: Any]?
    private var textCreateMutationID = UUID().uuidString

    init(document: NativeDocumentReference, store: NativeWorkspaceStore, onOpenDocument: ((NativeDocumentReference) -> Void)? = nil, defaults: UserDefaults = .standard) {
        self.document = document; self.store = store; self.onOpenDocument = onOpenDocument; self.defaults = defaults
        let hasPreferences = NativePDFWorkspacePreferences.hasStored(root: store.root, documentID: document.id, defaults: defaults)
        let preferenceID = (hasPreferences ? nil : store.documentDuplicateSourceIDs[document.id]) ?? document.id
        var saved = NativePDFWorkspacePreferences.load(root: store.root, documentID: preferenceID, defaults: defaults)
        let palette = NativePDFPalettePreferences.load(root: store.root, defaults: defaults)
        if !NativePDFWorkspacePreferences.hasStored(root: store.root, documentID: preferenceID, defaults: defaults) {
            saved.penStyle = palette.recentPen; saved.highlighterStyle = palette.recentHighlighter; saved.ballpointStyle = palette.recentBallpoint
            saved.color = palette.recentPen.color; saved.width = palette.recentPen.width; saved.opacity = palette.recentPen.opacity
        }
        saved.shapeRecognitionEnabled = palette.drawAndHold
        favorites = palette.favorites; shapeRecognitionEnabled = palette.drawAndHold
        if preferenceID != document.id { saved.pendingPage = nil; saved.save(root: store.root, documentID: document.id, defaults: defaults) }
        preferences = saved
        tool = saved.tool; color = saved.color; width = saved.width; opacity = saved.opacity
        previousTool = saved.previousTool; savedPenStyle = saved.penStyle; savedHighlighterStyle = saved.highlighterStyle; savedBallpointStyle = saved.ballpointStyle
        toolsExpanded = saved.toolsExpanded; showPages = saved.showPages; showAnnotations = saved.showAnnotations
        lassoMode = saved.lassoMode; canPaste = Self.clipboardHasContent
        clipboardEvents = NotificationCenter.default.publisher(for: UIPasteboard.changedNotification).sink { [weak self] _ in
            self?.canPaste = Self.clipboardHasContent
        }
        assistantEvents = store.annotation.$request.sink { [weak self] request in
            self?.setAssistantAnnotation(request)
        }
        storeEvents = store.events.sink { [weak self] event in self?.receiveStoreEvent(event) }
        paletteEvents = NotificationCenter.default.publisher(for: NativePDFPalettePreferences.changed).sink { [weak self] event in
            guard let self, event.userInfo?["key"] as? String == NativePDFPalettePreferences.key(root: self.store.root),
                  let changedDefaults = event.object as? UserDefaults, changedDefaults === self.defaults else { return }
            let shared = NativePDFPalettePreferences.load(root: self.store.root, defaults: self.defaults)
            self.favorites = shared.favorites
            if self.shapeRecognitionEnabled != shared.drawAndHold {
                self.shapeRecognitionEnabled = shared.drawAndHold; self.updateStyle()
            }
        }
    }
    func attach(to container: UIView) {
        guard host == nil, !retired else { return }
        // Store retains the closure until close succeeds. A disappearing view
        // cannot release a failed journal/ACK or an unfinished history action.
        registration = store.registerDocumentFlush(id: document.id, document: document,
            freeze: { [weak self] in self?.setMaterialMutating(true) },
            suspendWrites: { [weak self] in self?.writesSuspended = true },
            resume: { [weak self] in self?.writesSuspended = false; self?.setMaterialMutating(false) },
            retire: { [weak self] in self?.retire() }) { [self] in try await flush() }
        do {
            let native = try NativePDFHost(root: store.root, directEnabled: true) { [store] channel, request in
                try await store.invokePrivate(channel, request)
            }
            host = native; native.attach(to: container)
            native.setPresentation(blocked: false, inputBlocked: true, overlays: [])
            native.emit = { [weak self] channel, value in
                guard channel == "pdfNative:event", let event = value as? [String: Any] else { return }
                self?.receive(event)
            }
            let task = Task { @MainActor in try await self.open() }
            opening = task
            Task { do { try await task.value } catch { self.fail(error); self.isLoading = false } }
        } catch { fail(error); isLoading = false }
    }
    private var identity: [String: Any] {
        ["surfaceId": surfaceID, "generation": generation, "courseId": document.courseID, "relPath": document.relativePath]
    }
    private func call(_ command: String, _ request: [String: Any] = [:]) async throws -> Any {
        guard let host else { throw NativePDFError.invalid("PDF 화면 연결이 닫혔습니다.") }
        return try await host.handle("pdfNative:" + command, request: identity.merging(request) { _, new in new })
    }
    private func open() async throws {
        await store.waitForExternalMutation()
        guard !retired, !Task.isCancelled else { return }
        store.runtime.beginForegroundWork(); defer { store.runtime.endForegroundWork() }
        // The saved position needs no binding; it rides the storage queue alongside the host open.
        async let savedViewState = store.invoke("pdf:getViewState", ["courseId": document.courseID, "relPath": document.relativePath])
        guard let state = try await DesktopSignpost.measure(DesktopSignpost.open, "host.open", { try await call("open") }) as? [String: Any],
              let revision = state["documentRevision"] as? String else { _ = try? await savedViewState; throw NativePDFError.invalid("PDF를 열지 못했습니다.") }
        opened = true; pageRevision = revision
        thumbnailSource = NativePDFPageThumbnailSource(root: store.root, revision: revision)
        pageCount = state["numPages"] as? Int ?? 1
        pageWidths = (state["pageSizes"] as? [[String: Any]] ?? []).map { ($0["width"] as? NSNumber)?.doubleValue ?? 0 }
        pageAspects = (state["pageSizes"] as? [[String: Any]] ?? []).map {
            let width = ($0["width"] as? NSNumber)?.doubleValue ?? 1
            return (($0["height"] as? NSNumber)?.doubleValue ?? sqrt(2)) / max(width, 0.001)
        }
        let recovery = try NativePDFEditRecovery(root: store.root, courseID: document.courseID, relativePath: document.relativePath)
        let writer = persistence ?? NativePDFPersistence(courseID: document.courseID, relativePath: document.relativePath, documentRevision: revision,
            recovery: recovery,
            coordinator: NativePDFFileCoordinator.shared(root: store.root, courseID: document.courseID, relativePath: document.relativePath),
            instanceID: document.id, backend: { [store] channel, input in try await store.invoke(channel, input) },
            host: { [weak self] command, input in
                guard let self else { throw CancellationError() }; return try await self.call(command, input)
            })
        persistence = writer
        writer.onPeerChanged = { [weak self, weak writer] changed in
            guard let self, let writer, !self.retired else { return }
            self.drawingRevision += 1; self.annotations = writer.annotations; self.annotationCount = writer.annotations.count
            if let gesture = self.gesture, gesture.rows.contains(where: { changed.contains($0["id"] as? String ?? "") }) {
                self.gesture = nil
            }
            self.refreshHistory()
            Task { @MainActor [weak self] in
                guard let self, !self.retired, self.setupComplete else { return }
                do { try await self.refreshAnnotations(); try await self.publishSnapshot(); self.schedulePageHistoryRefresh() }
                catch { self.fail(error) }
            }
        }
        writer.onAnnotationsChanged = { [weak self] in
            guard let self else { return }; try await self.refreshAnnotations(); try await self.publishSnapshot(); self.schedulePageHistoryRefresh()
            self.store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:pdfContentChanged", payload: ["courseId": self.document.courseID, "relPath": self.document.relativePath]))
        }
        try await DesktopSignpost.measure(DesktopSignpost.open, "recoverEdits") { try await writer.recoverEdits() }
        // Annotations only need the binding; load them while history and strokes recover.
        async let annotationsLoaded: () = refreshAnnotations()
        writer.restoreHistory(root: store.root)
        // Page history (a double PDF parse) is deferred to the pages panel.
        // Recover old journal payloads before enabling this generation's
        // ordered native eraser. No new contact is exposed during recovery.
        let recovered: [[String: Any]]
        if let pending = state["pending"] as? [[String: Any]] { recovered = pending }
        else { recovered = (try await call("flush") as? [String: Any])?["pending"] as? [[String: Any]] ?? [] }
        try await writer.recoverStrokes(recovered)
        try await annotationsLoaded
        writer.onRowsChanged = { [weak self] in
            guard let self else { return }
            self.drawingRevision += 1
            try await self.publishSnapshot()
            self.schedulePageHistoryRefresh()
            self.store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:pdfContentChanged", payload: ["courseId": self.document.courseID, "relPath": self.document.relativePath]))
        }
        try await DesktopSignpost.measure(DesktopSignpost.open, "publishSnapshot") { try await publishSnapshot() }
        do {
            let saved = try await savedViewState as? [String: Any] ?? [:]
            preferences.pendingPage = NativePDFWorkspacePreferences.load(root: store.root, documentID: document.id, defaults: defaults).pendingPage
            viewport = preferences.restoringViewState(saved, revision: revision, pageCount: pageCount)
            zoom = (viewport["zoom"] as? NSNumber)?.doubleValue ?? 1
            viewport["zoom"] = zoom
            viewport["page"] = min(pageCount, max(1, viewport["page"] as? Int ?? 1))
            pendingViewportRestore = viewport
            pendingPageToAcknowledge = preferences.pendingPage
            page = viewport["page"] as? Int ?? 1
        }
        try await DesktopSignpost.measure(DesktopSignpost.open, "first.layout") { try await publishLayout() }
        isLoading = false; refreshHistory(); exposed = true
        setupComplete = true
        if bounds.width > 0, bounds.height > 0 { restoreInput() }
        if showPages { schedulePageHistoryRefresh() }
    }
    private var pageHistoryTask: Task<Void, Never>?
    /// `pdf:pageHistory` reads and parses the whole PDF; while the pages panel is
    /// open it is refreshed once a second at most instead of after every stroke.
    private func schedulePageHistoryRefresh() {
        guard showPages else { return }
        pageHistoryTask?.cancel()
        pageHistoryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.showPages, !self.retired else { return }
            do { try await self.refreshPageHistory() } catch { self.fail(error) }
        }
    }
    func layout(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0, rect != bounds else { return }
        bounds = rect
        guard opened, !isLoading, !retired else { return }
        // Keyboard, pane and panel animations deliver a frame per tick; each one
        // re-laid out PDFKit (prepareNavigation). Publish the settled frame only.
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.layoutSettleDelayMs))
            guard !Task.isCancelled, let self else { return }
            do { try await self.publishLayout() } catch { self.fail(error) }
        }
    }
    private static let layoutSettleDelayMs = 40
    private var layoutTask: Task<Void, Never>?
    /// A hidden (retained) tab keeps its model and host but the host suspends
    /// the PDF view and releases GPU caches; edits are flushed on hide.
    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        guard opened, !retired else { return }
        Task { do { try await publishLayout(); if !value { try await flush() } } catch { fail(error) } }
    }
    private func publishLayout() async throws {
        guard bounds.width > 0, bounds.height > 0 else { return }
        layoutRevision += 1
        var request: [String: Any] = ["revision": layoutRevision, "visible": visible, "occluded": false, "holes": [],
            "rect": ["x": Double(bounds.minX), "y": Double(bounds.minY), "width": Double(bounds.width), "height": Double(bounds.height)]]
        // PDFKit computes its fit scale only after the real container frame is
        // installed. The host restores after fitting, before preparing ink on
        // intermediate pages that the user will never see.
        // A suspended (hidden) host has no document to navigate; keep the restore pending.
        let saved = visible ? pendingViewportRestore : nil
        let requestedPage = saved == nil ? nil : pendingPageToAcknowledge
        if let saved {
            pendingViewportRestore = nil
            request["restoreViewport"] = saved
        }
        do {
            _ = try await call("layout", request)
            if let saved, let requestedPage { acknowledgePendingPage(requestedPage, viewport: saved) }
        }
        catch { if let saved { pendingViewportRestore = saved }; throw error }
        if setupComplete { restoreInput() }
    }
    private func publishSnapshot() async throws {
        snapshotRequested = true
        if let snapshotTask { try await snapshotTask.value; return }
        let task = Task { @MainActor in
            defer { self.snapshotTask = nil }
            while self.snapshotRequested {
                self.snapshotRequested = false
                let drawingRevision = self.drawingRevision
                var payload: [String: Any] = [:]
                var drawingPrints: NativePDFScenePatch.Fingerprints?
                if self.publishedDrawingRevision != drawingRevision {
                    // Persistence reloads its rows before every revision bump. Only the
                    // changed rows travel; re-sending the whole document made each
                    // stroke cost as much as all the ink already on the page.
                    let drawings = self.persistence?.rows ?? []
                    let patch = NativePDFScenePatch.patch(rows: drawings, previous: self.drawingFingerprints,
                        baseRevision: self.drawingPatchRevision, revision: self.drawingPatchRevision + 1)
                    var drawingPatch = patch.patch
                    drawingPatch["upserts"] = try (drawingPatch["upserts"] as? [[String: Any]] ?? []).map(self.legacyPrepared)
                    payload["drawingPatch"] = drawingPatch; drawingPrints = patch.fingerprints
                    self.displayRows = drawings
                    self.displayRowsByPage = Dictionary(grouping: drawings, by: { ($0["page"] as? NSNumber)?.intValue ?? 1 })
                    self.dirtyScenes.formUnion(self.scenePages)
                    self.pruneSelection()
                }
                let style = self.currentPreferences.drawingStyle
                let epoch = self.sceneEpoch
                payload.merge(["nativeInkErase": true, "loading": false, "active": true,
                    "annotations": self.annotations, "tool": ["name": self.tool == "ballpoint" ? "pen" : self.tool, "style": style, "drawAndHold": self.shapeRecognitionEnabled, "lassoMode": self.lassoMode], "objectSceneEpoch": self.sceneEpoch]) { _, new in new }
                do { _ = try await self.call("snapshot", payload) }
                catch where drawingPrints != nil && self.drawingFingerprints != nil {
                    // The host lost the patch chain; resend the whole document once.
                    self.drawingFingerprints = nil; self.publishedDrawingRevision = -1; self.snapshotRequested = true; continue
                }
                if let drawingPrints {
                    self.drawingFingerprints = drawingPrints; self.drawingPatchRevision += 1
                    // Pages with upserted rows plus pages whose row count changed (removals carry no page).
                    var counts: [Int: Int] = [:]
                    for row in self.displayRows { if let page = (row["page"] as? NSNumber)?.intValue { counts[page, default: 0] += 1 } }
                    var touched = Set((payload["drawingPatch"] as? [String: Any]).flatMap { $0["upserts"] as? [[String: Any]] }?.compactMap { ($0["page"] as? NSNumber)?.intValue } ?? [])
                    for page in Set(counts.keys).union(self.thumbnailPageCounts.keys) where counts[page] != self.thumbnailPageCounts[page] { touched.insert(page) }
                    self.thumbnailPageCounts = counts
                    self.scheduleThumbnailRefresh(pages: touched)
                }
                self.publishedDrawingRevision = drawingRevision
                guard self.sceneEpoch == epoch else { self.snapshotRequested = true; continue }
                if !self.isInkTool {
                    for page in self.dirtyScenes.sorted() {
                        if self.sceneEpoch != epoch { self.snapshotRequested = true; break }
                        self.dirtyScenes.remove(page)
                        try await self.publishScene(page)
                    }
                } else { self.scenePages.removeAll(); self.dirtyScenes.removeAll(); self.sceneFingerprints.removeAll() }
            }
            self.refreshHistory()
        }
        snapshotTask = task
        try await task.value
    }
    private var inputSinceFlush = true, lastSavedViewport: [String: Any]?
    private func receive(_ event: [String: Any]) {
        guard event["surfaceId"] as? String == surfaceID, event["generation"] as? String == generation,
              let type = event["type"] as? String, let payload = event["payload"] as? [String: Any] else { return }
        inputSinceFlush = true
        switch type {
        case "selection":
            guard tool == "select", !isBusy else { return }
            guard let quote = payload["quote"] as? String, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let number = payload["page"] as? Int, number > 0, number <= pageCount,
                  let rects = payload["rects"] as? [[String: Any]], !rects.isEmpty else {
                sourceQuote = ""; sourceSelection = nil; return
            }
            clearSelection(); sourceQuote = quote
            sourceSelection = ["page": number, "rects": rects, "anchor": ["quote": quote, "prefix": "", "suffix": ""]]
        case "annotation":
            guard assistantAnnotation == nil else { return }
            guard tool == "select", !isBusy, let id = payload["id"] as? String else { return }
            openAnnotation(id: id)
        case "pointer": receivePointer(payload)
        case "bodyTap":
            guard assistantAnnotation == nil else { return }
            guard errorMessage == nil, !isBusy else { return }
            if textEditorDraft != nil {
                // The tap that opened a box can also arrive here; only a later tap commits.
                if CFAbsoluteTimeGetCurrent() - textEditorPresentedAt > 0.4 { finishText() }
            } else if tool == "text", gesture == nil, let number = payload["page"] as? Int, number > 0, number <= pageCount,
                      let x = payload["x"] as? Double, let y = payload["y"] as? Double {
                openText(at: CGPoint(x: x, y: y), page: number)
            } else if let number = payload["page"] as? Int, let x = payload["x"] as? Double, let y = payload["y"] as? Double {
                let point = CGPoint(x: x, y: y)
                let box = selectedRegion ?? NativePDFEditingGeometry.union(selectedRows, aspect: aspect(number))
                let inside = selectionPage == number && (box?.insetBy(dx: -0.018, dy: -0.018 / aspect(number)).contains(point) ?? false)
                if !inside {
                    clearSelection()
                    if tool == "lasso" { showPasteMenu(at: point, page: number) }
                }
            }
        case "selectionFrame":
            guard hasSelectionMenu, let x = payload["x"] as? Double, let y = payload["y"] as? Double,
                  let width = payload["width"] as? Double, let height = payload["height"] as? Double else { selectionFrame = nil; return }
            selectionFrame = CGRect(x: x, y: y, width: width, height: height)
        case "stroke", "eraseCommit":
            guard let persistence else { return }
            store.markDocumentChanged()
            do { try persistence.accept(payload, type: type) }
            catch { fail(error); return }
            refreshHistory()
            // An explicit retry owns failures. Additional incoming completions
            // remain queued rather than repeatedly retrying a full/protected disk.
            guard errorMessage == nil else { return }
            Task { do { try await persistence.drain(); refreshHistory() } catch { fail(error) } }
        case "viewport":
            viewport = payload
            let nextZoom = (payload["zoom"] as? NSNumber)?.doubleValue ?? zoom
            if nextZoom != zoom { zoom = nextZoom }
            let next = payload["page"] as? Int ?? page
            if next != page {
                if gesture == nil, pasteAnchor != nil { clearSelection() }
                page = next
                store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:pdfPageChanged", payload: ["courseId": document.courseID, "relPath": document.relativePath, "tabID": document.id, "page": next]))
            }
        case "pending":
            let next = max(persistence?.pendingCount ?? 0, payload["count"] as? Int ?? 0)
            if next != pendingCount { pendingCount = next }
        case "error": fail(NativePDFError.invalid(payload["message"] as? String ?? "PDF 저장 중 문제가 발생했습니다."))
        case "pullToAddPage":
            guard assistantAnnotation == nil, errorMessage == nil, !isBusy else { return }
            addPage(after: pageCount)
        case "pencilTap":
            guard assistantAnnotation == nil, errorMessage == nil, !isBusy else { return }
            switch payload["action"] as? String {
            case "switchEraser": chooseTool(tool == "eraser" ? previousTool : "eraser"); pencilEraser = tool == "eraser"
            case "switchPrevious": chooseTool(previousTool)
            case "showColorPalette": showStyle = true
            default: break
            }
        case "deactivate":
            // A double-tap eraser lasts one contact: the Pencil returns to the previous tool on lift.
            guard pencilEraser, tool == "eraser" else { return }
            pencilEraser = false
            Task { @MainActor [weak self] in guard let self else { return }; self.chooseTool(self.previousTool) }
        case "activate":
            // Pen-down must not trigger a SwiftUI pass or a host layout; assign only on change.
            if showStyle { showStyle = false }
            // A contact that begins after this editor was flushed must extend
            // a store-wide transition barrier even before its completion event.
            if assistantAnnotation == nil && (tool != "select" || selectionCount > 0) { store.markDocumentChanged() }
        default: break
        }
    }
    func chooseTool(_ next: String) {
        guard assistantAnnotation == nil, NativePDFWorkspacePreferences.tools.contains(next), !isBusy else { return }
        if next == tool { if isInkTool { showStyle.toggle() }; return }
        host?.flush()
        guard !isBusy, errorMessage == nil else { return }
        if textEditorDraft != nil { finishText() }
        rememberActiveStyle()
        gesture = nil; clearSelection(); clearSourceSelection(); advanceSceneEpoch()
        previousTool = tool; tool = next; pencilEraser = false
        if next != "select" { toolsExpanded = true }
        canPaste = Self.clipboardHasContent
        if next == "pen" { applyStyle(savedPenStyle) }
        if next == "highlighter" { applyStyle(savedHighlighterStyle) }
        if next == "ballpoint" { applyStyle(savedBallpointStyle) }
        showStyle = false
        updateStyle()
    }
    func chooseColor(_ next: String) {
        guard NativePDFWorkspacePreferences.colors.contains(next), isInkTool else { return }
        if color == next { showStyle = true; return }
        color = next; rememberActiveStyle(); updateStyle()
    }
    func chooseQuickWidth(_ next: Double) {
        if abs(width - next) < 0.0000001 { showStyle = true } else { setWidth(next) }
    }
    func setWidth(_ value: Double) {
        guard value.isFinite, isInkTool else { return }
        width = min(0.04, max(0.001, value)); rememberActiveStyle(); updateStyle()
    }
    func setOpacity(_ value: Double) {
        guard value.isFinite, isInkTool else { return }
        opacity = min(tool == "highlighter" ? 0.34 : 1, max(0.05, value)); rememberActiveStyle(); updateStyle()
    }
    func chooseFavorite(_ index: Int) {
        guard favorites.indices.contains(index), !isBusy, errorMessage == nil else { return }
        let favorite = favorites[index]
        if !isPenLike { chooseTool("pen") }
        guard isPenLike else { return }
        applyStyle(favorite); rememberActiveStyle(); updateStyle()
    }
    func saveFavorite(_ index: Int) {
        guard favorites.indices.contains(index), isPenLike else { return }
        let value = currentPreset.validated()
        favorites = NativePDFPalettePreferences.update(root: store.root, defaults: defaults) { $0.favorites[index] = value }.favorites
    }
    func setLassoMode(_ mode: String) {
        guard NativePDFWorkspacePreferences.lassoModes.contains(mode), mode != lassoMode else { return }
        lassoMode = mode; clearSelection(); updateStyle()
    }
    func setShapeRecognition(_ enabled: Bool) {
        shapeRecognitionEnabled = enabled
        NativePDFPalettePreferences.update(root: store.root, defaults: defaults) { $0.drawAndHold = enabled }
        updateStyle()
    }
    private func applyStyle(_ style: NativePDFPenPreset) { color = style.color; width = style.width; opacity = style.opacity }
    private func rememberActiveStyle() {
        if tool == "pen" {
            savedPenStyle = currentPreset.validated()
            NativePDFPalettePreferences.update(root: store.root, defaults: defaults) { $0.recentPen = savedPenStyle }
        } else if tool == "highlighter" {
            savedHighlighterStyle = currentPreset.validated(highlighter: true)
            NativePDFPalettePreferences.update(root: store.root, defaults: defaults) { $0.recentHighlighter = savedHighlighterStyle }
        } else if tool == "ballpoint" {
            savedBallpointStyle = currentPreset.validated()
            NativePDFPalettePreferences.update(root: store.root, defaults: defaults) { $0.recentBallpoint = savedBallpointStyle }
        }
    }
    private var currentPreferences: NativePDFWorkspacePreferences {
        var value = preferences
        value.tool = tool; value.color = color; value.width = width; value.opacity = opacity
        value.previousTool = previousTool
        value.penStyle = tool == "pen" ? currentPreset : savedPenStyle
        value.highlighterStyle = tool == "highlighter" ? currentPreset : savedHighlighterStyle
        value.ballpointStyle = tool == "ballpoint" ? currentPreset : savedBallpointStyle
        value.penColor = value.penStyle.color; value.highlighterColor = value.highlighterStyle.color
        value.shapeRecognitionEnabled = shapeRecognitionEnabled; value.lassoMode = lassoMode
        value.toolsExpanded = toolsExpanded; value.showPages = showPages; value.showAnnotations = showAnnotations
        return value
    }
    private func savePreferences() {
        guard assistantOriginalTool == nil else { return }
        preferences = currentPreferences
        // A router can queue a jump while an already-mounted model is flushing.
        preferences.pendingPage = NativePDFWorkspacePreferences.load(root: store.root, documentID: document.id, defaults: defaults).pendingPage
        preferences.save(root: store.root, documentID: document.id, defaults: defaults)
    }
    private func acknowledgePendingPage(_ requested: Int, viewport: [String: Any]) {
        var stored = NativePDFWorkspacePreferences.load(root: store.root, documentID: document.id, defaults: defaults)
        guard stored.pendingPage == requested else { return }
        stored.pendingPage = nil; stored.viewport = .init(revision: pageRevision, values: viewport)
        stored.save(root: store.root, documentID: document.id, defaults: defaults)
        preferences.pendingPage = nil; preferences.viewport = stored.viewport
        if pendingPageToAcknowledge == requested { pendingPageToAcknowledge = nil }
    }
    private func updateStyle() {
        savePreferences()
        guard opened, !isLoading, !retired else { return }
        snapshotRequested = true
        Task { do { try await publishSnapshot() } catch { fail(error) } }
    }
    /// The host scopes object-scene revisions to the active tool. Temporary
    /// annotation tools need the same transition as a normal toolbar selection.
    private func advanceSceneEpoch() {
        sceneEpoch += 1; sceneRevisions.removeAll(); sceneFingerprints.removeAll()
        dirtyScenes.formUnion(scenePages)
    }
    private func aspect(_ page: Int) -> Double { pageAspects.indices.contains(page - 1) ? pageAspects[page - 1] : sqrt(2) }
    private func pageSize(_ page: Int) -> CGSize {
        let width = pageWidths.indices.contains(page - 1) ? pageWidths[page - 1] : 595.28
        let validWidth = width.isFinite && width > 0 ? width : 595.28
        return CGSize(width: validWidth, height: validWidth * aspect(page))
    }
    private func rows(on page: Int) -> [[String: Any]] { (persistence?.rows ?? []).filter { ($0["page"] as? NSNumber)?.intValue == page } }
    private var selectedRows: [[String: Any]] {
        guard let selectionPage else { return [] }
        if let selectedRowCache, selectedRowCache.revision == drawingRevision { return selectedRowCache.rows }
        let rows = rows(on: selectionPage).filter { selectedIDs.contains($0["id"] as? String ?? "") }
        selectedRowCache = (drawingRevision, rows); return rows
    }
    private func pruneSelection() {
        selectedIDs.formIntersection(Set(selectedRows.compactMap { $0["id"] as? String }))
        selectionCount = selectedIDs.count
        selectedText = selectedRows.count == 1 && selectedRows.first?["kind"] as? String == "textbox"
    }
    private func setSelection(_ ids: Set<String>, page: Int) {
        if let previous = selectionPage { dirtyScenes.insert(previous) }
        selectionPage = page; selectedIDs = ids; selectedRowCache = nil; selectedRegion = nil; pasteAnchor = nil
        pruneSelection(); dirtyScenes.insert(page)
    }
    func clearSelection() {
        if let selectionPage { dirtyScenes.insert(selectionPage) }
        selectedIDs.removeAll(); selectionPage = nil; selectionCount = 0; selectedText = false; selectionFrame = nil
        selectedRowCache = nil; selectedRegion = nil; pasteAnchor = nil
        publishDirtyScenes()
    }
    private func showPasteMenu(at point: CGPoint, page: Int) {
        setSelection([], page: page); pasteAnchor = point; canPaste = Self.clipboardHasContent
        requestScene(page)
    }
    private func requestScene(_ page: Int) { dirtyScenes.insert(page); publishDirtyScenes() }
    private func publishScene(_ page: Int) async throws {
        var values = displayRowsByPage[page] ?? []
        if textEditorPage == page, let editing = textObject?["id"] as? String { values.removeAll { $0["id"] as? String == editing } }
        var selection = selectionPage == page ? (NativePDFEditingGeometry.union(selectedRows, aspect: aspect(page)) ?? selectedRegion) : nil
        if selectionPage == page, let anchor = pasteAnchor { selection = CGRect(origin: anchor, size: .zero) }
        var volatile = Set<String>()
        if let gesture, !gesture.preview.isEmpty {
            let destination = gesture.destinationPage ?? gesture.page
            if page == gesture.page || page == destination {
                volatile = Set(gesture.preview.compactMap { $0["id"] as? String })
                values.removeAll { volatile.contains($0["id"] as? String ?? "") }
                if page == destination { values += gesture.preview }
                selection = page == destination ? NativePDFEditingGeometry.union(gesture.preview, aspect: aspect(page)) : nil
            }
        }
        // Claim the revision before awaiting: a concurrent publish of this page must not reuse it.
        let revision = (sceneRevisions[page] ?? 0) + 1
        sceneRevisions[page] = revision
        let patch = NativePDFScenePatch.patch(rows: values, previous: sceneFingerprints[page], baseRevision: revision - 1, revision: revision, volatile: volatile)
        var objectPatch = patch.patch
        objectPatch["upserts"] = try (objectPatch["upserts"] as? [[String: Any]] ?? []).map(legacyPrepared)
        var payload: [String: Any] = ["page": page, "objectSceneEpoch": sceneEpoch, "objectSceneRevision": revision, "objectPatch": objectPatch, "resizable": selection != nil && !selectedIDs.isEmpty, "textHandles": selectedText]
        if let selection { payload["selection"] = NativePDFEditingGeometry.dictionary(selection) }
        do { _ = try await call("objectScene", payload) }
        catch where sceneFingerprints[page] != nil {
            // The host lost this page's patch chain; resend the page once.
            sceneFingerprints[page] = nil; try await publishScene(page); return
        }
        sceneFingerprints[page] = patch.fingerprints; scenePages.insert(page)
    }
    /// Pre-inkVersion strokes render from a path string the host does not derive itself.
    private func legacyPrepared(_ row: [String: Any]) throws -> [String: Any] {
        guard ["ink", "highlighter"].contains(row["kind"] as? String ?? ""), let data = row["data"] as? [String: Any], data["inkVersion"] == nil,
              row["nativePath"] == nil, let page = (row["page"] as? NSNumber)?.intValue else { return row }
        var row = row; row["nativePath"] = try NativePDFLegacyInk.path(row, aspect: aspect(page)); return row
    }
    /// Scene-only refresh for an in-flight gesture: no preference save, no document
    /// snapshot. A snapshot in progress drains the dirty pages itself.
    private func publishDirtyScenes() {
        guard sceneTask == nil else { return }
        sceneTask = Task { @MainActor in
            defer { self.sceneTask = nil }
            if self.snapshotRequested {
                do { try await self.publishSnapshot() } catch { self.fail(error); return }
            }
            if let snapshotTask = self.snapshotTask { _ = try? await snapshotTask.value }
            while self.snapshotTask == nil, !self.retired, !self.isInkTool, let page = self.dirtyScenes.min() {
                self.dirtyScenes.remove(page)
                do { try await self.publishScene(page) } catch { self.fail(error); return }
            }
        }
    }
    private func clearGesture() {
        if let gesture { dirtyScenes.insert(gesture.page); if let page = gesture.destinationPage { dirtyScenes.insert(page) } }
        gesture = nil
    }
    private func receivePointer(_ payload: [String: Any]) {
        if assistantAnnotation != nil {
            receiveAssistantPointer(payload); return
        }
        guard !isLoading, !retired, errorMessage == nil, let number = payload["page"] as? Int,
              let phase = payload["phase"] as? String, let raw = payload["points"] as? [[String: Any]],
              let first = raw.first.flatMap(NativePDFEditingGeometry.point), let last = raw.last.flatMap(NativePDFEditingGeometry.point) else { return }
        if phase == "down" {
            guard !isBusy, gesture == nil else { return }
            if textEditorDraft != nil {
                // The contact that opened the box also reaches here; only a later one commits.
                if CFAbsoluteTimeGetCurrent() - textEditorPresentedAt > 0.4 { finishText() }
                return
            }
            var rows: [[String: Any]] = [], box: CGRect?, corner: String?
            if ["select", "lasso"].contains(tool) {
                if selectionPage == number, let selected = NativePDFEditingGeometry.union(selectedRows, aspect: aspect(number)),
                   selected.insetBy(dx: -0.018, dy: -0.018 / aspect(number)).contains(first) {
                    rows = selectedRows; box = selected; corner = NativePDFEditingGeometry.corner(at: first, box: selected, aspect: aspect(number))
                } else if tool == "select", let id = NativePDFEditingGeometry.hit(first, rows: self.rows(on: number), aspect: aspect(number)) {
                    setSelection([id], page: number); rows = selectedRows; box = NativePDFEditingGeometry.union(rows, aspect: aspect(number))
                } else { setSelection([], page: number) }
            } else { clearSelection() }
            gesture = Gesture(page: number, tool: tool, start: first, id: "native-preview-" + UUID().uuidString, points: [first], rows: rows, preview: [], box: box, corner: corner)
            store.markDocumentChanged()
        }
        guard var contact = gesture, contact.page == number else { return }
        if phase == "cancel" { clearGesture(); publishDirtyScenes(); return }
        if phase != "down", contact.rows.isEmpty, contact.tool == "lasso" { contact.points += raw.compactMap(NativePDFEditingGeometry.point) }
        let distance = hypot(last.x - contact.start.x, (last.y - contact.start.y) * aspect(number))
        let destinationPage = (payload["destinationPage"] as? Int).flatMap { (1...pageCount).contains($0) ? $0 : nil } ?? number
        let destinationPoint = CGPoint(x: (payload["destinationX"] as? Double) ?? Double(last.x), y: (payload["destinationY"] as? Double) ?? Double(last.y))
        if !contact.rows.isEmpty, distance > 0.002 || destinationPage != number {
            if let previous = contact.destinationPage { dirtyScenes.insert(previous) }
            if let corner = contact.corner, let box = contact.box {
                contact.preview = NativePDFEditingGeometry.resized(contact.rows, original: box, corner: corner, to: last)
                    .map { NativePDFTextDraft.fittedObject($0, pageSize: pageSize(number)) }
            }
            else {
                contact.destinationPage = destinationPage
                contact.preview = NativePDFEditingGeometry.movedAcrossPages(contact.rows,
                    from: pageSize(number), to: pageSize(destinationPage), grabbedAt: contact.start,
                    droppedAt: destinationPoint, page: destinationPage)
                dirtyScenes.insert(destinationPage)
            }
        } else if ["line", "arrow", "rect", "ellipse"].contains(contact.tool), distance > 0.003 {
            contact.preview = [shape(tool: contact.tool, start: contact.start, end: last, page: number, id: contact.id)]
        }
        gesture = contact
        // The surface draws the dashed lasso itself; nothing changes in the scene until release.
        if phase == "move", contact.tool == "lasso", contact.rows.isEmpty { return }
        // Mid-gesture frames republish only this page's scene.
        if phase == "move" { if !contact.preview.isEmpty { dirtyScenes.insert(number); publishDirtyScenes() }; return }
        if phase == "up" {
            // A preview stays in the scene until the persisted rows replace it (performObjectEdit
            // clears the gesture). Dropping it first drew the old position for a few frames.
            if contact.preview.isEmpty { gesture = nil }
            if !contact.preview.isEmpty {
                // A moved or resized selection stays selected until the user taps outside or ✕.
                performObjectEdit(contact.rows.isEmpty ? "create" : "update", values: contact.preview, expected: contact.rows, keepSelection: !contact.rows.isEmpty)
            } else if contact.tool == "lasso", contact.rows.isEmpty {
                let polygon = lassoMode == "box"
                    ? [contact.start, CGPoint(x: last.x, y: contact.start.y), last, CGPoint(x: contact.start.x, y: last.y)]
                    : contact.points
                let ids = NativePDFEditingGeometry.lasso(polygon, rows: rows(on: number), aspect: aspect(number))
                let region = NativePDFEditingGeometry.regionBounds(polygon)
                if !ids.isEmpty || region != nil {
                    setSelection(ids, page: number); selectedRegion = region
                } else { showPasteMenu(at: last, page: number) }
            } else if contact.tool == "text" {
                openText(at: last, page: number)
            }
        }
        requestScene(number)
    }
    private func shape(tool: String, start: CGPoint, end: CGPoint, page: Int, id: String) -> [String: Any] {
        let data: [String: Any]
        if ["line", "arrow"].contains(tool) { data = ["points": [start, end].map { ["x": Double($0.x), "y": Double($0.y), "p": 0.5] }] }
        else { data = ["box": NativePDFEditingGeometry.dictionary(CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))) ] }
        return ["id": id, "page": page, "kind": tool, "data": data, "style": ["color": color, "width": width, "opacity": opacity]]
    }
    private func performObjectEdit(_ action: String, values: [[String: Any]], expected original: [[String: Any]]? = nil, keepSelection: Bool = false) {
        guard editorTask == nil, let persistence, !values.isEmpty else { clearGesture(); return }
        let ids = Set(values.compactMap { $0["id"] as? String })
        let expected = original ?? persistence.rows.filter { ids.contains($0["id"] as? String ?? "") }
        store.markDocumentChanged(); isBusy = true
        let task = Task { @MainActor in
            defer { self.editorTask = nil }
            // Defer freezing until the contact completion callback has returned.
            self.host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
            try await self.flushInput()
            switch action {
            case "create": try await persistence.createObjects(values)
            case "update": try await persistence.updateObjects(values, expected: expected)
            case "delete": try await persistence.deleteObjects(ids: Set(values.compactMap { $0["id"] as? String }), expected: expected)
            default: throw NativePDFError.invalid("지원하지 않는 개체 편집입니다.")
            }
            self.clearGesture()
            if keepSelection, let destination = (values.first?["page"] as? NSNumber)?.intValue {
                self.setSelection(ids, page: destination)
            } else { self.clearSelection() }
            try await self.publishSnapshot(); self.refreshHistory()
        }
        editorTask = task
        Task { @MainActor in
            do { try await task.value; self.isBusy = self.materialMutating; self.restoreInput() }
            catch { self.clearGesture(); self.isBusy = self.materialMutating; self.fail(error) }
        }
    }
    private func restoreInput() {
        host?.setPresentation(blocked: false, inputBlocked: isBusy || materialMutating || blockedForError || closing != nil || showAnnotationEditor || showStyle, overlays: [])
        textInput?.view.isEditable = !(isBusy || errorMessage != nil)
    }
    func deleteSelection() { guard !isBusy else { return }; performObjectEdit("delete", values: selectedRows) }
    func duplicateSelection() {
        guard !isBusy, let selectionPage else { return }
        performObjectEdit("create", values: NativePDFEditingGeometry.translated(selectedRows, dx: 0.025, dy: 0.025, aspect: aspect(selectionPage)).map { value in var value = value; value.removeValue(forKey: "id"); return value })
    }
    func editSelectedText() { guard selectedText, let row = selectedRows.first, !isBusy else { return }; presentText(row, existing: true) }
    private static var clipboardHasContent: Bool {
        UIPasteboard.general.contains(pasteboardTypes: [pasteboardType, NativePDFObjectClipboard.type]) || UIPasteboard.general.hasImages
    }
    func copySelection() { copySelectedObjects(cut: false) }
    private func copySelectedObjects(cut: Bool) {
        guard !isCopyingSelection else { return }
        guard selectionCount > 0 else { if !cut { copyPDFRegion() }; return }
        let source = selectedRows
        guard source.contains(where: { $0["kind"] as? String == "image" }) else {
            let rows = NativePDFEditingGeometry.portable(source)
            guard !rows.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
            UIPasteboard.general.setData(data, forPasteboardType: Self.pasteboardType); canPaste = true
            if cut { performObjectEdit("delete", values: source, expected: source) }
            return
        }
        isCopyingSelection = true
        let sourceGeneration = generation, sourceRevision = pageRevision
        selectionCopyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCopyingSelection = false; self.selectionCopyTask = nil }
            do {
                let encoded = try await NativePDFObjectClipboard.encode(source, courseID: self.document.courseID, store: self.store)
                var item: [String: Any] = [NativePDFObjectClipboard.type: encoded.data]
                if let png = encoded.png { item["public.png"] = png }
                UIPasteboard.general.setItems([item]); self.canPaste = true
                if cut {
                    guard !self.retired, !self.isBusy, sourceGeneration == self.generation, sourceRevision == self.pageRevision else {
                        self.mediaImportError = "선택한 개체는 복사했지만 문서가 변경되어 잘라내지 않았습니다."; return
                    }
                    self.performObjectEdit("delete", values: source, expected: source)
                }
            } catch { self.reportMediaDropError(error) }
        }
    }
    private func setAssistantAnnotation(_ request: NativeAnnotationCoordinator.Request?) {
        let next = request?.documentID == document.id ? request : nil
        guard next?.id != assistantAnnotation?.id else { return }
        if next != nil {
            host?.flush()
            assistantOriginalTool = (tool, lassoMode, previousTool)
            assistantAnnotation = next; assistantRegionMode = true
            gesture = nil; clearSelection(); clearSourceSelection()
            advanceSceneEpoch()
            tool = "lasso"; lassoMode = "box"; showStyle = false
            updateStyle()
        } else {
            assistantCaptureTask?.cancel(); assistantCaptureTask = nil; assistantCapturing = false
            assistantAnnotation = nil; assistantSelectionStart = nil
            clearSelection(); clearSourceSelection()
            if let original = assistantOriginalTool {
                advanceSceneEpoch()
                tool = original.tool; lassoMode = original.lasso; previousTool = original.previous
                assistantOriginalTool = nil; updateStyle()
            }
        }
    }
    func setAssistantRegionMode(_ region: Bool) {
        guard assistantAnnotation != nil else { return }
        assistantRegionMode = region; assistantSelectionStart = nil
        clearSelection(); clearSourceSelection(); advanceSceneEpoch()
        tool = region ? "lasso" : "select"; updateStyle()
    }
    private func receiveAssistantPointer(_ payload: [String: Any]) {
        guard assistantRegionMode, !assistantCapturing, !isLoading, !retired,
              let phase = payload["phase"] as? String, let number = payload["page"] as? Int,
              let values = payload["points"] as? [[String: Any]],
              let point = values.last.flatMap(NativePDFEditingGeometry.point) else { return }
        if phase == "down" { assistantSelectionStart = values.first.flatMap(NativePDFEditingGeometry.point); setSelection([], page: number) }
        if phase == "cancel" { assistantSelectionStart = nil; clearSelection(); return }
        guard let start = assistantSelectionStart else { return }
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        selectedRegion = rect; requestScene(number)
        if phase == "up" {
            assistantSelectionStart = nil
            guard rect.width > 0.003, rect.height > 0.003 else { clearSelection(); return }
            captureAssistantRegion(rect, page: number, text: nil)
        }
    }
    func captureAssistantViewport(_ region: CGRect) {
        guard let request = assistantAnnotation, !assistantCapturing,
              bounds.width > 0, bounds.height > 0 else { return }
        let captureBounds = bounds
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The panel/keyboard may have just resized this container. Wait for
            // its scheduled PDFKit layout before converting overlay coordinates.
            await self.layoutTask?.value
            guard self.assistantAnnotation?.id == request.id, !self.assistantCapturing, let host = self.host else { return }
            guard self.bounds == captureBounds else {
                self.store.annotation.fail("화면 크기가 바뀌었습니다. 영역을 다시 선택해 주세요.", requestID: request.id); return
            }
            let from = CGPoint(x: captureBounds.minX + region.minX * captureBounds.width, y: captureBounds.minY + region.minY * captureBounds.height)
            let to = CGPoint(x: captureBounds.minX + region.maxX * captureBounds.width, y: captureBounds.minY + region.maxY * captureBounds.height)
            guard let first = host.documentLocation(surfaceID: self.surfaceID, generation: self.generation, point: from),
                  let last = host.documentLocation(surfaceID: self.surfaceID, generation: self.generation, point: to),
                  first.page == last.page else {
                self.store.annotation.fail("한 페이지 안에서 질문할 영역을 선택해 주세요.", requestID: request.id); return
            }
            let crop = CGRect(x: min(first.point.x, last.point.x), y: min(first.point.y, last.point.y),
                              width: abs(last.point.x - first.point.x), height: abs(last.point.y - first.point.y))
            self.captureAssistantRegion(crop, page: first.page, text: nil)
        }
    }
    /// Replays the visible pages and their saved/live drawing snapshot rather
    /// than relying on UIKit to read pixels out of Metal's drawable.
    func workspacePreview() async throws -> UIImage? {
        guard opened, !retired, visible else { return nil }
        try await flush()
        await layoutTask?.value
        guard let host, let geometry = host.previewGeometry(surfaceID: surfaceID, generation: generation),
              !geometry.pages.isEmpty else { return nil }
        let capturedGeneration = generation, capturedRevision = pageRevision, capturedDrawing = drawingRevision
        let rows = persistence?.rows ?? displayRows, marks = annotations
        let original = store.root.appendingPathComponent("PDFOriginals/" + pageRevision + ".pdf")
        var images: [String: UIImage] = [:]
        let pages = Set(geometry.pages.map(\.number)), budget = NativeEditorMediaImport.Budget()
        for row in rows where row["kind"] as? String == "image" && pages.contains((row["page"] as? NSNumber)?.intValue ?? 0) {
            guard let id = row["id"] as? String, let data = row["data"] as? [String: Any],
                  let image = data["image"] as? [String: Any], let path = image["relPath"] as? String else { continue }
            let url = try await NativeLibraryMaterialAccess.url(store: store, courseID: document.courseID, relativePath: path)
            let captured = try await Task.detached(priority: .userInitiated) { try NativeEditorMediaImport.readFile(url, imagesOnly: true, budget: budget) }.value
            guard let bitmap = captured.image else { return nil }; images[id] = bitmap
        }
        var rendered: [(CGRect, UIImage)] = []
        for page in geometry.pages {
            guard let image = await NativePDFRegionCapture.annotatedImage(url: original, page: page.number,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                rows: rows.filter { ($0["page"] as? NSNumber)?.intValue == page.number },
                annotations: marks.filter { ($0["page"] as? NSNumber)?.intValue == page.number }, images: images) else { return nil }
            rendered.append((page.frame, image))
        }
        guard !Task.isCancelled, !retired, visible, generation == capturedGeneration,
              pageRevision == capturedRevision, drawingRevision == capturedDrawing,
              host.previewGeometry(surfaceID: surfaceID, generation: generation) == geometry else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.opaque = true
        format.scale = min(1, 1200 / max(geometry.size.width, geometry.size.height))
        return UIGraphicsImageRenderer(size: geometry.size, format: format).image { renderer in
            UIColor.secondarySystemBackground.setFill(); renderer.fill(CGRect(origin: .zero, size: geometry.size))
            for (frame, image) in rendered { image.draw(in: frame) }
        }
    }
    func attachAssistantText() {
        guard let request = assistantAnnotation else { return }
        guard !sourceQuote.isEmpty else {
            store.annotation.fail("먼저 PDF의 텍스트를 선택해 주세요.", requestID: request.id); return
        }
        let number = sourceSelection?["page"] as? Int ?? page
        store.annotation.complete(.init(title: document.title, text: sourceQuote, courseID: document.courseID,
            relativePath: document.relativePath, page: number, revision: pageRevision + ":" + String(drawingRevision)), requestID: request.id)
    }
    private func captureAssistantRegion(_ bounds: CGRect, page number: Int, text: String?) {
        guard let request = assistantAnnotation, !assistantCapturing else { return }
        assistantCapturing = true
        // Copy value snapshots before the first suspension; no later document change can enter this capture.
        let rows = (persistence?.rows ?? displayRows).filter {
            ($0["page"] as? NSNumber)?.intValue == number && (NativePDFEditingGeometry.bounds($0, aspect: aspect(number))?.intersects(bounds) ?? true)
        }
        let marks = annotations.filter { ($0["page"] as? NSNumber)?.intValue == number }
        let revision = pageRevision + ":" + String(drawingRevision)
        let original = store.root.appendingPathComponent("PDFOriginals/" + pageRevision + ".pdf")
        assistantCaptureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.assistantCapturing = false; self.assistantCaptureTask = nil }
            do {
                var images: [String: UIImage] = [:]
                let imageBudget = NativeEditorMediaImport.Budget()
                for row in rows where row["kind"] as? String == "image" {
                    guard let id = row["id"] as? String, let data = row["data"] as? [String: Any],
                          let image = data["image"] as? [String: Any], let relative = image["relPath"] as? String else { continue }
                    let url = try await NativeLibraryMaterialAccess.url(store: self.store, courseID: self.document.courseID, relativePath: relative)
                    let captured = try await Task.detached(priority: .userInitiated) { try NativeEditorMediaImport.readFile(url, imagesOnly: true, budget: imageBudget) }.value
                    guard let bitmap = captured.image else { throw NativePDFError.invalid("삽입한 이미지를 읽지 못했습니다.") }
                    images[id] = bitmap
                }
                guard !Task.isCancelled else { return }
                guard let image = await NativePDFRegionCapture.annotatedImage(url: original, page: number, bounds: bounds, rows: rows, annotations: marks, images: images),
                      let dataURL = NativeAssistantAttachment.dataURL(image) else { throw NativePDFError.invalid("선택한 영역을 캡처하지 못했습니다. 다시 선택해 주세요.") }
                guard !Task.isCancelled else { return }
                self.store.annotation.complete(.init(title: self.document.title, text: text, imageDataURL: dataURL,
                    courseID: self.document.courseID, relativePath: self.document.relativePath, page: number, revision: revision), requestID: request.id)
            } catch { self.store.annotation.fail(error.localizedDescription, requestID: request.id) }
        }
    }
    func copyPDFRegion() {
        guard regionCopyTask == nil, let region = selectedRegion ?? NativePDFEditingGeometry.union(selectedRows, aspect: aspect(selectionPage ?? page)),
              let number = selectionPage else { return }
        isCopyingRegion = true
        let url = store.root.appendingPathComponent("PDFOriginals/" + pageRevision + ".pdf")
        regionCopyTask = Task { @MainActor [weak self] in
            let image = await NativePDFRegionCapture.image(url: url, page: number, bounds: region)
            guard let self else { return }
            self.regionCopyTask = nil; self.isCopyingRegion = false
            guard let image else { self.mediaImportError = "선택한 PDF 영역을 이미지로 복사하지 못했습니다. 다시 선택해 주세요."; return }
            UIPasteboard.general.image = image; self.canPaste = true
        }
    }
    func cutSelection() { guard !isBusy, selectionCount > 0 else { return }; copySelectedObjects(cut: true) }
    func pasteObjects() {
        guard !isBusy else { return }
        let destination = pasteAnchor == nil ? page : (selectionPage ?? page)
        if let data = UIPasteboard.general.data(forPasteboardType: NativePDFObjectClipboard.type) {
            pasteObjectsWithImages(data, at: pasteAnchor, page: destination)
        } else if let data = UIPasteboard.general.data(forPasteboardType: Self.pasteboardType),
           let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !rows.isEmpty {
            let samePage = (rows.first?["page"] as? NSNumber)?.intValue == destination
            let box = NativePDFEditingGeometry.union(rows, aspect: aspect(destination))
            let dx = pasteAnchor.map { Double($0.x - (box?.midX ?? 0)) } ?? (samePage ? 0.025 : 0)
            let dy = pasteAnchor.map { Double($0.y - (box?.midY ?? 0)) } ?? (samePage ? 0.025 : 0)
            let values = NativePDFEditingGeometry.translated(rows, dx: dx, dy: dy, aspect: aspect(destination))
                .map { row in var row = row; row["page"] = destination; return row }
            performObjectEdit("create", values: values)
        } else if let image = UIPasteboard.general.image {
            pasteImage(image, at: pasteAnchor, page: destination)
        } else { canPaste = false }
    }
    private func pasteObjectsWithImages(_ data: Data, at point: CGPoint?, page number: Int) {
        guard !isBusy, !retired, !materialMutating, !writesSuspended, editorTask == nil, let persistence else { return }
        let targetGeneration = generation, targetRevision = pageRevision
        isBusy = true; store.markDocumentChanged(); restoreInput()
        let task = Task { @MainActor in
            defer { self.editorTask = nil }
            try await self.flushInput()
            let values: [[String: Any]]
            do {
                let decoded = try await NativePDFObjectClipboard.decode(data)
                var assets: [String: String] = [:]
                for (token, image) in decoded.images {
                    assets[token] = try await NativeEditorMediaImport.saveImage(image, courseID: self.document.courseID, store: self.store).relativePath
                }
                let rows = try NativePDFObjectClipboard.replacingAssets(in: decoded.rows, with: assets)
                let box = NativePDFEditingGeometry.union(rows, aspect: self.aspect(number))
                let samePage = (rows.first?["page"] as? NSNumber)?.intValue == number
                let dx = point.map { Double($0.x - (box?.midX ?? 0)) } ?? (samePage ? 0.025 : 0)
                let dy = point.map { Double($0.y - (box?.midY ?? 0)) } ?? (samePage ? 0.025 : 0)
                values = NativePDFEditingGeometry.translated(rows, dx: dx, dy: dy, aspect: self.aspect(number)).map {
                    var row = $0; row["page"] = number; return row
                }
            } catch { self.reportMediaDropError(error); return }
            guard !self.retired, !self.writesSuspended, self.generation == targetGeneration, self.pageRevision == targetRevision else {
                self.mediaImportError = "붙여넣는 동안 PDF가 변경되었습니다. 다시 붙여넣어 주세요."; return
            }
            try await persistence.createObjects(values)
            self.clearSelection(); try await self.publishSnapshot(); self.refreshHistory()
        }
        editorTask = task
        Task { @MainActor in
            do { try await task.value; self.isBusy = self.materialMutating; self.restoreInput() }
            catch { self.isBusy = self.materialMutating; self.fail(error) }
        }
    }
    private var mediaDropTarget: (page: Int, point: CGPoint, generation: String, revision: String)?
    func beginMediaDrop(at point: CGPoint) {
        if let target = host?.documentLocation(surfaceID: surfaceID, generation: generation, point: point) {
            mediaDropTarget = (target.page, target.point, generation, pageRevision)
        } else { mediaDropTarget = nil }
    }
    func receiveMediaDrop(_ items: [NativeDroppedMedia], at point: CGPoint) {
        let target = mediaDropTarget
        mediaDropTarget = nil
        guard let target, target.generation == generation, target.revision == pageRevision, !retired,
              !isBusy, !materialMutating, !writesSuspended else {
            reportMediaDropError(NativePDFError.invalid("파일을 가져오는 동안 PDF가 변경되었습니다. 원하는 페이지에 다시 놓아 주세요.")); return
        }
        insertImages(items.compactMap(\.image), at: target.point, page: target.page)
    }
    func reportMediaDropError(_ error: Error) { mediaImportError = error.localizedDescription }
    func pasteImage(_ image: UIImage, at normalizedPoint: CGPoint?, page: Int) {
        insertImages([image], at: normalizedPoint ?? CGPoint(x: 0.5, y: 0.5), page: page)
    }
    private func insertImages(_ images: [UIImage], at point: CGPoint, page number: Int) {
        guard !isBusy, !retired, !materialMutating, !writesSuspended, !images.isEmpty,
              editorTask == nil, let persistence, (1...pageCount).contains(number) else { return }
        let targetGeneration = generation, targetRevision = pageRevision
        isBusy = true; store.markDocumentChanged(); restoreInput()
        let task = Task { @MainActor in
            defer { self.editorTask = nil }
            try await self.flushInput()
            var values: [[String: Any]] = []
            for (index, image) in images.enumerated() {
                let asset: NativeImportedImage
                do { asset = try await NativeEditorMediaImport.saveImage(image, courseID: self.document.courseID, store: self.store) }
                catch { self.reportMediaDropError(error); return }
                let ratio = asset.pixelSize.height / max(asset.pixelSize.width, 1)
                let width = min(0.45, 0.65 * self.aspect(number) / max(ratio, 0.001))
                let height = width * ratio / self.aspect(number)
                let x = min(1 - width, max(0, point.x - width / 2 + Double(index) * 0.025))
                let y = min(1 - height, max(0, point.y - height / 2 + Double(index) * 0.025))
                values.append(["page": number, "kind": "image", "data": ["box": ["x": x, "y": y, "width": width, "height": height],
                    "image": ["relPath": asset.relativePath, "label": asset.name]], "style": ["color": "ink", "width": 0.003, "opacity": 1]])
            }
            guard !self.retired, !self.writesSuspended, self.generation == targetGeneration, self.pageRevision == targetRevision else {
                self.mediaImportError = "이미지를 저장하는 동안 PDF가 변경되어 삽입하지 않았습니다. 다시 놓아 주세요."; return
            }
            // A transition may set materialMutating while waiting for editorTask;
            // finish this already-accepted edit before releasing that barrier.
            try await persistence.createObjects(values)
            let importedPaths = Set(values.compactMap { (($0["data"] as? [String: Any])?["image"] as? [String: Any])?["relPath"] as? String })
            let insertedIDs = Set(persistence.rows.compactMap { row -> String? in
                guard let path = ((row["data"] as? [String: Any])?["image"] as? [String: Any])?["relPath"] as? String,
                      importedPaths.contains(path) else { return nil }
                return row["id"] as? String
            })
            self.rememberActiveStyle()
            self.previousTool = self.tool; self.tool = "select"; self.pencilEraser = false; self.showStyle = false
            self.gesture = nil; self.clearSourceSelection()
            self.sceneEpoch += 1; self.sceneRevisions.removeAll(); self.sceneFingerprints.removeAll()
            self.dirtyScenes.formUnion(self.scenePages)
            self.setSelection(insertedIDs, page: number)
            self.savePreferences()
            try await self.publishSnapshot(); self.refreshHistory()
        }
        editorTask = task
        Task { @MainActor in
            do { try await task.value; self.isBusy = self.materialMutating; self.restoreInput() }
            catch { self.isBusy = self.materialMutating; self.fail(error) }
        }
    }
    func restyleSelection(color: String? = nil, width: Double? = nil, opacity: Double? = nil) {
        guard !isBusy, !selectedRows.isEmpty else { return }
        performObjectEdit("update", values: NativePDFEditingGeometry.restyled(selectedRows, color: color, width: width, opacity: opacity), expected: selectedRows, keepSelection: true)
    }
    private func openText(at point: CGPoint, page number: Int) {
        let boxes = rows(on: number).filter { $0["kind"] as? String == "textbox" }
        if let target = NativePDFEditingGeometry.hit(point, rows: boxes, aspect: aspect(number)), let row = boxes.first(where: { $0["id"] as? String == target }) {
            presentText(row, existing: true)
        } else {
            presentText(NativePDFTextDraft.newObject(at: point, page: number, pageSize: pageSize(number), defaults: defaults), existing: false)
        }
    }
    /// Edits in place: the page overlay hosts the text view, the pane shows the format bar.
    private func presentText(_ object: [String: Any], existing: Bool) {
        if textEditorDraft != nil { clearTextEditor() }
        textObject = object; editingExistingText = existing; pendingTextSave = nil; textCreateMutationID = UUID().uuidString
        let number = (object["page"] as? NSNumber)?.intValue ?? page
        let draft = NativePDFTextDraft(object: object, pageSize: pageSize(number), existing: existing, defaults: defaults,
            onChange: { [weak self] in self?.markDraftChanged() })
        textEditorDraft = draft; textEditorPage = number; textEditorPresentedAt = CFAbsoluteTimeGetCurrent()
        let input = NativePDFTextInput(draft: draft, onSave: { [weak self] in self?.finishText() }, onCancel: { [weak self] in self?.cancelText() })
        textInput = input
        clearSelection(); showStyle = false
        host?.setTextEditor(surfaceID: surfaceID, generation: generation, page: number, view: input.view)
        requestScene(number); restoreInput()
    }
    private func clearTextEditor() {
        if let page = textEditorPage { host?.setTextEditor(surfaceID: surfaceID, generation: generation, page: page, view: nil); dirtyScenes.insert(page) }
        textInput?.detach(); textInput = nil; textObject = nil; textEditorDraft = nil; textEditorPage = nil
    }
    /// 완료 / tap outside / tool switch: keep text, drop an emptied box.
    func finishText() {
        guard let draft = textEditorDraft, !isBusy else { return }
        host?.restoreTextScroll(surfaceID: surfaceID, generation: generation)
        draft.finishComposition()
        if draft.hasText { commitText() } else if editingExistingText { deleteText() } else { cancelText() }
    }
    func commitText() {
        guard let object = textObject, let draft = textEditorDraft, let persistence, editorTask == nil else { return }
        if pendingTextSave == nil {
            guard let value = draft.objectForSave() else { return }
            pendingTextSave = value
        }
        guard let row = pendingTextSave else { return }
        let existing = editingExistingText
        store.markDocumentChanged(); isBusy = true; restoreInput()
        let task = Task { @MainActor in
            defer { self.editorTask = nil }
            // Drain the original durable operation before retrying. A lost
            // reply must not create a second copy of the same text box.
            try await self.flushInput()
            @MainActor func savedRows() -> [[String: Any]] {
                persistence.rows.filter { saved in
                    guard saved["kind"] as? String == "textbox", let id = saved["id"] as? String,
                          let data = saved["data"] as? [String: Any], let style = saved["style"] as? [String: Any],
                          let wantedData = row["data"] as? [String: Any], let wantedStyle = row["style"] as? [String: Any] else { return false }
                    return id == object["id"] as? String && (saved["page"] as? NSNumber) == (row["page"] as? NSNumber) &&
                        NSDictionary(dictionary: data).isEqual(to: wantedData) && NSDictionary(dictionary: style).isEqual(to: wantedStyle)
                }
            }
            let saved: [String: Any]
            if existing {
                if savedRows().isEmpty { try await persistence.updateObjects([row], expected: [object]) }
                guard let value = savedRows().first else { throw NativePDFError.invalid("텍스트 저장 결과를 확인하지 못했습니다. 다시 저장해 주세요.") }
                saved = value
            } else {
                saved = try await persistence.createObject(row, mutationID: self.textCreateMutationID)
                guard let data = saved["data"] as? [String: Any], let style = saved["style"] as? [String: Any],
                      let wantedData = row["data"] as? [String: Any], let wantedStyle = row["style"] as? [String: Any],
                      NSDictionary(dictionary: data).isEqual(to: wantedData), NSDictionary(dictionary: style).isEqual(to: wantedStyle) else {
                    throw NativePDFError.invalid("다른 PDF 창에서 저장된 텍스트를 변경했습니다. 최신 내용을 확인해 주세요.")
                }
            }
            try await self.publishSnapshot(); self.refreshHistory()
            guard let id = saved["id"] as? String else {
                throw NativePDFError.invalid("텍스트 저장 결과를 확인하지 못했습니다. 다시 저장해 주세요.")
            }
            self.pendingTextSave = nil
            self.clearTextEditor()
            self.errorMessage = nil; self.blockedForError = false; self.isBusy = self.materialMutating
            if self.tool == "text" { self.chooseTool("select") }
            let number = (saved["page"] as? NSNumber)?.intValue ?? self.page
            if self.tool == "select" { self.setSelection([id], page: number) }
            self.requestScene(number); self.restoreInput()
        }
        editorTask = task
        Task { @MainActor in
            do { try await task.value }
            catch {
                if !persistence.hasUnsettledEdits, persistence.pendingCount == 0 {
                    self.pendingTextSave = nil
                }
                self.isBusy = self.materialMutating; self.fail(error)
            }
        }
    }
    func cancelText() {
        guard !isBusy, pendingTextSave == nil else { return }
        clearTextEditor()
        errorMessage = nil; blockedForError = false; updateStyle(); restoreInput()
    }
    func deleteText() {
        guard let object = textObject, editingExistingText, !isBusy, pendingTextSave == nil else { return }
        clearTextEditor()
        performObjectEdit("delete", values: [object])
    }
    private func refreshAnnotations() async throws {
        try await persistence?.reloadAnnotations(); annotations = persistence?.annotations ?? []
        annotationCount = annotations.count
        annotationItems = annotations.compactMap { row in
            guard let id = row["id"] as? String, let page = row["page"] as? Int else { return nil }
            return AnnotationItem(id: id, page: page, quote: (row["anchor"] as? [String: Any])?["quote"] as? String ?? "", comment: row["comment"] as? String ?? "", color: row["color"] as? String ?? "yellow")
        }
    }
    func markDraftChanged() { store.markDocumentChanged() }
    func clearSourceSelection() {
        sourceQuote = ""; sourceSelection = nil
        host?.clearTextSelection(surfaceID: surfaceID, generation: generation)
    }
    func highlightSource(color: String) {
        guard var value = sourceSelection, !isBusy else { return }
        value["color"] = color; value["comment"] = NSNull()
        performAnnotationEdit("create", value: value)
    }
    func commentSource() {
        guard let value = sourceSelection, !isBusy else { return }
        presentAnnotation(value, existing: false)
    }
    func openAnnotation(id: String) {
        guard !isBusy, let value = annotations.first(where: { $0["id"] as? String == id }) else { return }
        presentAnnotation(value, existing: true)
    }

    private func presentAnnotation(_ value: [String: Any], existing: Bool) {
        clearSelection(); annotationDraft = value; editingAnnotation = existing
        annotationComment = value["comment"] as? String ?? ""; annotationColor = value["color"] as? String ?? "yellow"
        annotationQuote = (value["anchor"] as? [String: Any])?["quote"] as? String ?? ""
        showAnnotationEditor = true; restoreInput()
    }
    func commitAnnotation() {
        guard var value = annotationDraft, editorTask == nil else { return }
        value["color"] = annotationColor; value["comment"] = annotationComment.isEmpty ? NSNull() : annotationComment as Any
        let existing = editingAnnotation, original = annotationDraft; annotationDraft = nil; showAnnotationEditor = false
        performAnnotationEdit(existing ? "update" : "create", value: value, expected: original)
    }
    func deleteAnnotation() {
        guard let value = annotationDraft, editingAnnotation else { return }
        annotationDraft = nil; showAnnotationEditor = false; performAnnotationEdit("delete", value: value)
    }
    func cancelAnnotation() { annotationDraft = nil; showAnnotationEditor = false; restoreInput() }
    func dismissAnnotation() { annotationDraft = nil; restoreInput() }
    private func performAnnotationEdit(_ action: String, value: [String: Any], expected: [String: Any]? = nil) {
        guard editorTask == nil, let persistence, !retired else { return }
        store.markDocumentChanged(); isBusy = true; clearSourceSelection()
        let task = Task { @MainActor in
            defer { self.editorTask = nil }
            self.restoreInput(); try await self.flushInput()
            switch action {
            case "create": try await persistence.createAnnotation(value)
            case "update": try await persistence.updateAnnotation(value, expected: expected)
            case "delete": guard let id = value["id"] as? String else { throw NativePDFError.invalid("주석을 확인하지 못했습니다.") }; try await persistence.deleteAnnotation(id: id)
            default: throw NativePDFError.invalid("주석 작업을 확인하지 못했습니다.")
            }
            try await self.refreshAnnotations(); try await self.publishSnapshot(); self.refreshHistory()
        }
        editorTask = task
        Task { @MainActor in
            do { try await task.value; self.isBusy = self.materialMutating; self.restoreInput() }
            catch { self.isBusy = self.materialMutating; self.fail(error) }
        }
    }
    func go(to requested: Int) {
        guard !isLoading, !isBusy else { return }
        let target = min(pageCount, max(1, requested))
        Task {
            do {
                _ = try await call("navigate", ["page": target, "progress": 0])
                if page != target {
                    page = target
                    store.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:pdfPageChanged", payload: ["courseId": document.courseID, "relPath": document.relativePath, "tabID": document.id, "page": target]))
                }
            }
            catch { fail(error) }
        }
    }
    func setZoom(_ value: Double) {
        guard !isLoading, !isBusy else { return }
        Task { do { _ = try await call("navigate", ["zoom": min(4, max(0.4, value))]) } catch { fail(error) } }
    }
    func fitPage() { Task { do { _ = try await call("navigate", ["zoom": 1.0]) } catch { fail(error) } } }
    func find() { Task { do { _ = try await call("find") } catch { fail(error) } } }
    func exportPDF() {
        guard !isLoading, !isBusy, errorMessage == nil else { return }
        isBusy = true; host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        Task {
            do {
                try await flush()
                _ = try await store.invoke("pdf:exportAnnotated", ["courseId": document.courseID, "relPath": document.relativePath])
                isBusy = materialMutating
                host?.setPresentation(blocked: false, inputBlocked: materialMutating || blockedForError || closing != nil, overlays: [])
            } catch { isBusy = materialMutating; fail(error) }
        }
    }
    func undo() { runHistory(undo: true) }
    func redo() { runHistory(undo: false) }
    private func runHistory(undo: Bool) {
        guard !isBusy, !isLoading, errorMessage == nil else { return }
        store.markDocumentChanged()
        isBusy = true; host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        let task = Task { @MainActor in
            defer { self.historyTask = nil }
            if let editorTask = self.editorTask { try await editorTask.value }
            try await self.flushInput()
            self.clearSelection()
            if undo { try await self.persistence?.undo() } else { try await self.persistence?.redo() }
            self.refreshHistory()
        }
        historyTask = task
        Task { @MainActor in
            do {
                try await task.value
                isBusy = materialMutating
                host?.setPresentation(blocked: false, inputBlocked: materialMutating || blockedForError || closing != nil, overlays: [])
            } catch { isBusy = materialMutating; fail(error) }
        }
    }
    func flush() async throws {
        if showAnnotationEditor, annotationDraft != nil { commitAnnotation() }
        if textEditorDraft != nil { finishText() }
        repeat {
            if let historyTask { try await historyTask.value }
            if let editorTask { try await editorTask.value }
            try await flushInput()
            // Host.flush can complete an active shape/selection gesture.
            // Include that newly registered edit in the same close barrier.
        } while historyTask != nil || editorTask != nil
    }
    private func flushInput() async throws {
        if writesSuspended { await store.waitForExternalMutation() }
        guard !retired else { return }
        if let opening {
            do { try await opening.value }
            catch {
                // A malformed/locked PDF never accepted a contact. Its existing
                // on-disk recovery files remain intact and must not trap navigation.
                if !exposed { return }
                throw error
            }
        }
        guard opened, !retired else { return }
        if let flushing { try await flushing.value; return }
        // The 15 s sync tick flushes every open document. Nothing to flush when
        // no event reached this editor since the last barrier.
        guard inputSinceFlush else { return }
        inputSinceFlush = false
        let task = Task { @MainActor in
            defer { self.flushing = nil }
            guard let persistence = self.persistence,
                  let result = try await self.call("flush") as? [String: Any] else { return }
            try await persistence.recoverStrokes(result["pending"] as? [[String: Any]] ?? [])
            for operation in result["pendingOperations"] as? [[String: Any]] ?? [] {
                try persistence.accept(operation, type: operation["type"] as? String ?? "stroke")
            }
            try await persistence.drain(through: result["throughOperationSequence"] as? Int)
            if let snapshot = self.snapshotTask { try await snapshot.value }
            // Read the host's exact position at the persistence barrier. The
            // coalesced UI event can still describe the previous page/zoom.
            if let current = result["viewport"] as? [String: Any] { self.viewport = current }
            var saved = self.viewport
            saved["courseId"] = self.document.courseID; saved["relPath"] = self.document.relativePath
            if !(saved as NSDictionary).isEqual(to: self.lastSavedViewport ?? [:]) {
                _ = try await self.store.invoke("pdf:setViewState", saved); self.lastSavedViewport = saved
            }
            self.preferences.viewport = .init(revision: self.pageRevision, values: saved)
            self.savePreferences()
            persistence.checkpointHistory(root: self.store.root)
            self.refreshHistory()
        }
        flushing = task
        do { try await task.value }
        catch {
            // The clean fast path is valid only after the barrier succeeds.
            // A failed save must run again even without another touch event.
            inputSinceFlush = true
            throw error
        }
    }
    func retry() {
        guard !isBusy else { return }
        if pendingPageOperation != nil { resumePageOperation(); return }
        isBusy = true
        Task {
            do {
                if !setupComplete {
                    opening = nil
                    let task = Task { @MainActor in try await self.open() }; opening = task
                    try await task.value
                }
                try await flush(); try await publishSnapshot(); try await publishLayout()
                errorMessage = nil; blockedForError = false; isBusy = false; isLoading = false
                host?.setPresentation(blocked: false, inputBlocked: materialMutating, overlays: [])
            } catch { isBusy = false; fail(error) }
        }
    }
    func close() {
        guard closing == nil, !retired else { return }
        host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        closing = Task { @MainActor in
            defer { self.closing = nil }
            do {
                try await self.flush()
                if self.opened {
                    do { _ = try await self.call("close") }
                    catch { if self.exposed { throw error } }
                }
                self.retired = true; self.host = nil
                if let registration = self.registration { self.store.unregisterDocumentFlush(registration); self.registration = nil }
            } catch { self.fail(error) }
        }
    }
    func saveInBackground() {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Save native PDF")
        Task { @MainActor in
            defer { if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) } }
            do { try await flush() } catch { fail(error) }
        }
    }
    private func refreshHistory() {
        // @Published fires on every assignment; several refreshes land per stroke.
        let undo = persistence?.canUndo == true || (persistence?.pendingCount ?? 0) > 0
        if undo != canUndo { canUndo = undo }
        let redo = persistence?.canRedo == true
        if redo != canRedo { canRedo = redo }
        let count = persistence?.rows.count ?? 0
        if count != drawingCount { drawingCount = count }
        let pending = persistence?.pendingCount ?? 0
        if pending != pendingCount { pendingCount = pending }
    }
    private func fail(_ error: Error) {
        errorMessage = error.localizedDescription
        textInput?.view.isEditable = false
        if !blockedForError {
            blockedForError = true
            host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        }
        refreshHistory()
    }
    func setAvailableWidth(_ value: CGFloat) {
        availableWidth = value
        if value < 900, showPages, showAnnotations { showAnnotations = false }
    }
    func openPageNote() {
        guard !isBusy, !isLoading, let onOpenDocument else { return }
        isBusy = true; restoreInput()
        Task { @MainActor in
            do {
                let note = try await store.openPDFPageNote(courseID: document.courseID, relativePath: document.relativePath)
                isBusy = materialMutating; restoreInput(); onOpenDocument(note)
            } catch { isBusy = materialMutating; fail(error) }
        }
    }
    func togglePages() {
        showPages.toggle()
        if showPages {
            if availableWidth < 900 { showAnnotations = false }
            Task { do { try await refreshPageHistory() } catch { fail(error) } }
        }
        savePreferences()
    }
    func toggleAnnotations() {
        showAnnotations.toggle()
        if showAnnotations, availableWidth < 900 { showPages = false }
        savePreferences()
    }
    func toggleTools() {
        if toolsExpanded { if tool != "select" { chooseTool("select") }; toolsExpanded = false; showStyle = false } else { toolsExpanded = true }
        savePreferences()
    }
    func requestDeletePage(_ number: Int) {
        guard !isBusy, pageCanRestructure, pageCount > 1, (1...pageCount).contains(number) else { return }
        pageDeleteConfirmation = number
    }
    func confirmDeletePage(_ number: Int) {
        pageDeleteConfirmation = nil
        guard let recipe = NativePDFPageEditing.deleted(count: pageCount, page: number) else { return }
        restructure(recipe)
    }
    func movePage(_ number: Int, to target: Int) {
        guard let recipe = NativePDFPageEditing.moved(count: pageCount, from: number, to: target) else { return }
        restructure(recipe)
    }
    func dropPage(_ number: Int, at slot: Int) {
        draggedPage = nil; pageDropSlot = nil
        guard let recipe = NativePDFPageEditing.moved(count: pageCount, from: number, insertionSlot: slot) else { return }
        restructure(recipe)
    }
    /// GoodNotes-style: a new page copies the preceding page's paper template.
    func addPage(after number: Int) {
        guard let recipe = NativePDFPageEditing.inserted(count: pageCount, after: number) else { return }
        restructure(recipe, goTo: number + 1)
    }
    private func restructure(_ pages: [Int], goTo: Int? = nil) {
        guard !isBusy, !isLoading, pageCanRestructure, !pageRevision.isEmpty else { return }
        performPageOperation("pdf:restructure", request: ["courseId": document.courseID, "relPath": document.relativePath,
            "documentRevision": pageRevision, "clientMutationId": UUID().uuidString, "pages": pages], goTo: goTo)
    }
    func restorePageChange(undo: Bool) {
        guard !isBusy, !isLoading, let token = undo ? pageUndoToken : pageRedoToken else { return }
        performPageOperation("pdf:restorePages", request: ["courseId": document.courseID, "relPath": document.relativePath,
            "documentRevision": pageRevision, "clientMutationId": UUID().uuidString, "historyToken": token, "direction": undo ? "undo" : "redo"])
    }
    func recoverPageCopy() {
        guard !isBusy, let token = pageRecoverToken else { return }
        performPageOperation("pdf:recoverPagesCopy", request: ["courseId": document.courseID, "relPath": document.relativePath,
            "clientMutationId": UUID().uuidString, "historyToken": token, "variant": "before"])
    }
    private func refreshPageHistory() async throws {
        guard !retired else { return }
        guard let result = try await store.invoke("pdf:pageHistory", ["courseId": document.courseID, "relPath": document.relativePath]) as? [String: Any] else { throw NativePDFError.invalid("페이지 복구 기록을 확인하지 못했습니다.") }
        guard !retired else { return }
        pageCanRestructure = result["canRestructure"] as? Bool ?? true
        pageUndoToken = result["undoToken"] as? String; pageRedoToken = result["redoToken"] as? String
        pageHistoryCanUndo = result["canUndo"] as? Bool == true; pageHistoryCanRedo = result["canRedo"] as? Bool == true
        pageHistoryReason = result["restructureReason"] as? String ?? result["reason"] as? String
        pageRecoverToken = result["recoverToken"] as? String ?? pageUndoToken ?? pageRedoToken
        pageHistoryCanRecover = pageRecoverToken != nil
    }
    private func performPageOperation(_ channel: String, request: [String: Any], goTo: Int? = nil) {
        guard pageOperation == nil, pendingPageOperation == nil, !retired else { return }
        pendingPageOperation = PendingPageOperation(channel: channel, request: request, goTo: goTo)
        resumePageOperation()
    }
    private func resumePageOperation() {
        guard pageOperation == nil, !retired, let pending = pendingPageOperation else { return }
        isBusy = true; errorMessage = nil; blockedForError = false
        host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        // This task intentionally does not join editorTask: the store barrier
        // must be able to flush this editor before replacing its file bytes.
        pageOperation = Task { @MainActor in
            defer { self.pageOperation = nil }
            do {
                // This editor started the mutation: the store resumes it instead of
                // retiring it, and it reopens its own surface at the new revision.
                if pending.committedResult == nil {
                    _ = try await self.store.withExternalMutation({
                        let result = try await self.store.invoke(pending.channel, pending.request)
                        guard let value = result as? [String: Any] else { throw NativePDFError.invalid("페이지 변경 결과를 확인하지 못했습니다.") }
                        // Keep the receipt even if post-mutation sidebar work,
                        // view-state persistence or the new surface later fails.
                        pending.committedResult = value
                        return result
                    }, reopening: self.registration)
                }
                guard !self.retired, let value = pending.committedResult else { throw CancellationError() }
                if !pending.viewStateSaved, let goTo = pending.goTo, let count = value["pageCount"] as? Int {
                    // The reopen restores this saved position.
                    var saved = self.viewport
                    saved["courseId"] = self.document.courseID; saved["relPath"] = self.document.relativePath; saved["page"] = min(goTo, count)
                    _ = try await self.store.invoke("pdf:setViewState", saved)
                }
                pending.viewStateSaved = true
                if pending.channel == "pdf:recoverPagesCopy", let courseID = value["courseId"] as? String,
                   let relativePath = value["relPath"] as? String, let title = value["title"] as? String {
                    self.onOpenDocument?(.init(courseID: courseID, relativePath: relativePath, title: title, kind: "pdf"))
                } else if let revision = value["documentRevision"] as? String, revision != self.pageRevision || !self.setupComplete {
                    try await self.reopen()
                    guard self.setupComplete else { throw NativePDFError.invalid("변경된 PDF 화면을 다시 열지 못했습니다.") }
                } else if self.showPages { try await self.refreshPageHistory() }
                self.pendingPageOperation = nil
                self.isBusy = self.materialMutating; self.restoreInput()
            } catch {
                self.isBusy = self.materialMutating; self.fail(error)
            }
        }
    }
    private func setMaterialMutating(_ value: Bool) {
        materialMutating = value; isBusy = value || editorTask != nil || historyTask != nil || pageOperation != nil
        restoreInput()
    }
    /// After a page operation on this file: same host and surface, new generation
    /// and revision. Stroke undo does not survive (rows were rewritten); page
    /// history undo is the undo for the operation.
    private func reopen() async throws {
        guard host != nil, !retired else { return }
        clearTextEditor(); gesture = nil; sourceQuote = ""; sourceSelection = nil
        selectedIDs.removeAll(); selectionPage = nil; selectionCount = 0; selectedText = false; selectionFrame = nil
        persistence?.invalidateHistory(root: store.root)
        persistence?.onPeerChanged = nil; persistence?.onRowsChanged = nil; persistence?.onAnnotationsChanged = nil
        persistence = nil
        generation = UUID().uuidString // old-generation host events now fail receive()'s guard
        opened = false; setupComplete = false; isLoading = true
        drawingFingerprints = nil; publishedDrawingRevision = -1; displayRows = []
        sceneEpoch += 1; sceneRevisions.removeAll(); sceneFingerprints.removeAll(); scenePages.removeAll(); dirtyScenes.removeAll()
        thumbnailRevisions = [:]; thumbnailRowCache = [:]; thumbnailPageCounts = [:]; thumbnailDirtyPages = []
        thumbnailRefreshTask?.cancel(); thumbnailRefreshTask = nil
        let task = Task { @MainActor in try await self.open() }
        opening = task
        try await task.value
    }
    private func retire() {
        guard !retired else { return }
        retired = true; opened = false; writesSuspended = false
        persistence?.invalidateHistory(root: store.root)
        if let registration { store.unregisterDocumentFlush(registration); self.registration = nil }
        host?.setPresentation(blocked: false, inputBlocked: true, overlays: [])
        host?.emit = { _, _ in }; host = nil
    }
    private func receiveStoreEvent(_ event: NativeWorkspaceEvent) {
        guard let payload = event.payload as? [String: Any], payload["courseId"] as? String == document.courseID,
              let path = (payload["fromRelPath"] ?? payload["relPath"]) as? String,
              path == document.relativePath || payload["isDirectory"] as? Bool == true && document.relativePath.hasPrefix(path + "/") else { return }
        switch event.channel {
        case "nativeWorkspace:goToPage":
            if let tabID = payload["tabID"] as? String, tabID != document.id { return }
            guard let requested = payload["page"] as? Int, requested > 0 else { return }
            Task { @MainActor in
                do {
                    if let opening { try await opening.value }
                    try await flush()
                    guard !retired else { return }
                    let latest = NativePDFWorkspacePreferences.load(root: store.root, documentID: document.id, defaults: defaults).pendingPage
                    guard latest == nil || latest == requested else { return }
                    pendingViewportRestore = ["page": min(pageCount, max(1, requested)), "zoom": zoom,
                                              "progress": 0.0, "horizontalProgress": 0.0]
                    pendingPageToAcknowledge = latest
                    try await publishLayout()
                }
                catch { fail(error) }
            }
        case "nativeWorkspace:materialWillMutate":
            setMaterialMutating(true)
        case "nativeWorkspace:materialMutationCancelled":
            writesSuspended = false; setMaterialMutating(false)
        case "nativeWorkspace:materialReplaced" where pageOperation != nil:
            break // this editor's own page operation; it reopens in place
        case "nativeWorkspace:materialRenamed", "nativeWorkspace:materialDeleted", "nativeWorkspace:materialReplaced":
            // The store's mutation barrier already finished all input. Do not
            // recreate pdf_view_state under the obsolete file path on teardown.
            retire()
        default: break
        }
    }
}

private struct NativePDFBody: UIViewControllerRepresentable {
    let model: NativePDFWorkspaceModel
    var visible = true
    func makeUIViewController(context: Context) -> NativePDFBodyController { NativePDFBodyController(model: model) }
    func updateUIViewController(_ controller: NativePDFBodyController, context: Context) {
        // UIKit hidden views leave the accessibility tree; SwiftUI's accessibilityHidden does not reach them.
        // UIKit hidden views leave the accessibility tree; SwiftUI's accessibilityHidden does not reach them.
        if controller.view.isHidden != !visible { controller.view.isHidden = !visible }
        controller.view.accessibilityElementsHidden = !visible
    }
    static func dismantleUIViewController(_ controller: NativePDFBodyController, coordinator: ()) { controller.model.close() }
}
private final class NativePDFBodyController: UIViewController {
    let model: NativePDFWorkspaceModel
    init(model: NativePDFWorkspaceModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var mediaDrop: NativeEditorDropInteraction?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .secondarySystemBackground; model.attach(to: view)
        let drop = NativeEditorDropInteraction(view: view, imagesOnly: true) { [weak model] items, point in model?.receiveMediaDrop(items, at: point) }
        drop.onBegin = { [weak model] point in model?.beginMediaDrop(at: point) }
        drop.onError = { [weak model] error in model?.reportMediaDropError(error) }
        drop.isEnabled = { [weak model] in model.map { $0.assistantAnnotation == nil && !$0.isBusy && !$0.isLoading && $0.errorMessage == nil } ?? false }
        mediaDrop = drop
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); model.layout(view.bounds) }
}
