import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import WebKit

/// The one 찾아보기 card in the app. A pane asks for it with the reader's selection and shows it while the card
/// says it belongs to that pane; asking again anywhere replaces it, so there is never more than one card
/// or one preview web view.
@MainActor
@Observable
final class NativeQuickLookupCenter {
    static let shared = NativeQuickLookupCenter()

    enum Phase: Equatable {
        case loading
        case result(NativeQuickLookupResult)
    }
    struct Card: Identifiable, Equatable {
        let id = UUID()
        let owner: String
        let query: NativeQuickLookupQuery
        var engine = "google"
        var phase = Phase.loading
        /// The search preview could not load its page.
        var previewFailed = false
    }
    private(set) var card: Card?
    /// A touched card stays until it is closed: the reader is reading it.
    private(set) var held = false

    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private weak var store: NativeWorkspaceStore?
    @ObservationIgnored private var target: NativeWorkspaceTarget?
    @ObservationIgnored private var dictionary: DesktopDictionaryService?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private(set) var preview: NativeQuickLookupPreview?

    /// Runs only from the reader's tap on 찾아보기, never from a selection by itself.
    func lookUp(_ selection: String, owner: String, store: NativeWorkspaceStore, target: NativeWorkspaceTarget? = nil) {
        guard let query = NativeQuickLookupQuery.classify(selection) else { return }
        dismiss()
        self.store = store; self.target = target
        card = Card(owner: owner, query: query)
        start()
    }

    func retry() {
        guard let card else { return }
        lookup?.cancel(); dismissal?.cancel(); releasePreview()
        self.card = Card(owner: card.owner, query: card.query)
        start()
    }

    private func start() {
        guard let card else { return }
        let id = card.id, dictionary = dictionary ?? DesktopDictionaryService(), session = session ?? NativeQuickLookupNetwork.session()
        self.dictionary = dictionary; self.session = session
        let resolver = NativeQuickLookupResolver(
            dictionary: { await dictionary.lookup($0)["entries"] as? [[String: Any]] ?? [] },
            summary: { try await NativeWikipediaClient.fetch(language: $0, title: $1, session: session) })
        let store = self.store
        lookup = Task { @MainActor [weak self, weak store] in
            let engine = ((try? await store?.invoke("settings:get")) as? [String: Any])?["browserSearchEngine"] as? String ?? "google"
            let result = await resolver.resolve(card.query)
            guard let self, !Task.isCancelled, self.card?.id == id else { return }
            self.card?.engine = engine
            self.card?.phase = .result(result)
            switch result {
            case .search(let query):
                guard let url = NativeQuickLookupQuery.searchURL(query, engine: engine) else { self.card?.phase = .result(.unreachable(query)); return }
                // The dismissal clock starts once the page has loaded (or failed): a blank preview is not something read.
                self.makePreview().load(url)
            case .dictionary(let definition): self.scheduleDismissal(characters: definition.lines.joined().count)
            case .wikipedia(let summary): self.scheduleDismissal(characters: summary.extract.count)
            case .unreachable: self.scheduleDismissal(characters: 0)
            }
        }
    }

    /// A finger on the card.
    func hold() {
        guard card != nil, !held else { return }
        held = true; dismissal?.cancel(); dismissal = nil
    }

    /// `owner` closes the card only if it is that pane's (the pane went away).
    func dismiss(owner: String? = nil) {
        guard card != nil, owner == nil || card?.owner == owner else { return }
        lookup?.cancel(); lookup = nil
        dismissal?.cancel(); dismissal = nil
        releasePreview()
        card = nil; held = false
    }

    /// 브라우저에서 열기: a tab of the in-app browser, the card closes.
    func openInBrowser(_ url: URL? = nil) {
        guard let card, let url = url ?? Self.pageURL(card), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        var payload: [String: Any] = ["url": url.absoluteString, "sourcePanelID": card.owner]
        if let target { payload["nativeWorkspaceTarget"] = target }
        store?.events.send(NativeWorkspaceEvent(channel: "nativeWorkspace:openBrowserURL", payload: payload))
        dismiss()
    }

    static func pageURL(_ card: Card) -> URL? {
        switch card.phase {
        case .result(.dictionary(let definition)): definition.url ?? NativeQuickLookupQuery.searchURL(card.query.text, engine: card.engine)
        case .result(.wikipedia(let summary)): summary.url
        case .result(.search(let query)): NativeQuickLookupQuery.searchURL(query, engine: card.engine)
        case .result(.unreachable), .loading: NativeQuickLookupQuery.searchURL(card.query.text, engine: card.engine)
        }
    }

    private func makePreview() -> NativeQuickLookupPreview {
        releasePreview()
        let preview = NativeQuickLookupPreview(
            loaded: { [weak self] in self?.scheduleDismissal(characters: 120) },
            failed: { [weak self] in self?.card?.previewFailed = true; self?.scheduleDismissal(characters: 0) },
            open: { [weak self] in self?.openInBrowser($0) })
        self.preview = preview
        return preview
    }

    private func releasePreview() { preview?.release(); preview = nil }

    private func scheduleDismissal(characters: Int) {
        dismissal?.cancel(); dismissal = nil
        // Assistive technology moves at its own pace; the card waits for 닫기.
        guard let id = card?.id, !held, !UIAccessibility.isVoiceOverRunning, !UIAccessibility.isSwitchControlRunning else { return }
        let seconds = NativeQuickLookupQuery.dwell(characters: characters)
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, self.card?.id == id, !self.held else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.dismiss() }
        }
    }
}

/// The search preview's web view: one at a time, created for a search card and torn down with it.
/// It keeps no cookies or history; a result the reader taps opens in a browser tab instead of in the card.
@MainActor
final class NativeQuickLookupPreview: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private var host: String?
    private let loaded: () -> Void, failed: () -> Void, open: (URL) -> Void
    private var finished = false

    init(loaded: @escaping () -> Void, failed: @escaping () -> Void, open: @escaping (URL) -> Void) {
        self.loaded = loaded; self.failed = failed; self.open = open
    }

    func load(_ url: URL) {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        if let proxy = NativeQuickLookupNetwork.offlineProxy { store.proxyConfigurations = [proxy] }
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 320), configuration: configuration)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.accessibilityIdentifier = "native-quick-lookup-preview"
        let presence = NativeTouchPresence(); presence.began = { [weak self] in self?.touched?() }
        webView.addGestureRecognizer(presence)
        host = url.host?.lowercased()
        self.webView = webView
        webView.load(URLRequest(url: url, timeoutInterval: 10))
    }
    /// Set by the card: a finger on the page holds the card like one on the card itself.
    var touched: (() -> Void)?

    func release() {
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about"].contains(scheme) else { decisionHandler(.cancel); return }
        // The results page loads here with its redirects (a mobile page on another host, search.naver.com to
        // m.search.naver.com); once it has loaded, anything the reader picks goes to the browser.
        let redirect = action.navigationType != .linkActivated && (!finished || Self.site(url.host) == Self.site(host))
        if scheme == "about" || redirect { decisionHandler(.allow); return }
        decisionHandler(.cancel); open(url)
    }
    /// "naver.com" for m.search.naver.com: the engine's own site.
    private static func site(_ host: String?) -> String {
        (host ?? "").lowercased().split(separator: ".").suffix(2).joined(separator: ".")
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }; finished = true; loaded()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(URLError(.networkConnectionLost)) }

    private func fail(_ error: Error) {
        let error = error as NSError
        // A navigation this delegate cancelled (a tapped result) is not a failure of the preview.
        guard !finished, !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled),
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        finished = true; failed()
    }
}

/// Reports a finger coming down without taking part in gesture recognition: it never begins, so the web view's
/// scrolling and taps go on as if it were not there.
private final class NativeTouchPresence: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var began: (() -> Void)?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false; delaysTouchesBegan = false; delaysTouchesEnded = false; delegate = self
    }
    convenience init() { self.init(target: nil, action: nil) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { began?() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(event) }
    private func finish(_ event: UIEvent) {
        if event.allTouches?.allSatisfy({ $0.phase == .ended || $0.phase == .cancelled }) ?? true { state = .failed }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

private struct NativeQuickLookupWebView: UIViewRepresentable {
    let preview: NativeQuickLookupPreview
    let touched: () -> Void
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        attach(to: container)
        return container
    }
    func updateUIView(_ container: UIView, context: Context) { attach(to: container) }
    private func attach(to container: UIView) {
        preview.touched = touched
        guard let webView = preview.webView, webView.superview !== container else { return }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

/// Where a pane draws the card: at its leading edge, and only the card this pane asked for.
/// When the pane goes away (its tab is hidden or closed) its card goes too, and with it the preview.
struct NativeQuickLookupCardHost: View {
    let owner: String
    @Environment(\.nativeEditorVisible) private var visible
    private var center: NativeQuickLookupCenter { .shared }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            if visible, let card = center.card, card.owner == owner {
                NativeQuickLookupCard(card: card, center: center).id(card.id)
                    .transition(.opacity.combined(with: .offset(x: -12)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: center.card?.id)
        // A retained tab that is hidden keeps its view: its card goes when the tab does.
        .onChange(of: visible) { _, value in if !value { center.dismiss(owner: owner) } }
        .onDisappear { center.dismiss(owner: owner) }
    }
}

private struct NativeQuickLookupCard: View {
    let card: NativeQuickLookupCenter.Card
    let center: NativeQuickLookupCenter
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).accessibilityHidden(true)
                source.font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button { center.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28).contentShape(Rectangle())
                }.accessibilityLabel("닫기").accessibilityIdentifier("native-quick-lookup-close")
            }.foregroundStyle(NativeDesktopTheme.secondary)
            content
            if showsOpen {
                Button { center.openInBrowser() } label: {
                    Label("브라우저에서 열기", systemImage: "arrow.up.right.square").font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 36).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }.accessibilityIdentifier("native-quick-lookup-open")
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
        .frame(maxWidth: 320, alignment: .leading)
        .buttonStyle(.plain).foregroundStyle(NativeDesktopTheme.text)
        .bandalGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in center.hold() })
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-quick-lookup-card").accessibilityValue(state)
    }

    @ViewBuilder private var content: some View {
        switch card.phase {
        case .loading:
            HStack(spacing: 8) { ProgressView(); Text("찾는 중…").font(.callout).foregroundStyle(NativeDesktopTheme.secondary) }
            title(card.query.text)
        case .result(.dictionary(let definition)):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title(definition.headword)
                if let pronunciation = definition.pronunciation { Text(verbatim: pronunciation).font(.callout).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1) }
            }
            ForEach(Array(definition.lines.enumerated()), id: \.offset) { Text(verbatim: $0.element).font(.callout).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        case .result(.wikipedia(let summary)):
            title(summary.title)
            if let description = summary.description { Text(verbatim: description).font(.caption).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1) }
            Text(verbatim: summary.extract).font(.callout).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        case .result(.search(let query)):
            title(query, lines: 2)
            if card.previewFailed { unreachable }
            else if let preview = center.preview {
                // Shorter where the pane is (a note with the keyboard up), so 브라우저에서 열기 stays on screen.
                NativeQuickLookupWebView(preview: preview, touched: { center.hold() })
                    .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NativeGlass.hairline) }
            }
        case .result(.unreachable(let query)):
            title(query, lines: 2)
            unreachable
        }
    }

    private var unreachable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("인터넷에 연결할 수 없어 찾지 못했어요.").font(.callout).foregroundStyle(NativeDesktopTheme.secondary).fixedSize(horizontal: false, vertical: true)
            Button { center.retry() } label: {
                Label("다시 시도", systemImage: "arrow.clockwise").font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 36).background(NativeGlass.tool, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }.accessibilityIdentifier("native-quick-lookup-retry")
        }
    }

    private func title(_ text: String, lines: Int = 1) -> some View {
        Text(verbatim: text).font(.system(size: 17, weight: .semibold)).lineLimit(lines)
    }

    private var unreachableShown: Bool {
        if case .result(.unreachable) = card.phase { return true }
        if case .result(.search) = card.phase { return card.previewFailed }
        return false
    }
    private var showsOpen: Bool {
        if case .loading = card.phase { return false }
        return !unreachableShown
    }

    @ViewBuilder private var source: some View {
        switch card.phase {
        case .loading: Text("찾아보기")
        case .result(.dictionary): Text("영한사전 · Wiktionary")
        case .result(.wikipedia(let summary)): if summary.language == "ko" { Text("위키백과") } else { Text("영어 위키백과") }
        // Nothing was found offline, whichever source was tried.
        case .result(.unreachable): Text("찾아보기")
        case .result(.search):
            switch card.engine {
            case "naver": Text("네이버 검색")
            case "daum": Text("다음 검색")
            case "duckduckgo": Text("DuckDuckGo 검색")
            default: Text("Google 검색")
            }
        }
    }
    private var symbol: String {
        switch card.phase {
        case .loading: "text.magnifyingglass"
        case .result(.dictionary): "character.book.closed"
        case .result(.wikipedia): "book"
        case .result(.search): "magnifyingglass"
        case .result(.unreachable): "wifi.slash"
        }
    }
    /// For UI tests and assistive technology: which answer the card holds.
    private var state: String {
        switch card.phase {
        case .loading: "loading"
        case .result(.dictionary): "dictionary"
        case .result(.wikipedia(let summary)): "wikipedia-" + summary.language
        case .result(.search): card.previewFailed ? "unreachable" : "search"
        case .result(.unreachable): "unreachable"
        }
    }
}

/// 찾아보기 in a pane's selection bar.
struct NativeQuickLookupButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("찾아보기", systemImage: "text.magnifyingglass").frame(minHeight: 44).contentShape(Rectangle())
        }.accessibilityIdentifier("native-quick-lookup")
    }
}

/// 찾아보기 in a note's tool row while text is selected. It reads the selection itself, so a selection that
/// changes under the finger redraws this button and not the note around it.
struct NativeQuickLookupSelectionButton: View {
    let store: NativeWorkspaceStore
    let documentID: String
    var target: NativeWorkspaceTarget?
    var body: some View {
        if let text = store.documentSelections[documentID], text.contains(where: { $0.isLetter || $0.isNumber }) {
            Button { NativeQuickLookupCenter.shared.lookUp(text, owner: documentID, store: store, target: target) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 16))
                    Text("찾아보기").font(.system(size: 15, weight: .medium)).lineLimit(1)
                }.padding(.horizontal, 8).frame(height: 31).contentShape(Rectangle())
            }.accessibilityIdentifier("native-quick-lookup")
        }
    }
}
