import SwiftUI
import PDFKit
import PencilKit
import PhotosUI
import ImageIO

@MainActor
enum PendingPDFNavigation {
    static let changed = Notification.Name("app.bandal.pdf.navigation")
    private static var pages: [String: Int] = [:]
    static func request(materialID: String, page: Int) {
        pages[materialID] = page
        NotificationCenter.default.post(name: changed, object: materialID)
    }
    static func takePage(materialID: String) -> Int? { pages.removeValue(forKey: materialID) }
}

struct PDFWorkspaceView: View {
    @StateObject private var controller: PDFWorkspaceController
    @StateObject private var tools = InkToolState()
    @State private var searchText = ""
    @State private var showsSearch = false
    @State private var showsPages = false
    @State private var showsText = false
    @State private var textToInsert = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @Environment(\.scenePhase) private var scenePhase
    private let onPageNote: ((Int) -> Void)?

    init(documentURL: URL, materialID: String, revision: String,
         loadPage: @escaping (Int) -> Data?, savePage: @escaping (Int, Data) -> Void,
         onExport: @escaping (URL) -> Void,
         resolveImage: @escaping (InkImageSource) -> URL? = { _ in nil },
         saveImage: ((Data) -> InkImageSource?)? = nil,
         onPageNote: ((Int) -> Void)? = nil,
         initialPage: Int? = nil, onPageChange: ((Int) -> Void)? = nil) {
        self.onPageNote = onPageNote
        _controller = StateObject(wrappedValue: PDFWorkspaceController(
            documentURL: documentURL, materialID: materialID, revision: revision,
            loadPage: loadPage, savePage: savePage, onExport: onExport,
            resolveImage: resolveImage, saveImage: saveImage, initialPage: initialPage, onPageChange: onPageChange))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { showsPages = true } label: { Image(systemName: "square.grid.2x2").frame(width: 44, height: 44) }
                    .accessibilityLabel("PDF 페이지 목록")
                Button { controller.previousPage() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(controller.currentPage <= 1).accessibilityLabel("이전 페이지")
                Text("\(controller.currentPage) / \(controller.pageCount)")
                    .font(.footnote.monospacedDigit()).accessibilityLabel("\(controller.pageCount)쪽 중 \(controller.currentPage)쪽")
                Button { controller.nextPage() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(controller.currentPage >= controller.pageCount).accessibilityLabel("다음 페이지")
                Spacer(minLength: 0)
                Button { showsSearch.toggle() } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }
                    .accessibilityLabel("PDF 검색").keyboardShortcut("f", modifiers: .command)
                if controller.imageImportEnabled {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo.badge.plus").frame(width: 44, height: 44)
                    }.accessibilityLabel("PDF에 이미지 추가")
                }
                Menu {
                    if let onPageNote {
                        Button("이 페이지 노트", systemImage: "note.text") { onPageNote(controller.currentPage) }
                    }
                    Button("선택한 텍스트 강조", systemImage: "highlighter") { controller.highlightSelection(color: tools.color == .ink ? .yellow : tools.color) }
                    Button("텍스트 메모 추가", systemImage: "text.bubble") { showsText = true }
                    Button("필기 포함 PDF 내보내기", systemImage: "square.and.arrow.up") { controller.exportPDF() }
                    Button("현재 쪽에 맞춤", systemImage: "arrow.up.left.and.arrow.down.right") { controller.fitPage() }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .accessibilityLabel("PDF 작업")
            }.padding(.horizontal, 8).background(.bar)
            if showsSearch {
                HStack {
                    TextField("PDF에서 검색", text: $searchText).textFieldStyle(.roundedBorder)
                        .submitLabel(.search).onSubmit { controller.search(searchText) }
                    Button("검색") { controller.search(searchText) }.frame(minWidth: 44, minHeight: 44)
                    if !controller.searchResults.isEmpty {
                        Text("\(controller.searchIndex + 1)/\(controller.searchResults.count)").font(.caption)
                        Button { controller.nextSearchResult() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                            .accessibilityLabel("다음 검색 결과")
                    }
                }.padding(.horizontal, 12).background(.bar)
            }
            if let error = controller.warning {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.caption)
                    Spacer(minLength: 0)
                    Button { controller.warning = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("안내 닫기")
                }.padding(.leading, 12).background(Color.orange.opacity(0.12))
            }
            if controller.document == nil {
                ContentUnavailableView("PDF를 열 수 없습니다", systemImage: "doc.questionmark",
                                       description: Text("파일이 손상되었거나 접근할 수 없는 위치에 있습니다."))
            } else {
                PDFViewHost(controller: controller, tools: tools)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
            InkToolPalette(tools: tools, undo: controller.undo, redo: controller.redo,
                           insertShape: { controller.insertShape($0, tools: tools) })
        }
        .sheet(isPresented: $showsPages) {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 18) {
                        ForEach(0..<controller.pageCount, id: \.self) { index in
                            if let page = controller.document?.page(at: index) {
                                Button {
                                    controller.goToPage(index + 1); showsPages = false
                                } label: {
                                    VStack {
                                        Image(uiImage: page.thumbnail(of: CGSize(width: 110, height: 150), for: .cropBox))
                                            .resizable().scaledToFit().frame(width: 110, height: 150)
                                            .background(.white).clipShape(RoundedRectangle(cornerRadius: 5))
                                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(controller.currentPage == index + 1 ? Color.accentColor : .clear, lineWidth: 3))
                                        Text("\(index + 1)").font(.caption)
                                    }
                                }.accessibilityLabel("\(index + 1)쪽 열기")
                            }
                        }
                    }.padding()
                }.navigationTitle("페이지")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { showsPages = false } } }
            }.presentationDetents([.medium, .large])
        }
        .alert("텍스트 메모", isPresented: $showsText) {
            TextField("내용", text: $textToInsert)
            Button("추가") { controller.insertText(textToInsert, color: tools.color); textToInsert = "" }
            Button("취소", role: .cancel) { textToInsert = "" }
        } message: { Text("현재 페이지 중앙에 메모를 추가합니다.") }
        .onDisappear { controller.flush() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller.flush() } }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            Task {
                do {
                    if let data = try await photo.loadTransferable(type: Data.self) { controller.insertImage(data) }
                    else { controller.warning = "이미지를 읽지 못했습니다." }
                } catch { controller.warning = "이미지를 가져오지 못했습니다: \(error.localizedDescription)" }
                selectedPhoto = nil
            }
        }
    }
}

private struct PDFViewHost: UIViewRepresentable {
    @ObservedObject var controller: PDFWorkspaceController
    @ObservedObject var tools: InkToolState
    func makeUIView(context: Context) -> PDFView {
        controller.install(tools: tools)
        return controller.pdfView
    }
    func updateUIView(_ view: PDFView, context: Context) { controller.configure(tools: tools) }
    static func dismantleUIView(_ uiView: PDFView, coordinator: ()) {
        (uiView.pageOverlayViewProvider as? PDFWorkspaceController)?.flush()
    }
}

@MainActor
final class PDFWorkspaceController: NSObject, ObservableObject, @preconcurrency PDFPageOverlayViewProvider {
    @Published var currentPage = 1
    @Published var pageCount = 0
    @Published var warning: String?
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    let pdfView: PDFView = ReadingPDFView()
    let document: PDFDocument?
    private let documentURL: URL
    private let materialID: String
    private let revision: String
    private let loadPage: (Int) -> Data?
    private let savePage: (Int, Data) -> Void
    private let onExport: (URL) -> Void
    private let resolveImage: (InkImageSource) -> URL?
    private let saveImage: ((Data) -> InkImageSource?)?
    private let initialPage: Int?
    private let onPageChange: ((Int) -> Void)?
    private var restoredReadingPosition = false
    private var restoringNavigation = false
    private var lastEmittedPage: Int?
    private var readingKey: String { "Bandal.PDFReading.\(materialID).\(revision)" }
    var imageImportEnabled: Bool { saveImage != nil }
    private var overlays: [Int: PDFInkOverlay] = [:]
    private var records: [Int: PortableInkPageRecord] = [:]
    private var blockedPages = Set<Int>()
    private var annotationPages = Set<Int>()
    private var addedAnnotations: [Int: [PDFAnnotation]] = [:]
    private var loadedData: [Int: Data] = [:]
    private var unresolvedImagePages = Set<Int>()
    private var refreshTask: Task<Void, Never>?
    private var incomingPages: [Int: (base: PortableInkPageRecord, remote: PortableInkPageRecord)] = [:]
    private var tools: InkToolState?
    private var installed = false
    private weak var activeCanvas: PersistentInkCanvas?

    init(documentURL: URL, materialID: String, revision: String,
         loadPage: @escaping (Int) -> Data?, savePage: @escaping (Int, Data) -> Void,
         onExport: @escaping (URL) -> Void,
         resolveImage: @escaping (InkImageSource) -> URL? = { _ in nil },
         saveImage: ((Data) -> InkImageSource?)? = nil,
         initialPage: Int? = nil, onPageChange: ((Int) -> Void)? = nil) {
        self.documentURL = documentURL; self.materialID = materialID; self.revision = revision
        self.loadPage = loadPage; self.savePage = savePage; self.onExport = onExport
        self.resolveImage = resolveImage; self.saveImage = saveImage
        self.initialPage = initialPage; self.onPageChange = onPageChange
        document = PDFDocument(url: documentURL)
        super.init()
        pageCount = document?.pageCount ?? 0
        if document?.isLocked == true { warning = "암호로 잠긴 PDF입니다. 잠금 해제된 파일을 가져와 주세요." }
    }

    func install(tools: InkToolState) {
        self.tools = tools
        guard !installed else { configure(tools: tools); return }
        installed = true
        (pdfView as? ReadingPDFView)?.onReady = { [weak self] in self?.restoreReadingPosition() }
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.pageOverlayViewProvider = self
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.isInMarkupMode = true
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(memoryWarning), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(followPageLink), name: PendingPDFNavigation.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recordsChanged), name: Notification.Name("app.bandal.records.changed"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(saveReadingPosition), name: .PDFViewScaleChanged, object: pdfView)
        configure(tools: tools)
        DispatchQueue.main.async { [weak self] in self?.restoreReadingPosition() }
    }

    func configure(tools: InkToolState) {
        self.tools = tools
        for overlay in overlays.values { overlay.canvas.configure(tools) }
        pdfView.isInMarkupMode = tools.tool != .read
        configureScrollGestures(in: pdfView, tools: tools)
    }

    private func configureScrollGestures(in view: UIView, tools: InkToolState) {
        if let scroll = view as? UIScrollView, !(scroll is PersistentInkCanvas) {
            scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.indirect.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            scroll.panGestureRecognizer.minimumNumberOfTouches = tools.fingerDrawing && tools.tool != .read ? 2 : 1
        }
        for child in view.subviews where !(child is PersistentInkCanvas) { configureScrollGestures(in: child, tools: tools) }
    }

    @objc private func pageChanged() {
        guard let page = pdfView.currentPage, let document else { return }
        guard restoredReadingPosition, !restoringNavigation else { return }
        currentPage = document.index(for: page) + 1
        emitCurrentPage()
        saveReadingPosition()
    }
    @objc private func backgrounded() { flush() }
    @objc private func followPageLink() {
        guard restoredReadingPosition else { return }
        if let number = PendingPDFNavigation.takePage(materialID: materialID) { goToPage(number) }
    }
    private func restoreReadingPosition() {
        guard !restoredReadingPosition, pdfView.window != nil, pdfView.bounds.width > 0,
              pdfView.bounds.height > 0, let document, document.pageCount > 0 else { return }
        let saved = UserDefaults.standard.dictionary(forKey: readingKey)
        let linked = PendingPDFNavigation.takePage(materialID: materialID)
        let requested = linked ?? initialPage ?? (saved?["page"] as? Int) ?? 1
        let number = min(max(1, requested), document.pageCount)
        guard let page = document.page(at: number - 1) else { return }
        // Mark before navigation because PDFKit emits synchronously while scrolling.
        restoredReadingPosition = true
        restoringNavigation = true
        lastEmittedPage = number
        currentPage = number
        if let ratio = saved?["zoomRatio"] as? Double, ratio.isFinite, ratio >= 1, ratio <= 8 {
            pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor, pdfView.scaleFactorForSizeToFit * ratio))
        }
        if linked == nil, (saved?["page"] as? Int) == number,
           let x = saved?["x"] as? Double, let y = saved?["y"] as? Double,
           x.isFinite, y.isFinite, abs(x) < 1_000_000, abs(y) < 1_000_000 {
            pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: x, y: y)))
        } else { pdfView.go(to: page) }
        currentPage = number; lastEmittedPage = number
        restoringNavigation = false
        onPageChange?(number)
        saveReadingPosition()
    }
    private func emitCurrentPage() {
        guard lastEmittedPage != currentPage else { return }
        lastEmittedPage = currentPage; onPageChange?(currentPage)
    }
    @objc private func saveReadingPosition() {
        guard restoredReadingPosition, !restoringNavigation, let destination = pdfView.currentDestination else { return }
        let fit = max(pdfView.scaleFactorForSizeToFit, 0.001)
        UserDefaults.standard.set(["page": currentPage, "x": Double(destination.point.x),
                                  "y": Double(destination.point.y), "zoomRatio": Double(pdfView.scaleFactor / fit)], forKey: readingKey)
    }
    @objc private func recordsChanged() {
        // Capture the remote page before a just-finished Pencil stroke invokes
        // savePage and changes the caller's in-memory record snapshot.
        for (number, baseline) in records {
            let data = loadPage(number)
            guard data != loadedData[number] else { continue }
            do {
                let remote = try data.map { try JSONDecoder().decode(PortableInkPageRecord.self, from: $0) } ??
                    PortableInkPageRecord.empty(materialID: materialID, revision: revision, page: number, geometry: baseline.geometry)
                try remote.validate(materialID: materialID, revision: revision, page: number, geometry: baseline.geometry)
                incomingPages[number] = (incomingPages[number]?.base ?? baseline, remote)
            } catch { warning = error.localizedDescription }
        }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while overlays.values.contains(where: { $0.canvas.hasActiveTool }) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            flush()
            for number in Array(Set(records.keys).union(overlays.keys).union(unresolvedImagePages)) {
                guard let page = document?.page(at: number - 1) else { continue }
                let incoming = loadPage(number)
                guard incoming != loadedData[number] || unresolvedImagePages.contains(number) else { continue }
                for annotation in addedAnnotations.removeValue(forKey: number) ?? [] { page.removeAnnotation(annotation) }
                annotationPages.remove(number); records.removeValue(forKey: number); blockedPages.remove(number)
                let geometry = InkPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
                let replacement = loadRecord(page: number, geometry: geometry)
                incomingPages.removeValue(forKey: number)
                overlays[number]?.canvas.reload(replacement)
                overlays[number]?.canvas.isReadOnly = blockedPages.contains(number)
                applyTextAnnotations(replacement, to: page)
            }
            if let tools { configure(tools: tools) }
        }
    }
    @objc private func memoryWarning() {
        flush()
        let visible = Set(pdfView.visiblePages.compactMap { page in document.map { $0.index(for: page) + 1 } })
        overlays = overlays.filter { visible.contains($0.key) }
        // Records are persisted; retain only visible page caches under memory pressure.
        records = records.filter { visible.contains($0.key) }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document else { return nil }
        let number = document.index(for: page) + 1
        if let existing = overlays[number] { return existing }
        let overlay = PDFInkOverlay()
        let canvas = overlay.canvas
        let geometry = InkPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let record = loadRecord(page: number, geometry: geometry)
        canvas.isReadOnly = blockedPages.contains(number)
        canvas.save = { [weak self] changed in self?.store(changed) }
        canvas.onBegin = { [weak self, weak canvas] in self?.activeCanvas = canvas }
        canvas.onLayout = { [weak self, weak page] canvas in
            guard let self, let page, canvas.window != nil else { return }
            let convert: (CGPoint) -> CGPoint = { point in
                self.pdfView.convert(canvas.convert(point, to: self.pdfView), to: page)
            }
            let origin = convert(.zero), x = convert(CGPoint(x: 1, y: 0)), y = convert(CGPoint(x: 0, y: 1))
            let map = InkCoordinateMapper(canvasToPDF: CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                c: y.x - origin.x, d: y.y - origin.y, tx: origin.x, ty: origin.y), geometry: geometry)
            if canvas.record == nil { canvas.restore(record, mapper: map) }
            canvas.updateMapper(map)
        }
        if let tools { canvas.configure(tools) }
        overlays[number] = overlay
        applyTextAnnotations(record, to: page)
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        overlayView.setNeedsLayout()
        overlayView.layoutIfNeeded()
        if let tools { configureScrollGestures(in: pdfView, tools: tools) }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        (overlayView as? PDFInkOverlay)?.canvas.flush()
    }

    private func loadRecord(page: Int, geometry: InkPageGeometry) -> PortableInkPageRecord {
        if let cached = records[page] { return cached }
        let empty = PortableInkPageRecord.empty(materialID: materialID, revision: revision, page: page, geometry: geometry)
        guard let data = loadPage(page) else { records[page] = empty; loadedData.removeValue(forKey: page); return empty }
        loadedData[page] = data
        do {
            let record = try JSONDecoder().decode(PortableInkPageRecord.self, from: data)
            try record.validate(materialID: materialID, revision: revision, page: page, geometry: geometry)
            records[page] = record
            return record
        } catch {
            blockedPages.insert(page)
            DispatchQueue.main.async { [weak self] in self?.warning = error.localizedDescription }
            return empty
        }
    }

    private func store(_ incomingRecord: PortableInkPageRecord) {
        var record = incomingRecord
        guard !blockedPages.contains(record.page) else { return }
        do {
            if let incoming = incomingPages.removeValue(forKey: record.page) {
                let merged = try PortableInkThreeWayMerge.merge(base: incoming.base, local: record, remote: incoming.remote)
                record = merged.record
                if overlays[record.page]?.canvas.hasActiveTool == true {
                    incomingPages[record.page] = (incomingRecord, record)
                } else { overlays[record.page]?.canvas.reload(record) }
                if let page = document?.page(at: record.page - 1) {
                    for annotation in addedAnnotations.removeValue(forKey: record.page) ?? [] { page.removeAnnotation(annotation) }
                    annotationPages.remove(record.page); applyTextAnnotations(record, to: page)
                }
                if merged.preservedConflicts { warning = "같은 필기의 동시 수정이 있어 두 버전을 별도 항목으로 보존했습니다." }
            }
            let data = try PortableInkPersistence.encode(record)
            records[record.page] = record
            loadedData[record.page] = data
            savePage(record.page, data)
        } catch { warning = "필기를 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func flush() { overlays.values.forEach { $0.canvas.flush() }; saveReadingPosition() }
    func previousPage() { goToPage(currentPage - 1) }
    func nextPage() { goToPage(currentPage + 1) }
    func goToPage(_ number: Int) {
        guard number > 0, let page = document?.page(at: number - 1) else { return }
        pdfView.go(to: page)
    }
    func fitPage() { pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit }
    private var currentCanvas: PersistentInkCanvas? { activeCanvas ?? overlays[currentPage]?.canvas }
    func undo() { currentCanvas?.performUndo() }
    func redo() { currentCanvas?.performRedo() }
    func insertShape(_ kind: String, tools: InkToolState) { overlays[currentPage]?.canvas.insertShape(kind, state: tools) }

    func search(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = query.isEmpty ? [] : document?.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
        searchIndex = 0
        if searchResults.isEmpty, !query.isEmpty { warning = "검색 결과가 없습니다." }
        showSearchResult()
    }
    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchResults.count
        showSearchResult()
    }
    private func showSearchResult() {
        guard searchResults.indices.contains(searchIndex) else { pdfView.clearSelection(); return }
        let selection = searchResults[searchIndex]
        selection.color = .systemYellow
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    func highlightSelection(color: InkPalette) {
        guard let selection = pdfView.currentSelection, let document, !(selection.string ?? "").isEmpty else {
            warning = "텍스트 선택 도구로 PDF의 글자를 선택한 뒤 강조해 주세요."; return
        }
        flush()
        for page in selection.pages {
            let number = document.index(for: page) + 1
            let geometry = InkPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            var record = loadRecord(page: number, geometry: geometry)
            guard !blockedPages.contains(number) else { continue }
            let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
            let highlight = PortableTextHighlight(id: UUID().uuidString, quote: selection.string ?? "",
                rects: lines.map { geometry.normalize($0.bounds(for: page)) }, color: color.rawValue,
                createdAt: ISO8601DateFormatter().string(from: Date()))
            record.highlights.append(highlight)
            overlays[number]?.canvas.record = record
            store(record); addHighlight(highlight, geometry: geometry, to: page)
        }
        pdfView.clearSelection()
    }

    func insertText(_ text: String, color: InkPalette) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let page = document?.page(at: currentPage - 1) else { return }
        flush()
        let geometry = InkPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        var record = loadRecord(page: currentPage, geometry: geometry)
        guard !blockedPages.contains(currentPage) else { return }
        let date = ISO8601DateFormatter().string(from: Date())
        let object = PortableInkObject(id: UUID().uuidString, kind: "textbox",
            data: InkGeometry(box: InkBox(x: 0.2, y: 0.35, width: 0.6, height: 0.2), text: text),
            style: InkStyle(color: color.rawValue, width: 0, opacity: 1), createdAt: date, updatedAt: date)
        record.objects.append(object)
        overlays[currentPage]?.canvas.record = record
        store(record); addText(object, geometry: geometry, to: page)
    }

    func insertImage(_ data: Data) {
        guard let saveImage, let page = document?.page(at: currentPage - 1) else { return }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary),
              let png = UIImage(cgImage: bitmap).pngData() else { warning = "지원하지 않는 이미지입니다."; return }
        flush()
        let geometry = InkPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        var record = loadRecord(page: currentPage, geometry: geometry)
        guard !blockedPages.contains(currentPage) else { return }
        guard var reference = saveImage(png) else { warning = "이미지 파일을 저장하지 못했습니다."; return }
        reference.widthPx = Double(bitmap.width); reference.heightPx = Double(bitmap.height)
        let width = 0.5
        let height = min(0.6, width * geometry.width * Double(bitmap.height) / Double(bitmap.width) / geometry.height)
        let scaledWidth = height * geometry.height * Double(bitmap.width) / Double(bitmap.height) / geometry.width
        let now = ISO8601DateFormatter().string(from: Date())
        let object = PortableInkObject(id: UUID().uuidString, kind: "image",
            data: InkGeometry(box: InkBox(x: (1 - scaledWidth) / 2, y: (1 - height) / 2,
                                         width: scaledWidth, height: height), image: reference),
            style: InkStyle(color: "ink", width: 0, opacity: 1), createdAt: now, updatedAt: now)
        record.objects.append(object); overlays[currentPage]?.canvas.record = record
        store(record)
        if !addImage(object, geometry: geometry, to: page) { warning = "이미지를 저장했지만 표시할 파일을 찾지 못했습니다." }
    }

    private func applyTextAnnotations(_ record: PortableInkPageRecord, to page: PDFPage) {
        guard !annotationPages.contains(record.page) else { return }
        annotationPages.insert(record.page)
        record.highlights.forEach { addHighlight($0, geometry: record.geometry, to: page) }
        record.objects.filter { $0.kind == "textbox" }.forEach { addText($0, geometry: record.geometry, to: page) }
        record.objects.filter { ["rect", "ellipse", "line", "arrow"].contains($0.kind) }
            .forEach { addShape($0, geometry: record.geometry, to: page) }
        let missingImage = record.objects.filter { $0.kind == "image" }
            .map { addImage($0, geometry: record.geometry, to: page) }.contains(false)
        if missingImage { unresolvedImagePages.insert(record.page) } else { unresolvedImagePages.remove(record.page) }
        if missingImage || record.objects.contains(where: { $0.kind == "clip" }) {
            DispatchQueue.main.async { [weak self] in
                self?.warning = "연결된 이미지 파일이나 자료 조각을 표시하지 못했습니다. 원본 필기 데이터는 보존됩니다."
            }
        }
    }

    private func addHighlight(_ highlight: PortableTextHighlight, geometry: InkPageGeometry, to page: PDFPage) {
        for box in highlight.rects {
            let annotation = PDFAnnotation(bounds: geometry.pdfRect(box), forType: .highlight, withProperties: nil)
            annotation.color = (InkPalette(rawValue: highlight.color) ?? .yellow).uiColor.withAlphaComponent(0.35)
            annotation.contents = highlight.quote
            annotation.userName = "Bandal"
            page.addAnnotation(annotation)
            track(annotation, page: page)
        }
    }
    private func addText(_ object: PortableInkObject, geometry: InkPageGeometry, to page: PDFPage) {
        guard let box = object.data.box else { return }
        let annotation = PDFAnnotation(bounds: geometry.pdfRect(box), forType: .freeText, withProperties: nil)
        annotation.contents = object.data.text
        annotation.font = .systemFont(ofSize: object.style.fontSizePt ?? 16, weight: object.style.bold == true ? .bold : .regular)
        annotation.fontColor = (InkPalette(rawValue: object.style.color) ?? .ink).uiColor
        annotation.color = object.style.fill.flatMap(InkPalette.init(rawValue:))?.uiColor.withAlphaComponent(0.2) ?? .clear
        annotation.alignment = object.style.align == "center" ? .center : object.style.align == "right" ? .right : .left
        let border = PDFBorder(); border.lineWidth = 0; annotation.border = border
        page.addAnnotation(annotation)
        track(annotation, page: page)
    }

    private func addShape(_ object: PortableInkObject, geometry: InkPageGeometry, to page: PDFPage) {
        guard let box = object.data.box else { return }
        let bounds = geometry.pdfRect(box)
        let subtype: PDFAnnotationSubtype = object.kind == "rect" ? .square : object.kind == "ellipse" ? .circle : .line
        let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = (InkPalette(rawValue: object.style.color) ?? .ink).uiColor.withAlphaComponent(object.style.opacity)
        let border = PDFBorder(); border.lineWidth = max(0.2, object.style.width * geometry.width); annotation.border = border
        if subtype == .line {
            annotation.startPoint = CGPoint(x: 0, y: bounds.height)
            annotation.endPoint = CGPoint(x: bounds.width, y: 0)
            if object.kind == "arrow" { annotation.endLineStyle = .openArrow }
        }
        page.addAnnotation(annotation)
        track(annotation, page: page)
    }

    private func track(_ annotation: PDFAnnotation, page: PDFPage) {
        guard let document, page.document === document else { return }
        addedAnnotations[document.index(for: page) + 1, default: []].append(annotation)
    }

    @discardableResult private func addImage(_ object: PortableInkObject, geometry: InkPageGeometry, to page: PDFPage) -> Bool {
        guard let box = object.data.box, let source = object.data.image,
              let url = resolveImage(source), let image = UIImage(contentsOfFile: url.path) else { return false }
        let annotation = PDFImageAnnotation(bounds: geometry.pdfRect(box), image: image)
        page.addAnnotation(annotation); track(annotation, page: page)
        return true
    }

    func exportPDF() {
        flush()
        // Open the untouched source to avoid duplicating transient annotations.
        guard let exported = PDFDocument(url: documentURL) else { warning = "원본 PDF를 읽지 못했습니다."; return }
        var hasImages = false
        for index in 0..<exported.pageCount {
            guard let page = exported.page(at: index) else { continue }
            let geometry = InkPageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
            let record = loadRecord(page: index + 1, geometry: geometry)
            guard !blockedPages.contains(index + 1) else {
                warning = "원본과 일치하지 않는 필기가 있어 내보내기를 중지했습니다."; return
            }
            for object in record.objects {
                if object.kind == "clip" { warning = "자료 조각이 포함된 페이지는 아직 iPad에서 내보낼 수 없습니다."; return }
                if object.kind == "image" {
                    guard addImage(object, geometry: geometry, to: page) else {
                        warning = "이미지 파일을 찾을 수 없어 내보내기를 중지했습니다."; return
                    }
                    hasImages = true; continue
                }
                if object.kind == "textbox" { addText(object, geometry: geometry, to: page); continue }
                if ["rect", "ellipse", "line", "arrow"].contains(object.kind) {
                    addShape(object, geometry: geometry, to: page); continue
                }
                guard let points = object.data.points, let first = points.first else { continue }
                let path = UIBezierPath()
                func relative(_ point: InkPoint) -> CGPoint {
                    let p = geometry.pdfPoint(point)
                    return CGPoint(x: p.x - geometry.cropX, y: p.y - geometry.cropY)
                }
                path.move(to: relative(first))
                for point in points.dropFirst() { path.addLine(to: relative(point)) }
                if points.count == 1 { let p = relative(first); path.addLine(to: CGPoint(x: p.x + 0.1, y: p.y)) }
                let annotation = PDFAnnotation(bounds: geometry.cropBox, forType: .ink, withProperties: nil)
                annotation.add(path)
                annotation.color = (InkPalette(rawValue: object.style.color) ?? .ink).uiColor.withAlphaComponent(object.style.opacity)
                let border = PDFBorder(); border.lineWidth = max(0.2, object.style.width * geometry.width)
                annotation.border = border; annotation.userName = "Bandal"
                page.addAnnotation(annotation)
            }
            record.highlights.forEach { addHighlight($0, geometry: geometry, to: page) }
        }
        let filename = documentURL.deletingPathExtension().lastPathComponent + "-필기-" + UUID().uuidString.prefix(6) + ".pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        if hasImages {
            do { try flattenedPDF(exported).write(to: url, options: .atomic) }
            catch { warning = "PDF 내보내기에 실패했습니다: \(error.localizedDescription)"; return }
        } else if !exported.write(to: url) { warning = "PDF 내보내기에 실패했습니다."; return }
        onExport(url)
    }

    /// Image stamps require a PDF appearance stream. Drawing them into the export
    /// keeps their pixels and the original PDF's vector text without a raster page.
    private func flattenedPDF(_ document: PDFDocument) -> Data {
        UIGraphicsPDFRenderer(bounds: .zero).pdfData { renderer in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let reference = page.pageRef else { continue }
                let crop = reference.getBoxRect(.cropBox)
                let sideways = abs(page.rotation) % 180 == 90
                let size = sideways ? CGSize(width: crop.height, height: crop.width) : crop.size
                let bounds = CGRect(origin: .zero, size: size)
                renderer.beginPage(withBounds: bounds, pageInfo: [:])
                let context = renderer.cgContext
                context.saveGState()
                context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                context.concatenate(reference.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(reference)
                for annotation in page.annotations where annotation.shouldDisplay { annotation.draw(with: .cropBox, in: context) }
                context.restoreGState()
            }
        }
    }
}

@MainActor
private final class ReadingPDFView: PDFView {
    var onReady: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); if window != nil { onReady?() } }
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { setNeedsLayout() } }
}

private final class PDFImageAnnotation: PDFAnnotation {
    private let image: UIImage
    init(bounds: CGRect, image: UIImage) { self.image = image; super.init(bounds: bounds, forType: .stamp, withProperties: nil) }
    required init?(coder: NSCoder) { return nil }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let bitmap = image.cgImage else { return }
        context.saveGState(); context.draw(bitmap, in: bounds); context.restoreGState()
    }
}

@MainActor
private final class PDFInkOverlay: UIView {
    let canvas = PersistentInkCanvas()
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; isOpaque = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor), canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard canvas.isUserInteractionEnabled else { return nil }
        if !canvas.acceptsFingerDrawing, let touches = event?.allTouches,
           !touches.isEmpty, touches.allSatisfy({ $0.type != .pencil }) { return nil }
        return super.hitTest(point, with: event)
    }
}
