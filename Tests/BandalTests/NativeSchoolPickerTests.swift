import XCTest
@testable import Bandal

/// The school picker's flow, the settings a chosen school becomes, the directory's wire contract,
/// the first-run decision and the app language. No server: the directory is a fake or a stubbed transport.
@MainActor
final class NativeSchoolPickerTests: XCTestCase {
    private final class Calls {
        var searches: [String] = []
        var setups: [[String]] = []
        var suggestions: [(id: String, links: [School.Link])] = []
    }
    private var calls = Calls()
    private var saved: [School] = []
    private var finished: [School] = []

    override func setUp() async throws { calls = Calls(); saved = []; finished = [] }

    private func link(_ id: String, _ kind: String = "other", order: Int = 0) -> School.Link {
        School.Link(id: id, kind: kind, title: id, url: "https://\(id).bandal.ac.kr", verified: false, order: order)
    }
    private func school(_ id: String = "s1", name: String = "반달대학교", links: [School.Link]? = nil, verified: Bool = false) -> School {
        School(id: id, name: name, nameEn: nil, aliases: [], country: "KR", domain: "bandal.ac.kr", verified: verified, source: "ai",
               links: links ?? [link("home", "home"), link("lms", "lms", order: 1)])
    }
    /// A directory that records what it is asked. The defaults find nothing and are signed in.
    private func directory(search: @escaping (String) async throws -> [School] = { _ in [] }, setup: @escaping () async throws -> School? = { nil },
                           signedIn: @escaping () async -> Bool = { true }, suggest: @escaping () async throws -> Void = {}) -> SchoolDirectoryFake {
        let calls = calls
        return SchoolDirectoryFake(signedIn: signedIn, onSearch: { query, _ in calls.searches.append(query); return try await search(query) },
                                   onSetup: { query, country, locale in calls.setups.append([query, country, locale]); return try await setup() },
                                   onSuggest: { id, links in calls.suggestions.append((id, links)); try await suggest() })
    }
    private func model(_ directory: SchoolDirectoryFake, country: String = "KR", debounce: Duration = .zero, slowAfter: Duration = .seconds(15)) -> NativeSchoolPickerModel {
        NativeSchoolPickerModel(directory: directory, country: country, locale: "ko-KR", debounce: debounce, slowAfter: slowAfter,
                                save: { [unowned self] in self.saved.append($0) }, done: { [unowned self] in self.finished.append($0) })
    }

    // MARK: Flow

    func testEmptyQueryListsTheCountrysBundledSchoolsAndAResultSavesAndEnds() async {
        let found = school("server-1", name: "서울과학기술대학교", verified: true)
        let picker = model(directory(search: { _ in [found] }))
        await picker.search()
        XCTAssertEqual(picker.results.count, 18, "Korea starts on the bundled list without asking the server")
        XCTAssertTrue(calls.searches.isEmpty)
        picker.query = " 서울과기대 "
        await picker.search()
        XCTAssertEqual(picker.results, [found])
        XCTAssertTrue(picker.searched); XCTAssertFalse(picker.offline)
        XCTAssertEqual(calls.searches.last, "서울과기대", "The query is trimmed")
        await picker.choose(found)
        XCTAssertEqual(saved, [found]); XCTAssertEqual(finished, [found])

        let abroad = model(directory(), country: "US")
        await abroad.search()
        XCTAssertTrue(abroad.results.isEmpty, "The bundled list is Korean")
    }

    func testTypingSearchesOnceAfterTheDebounceAndALateAnswerNeverReplacesANewerOne() async throws {
        // Names no bundled school matches, so the lists below are the server's alone.
        let picker = model(directory(search: { [unowned self] query in
            if query == "달빛" { try await Task.sleep(for: .milliseconds(200)) }
            return [self.school(query, name: query)]
        }), debounce: .milliseconds(40))
        picker.query = "반"; picker.query = "반달"
        XCTAssertFalse(picker.searched)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(calls.searches, ["반달"], "Only the text left after the pause is searched")
        XCTAssertEqual(picker.results.map(\.name), ["반달"])

        picker.query = "달빛"
        let slow = Task { await picker.search() }
        try await Task.sleep(for: .milliseconds(20))
        picker.query = "달빛대"
        await picker.search()
        await slow.value
        XCTAssertEqual(picker.results.map(\.name), ["달빛대"])
    }

    func testNoMatchThenAISearchConfirmsEditedLinksSavesAndSuggestsThem() async throws {
        let found = school()
        let picker = model(directory(setup: { found }, suggest: { throw SchoolDirectoryError.unavailable }))
        picker.query = "반달대"
        await picker.search()
        XCTAssertTrue(picker.searched && picker.results.isEmpty, "No match: the picker offers AI and 직접 입력")
        await picker.findWithAI()
        XCTAssertEqual(calls.setups, [["반달대", "KR", "ko-KR"]])
        XCTAssertEqual(picker.phase, .confirming)
        XCTAssertEqual(picker.found, found); XCTAssertEqual(picker.links, found.links)
        XCTAssertTrue(saved.isEmpty, "Nothing is saved before the user confirms")

        XCTAssertFalse(picker.updateLink("lms", title: "", url: "https://lms.bandal.ac.kr"))
        XCTAssertFalse(picker.updateLink("lms", title: "강의실", url: "file:///etc/hosts"))
        XCTAssertEqual(picker.links, found.links, "A rejected edit changes nothing")
        XCTAssertTrue(picker.updateLink("lms", title: "강의실", url: "eclass.bandal.ac.kr"))
        picker.removeLink("home")
        let added = picker.addLink()
        XCTAssertTrue(picker.updateLink(added, title: "도서관", url: "https://lib.bandal.ac.kr"))
        _ = picker.addLink() // left empty
        await picker.confirm()
        await picker.suggestion?.value

        let school = try XCTUnwrap(saved.first)
        XCTAssertEqual(school.links.map(\.title), ["강의실", "도서관"])
        XCTAssertEqual(school.links.map(\.url), ["https://eclass.bandal.ac.kr", "https://lib.bandal.ac.kr"])
        XCTAssertEqual(school.source, "user", "Edited links are this user's")
        XCTAssertEqual(finished, [school], "A failed suggestion does not hold the user back")
        XCTAssertEqual(calls.suggestions.map(\.id), ["s1"])
        XCTAssertEqual(calls.suggestions.first?.links, school.links)
    }

    func testConfirmingUnchangedLinksSavesTheSchoolAsFoundAndSuggestsNothing() async {
        let found = school(verified: true)
        let picker = model(directory(setup: { found }))
        picker.query = "반달대"
        await picker.findWithAI()
        await picker.confirm()
        XCTAssertEqual(saved, [found])
        XCTAssertNil(picker.suggestion); XCTAssertTrue(calls.suggestions.isEmpty)
    }

    func testASecondTapWhileSavingNeitherSavesNorSuggestsTwice() async {
        let found = school()
        let picker = NativeSchoolPickerModel(directory: directory(setup: { found }), country: "KR", locale: "ko-KR", debounce: .zero, save: { [unowned self] school in
            try await Task.sleep(for: .milliseconds(60))
            self.saved.append(school)
        }, done: { [unowned self] in self.finished.append($0) })
        picker.query = "반달대"
        await picker.findWithAI()
        picker.removeLink("home")
        async let first: Void = picker.confirm(), second: Void = picker.confirm()
        _ = await (first, second)
        await picker.suggestion?.value
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(finished.count, 1); XCTAssertEqual(calls.suggestions.count, 1)
        await picker.confirm()
        XCTAssertEqual(saved.count, 1, "Saved once: the picker is finished")
    }

    func testAISearchForABundledSchoolShowsItsCuratedSites() async {
        let picker = model(directory(setup: { [unowned self] in self.school("snu", name: "서울대", links: [self.link("only")]) }))
        picker.query = "설대"
        await picker.findWithAI()
        XCTAssertEqual(picker.found, NativeUniversityCatalog.schools.first { $0.id == "snu" }, "What is confirmed is what the sidebar will show")
        await picker.confirm()
        XCTAssertEqual(saved.first?.source, "bundled")
    }

    func testSignedOutAISearchWaitsForSignInThenRunsByItself() async {
        var signedIn = false
        let found = school()
        // Asking the account takes a moment, as the real one does.
        let picker = model(directory(setup: { found }, signedIn: { await Task.yield(); return signedIn }))
        picker.query = "반달대"
        await picker.findWithAI()
        XCTAssertEqual(picker.phase, .signIn); XCTAssertTrue(calls.setups.isEmpty)
        picker.dismissSignIn()
        XCTAssertEqual(picker.phase, .searching, "Closing the prompt goes back to the search")
        await picker.signedIn()
        XCTAssertTrue(calls.setups.isEmpty, "A sign-in elsewhere starts nothing")

        await picker.findWithAI()
        signedIn = true
        // The account announces a sign-in more than once; the rationed search still runs once.
        async let first: Void = picker.signedIn(), second: Void = picker.signedIn()
        _ = await (first, second)
        XCTAssertEqual(picker.phase, .confirming); XCTAssertEqual(calls.setups.count, 1)
    }

    func testMovingOnWhileTheAccountIsAskedStartsNoAISearch() async throws {
        let found = school()
        let slowAccount: () async -> Bool = { try? await Task.sleep(for: .milliseconds(120)); return true }
        let picker = model(directory(setup: { found }, signedIn: slowAccount))
        picker.query = "반달대"
        let tapped = Task { await picker.findWithAI() }
        try await Task.sleep(for: .milliseconds(30))
        picker.enterManually()
        await tapped.value
        XCTAssertEqual(picker.phase, .manual, "직접 입력 is not taken away by the answer"); XCTAssertTrue(calls.setups.isEmpty)

        let retyped = model(directory(setup: { found }, signedIn: slowAccount))
        retyped.query = "반달대"
        let again = Task { await retyped.findWithAI() }
        try await Task.sleep(for: .milliseconds(30))
        retyped.query = "반달대학교"
        await again.value
        XCTAssertEqual(retyped.phase, .searching); XCTAssertTrue(calls.setups.isEmpty, "The name on screen is not the one that was asked for")
    }

    func testAnExpiredSessionAsksToSignInAgain() async {
        let picker = model(directory(setup: { throw SchoolDirectoryError.signInRequired }))
        picker.query = "반달대"
        await picker.findWithAI()
        XCTAssertEqual(picker.phase, .signIn)
    }

    func testRateLimitedAndUnavailableAISearchGoBackToTheSearchWithAReason() async {
        let limited = model(directory(setup: { throw SchoolDirectoryError.rateLimited(limit: 3) }))
        limited.query = "반달대"
        await limited.findWithAI()
        XCTAssertEqual(limited.phase, .searching); XCTAssertEqual(limited.notice, .rateLimited(3))
        limited.enterManually()
        XCTAssertEqual(limited.phase, .manual, "직접 입력 is still there"); XCTAssertNil(limited.notice)

        let down = model(directory(setup: { throw SchoolDirectoryError.unavailable }))
        down.query = "반달대"
        await down.findWithAI()
        XCTAssertEqual(down.phase, .searching); XCTAssertEqual(down.notice, .aiUnavailable)
    }

    func testNotFoundAndAnEmptyResultOfferTheNameAlone() async throws {
        for answer in [nil, school(links: [])] {
            calls = Calls(); saved = []; finished = []
            let picker = model(directory(setup: { answer }))
            picker.query = "없는대학교"
            await picker.findWithAI()
            XCTAssertEqual(picker.phase, .notFound)
            picker.enterManually()
            try await picker.saveManually(" 없는대학교 ")
            let school = try XCTUnwrap(saved.first)
            XCTAssertEqual(school.name, "없는대학교"); XCTAssertTrue(school.links.isEmpty)
            XCTAssertEqual(school.source, "user"); XCTAssertEqual(school.country, "KR")
            XCTAssertEqual(finished, [school])
        }
    }

    func testBundledMatchesShowAtOnceAndStayBesideTheServersAnswer() async throws {
        let other = school("server-1", name: "서울과학기술대학교")
        var answer = [other]
        let picker = model(directory(search: { _ in try await Task.sleep(for: .milliseconds(200)); return answer }))
        picker.query = "서울"
        let run = Task { await picker.search() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(picker.results.map(\.id), ["snu"], "A slow connection does not hold back what the iPad already knows")
        XCTAssertFalse(picker.searched); XCTAssertFalse(picker.offline)
        await run.value
        XCTAssertEqual(picker.results.map(\.id), ["server-1", "snu"], "A school the server does not list is still offered")
        XCTAssertTrue(picker.searched); XCTAssertFalse(picker.offline)

        answer = [school("snu", name: "서울대학교"), other]
        await picker.search()
        XCTAssertEqual(picker.results.map(\.id), ["snu", "server-1"], "The server's own entry for a bundled school is not listed twice")
        answer = []
        await picker.search()
        XCTAssertEqual(picker.results.map(\.id), ["snu"], "An empty answer does not hide a school the iPad knows")
    }

    func testUnreachableServerFallsBackToTheBundledListAndSaysSo() async {
        let picker = model(directory(search: { _ in throw SchoolDirectoryError.unavailable }))
        picker.query = "snu"
        await picker.search()
        XCTAssertEqual(picker.results.map(\.id), ["snu"], "Aliases match without regard to case")
        XCTAssertTrue(picker.offline); XCTAssertTrue(picker.searched)
        picker.query = "Yonsei"
        await picker.search()
        XCTAssertEqual(picker.results.map(\.name), ["연세대학교"], "The English name matches too")
        picker.query = "어디에도 없는 학교"
        await picker.search()
        XCTAssertTrue(picker.results.isEmpty && picker.searched, "Never a dead end: AI and 직접 입력 are offered")
    }

    func testALongAISearchSaysSoAndStoppingItDropsTheLateAnswer() async throws {
        let found = school()
        let picker = model(directory(setup: { try await Task.sleep(for: .milliseconds(600)); return found }), slowAfter: .milliseconds(150))
        picker.query = "반달대"
        let run = Task { await picker.findWithAI() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(picker.phase, .finding); XCTAssertFalse(picker.slow)
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertTrue(picker.slow, "조금 더 걸려요")
        await run.value
        XCTAssertEqual(picker.phase, .confirming); XCTAssertFalse(picker.slow)

        // A server that answers anyway, after the user stopped waiting: the answer goes nowhere.
        let stopped = model(directory(setup: { try? await Task.sleep(for: .milliseconds(150)); return found }))
        stopped.query = "반달대"
        let second = Task { await stopped.findWithAI() }
        try await Task.sleep(for: .milliseconds(30))
        stopped.backToSearch()
        await second.value
        XCTAssertEqual(stopped.phase, .searching); XCTAssertNil(stopped.found); XCTAssertNil(stopped.notice)
        XCTAssertTrue(stopped.links.isEmpty)
    }

    func testAFailedSaveStaysOnTheConfirmationWithTheReason() async {
        let found = school()
        let picker = NativeSchoolPickerModel(directory: directory(setup: { found }), country: "KR", locale: "ko-KR", debounce: .zero,
                                             save: { _ in throw DesktopRuntimeError("설정을 저장하지 못했습니다.") }, done: { [unowned self] in self.finished.append($0) })
        picker.query = "반달대"
        await picker.findWithAI()
        await picker.confirm()
        XCTAssertEqual(picker.phase, .confirming); XCTAssertEqual(picker.notice, .saveFailed("설정을 저장하지 못했습니다."))
        XCTAssertTrue(finished.isEmpty)
    }

    func testAddressesAndCountryCodesAreValidatedBeforeUse() {
        XCTAssertEqual(NativeSchoolPickerModel.address(" portal.bandal.ac.kr/login "), "https://portal.bandal.ac.kr/login")
        XCTAssertEqual(NativeSchoolPickerModel.address("http://lms.bandal.ac.kr"), "http://lms.bandal.ac.kr")
        for bad in ["", "eclass", "https://", "javascript:alert(1)", "ftp://files.bandal.ac.kr", "https://user:pw@bandal.ac.kr", "bandal ac kr"] {
            XCTAssertNil(NativeSchoolPickerModel.address(bad), bad)
        }
        XCTAssertEqual(NativeSchoolPickerModel.region(" de "), "DE")
        for bad in ["", "D", "DEU", "ZZ", "12"] { XCTAssertNil(NativeSchoolPickerModel.region(bad), bad) }
    }

    // MARK: Settings

    func testABundledSchoolKeepsItsUniversityIdAndCuratedSites() throws {
        let snu = try XCTUnwrap(NativeUniversityCatalog.schools.first { $0.id == "snu" })
        XCTAssertEqual(snu.name, "서울대학교"); XCTAssertEqual(snu.country, "KR"); XCTAssertTrue(snu.verified)
        XCTAssertEqual(snu.links.first?.id, "snu.portal")
        let patch = NativeUniversityCatalog.patch(choosing: snu, current: [:])
        XCTAssertEqual(patch["universityId"] as? String, "snu")
        XCTAssertTrue(patch["customUniversity"] is NSNull)
        XCTAssertTrue((patch["customServices"] as? [[String: Any]])?.isEmpty == true)
        let settings: [String: Any] = ["university": patch]
        XCTAssertEqual(NativeUniversityCatalog.resolvedServices(settings: settings).first?.id, "snu.portal")
        XCTAssertFalse(NativeUniversityCatalog.needsLinks(settings))
    }

    func testAServerSchoolBecomesTheCustomUniversityWithItsLinksAsCustomServices() throws {
        let found = school("7c1e", links: [link("home", "home"), link("lms", "lms", order: 1), link("cal", "calendar", order: 2)])
        let patch = NativeUniversityCatalog.patch(choosing: found, current: [:])
        let settings: [String: Any] = ["university": patch]
        XCTAssertEqual(patch["universityId"] as? String, "custom:7c1e")
        XCTAssertEqual(patch["serviceOrder"] as? [String], ["custom:7c1e:home", "custom:7c1e:lms", "custom:7c1e:cal"], "The school's sites come before the shared ones")
        let university = try XCTUnwrap(NativeUniversityCatalog.university(settings))
        XCTAssertEqual(university["nameKo"] as? String, "반달대학교"); XCTAssertEqual(university["country"] as? String, "KR")
        let services = NativeUniversityCatalog.resolvedServices(settings: settings)
        XCTAssertEqual(services.map(\.id), ["custom:7c1e:home", "custom:7c1e:lms", "custom:7c1e:cal", "common.everytime"])
        XCTAssertEqual(services.map(\.kind).prefix(3), ["homepage", "lms", "calendar"], "`home` is the catalog's `homepage`")
        XCTAssertEqual(services.first?.url, "https://home.bandal.ac.kr")
        XCTAssertTrue(services.prefix(3).allSatisfy(\.custom), "Settings can delete them")
        XCTAssertEqual(NativeUniversityService.symbol("calendar"), "calendar")
        XCTAssertFalse(NativeUniversityCatalog.needsLinks(settings))
    }

    func testChangingSchoolKeepsTheUsersOwnSitesAndDropsThePreviousSchoolsLinks() {
        let own: [String: Any] = ["id": "custom:0A1B", "label": "동아리", "url": "https://club.example.org", "kind": "other"]
        func ids(_ university: [String: Any], _ key: String = "customServices") -> [String]? {
            key == "serviceOrder" ? university[key] as? [String] : (university[key] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        }
        // The user had put their own site ahead of the shared one.
        var university = NativeUniversityCatalog.patch(choosing: school("first"), current: ["customServices": [own], "serviceOrder": ["custom:0A1B", "common.everytime"]])
        XCTAssertEqual(ids(university), ["custom:0A1B", "custom:first:home", "custom:first:lms"])
        XCTAssertEqual(ids(university, "serviceOrder"), ["custom:first:home", "custom:first:lms", "custom:0A1B", "common.everytime"], "The school's sites lead; the user's order follows")
        university = NativeUniversityCatalog.patch(choosing: school("second", links: [link("portal", "portal")]), current: university)
        XCTAssertEqual(ids(university), ["custom:0A1B", "custom:second:portal"])
        XCTAssertEqual(ids(university, "serviceOrder"), ["custom:second:portal", "custom:0A1B", "common.everytime"])

        // 선택 해제 clears the school and its links, and a school chosen afterwards starts clean.
        var cleared = university
        cleared["universityId"] = NSNull(); cleared["customUniversity"] = NSNull(); cleared["customServices"] = NativeUniversityCatalog.ownServices(university)
        XCTAssertEqual(ids(cleared), ["custom:0A1B"])
        var stale = university
        stale["universityId"] = NSNull() // cleared by an older build, which left the links behind
        XCTAssertEqual(ids(NativeUniversityCatalog.patch(choosing: school("third", links: [link("home", "home")]), current: stale)), ["custom:0A1B", "custom:third:home"])

        university = NativeUniversityCatalog.patch(choosing: NativeUniversityCatalog.schools[0], current: university)
        XCTAssertEqual(ids(university), ["custom:0A1B"])
        XCTAssertTrue(NativeUniversityCatalog.isSchoolLink("custom:snu:mine")); XCTAssertFalse(NativeUniversityCatalog.isSchoolLink("custom:0A1B"))
        XCTAssertFalse(NativeUniversityCatalog.isSchoolLink("snu.portal")); XCTAssertFalse(NativeUniversityCatalog.isSchoolLink("common.everytime"))
    }

    func testEditedLinksOfABundledSchoolAreSavedAsTheUsersOwnSchool() throws {
        var edited = try XCTUnwrap(NativeUniversityCatalog.schools.first { $0.id == "snu" })
        edited.links = [link("mine")]; edited.source = "user"
        let patch = NativeUniversityCatalog.patch(choosing: edited, current: [:])
        XCTAssertEqual(patch["universityId"] as? String, "custom:snu")
        XCTAssertEqual(NativeUniversityCatalog.resolvedServices(settings: ["university": patch]).map(\.id), ["custom:snu:mine", "common.everytime"])
    }

    func testANameOnlySchoolNeedsLinksUntilTheAISearchAddsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("school-picker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await runtime.start()
        func choose(_ school: School) async throws -> [String: Any] {
            let current = try await runtime.invoke("settings:get") as? [String: Any] ?? [:]
            let patch = NativeUniversityCatalog.patch(choosing: school, current: current["university"] as? [String: Any] ?? [:])
            let saved = try await runtime.invoke("settings:set", request: ["university": patch])
            return try XCTUnwrap(saved as? [String: Any])
        }
        let untouched = try await runtime.invoke("settings:get") as? [String: Any] ?? [:]
        XCTAssertFalse(NativeUniversityCatalog.needsLinks(untouched), "No school yet")
        var settings = try await choose(School(id: "manual-1", name: "반달대학교", nameEn: nil, aliases: [], country: "JP", domain: nil, verified: false, source: "user", links: []))
        XCTAssertTrue(NativeUniversityCatalog.needsLinks(settings))
        XCTAssertEqual(NativeUniversityCatalog.university(settings)?["nameKo"] as? String, "반달대학교")
        XCTAssertEqual(NativeUniversityCatalog.university(settings)?["country"] as? String, "JP", "The sidebar's AI search keeps the country")

        settings = try await choose(school("7c1e"))
        XCTAssertFalse(NativeUniversityCatalog.needsLinks(settings))
        let reopened = DesktopRuntime(root: root, legacyRoot: root.appendingPathComponent("Legacy")); try await reopened.start()
        let reread = try await reopened.invoke("settings:get")
        let restored = try XCTUnwrap(reread as? [String: Any])
        XCTAssertEqual(NativeUniversityCatalog.resolvedServices(settings: restored).map(\.id).prefix(2), ["custom:7c1e:home", "custom:7c1e:lms"])

        // A school added by name before the directory existed.
        let legacy: [String: Any] = ["university": ["universityId": "custom:OLD", "customUniversity": ["id": "custom:OLD", "nameKo": "옛 학교", "services": [[String: Any]]()] as [String: Any],
                                                     "customServices": [["id": "custom:0A1B", "label": "동아리", "url": "https://club.example.org"]]] as [String: Any]]
        XCTAssertTrue(NativeUniversityCatalog.needsLinks(legacy), "The user's own sites are not the school's links")
    }

    // MARK: Directory contract

    private func live(status: Int = 200, _ body: String, signedIn: Bool = true, sent: @escaping (URLRequest) -> Void = { _ in }) -> LiveSchoolDirectory {
        LiveSchoolDirectory(configuration: { ("https://project.example/", "publishable") }, endpoint: {
            guard signedIn else { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            return AIEndpoint(userID: "user", projectURL: URL(string: "https://project.example")!, publishableKey: "publishable", token: { "jwt" })
        }, send: { request in
            sent(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
    private let schoolJSON = #"{"id":"7c1e","name":"반달대학교","nameEn":null,"aliases":["반달대"],"country":"KR","domain":"bandal.ac.kr","verified":false,"source":"ai","links":[{"id":"l2","kind":"lms","title":"강의실","url":"https://lms.bandal.ac.kr","verified":false,"order":1},{"id":"l1","kind":"home","title":"홈","url":"https://bandal.ac.kr","verified":true,"order":0},{"id":"bad","kind":"other","title":"나쁜 링크","url":"javascript:alert(1)","verified":false,"order":2},{"id":"l3","kind":"wiki","title":"위키","url":"https://wiki.bandal.ac.kr","verified":false,"order":3}]}"#

    func testSearchSendsOnlyThePublishableKeyAndReadsSchoolsDefensively() async throws {
        var request: URLRequest?
        let schools = try await live(#"{"schools":[\#(schoolJSON)]}"#, signedIn: false, sent: { request = $0 }).search("반달 C++", country: "KR")
        let sent = try XCTUnwrap(request), components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(sent.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "project.example"); XCTAssertEqual(components.path, "/functions/v1/schools/search")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: "반달 C++"), URLQueryItem(name: "country", value: "KR")])
        XCTAssertTrue(components.percentEncodedQuery?.contains("C%2B%2B") == true, "A literal + must not arrive as a space")
        XCTAssertEqual(sent.httpMethod, "GET")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "publishable")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"), "Search works signed out")

        let school = try XCTUnwrap(schools.first)
        XCTAssertEqual(school.name, "반달대학교"); XCTAssertNil(school.nameEn); XCTAssertEqual(school.aliases, ["반달대"]); XCTAssertFalse(school.verified)
        XCTAssertEqual(school.links.map(\.id), ["l1", "l2", "l3"], "In the server's order, without the link that is not a web address")
        XCTAssertEqual(school.links.map(\.kind), ["home", "lms", "other"], "An unknown kind is `other`")

        // One bad row does not take the list with it: no id, no name, a repeated school, a link without a title, a repeated link.
        let mixed = #"{"schools":[{"id":"","name":"이름만"},{"id":"x"},\#(schoolJSON),\#(schoolJSON),{"id":"ok","name":"달빛대학교","links":[{"id":"a","url":"https://a.example.org"},{"id":"b","title":"포털","url":"https://b.example.org"},{"id":"b","title":"포털 둘","url":"https://c.example.org"}]}]}"#
        let kept = try await live(mixed).search("반달", country: "KR")
        XCTAssertEqual(kept.map(\.id), ["7c1e", "ok"])
        XCTAssertEqual(kept.last?.links.map(\.title), ["포털"]); XCTAssertEqual(kept.last?.source, "ai"); XCTAssertEqual(kept.last?.aliases, [])

        let unconfigured = LiveSchoolDirectory(configuration: { ("", "") })
        do { _ = try await unconfigured.search("반달", country: "KR"); XCTFail("No project to ask") } catch { XCTAssertEqual(error as? SchoolDirectoryError, .unavailable) }
        do { _ = try await live(#"{"schools":"none"}"#).search("반달", country: "KR"); XCTFail("Not a list") } catch { XCTAssertEqual(error as? SchoolDirectoryError, .unavailable) }
        let insecure = LiveSchoolDirectory(endpoint: { AIEndpoint(userID: "user", projectURL: URL(string: "http://project.example")!, publishableKey: "publishable", token: { "jwt" }) },
                                           send: { _ in XCTFail("The token must not leave over http"); throw URLError(.badURL) })
        do { _ = try await insecure.setup(query: "반달대", country: "KR", locale: "ko-KR"); XCTFail("http") } catch { XCTAssertEqual(error as? SchoolDirectoryError, .unavailable) }
    }

    func testSetupGoesAsTheSignedInUserAndMapsEveryReply() async throws {
        var request: URLRequest?
        let found = try await live(#"{"status":"found","school":\#(schoolJSON)}"#, sent: { request = $0 }).setup(query: "반달대", country: "KR", locale: "en-US")
        XCTAssertEqual(found?.id, "7c1e")
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://project.example/functions/v1/schools/setup"); XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer jwt"); XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "publishable")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: String], ["query": "반달대", "country": "KR", "locale": "en-US"])

        let cached = try await live(#"{"status":"cached","school":\#(schoolJSON)}"#).setup(query: "반달대", country: "KR", locale: "ko-KR")
        XCTAssertEqual(cached?.name, "반달대학교")
        let missing = try await live(#"{"status":"not_found"}"#).setup(query: "없는대", country: "KR", locale: "ko-KR")
        XCTAssertNil(missing)

        let replies: [(Int, String, SchoolDirectoryError)] = [
            (401, #"{"code":"SIGN_IN_REQUIRED"}"#, .signInRequired), (429, #"{"code":"RATE_LIMITED","limit":3}"#, .rateLimited(limit: 3)),
            (429, "", .rateLimited(limit: 3)), (503, #"{"code":"AI_UNAVAILABLE"}"#, .unavailable), (500, "oops", .unavailable),
            (200, #"{"status":"found"}"#, .unavailable), (200, "not json", .unavailable),
        ]
        for (status, body, expected) in replies {
            do { _ = try await live(status: status, body).setup(query: "반달대", country: "KR", locale: "ko-KR"); XCTFail("\(status) \(body)") }
            catch { XCTAssertEqual(error as? SchoolDirectoryError, expected, "\(status) \(body)") }
        }
        var asked = false
        let signedOut = live("{}", signedIn: false, sent: { _ in asked = true })
        do { _ = try await signedOut.setup(query: "반달대", country: "KR", locale: "ko-KR"); XCTFail("Signed out") }
        catch { XCTAssertEqual(error as? SchoolDirectoryError, .signInRequired) }
        XCTAssertFalse(asked, "Nothing is sent without a session")
        let signedOutState = await signedOut.isSignedIn(), signedInState = await live("{}").isSignedIn()
        XCTAssertFalse(signedOutState); XCTAssertTrue(signedInState)

        let offline = LiveSchoolDirectory(configuration: { ("https://project.example", "publishable") }, send: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.search("반달", country: "KR"); XCTFail("Offline") } catch { XCTAssertEqual(error as? SchoolDirectoryError, .unavailable) }
    }

    func testSuggestPostsTheSchoolAndItsEditedLinks() async throws {
        var request: URLRequest?
        try await live("{}", sent: { request = $0 }).suggest(schoolID: "7c1e", links: [School.Link(id: "l1", kind: "home", title: "홈", url: "https://bandal.ac.kr", verified: false, order: 0)])
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.path, "/functions/v1/schools/suggest"); XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["schoolId"] as? String, "7c1e")
        let link = try XCTUnwrap((body["links"] as? [[String: Any]])?.first)
        XCTAssertEqual(link["id"] as? String, "l1"); XCTAssertEqual(link["kind"] as? String, "home"); XCTAssertEqual(link["title"] as? String, "홈")
        XCTAssertEqual(link["url"] as? String, "https://bandal.ac.kr"); XCTAssertEqual(link["verified"] as? Bool, false); XCTAssertEqual(link["order"] as? Int, 0)
    }

    // MARK: First run and language

    func testOnboardingIsOpenOnlyOnAFirstLaunchAndNeverInTestsThatDidNotAskForIt() throws {
        let name = "onboarding-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(NativeOnboardingGate.isPending(arguments: ["Bandal"], hostedTest: false, defaults: defaults))
        XCTAssertFalse(NativeOnboardingGate.isPending(arguments: ["Bandal", "--native-ui-testing", "--reset-native-ui-testing"], hostedTest: false, defaults: defaults))
        XCTAssertFalse(NativeOnboardingGate.isPending(arguments: ["Bandal"], hostedTest: true, defaults: defaults), "Unit test hosts")
        XCTAssertTrue(NativeOnboardingGate.isPending(arguments: ["Bandal", "--native-ui-testing", "--native-onboarding"], hostedTest: false, defaults: defaults))
        XCTAssertFalse(NativeOnboardingGate.isPending(), "This test run itself")

        // A new install is covered until the store answers; an update shows the workspace meanwhile.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(NativeOnboardingGate.initialStage(root: root, arguments: ["Bandal"], hostedTest: false, defaults: defaults), .pending)
        try Data().write(to: root.appendingPathComponent("bandal.db"))
        XCTAssertEqual(NativeOnboardingGate.initialStage(root: root, arguments: ["Bandal"], hostedTest: false, defaults: defaults), .deciding)
        XCTAssertEqual(NativeOnboardingGate.initialStage(root: root, arguments: ["Bandal", "--native-ui-testing"], hostedTest: false, defaults: defaults), .closed)

        defaults.set(true, forKey: NativeOnboardingGate.doneKey)
        XCTAssertFalse(NativeOnboardingGate.isPending(arguments: ["Bandal"], hostedTest: false, defaults: defaults), "Shown once")
        XCTAssertFalse(NativeOnboardingGate.isPending(arguments: ["Bandal", "--native-ui-testing", "--native-onboarding"], hostedTest: false, defaults: defaults))
        XCTAssertEqual(NativeOnboardingGate.initialStage(root: root, arguments: ["Bandal"], hostedTest: false, defaults: defaults), .closed)
    }

    func testExistingUsersNeverSeeOnboarding() {
        let fresh = NativeSettingsSchema.defaults(dataRoot: "/tmp/Courses")
        XCTAssertTrue(NativeOnboardingGate.shouldShow(settings: fresh, hasCourses: false))
        XCTAssertFalse(NativeOnboardingGate.shouldShow(settings: fresh, hasCourses: true), "Courses or data")
        XCTAssertFalse(NativeOnboardingGate.shouldShow(settings: ["university": ["universityId": "snu"]], hasCourses: false), "A school is set")
        XCTAssertFalse(NativeOnboardingGate.shouldShow(settings: ["university": ["universityId": "custom:1"]], hasCourses: false))
        XCTAssertTrue(NativeOnboardingGate.shouldShow(settings: [:], hasCourses: false))
    }

    func testTheFirstScreenIsInTheDeviceLanguageAndTheChoiceBecomesTheAppLanguage() {
        XCTAssertEqual(NativeOnboardingGate.language(saved: "ko-KR", preferred: ["ko-KR", "en-US"]), "ko-KR")
        XCTAssertEqual(NativeOnboardingGate.language(saved: "ko-KR", preferred: ["en-GB"]), "en-US", "ko-KR is only the default until someone chooses")
        XCTAssertEqual(NativeOnboardingGate.language(saved: nil, preferred: ["ja-JP"]), "en-US")
        XCTAssertEqual(NativeOnboardingGate.language(saved: "en-US", preferred: ["ko-KR"]), "en-US", "English chosen in Settings stays")
        XCTAssertEqual(NativeOnboardingGate.language(saved: nil, preferred: []), "en-US")

        let name = "locale-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        NativeAppearancePreference.apply(["locale": "en-US"], defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: NativeAppLocale.key), "en-US")
        NativeAppearancePreference.apply(["theme": "dark"], defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: NativeAppLocale.key), "en-US", "A partial update keeps the language")
        NativeAppearancePreference.apply(["locale": "fr-FR"], defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: NativeAppLocale.key), "ko-KR")
    }

    func testStringsForSharedComponentsFollowTheAppLanguage() {
        let english = Locale(identifier: "en-US"), korean = Locale(identifier: "ko-KR")
        XCTAssertEqual(NativeAppLocale.string("학교 이름 검색", english), "Search by school name")
        XCTAssertEqual(NativeAppLocale.string("학교 이름 검색", korean), "학교 이름 검색")
        XCTAssertEqual(NativeAppLocale.string("번역이 아직 없는 문장", english), "번역이 아직 없는 문장", "Untranslated text stays Korean")
        XCTAssertEqual(String(format: NativeAppLocale.string("%@ 사이트를 찾는 중…", english), "Bandal"), "Looking for Bandal sites…")
    }
    func testAnUnreviewedSearchResultIsConfirmedBeforeItIsSaved() async {
        // Another user's AI search put this school in the directory: its links were never reviewed.
        let found = school("server-2", name: "스탠퍼드")
        let picker = model(directory(search: { _ in [found] }))
        picker.query = "스탠퍼드"
        await picker.search()
        await picker.choose(found)
        XCTAssertEqual(picker.phase, .confirming); XCTAssertEqual(picker.found, found); XCTAssertEqual(picker.links, found.links)
        XCTAssertTrue(saved.isEmpty, "A tap on an unreviewed school saves nothing")
        picker.removeLink("lms")
        await picker.confirm()
        XCTAssertEqual(saved.first?.links.map(\.id), ["home"]); XCTAssertEqual(finished.count, 1)

        // With no links there is nothing to confirm.
        let bare = school("server-3", name: "이름만", links: [])
        let second = model(directory())
        await second.choose(bare)
        XCTAssertEqual(saved.last, bare)
    }
    func testServerTextLosesControlAndDirectionCharactersAndHasALength() throws {
        let links = (0..<25).map { #"{"id":"l\#($0)","kind":"other","title":"링크\#($0)","url":"https://l\#($0).bandal.ac.kr","order":\#($0)}"# }.joined(separator: ",")
        let json = #"{"id":"s1","name":"  반달\u202E대학교\u0007\u200B  ","nameEn":"\#(String(repeating: "A", count: 300))","aliases":["반\u2066달"],"country":"KR","links":[{"id":"t","kind":"home","title":"홈\u202E페이지\n","url":"https://www.bandal.ac.kr","order":-1},{"id":"e","kind":"home","title":"\u200B","url":"https://x.bandal.ac.kr"},\#(links)]}"#
        let decoded = try JSONDecoder().decode(School.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.name, "반달대학교"); XCTAssertEqual(decoded.nameEn?.count, 120); XCTAssertEqual(decoded.aliases, ["반달"])
        XCTAssertEqual(decoded.links.first?.title, "홈페이지")
        XCTAssertEqual(decoded.links.count, School.maxLinks, "An empty title is dropped and the list is bounded")
        XCTAssertFalse(decoded.links.contains { $0.id == "e" })
        XCTAssertThrowsError(try JSONDecoder().decode(School.self, from: Data(#"{"id":"s2","name":"\u202E\u200B"}"#.utf8)), "A name of invisible characters is no name")
    }
    func testAnOversizedReplyIsRefused() async {
        let huge = #"{"schools":[],"pad":""# + String(repeating: "x", count: School.maxReplyBytes) + #""}"#
        do { _ = try await live(huge).search("반달", country: "KR"); XCTFail("An oversized reply was read") }
        catch { XCTAssertEqual(error as? SchoolDirectoryError, .unavailable) }
    }
    func testASearchResultSaysWhenItsSchoolWasFoundByAIAndNotReviewed() {
        let found = School(id: "a", name: "Stanford University", nameEn: nil, aliases: [], country: "US", domain: "stanford.edu", verified: false, source: "ai", links: [])
        XCTAssertEqual(found.detail(mark: "검토 전"), "stanford.edu · 검토 전")
        var reviewed = found; reviewed.verified = true
        XCTAssertEqual(reviewed.detail(mark: "검토 전"), "stanford.edu")
        var bare = found; bare.domain = nil
        XCTAssertEqual(bare.detail(mark: "검토 전"), "검토 전")
        let bundled = School(id: "snu", name: "서울대학교", nameEn: "Seoul National University", aliases: [], country: "KR", domain: "snu.ac.kr", verified: true, source: "bundled", links: [])
        XCTAssertEqual(bundled.detail(mark: "검토 전"), "Seoul National University")
    }
}
