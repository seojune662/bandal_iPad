import Foundation
import Observation

/// The school picker's flow, the same in the sidebar popover, Settings and onboarding:
/// search and choose; or, with no match, find the sites with AI (signed in), confirm the links
/// and save; or enter the name alone.
@MainActor
@Observable
final class NativeSchoolPickerModel {
    enum Phase: Equatable { case searching, signIn, finding, confirming, notFound, manual }
    enum Notice: Equatable { case rateLimited(Int), aiUnavailable, saveFailed(String) }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            // Another name: the used-up notice gives the list back.
            if case .rateLimited = notice { notice = nil }
            scheduleSearch()
        }
    }
    var country: String { didSet { if country != oldValue { scheduleSearch() } } }
    private(set) var results: [School] = []
    /// `results` answer the query on screen, not an earlier one still loading.
    private(set) var searched = false
    /// The server did not answer; `results` come from the bundled list.
    private(set) var offline = false
    private(set) var phase = Phase.searching
    /// The AI search has run past `slowAfter`.
    private(set) var slow = false
    private(set) var notice: Notice?
    private(set) var saving = false
    /// The school being confirmed as it was found; `links` is the copy the user edits.
    private(set) var found: School?
    private(set) var links: [School.Link] = []
    /// The best-effort `/suggest` after a confirmed edit (tests wait for it).
    private(set) var suggestion: Task<Void, Never>?

    private let directory: any SchoolDirectory
    private let bundled: [School]
    private let locale: String
    private let debounce: Duration
    private let slowAfter: Duration
    private let save: (School) async throws -> Void
    /// The host's close. A picker that takes over a search left running sets its own.
    var done: (School) -> Void
    /// The row picked where choosing waits for "다음" (onboarding).
    var selected: School?
    /// Set while no picker shows this model ("닫고 기다리기"): how the search ended, for a toast.
    var announce: ((Phase, Notice?) -> Void)?
    /// A search left running by a popover that closed; the next picker shows it.
    static var waiting: NativeSchoolPickerModel?
    /// AI searches a day (the server's ration) and how many this iPad has started today.
    private(set) var limit = 3
    var remaining: Int { max(0, limit - used) }
    private let defaults: UserDefaults
    static let usedKey = "native.school.aiSearches"
    static var today: String { Date.now.formatted(.iso8601.year().month().day()) }
    private var used: Int {
        get {
            let parts = (defaults.string(forKey: Self.usedKey) ?? "").split(separator: ":")
            return parts.count == 2 && parts[0] == Self.today ? Int(parts[1]) ?? 0 : 0
        }
        set { defaults.set(Self.today + ":\(newValue)", forKey: Self.usedKey) }
    }
    private var pending: Task<Void, Never>?
    private var finding: Task<School?, Error>?
    private var attempt = 0
    /// Between the tap and knowing whether someone is signed in: a second tap or a repeated
    /// sign-in event must not start a second AI search (they are rationed).
    private var starting = false

    nonisolated static var deviceCountry: String { Locale.current.region?.identifier ?? "KR" }

    init(directory: any SchoolDirectory, bundled: [School] = NativeUniversityCatalog.schools, country: String = deviceCountry, locale: String = NativeAppLocale.current,
         debounce: Duration = .milliseconds(300), slowAfter: Duration = .seconds(15), defaults: UserDefaults = .standard,
         save: @escaping (School) async throws -> Void, done: @escaping (School) -> Void) {
        self.directory = directory; self.bundled = bundled; self.country = country; self.locale = locale
        self.debounce = debounce; self.slowAfter = slowAfter; self.defaults = defaults; self.save = save; self.done = done
    }

    // MARK: Search

    private func scheduleSearch() {
        searched = false
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            if !Task.isCancelled { await search() }
        }
    }

    /// An empty query lists the country's bundled schools. Otherwise the bundled matches show at
    /// once and the server's answer joins them, or they stand alone when it cannot answer.
    func search() async {
        let text = trimmed(query), country = country
        var answer = NativeUniversityCatalog.matching(text, country: country, in: bundled), offline = false
        if !text.isEmpty {
            results = answer
            do {
                // The server's answer first; a school only this iPad knows stays in the list.
                let server = try await directory.search(text, country: country)
                answer = server + answer.filter { known in !server.contains { $0.id == known.id } }
            }
            catch is CancellationError { return }
            catch { offline = true }
        }
        // A newer keystroke or country owns the list now.
        guard text == trimmed(query), country == self.country else { return }
        results = answer; self.offline = offline; searched = true
        if let selected, !answer.contains(where: { $0.id == selected.id }) { self.selected = nil }
    }

    /// A reviewed school saves at once. Links nobody reviewed (an AI finding that another search put
    /// in the directory) go through the same confirmation as a fresh AI result.
    func choose(_ school: School) async {
        guard phase == .searching, !saving else { return }
        if school.unreviewed, !school.links.isEmpty { notice = nil; found = school; links = school.links; phase = .confirming; return }
        do { try await finish(school) } catch { notice = .saveFailed(error.localizedDescription) }
    }

    // MARK: AI

    /// Signed out this stops at `.signIn`; `signedIn()` then carries on by itself.
    func findWithAI() async {
        let name = trimmed(query)
        guard !name.isEmpty, !starting, phase == .searching || phase == .signIn else { return }
        notice = nil
        starting = true
        let signedIn = await directory.isSignedIn()
        starting = false
        // Asking the account can take a moment: the user may have moved on, or typed something else.
        guard phase == .searching || phase == .signIn, name == trimmed(query) else { return }
        guard signedIn else { phase = .signIn; return }
        phase = .finding; slow = false
        used += 1
        attempt += 1
        let attempt = attempt
        let timer = Task { [slowAfter] in
            try? await Task.sleep(for: slowAfter)
            if !Task.isCancelled, self.attempt == attempt, phase == .finding { slow = true }
        }
        defer { timer.cancel() }
        let request = Task { [directory, country, locale] in try await directory.setup(query: name, country: country, locale: locale) }
        finding = request
        let outcome = await request.result
        // Stopped, or a newer search took over.
        guard self.attempt == attempt, phase == .finding else { return }
        finding = nil; slow = false
        switch outcome {
        case .success(let answer):
            // A school the app ships is shown with its curated sites: those are what the sidebar gets.
            let school = answer.map { answer in bundled.first { $0.id == answer.id } ?? answer }
            if let school, !school.links.isEmpty { found = school; links = school.links; phase = .confirming } else { phase = .notFound }
        case .failure(SchoolDirectoryError.signInRequired): phase = .signIn
        case .failure(SchoolDirectoryError.rateLimited(let limit)): self.limit = limit; used = limit; notice = .rateLimited(limit); phase = .searching
        case .failure: notice = .aiUnavailable; phase = .searching
        }
        announce?(phase, notice)
    }

    /// 다시 찾기 after a search that found nothing: one more of the day's searches.
    func findAgain() async {
        guard phase == .notFound else { return }
        phase = .searching
        await findWithAI()
    }

    func signedIn() async { if phase == .signIn { await findWithAI() } }
    func dismissSignIn() { if phase == .signIn { phase = .searching } }

    /// Back to the search field: stops an AI search and drops an unconfirmed result.
    func backToSearch() {
        attempt += 1
        finding?.cancel(); finding = nil
        found = nil; links = []; slow = false; notice = nil; phase = .searching
    }

    // MARK: 직접 입력

    func enterManually() { notice = nil; phase = .manual }

    /// The name alone, no links: the sidebar then offers the AI search for them.
    func saveManually(_ name: String) async throws {
        try await finish(School(id: UUID().uuidString.lowercased(), name: trimmed(name), nameEn: nil, aliases: [], country: country, domain: nil,
                                verified: false, source: "user", links: []))
    }

    // MARK: Confirmation

    /// A link needs a title and an http(s) address. False leaves the row as it was.
    func updateLink(_ id: String, title: String, url: String) -> Bool {
        let title = trimmed(title)
        guard !title.isEmpty, let address = Self.address(url), let index = links.firstIndex(where: { $0.id == id }) else { return false }
        if links[index].title != title || links[index].url != address {
            links[index].title = title; links[index].url = address; links[index].verified = false
        }
        return true
    }
    func removeLink(_ id: String) { links.removeAll { $0.id == id } }
    /// An empty row for the user to fill in; `confirm()` drops it if it stays empty.
    func addLink() -> String {
        let link = School.Link(id: "user-" + UUID().uuidString.lowercased(), kind: "other", title: "", url: "", verified: false, order: (links.map(\.order).max() ?? -1) + 1)
        links.append(link)
        return link.id
    }

    /// 이 학교로 설정: saves what is on screen. Edited links stay in this user's settings and are
    /// also offered to the directory for review.
    func confirm() async {
        guard phase == .confirming, !saving, var school = found else { return }
        let kept = links.filter { !$0.title.isEmpty && !$0.url.isEmpty }
        let edited = kept != school.links
        school.links = kept
        if edited { school.source = "user" }
        do { try await finish(school) } catch { notice = .saveFailed(error.localizedDescription); return }
        guard edited, !kept.isEmpty else { return }
        // Best effort by design: the edit is already saved here, and review can miss one.
        suggestion = Task { [directory] in try? await directory.suggest(schoolID: school.id, links: kept) }
    }

    /// "portal.school.ac.kr" becomes https://…; anything that is not a web address is nil.
    static func address(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let value = text.contains("://") ? text : "https://" + text
        guard NativeSettingsSchema.webURL(value), URL(string: value)?.host?.contains(".") == true else { return nil }
        return value
    }

    /// A two-letter ISO region ("de" → "DE"), nil when there is no such country.
    static func region(_ code: String) -> String? {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return code.count == 2 && Locale.Region.isoRegions.contains { $0.identifier == code } ? code : nil
    }

    private func finish(_ school: School) async throws {
        guard !saving else { return }
        saving = true
        notice = nil
        do { try await save(school) } catch { saving = false; throw error }
        // `saving` stays on: the picker is finished and its host closes it.
        done(school)
    }
    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension NativeUniversityCatalog {
    /// The `university` settings patch that makes `school` the user's school, in the shape the
    /// sidebar and everything else already read. A school the app ships keeps its bundled id and
    /// curated sites; any other becomes the `custom:` university with its links in `customServices`,
    /// where Settings can reorder, hide and delete them, and first in `serviceOrder` so they come
    /// before the sites every school shares. `current` is the group being replaced.
    static func patch(choosing school: School, current: [String: Any]) -> [String: Any] {
        // The user's own sites stay through a school change; the previous school's links go with it.
        let own = ownServices(current)
        // Links the user edited are theirs, not the bundle's.
        if school.source != "user", universities.contains(where: { $0["id"] as? String == school.id }) {
            return ["universityId": school.id, "customUniversity": NSNull(), "customServices": own]
        }
        let id = "custom:" + school.id
        let links: [[String: Any]] = school.links.map { link in
            ["id": id + ":" + link.id, "label": link.title, "url": link.url, "kind": link.kind == "home" ? "homepage" : link.kind,
             "verification": link.verified ? "verified" : "unverified"]
        }
        let university: [String: Any] = ["id": id, "nameKo": school.name, "nameEn": school.nameEn ?? "", "domain": school.domain ?? "", "aliases": school.aliases,
                                         "services": [[String: Any]](), "verifiedAt": "", "country": school.country]
        // The school's sites lead; everything else keeps the order the user gave it.
        let order = links.compactMap { $0["id"] as? String } + (current["serviceOrder"] as? [String] ?? []).filter { !isSchoolLink($0) }
        return ["universityId": id, "customUniversity": university, "customServices": own + links, "serviceOrder": order]
    }

    /// A school's link in `customServices` is `custom:<school>:<link>`; a site the user added is `custom:<uuid>`.
    static func isSchoolLink(_ id: String) -> Bool { id.hasPrefix("custom:") && id.dropFirst(7).contains(":") }

    /// `customServices` without any school's links: what stays when the school changes or is cleared.
    static func ownServices(_ university: [String: Any]) -> [[String: Any]] {
        (university["customServices"] as? [[String: Any]] ?? []).filter { !isSchoolLink($0["id"] as? String ?? "") }
    }

    /// A custom school with no sites of its own yet (직접 입력, or added before the directory
    /// existed): the sidebar offers the AI search for them.
    static func needsLinks(_ settings: [String: Any]) -> Bool {
        let value = settings["university"] as? [String: Any] ?? [:]
        guard let id = value["universityId"] as? String, id.hasPrefix("custom:"), let school = university(settings) else { return false }
        return (school["services"] as? [[String: Any]] ?? []).isEmpty
            && !(value["customServices"] as? [[String: Any]] ?? []).contains { ($0["id"] as? String ?? "").hasPrefix(id + ":") }
    }
}
