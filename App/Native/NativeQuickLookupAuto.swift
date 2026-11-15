import Foundation
import CoreGraphics

/// 자동 찾아보기's settings (설정 › AI › 찾아보기). The automatic lookup is asked about once, the first time it
/// would show a card; AI 설명 has its own switch whose default is one constant.
enum NativeQuickLookupPreferences {
    static let autoKey = "native.quickLookup.auto"
    static let explainKey = "native.quickLookup.aiExplain"
    private static let explanationCountKey = "native.quickLookup.aiExplainCount"
    /// AI 설명 until the reader sets it. On: a passage, a formula or a figure is only worth a card when a model
    /// has read it (signed in, a provider agreed to; without it those selections show no card).
    static let explainsByDefault = true

    enum Auto: Equatable { case undecided, on, off }
    static var auto: Auto {
        get { _ = ready; return (UserDefaults.standard.object(forKey: autoKey) as? Bool).map { $0 ? .on : .off } ?? .undecided }
        set { _ = ready; if newValue == .undecided { UserDefaults.standard.removeObject(forKey: autoKey) } else { UserDefaults.standard.set(newValue == .on, forKey: autoKey) } }
    }
    static var explains: Bool {
        get { _ = ready; return UserDefaults.standard.object(forKey: explainKey) as? Bool ?? explainsByDefault }
        set { _ = ready; UserDefaults.standard.set(newValue, forKey: explainKey) }
    }

    /// The day AI 설명 is counted in, Korea's (as the server's monthly period).
    static func day(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// This account's calls today on this iPad.
    static func explanationsToday(user: String, now: Date = Date()) -> Int {
        _ = ready
        let stored = UserDefaults.standard.dictionary(forKey: explanationCountKey) ?? [:]
        guard let entry = stored[user.lowercased()] as? [String: Any], entry["day"] as? String == day(now) else { return 0 }
        return entry["count"] as? Int ?? 0
    }
    static func recordExplanation(user: String, now: Date = Date()) {
        let count = explanationsToday(user: user, now: now) + 1
        var stored = UserDefaults.standard.dictionary(forKey: explanationCountKey) ?? [:]
        // Other accounts' entries of earlier days are dropped as they are rewritten.
        stored = stored.filter { ($0.value as? [String: Any])?["day"] as? String == day(now) }
        stored[user.lowercased()] = ["day": day(now), "count": count]
        UserDefaults.standard.set(stored, forKey: explanationCountKey)
    }

    /// UI tests start from the defaults (the store's reset list is another session's file); `--native-auto-lookup-on`
    /// starts with the lookup already turned on.
    static let ready: Void = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing") else { return }
        if arguments.contains("--reset-native-ui-testing") {
            for key in [autoKey, explainKey, explanationCountKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        if arguments.contains("--native-auto-lookup-on") { UserDefaults.standard.set(true, forKey: autoKey) }
        if arguments.contains("--native-auto-lookup-ai-fixture") { UserDefaults.standard.set(true, forKey: explainKey) }
        #endif
    }()
}

/// When a selection looks itself up, decided by rules alone.
enum NativeQuickLookupTrigger {
    /// A Markdown selection is looked up once it has stayed this long.
    static let settle: Duration = .milliseconds(600)
    /// A text change this close before a selection made that selection (typing, undo, a format): it is not looked up.
    static let typingWindow: TimeInterval = 0.6
    static let minimumCharacters = 2, maximumCharacters = 200

    /// The text of a Markdown selection to look up, without the Markdown around it; nil when too short or too long.
    static func markdown(_ selection: String) -> String? {
        let text = plain(selection).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minimumCharacters...maximumCharacters).contains(text.count), text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    static func typing(lastEdit: Date?, now: Date) -> Bool {
        guard let lastEdit else { return false }
        return now.timeIntervalSince(lastEdit) < typingWindow
    }

    /// A lasso is looked up when it caught nothing: no ink and no object, only what is printed on the page.
    static func lasso(caughtObjects: Bool, region: CGRect?) -> Bool {
        guard !caughtObjects, let region, !region.isNull else { return false }
        return region.width >= 0.01 && region.height >= 0.006
    }

    /// Markdown source as it reads: links, images and note links by their text, markers and emphasis gone.
    static func plain(_ source: String) -> String {
        var text = source
        for (pattern, template) in [(#"!\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"\[\[([^\]|]+)(?:\|[^\]]*)?\]\]"#, "$1"), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
                                    (#"(?m)^\s{0,3}(?:#{1,6}\s+|>\s?|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)"#, ""), (#"\*\*|__|~~|`|\$"#, ""),
                                    (#"(?<![\p{L}\p{N}])\*(?=\S)|(?<=\S)\*(?![\p{L}\p{N}])"#, "")] {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    /// The nearest Markdown heading above the selection's first occurrence in the note.
    static func markdownHeading(before selection: String, in source: String) -> String? {
        guard !selection.isEmpty, let range = source.range(of: selection) else { return nil }
        for line in source[..<range.lowerBound].split(separator: "\n").reversed() {
            guard let marker = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) else { continue }
            let title = plain(String(line[marker.upperBound...])).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : String(title.prefix(80))
        }
        return nil
    }
}

/// At most `limit` lookups in any `window` seconds.
struct NativeQuickLookupRateLimit {
    let limit: Int
    let window: TimeInterval
    private(set) var starts: [Date] = []
    init(limit: Int, window: TimeInterval) { self.limit = limit; self.window = window }
    mutating func allow(at now: Date) -> Bool {
        starts.removeAll { now.timeIntervalSince($0) >= window }
        guard starts.count < limit else { return false }
        starts.append(now)
        return true
    }
}

/// What an automatic card shows: the lookup's result (dictionary, article, or a link to search the web),
/// with AI 설명 on top of it for a passage (NativeQuickLookupAuto.content).
struct NativeQuickLookupAutoContent: Equatable {
    let query: String
    let result: NativeQuickLookupResult
    var explanation: NativeQuickLookupExplanation?
}

/// The last answers, newest kept: the same selection again shows its card without asking anyone.
struct NativeQuickLookupCache {
    let capacity: Int
    /// nil content: the lookup found nothing to show, which is remembered too.
    private var entries: [(key: String, content: NativeQuickLookupAutoContent?)] = []
    init(capacity: Int) { self.capacity = capacity }
    func lookup(_ key: String) -> NativeQuickLookupAutoContent?? { entries.last { $0.key == key }.map(\.content) }
    mutating func store(_ content: NativeQuickLookupAutoContent?, for key: String) {
        entries.removeAll { $0.key == key }
        entries.append((key, content))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
    var count: Int { entries.count }
}

/// 자동 찾아보기: an empty lasso over printed text in a PDF, or a Markdown selection that settles, looks itself up
/// and the pane's small card shows the answer. One lookup runs at a time: a newer selection cancels the older one.
/// Offline or on any failure nothing is shown; the 찾아보기 button keeps its own card with errors and 다시 시도.
@MainActor
final class NativeQuickLookupAuto {
    static let shared = NativeQuickLookupAuto()

    struct Source: Equatable {
        let owner: String
        let text: String
        let heading: String?
        let title: String
        /// The lassoed area, when it has to be seen to be understood (NativeQuickLookupRegion).
        var picture: Picture? = nil
    }
    struct Picture: Equatable {
        let url: URL
        let page: Int
        let region: CGRect
    }

    var center: NativeQuickLookupCenter = .shared
    var resolver: NativeQuickLookupAutoResolver
    var explainer = NativeQuickLookupExplainer()
    /// The decision step for passages (NativeQuickLookupDecide.swift), asked when no model read the passage.
    var decider = NativeQuickLookupDecider()
    var engine: (NativeWorkspaceStore?) async -> String = { store in
        ((try? await store?.invoke("settings:get")) as? [String: Any])?["browserSearchEngine"] as? String ?? "google"
    }
    var now: () -> Date = Date.init
    var settle = NativeQuickLookupTrigger.settle
    /// 읽는 중… comes only when the model's answer is not there this soon. A reader the model cannot be asked for
    /// (signed out, no provider agreed to, the day's limit) is refused at once and sees nothing come and go.
    var readingDelay: Duration = .milliseconds(300)
    /// Lookups that reach the network, per minute; the cache does not count.
    static let perMinute = 12

    private var lookup: Task<Void, Never>?
    private var lookupOwner: String?
    private var pending: Task<Void, Never>?
    /// The card the running lookup shows: its 읽는 중…, then its answer as it arrives.
    private var lookupCard: UUID?
    /// The running lookup's card was closed, or another card took its place: nothing more of it is shown.
    private var lookupClosed = false
    /// Counts lookups, so that a late part of an older answer never reaches a newer selection's card.
    private var generation = 0
    private var reading: Task<Void, Never>?
    private var settling: Task<Void, Never>?
    private var settlingOwner: String?
    private var lastSelection: [String: String] = [:]
    private var lastEdit: [String: Date] = [:]
    private(set) var cache = NativeQuickLookupCache(capacity: 40)
    private var rate = NativeQuickLookupRateLimit(limit: perMinute, window: 60)

    init() {
        let session = NativeQuickLookupNetwork.session()
        let dictionary = DesktopDictionaryService()
        resolver = NativeQuickLookupAutoResolver(
            dictionary: { await dictionary.lookup($0)["entries"] as? [[String: Any]] ?? [] },
            search: { try await NativeWikipediaSearch.fetch(language: $0, query: $1, context: $2, session: session) })
        explainer.config = { [weak self] in
            guard let config = self?.aiConfig else { throw AIError.server(code: "AI_UNAVAILABLE", info: [:]) }
            return try await config()
        }
        decider.config = explainer.config
        #if DEBUG
        NativeQuickLookupAutoFixture.install(on: self)
        NativeQuickLookupDecideFixture.install(on: self)
        #endif
    }
    /// The ai-proxy's models and consents, through the store (cached there).
    private var aiConfig: (() async throws -> [String: Any])?

    /// Whether lookups run by themselves in this process. Other UI tests select text for their own reasons:
    /// there it runs only with its own fixture.
    static var active: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--native-ui-testing") { return arguments.contains("--native-auto-lookup-fixture") }
        #endif
        return true
    }

    // MARK: entry points

    /// A Markdown note's selection changed. `source` gives the note's text for the heading above the selection.
    func selectionChanged(_ selection: String, owner: String, title: String, store: NativeWorkspaceStore, target: NativeWorkspaceTarget?, source: @escaping () -> String) {
        let previous = lastSelection[owner]
        lastSelection[owner] = selection.isEmpty ? nil : selection
        // The same selection reported again (a format applied to it, the view redrawn) is not a new one.
        guard selection != previous else { return }
        if settlingOwner == owner { settling?.cancel(); settling = nil }
        guard !selection.isEmpty, Self.active, NativeQuickLookupPreferences.auto != .off,
              !NativeQuickLookupTrigger.typing(lastEdit: lastEdit[owner], now: now()),
              let text = NativeQuickLookupTrigger.markdown(selection) else { return }
        let chosen = now(), settle = settle
        settlingOwner = owner
        settling = Task { @MainActor [weak self, weak store] in
            try? await Task.sleep(for: settle)
            guard let self, !Task.isCancelled, self.lastSelection[owner] == selection else { return }
            if let edit = self.lastEdit[owner], edit >= chosen { return }
            self.settling = nil
            let heading = NativeQuickLookupTrigger.markdownHeading(before: selection, in: source())
            self.look(Source(owner: owner, text: text, heading: heading, title: title), store: store, target: target)
        }
    }

    /// The note's text changed: whatever was selected then was typed, not chosen.
    func edited(owner: String) {
        lastEdit[owner] = now()
        if settlingOwner == owner { settling?.cancel(); settling = nil }
    }

    /// A lasso closed on a PDF page. `caughtObjects`: it selected ink or an object, and is only a selection.
    func lasso(region: CGRect?, caughtObjects: Bool, page: Int, original: URL, title: String, owner: String, store: NativeWorkspaceStore) {
        reading?.cancel(); reading = nil
        guard NativeQuickLookupTrigger.lasso(caughtObjects: caughtObjects, region: region), let region, Self.active,
              NativeQuickLookupPreferences.auto != .off else {
            if lookupOwner == owner { stopLookup() }
            return
        }
        reading = Task { @MainActor [weak self, weak store] in
            let read = await NativeQuickLookupPDFText.read(url: original, page: page, region: region)
            guard let self, !Task.isCancelled, let read else { return }
            self.reading = nil
            let picture = read.picture ? Picture(url: original, page: page, region: region) : nil
            self.look(Source(owner: owner, text: read.text, heading: read.heading, title: title, picture: picture), store: store, target: nil)
        }
    }

    /// Everything this pane started stops (the pane went away).
    func cancel(owner: String) {
        if settlingOwner == owner { settling?.cancel(); settling = nil }
        if lookupOwner == owner { stopLookup() }
        lastSelection[owner] = nil
    }

    /// The running lookup stops, and its unfinished card with it (읽는 중…, or an answer still arriving).
    private func stopLookup() {
        lookup?.cancel(); lookup = nil
        pending?.cancel(); pending = nil
        generation += 1
        lookupCard = nil; lookupClosed = false
        if let owner = lookupOwner { center.dismissPending(owner: owner) }
    }

    /// Shows the running lookup's answer, or the part of it that has come, on its card in place; nothing once the
    /// reader closed that card.
    private func show(_ content: NativeQuickLookupAutoContent, owner: String, engine: String, store: NativeWorkspaceStore?, target: NativeWorkspaceTarget?, done: Bool) {
        pending?.cancel(); pending = nil
        guard !lookupClosed else { return }
        if let id = center.showAutomatic(content, owner: owner, engine: engine, store: store, target: target, updating: lookupCard, done: done) { lookupCard = id }
        else { lookupClosed = true }
    }

    // MARK: the lookup

    func look(_ source: Source, store: NativeWorkspaceStore?, target: NativeWorkspaceTarget?) {
        stopLookup()
        if let store { aiConfig = { [weak store] in
            guard let store, let config = try await store.invokePrivate("native:aiConfig") as? [String: Any] else { throw CancellationError() }
            return config
        } }
        switch NativeQuickLookupPreferences.auto {
        case .off: return
        case .undecided:
            center.askAutomatic(owner: source.owner) { [weak self, weak store] on in
                NativeQuickLookupPreferences.auto = on ? .on : .off
                if on { self?.look(source, store: store, target: target) }
            }
            return
        case .on: break
        }
        let reads = explainer.wouldTry(source.text, picture: source.picture != nil)
        let area = source.picture.map { "\($0.page):\(Int($0.region.minX * 500)),\(Int($0.region.minY * 500)),\(Int($0.region.width * 500)),\(Int($0.region.height * 500))" } ?? ""
        let key = [source.text, source.heading ?? "", reads ? "ai" : "", decider.wouldTry(source.text) ? "decide" : "", area].joined(separator: "\u{1}")
        if let cached = cache.lookup(key) {
            guard let content = cached else { return }
            lookupOwner = source.owner
            lookup = Task { @MainActor [weak self, weak store] in
                guard let self else { return }
                let engine = await self.engine(store)
                guard !Task.isCancelled else { return }
                self.center.showAutomatic(content, owner: source.owner, engine: engine, store: store, target: target)
            }
            return
        }
        guard rate.allow(at: now()) else { return }
        lookupOwner = source.owner
        let generation = generation
        lookup = Task { @MainActor [weak self, weak store] in
            guard let self else { return }
            let engine = await self.engine(store)
            guard !Task.isCancelled else { return }
            let answer = await self.resolve(source) { [weak self, weak store] part in
                // AI 설명 as the model writes it: on the card at once.
                guard let self, self.generation == generation else { return }
                self.show(part, owner: source.owner, engine: engine, store: store, target: target, done: false)
            }
            // Cancelled: whoever cancelled took the unfinished card away, or put its own there.
            guard !Task.isCancelled, self.generation == generation else { return }
            self.pending?.cancel(); self.pending = nil
            // A failure (offline, a server error) is tried again next time; an answer, or knowing there is none, is kept.
            if answer.final { self.cache.store(answer.content, for: key) }
            // A closed card's answer is kept for the next time and not put back in front of the reader.
            if let content = answer.content { self.show(content, owner: source.owner, engine: engine, store: store, target: target, done: true) }
            else if !self.lookupClosed { self.center.dismissPending(owner: source.owner) }
            self.lookupCard = nil
        }
        // A model's answer takes a few seconds: the corner says something is being read until its first part comes.
        if reads {
            let delay = readingDelay
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.generation == generation, self.lookupCard == nil, !self.lookupClosed else { return }
                self.pending = nil
                self.lookupCard = self.center.showAutomaticPending(owner: source.owner)
            }
        }
    }

    /// A passage, or an area that has to be seen, is read by the model when it may be (AI 설명), and the card says
    /// what the model read, part by part as it arrives (`partial`). Without the model such a selection gets a card
    /// only when the decision step is sure of an article, never one guessed from its words; a word or a term is
    /// looked up as it is. No content: no card; `final` says whether that answer holds next time (false after a failure).
    func resolve(_ source: Source, partial: (@MainActor (NativeQuickLookupAutoContent) -> Void)? = nil) async -> (content: NativeQuickLookupAutoContent?, final: Bool) {
        if explainer.wouldTry(source.text, picture: source.picture != nil) {
            let picture = source.picture.map { area in { @Sendable in await NativeQuickLookupPDFText.picture(url: area.url, page: area.page, region: area.region) } }
            var shown: NativeQuickLookupAutoContent?
            let answer = await explainer.explain(text: source.text, heading: source.heading, title: source.title, picture: picture) { part in
                let content = Self.content(part)
                shown = content
                partial?(content)
            }
            if let answer {
                // The model found nothing worth a card.
                guard case .explanation(let explanation) = answer else { return (nil, true) }
                return (Self.content(explanation), true)
            }
            // Cut off after part of the answer was on the card: that part stays, and is asked for again next time.
            if let shown { return (shown, false) }
            guard !Task.isCancelled else { return (nil, false) }
        }
        // What has to be seen cannot be told from the pieces of text in it.
        if source.picture != nil { return (nil, false) }
        if let decided = await resolveByDecision(source) { return decided }
        guard !Task.isCancelled, !NativeQuickLookupExplain.isPassage(source.text) else { return (nil, false) }
        guard let outcome = await resolver.resolve(source.text, heading: source.heading) else { return (nil, false) }
        return (NativeQuickLookupAutoContent(query: outcome.query, result: outcome.result), true)
    }

    /// AI 설명's card: the topic and the explanation, opening the reader's search engine for the model's search
    /// words (or its topic). Nothing more is asked of anyone before it shows; a tap opens the search page, where
    /// Google's AI 개요 sits above the results.
    static func content(_ explanation: NativeQuickLookupExplanation) -> NativeQuickLookupAutoContent {
        let words = explanation.search ?? explanation.topic
        return NativeQuickLookupAutoContent(query: words, result: .search(words), explanation: explanation)
    }
}
