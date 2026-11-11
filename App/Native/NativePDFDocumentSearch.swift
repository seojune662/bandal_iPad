import SwiftUI

/// Search inside one open PDF or note: its text layer and its recognised handwriting.
/// The viewer's field and the thumbnails' field edit the same query.
@MainActor @Observable
final class NativePDFDocumentSearch {
    struct Match: Equatable {
        let page: Int
        /// The n-th occurrence in the page's text, or nil for a handwritten line.
        let ordinal: Int?
        /// A handwritten line's box, normalised from the page's top left.
        let box: [Double]?
    }
    var query = "" { didSet { if query != oldValue { update() } } }
    /// The viewer's field is showing.
    private(set) var isPresented = false
    /// Bumped by ⌘F and the toolbar button: the viewer's field takes focus.
    private(set) var focusRequests = 0
    private(set) var matches: [Match] = []
    private(set) var current: Int?
    /// Matches per page for the thumbnails; nil while nothing is searched.
    private(set) var counts: [Int: Int]?
    /// "3 / 17".
    var position: String { "\((current ?? -1) + 1) / \(matches.count)" }

    @ObservationIgnored var lookup: (String) async throws -> [String: Any] = { _ in [:] }
    @ObservationIgnored var host: (String, [String: Any]) async throws -> Any = { _, _ in [:] }
    @ObservationIgnored var currentPage: () -> Int = { 1 }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var settled = ""
    /// Line rects of each text occurrence, per page, as the viewer found them for `settled`.
    @ObservationIgnored private var textRects: [Int: [[[Double]]]] = [:]
    static let debounce = Duration.milliseconds(250)
    /// Text matches are measured for this many pages around the current one; the rest get theirs as the search moves.
    private static let markedPages = 9

    func present() { isPresented = true; focusRequests += 1 }
    func dismiss() { isPresented = false; query = "" }

    /// Runs the search after a short pause. `refresh` repeats the shown search at once, keeping the place:
    /// the index gained this document's text, or its handwriting was read.
    func update(refresh: Bool = false) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if refresh, needle.isEmpty || needle != settled { return }
        task?.cancel()
        guard !needle.isEmpty else {
            matches = []; current = nil; counts = nil; settled = ""; textRects = [:]
            task = Task { [weak self] in _ = try? await self?.host("searchMarks", ["marks": [[String: Any]]()]) }
            return
        }
        task = Task { [weak self] in
            if !refresh { try? await Task.sleep(for: Self.debounce) }
            guard !Task.isCancelled, let self, let result = try? await self.lookup(needle), !Task.isCancelled else { return }
            let kept = needle == self.settled ? self.current.flatMap { self.matches.indices.contains($0) ? self.matches[$0] : nil } : nil
            var next: [Match] = []
            let text = result["text"] as? [[String: Any]] ?? [], ink = result["handwriting"] as? [[String: Any]] ?? []
            for page in Set((text + ink).compactMap { $0["page"] as? Int }).sorted() {
                let count = text.first { $0["page"] as? Int == page }?["count"] as? Int ?? 0
                next += (0..<count).map { Match(page: page, ordinal: $0, box: nil) }
                next += ink.filter { $0["page"] as? Int == page }.compactMap { ($0["box"] as? [Double]).map { Match(page: page, ordinal: nil, box: $0) } }
            }
            if needle != self.settled { self.textRects = [:] }
            self.settled = needle; self.matches = next
            self.counts = Dictionary(grouping: next, by: \.page).mapValues(\.count)
            // From the page being read onward, like a find bar.
            let page = self.currentPage()
            self.current = kept.flatMap { next.firstIndex(of: $0) } ?? next.firstIndex { $0.page >= page } ?? (next.isEmpty ? nil : 0)
            // A refresh fills in what the index just learned; it never moves the page under the reader.
            await self.mark(navigate: kept == nil && !refresh)
        }
    }

    /// ↩ and ⇧↩: the next or previous match, wrapping at the ends.
    func step(_ delta: Int) {
        guard !matches.isEmpty else { return }
        current = ((current ?? (delta > 0 ? -1 : 0)) + delta + matches.count) % matches.count
        task?.cancel()
        task = Task { [weak self] in await self?.mark(navigate: true) }
    }

    /// Draws the matches of the pages around the current one and, when asked, brings the current match into view.
    func mark(navigate: Bool) async {
        guard let current, matches.indices.contains(current) else { _ = try? await host("searchMarks", ["marks": [[String: Any]]()]); return }
        let match = matches[current], needle = settled
        let pages = Set(matches.map(\.page)).sorted { abs($0 - match.page) < abs($1 - match.page) }.prefix(Self.markedPages)
        for page in pages where textRects[page] == nil && matches.contains(where: { $0.page == page && $0.ordinal != nil }) {
            let found = (try? await host("textMatches", ["page": page, "query": needle])) as? [String: Any]
            guard !Task.isCancelled, needle == settled else { return }
            textRects[page] = found?["matches"] as? [[[Double]]] ?? []
        }
        var marks: [[String: Any]] = []
        for page in pages {
            for (ordinal, rects) in (textRects[page] ?? []).enumerated() {
                marks.append(["page": page, "rects": rects, "current": match.page == page && match.ordinal == ordinal])
            }
            for other in matches where other.page == page {
                if let box = other.box { marks.append(["page": page, "rects": [box], "handwriting": true, "current": other == match]) }
            }
        }
        _ = try? await host("searchMarks", ["marks": marks])
        guard navigate else { return }
        let rects = textRects[match.page] ?? []
        let rect = match.box ?? match.ordinal.flatMap { rects.indices.contains($0) ? rects[$0].first : nil }
        _ = try? await host("navigate", ["page": match.page, "progress": rect.map { min(1, max(0, $0[1] + $0[3] / 2)) } ?? 0])
    }
}

/// The viewer's search row, in place of the zoom and view controls: the field, "3 / 17", previous, next, close.
struct NativePDFSearchBar: View {
    var search: NativePDFDocumentSearch
    @Environment(\.locale) private var locale
    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                // Return moves on, ⇧Return back, Esc closes: keys of this field only, while it has focus.
                NativeSearchTextField(text: Bindable(search).query, placeholder: NativeAppLocale.string("문서에서 찾기", locale), identifier: "native-pdf-search-field",
                                      focusRequests: search.focusRequests, submitKeepsFocus: true,
                                      onSubmit: { search.step(1) }, onShiftSubmit: { search.step(-1) }, onEscape: { search.dismiss() })
                if !search.query.isEmpty {
                    Text(verbatim: search.position).font(.system(size: 12).monospacedDigit()).foregroundStyle(NativeDesktopTheme.secondary).fixedSize()
                        .accessibilityIdentifier("native-pdf-search-count")
                }
            }.padding(.horizontal, 10).frame(minWidth: 150, maxWidth: 300).frame(height: 34).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 10))
            button("이전 결과", "chevron.up", id: "native-pdf-search-previous") { search.step(-1) }.disabled(search.matches.isEmpty)
            button("다음 결과", "chevron.down", id: "native-pdf-search-next") { search.step(1) }.disabled(search.matches.isEmpty)
            button("찾기 닫기", "xmark", id: "native-pdf-search-close") { search.dismiss() }
        }
    }
    private func button(_ title: LocalizedStringKey, _ symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15)).frame(width: 38, height: 38).contentShape(Rectangle()) }
            .accessibilityLabel(title).accessibilityIdentifier(id).help(title)
    }
}

/// The thumbnails' search field: the same query, sized for the narrow panel.
struct NativePDFPagesSearchField: View {
    var search: NativePDFDocumentSearch
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(NativeGlass.fieldGlyph)
            TextField("찾기", text: Bindable(search).query, prompt: Text("찾기").foregroundStyle(NativeGlass.fieldPrompt)).textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(NativeDesktopTheme.text).autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("native-pdf-pages-search")
            if !search.query.isEmpty {
                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(NativeGlass.fieldGlyph).frame(width: 24, height: 30).contentShape(Rectangle()) }
                    .accessibilityLabel("검색어 지우기").accessibilityIdentifier("native-pdf-pages-search-clear")
            }
        }.padding(.leading, 8).padding(.trailing, 2).frame(height: 30)
            .background(NativeGlass.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NativeGlass.fieldStroke) }
    }
}
