import XCTest
@testable import Bandal

/// The home sidebar's site tiles: school essentials first, then browser visits decide; pins stay on top.
final class NativeHomeSitesTests: XCTestCase {
    private func service(_ id: String, _ url: String, secondary: Bool = false) -> NativeUniversityService {
        .init(id: id, label: id, kind: "portal", url: url, opensExternally: false, secondary: secondary, note: nil, custom: false, hidden: false)
    }
    private let school = [
        "portal": "https://portal.school.ac.kr/", "lms": "https://lms.school.ac.kr/login", "library": "https://lib.school.ac.kr/",
        "mail": "https://mail.school.ac.kr/", "cafeteria": "https://food.school.ac.kr/",
    ]
    private var services: [NativeUniversityService] {
        ["portal", "lms", "library", "mail", "cafeteria"].map { service($0, school[$0]!) } + [service("extra", "https://extra.school.ac.kr/", secondary: true)]
    }

    func testSchoolEssentialsStartInTheirOrderWithOneVisitEach() {
        let sites = NativeHomeSites.rank(school: services, preferences: .init(), visited: [])
        XCTAssertEqual(sites.map(\.id), ["school:portal", "school:lms", "school:library", "school:mail"], "The first four primary links")
        XCTAssertTrue(sites.allSatisfy { $0.visits == 1 })
    }

    func testVisitsReorderAndFrequentSitesJoinOnTheirOwn() {
        let visited = [(host: "lib.school.ac.kr", title: "Library", visits: 5), (host: "www.youtube.com", title: "YouTube", visits: 3),
                       (host: "rare.example.com", title: "Rare", visits: 2)]
        let sites = NativeHomeSites.rank(school: services, preferences: .init(), visited: visited)
        XCTAssertEqual(sites.first?.id, "school:library", "1 + 5 visits")
        XCTAssertEqual(sites[1].id, "visited:youtube.com")
        XCTAssertFalse(sites.contains { $0.host == "rare.example.com" }, "Below the threshold")
    }

    func testPinsComeFirstInPinOrderAndRemovedHostsStayAway() {
        var preferences = NativeHomeSitePreferences()
        preferences.custom = [(id: "custom:a", title: "ChatGPT", url: "https://chatgpt.com/")]
        preferences.pinned = ["custom:a", "school:mail"]
        preferences.hidden = ["portal.school.ac.kr", "youtube.com"]
        let sites = NativeHomeSites.rank(school: services, preferences: preferences, visited: [(host: "youtube.com", title: "YouTube", visits: 9)])
        XCTAssertEqual(Array(sites.prefix(2).map(\.id)), ["custom:a", "school:mail"])
        XCTAssertTrue(sites.prefix(2).allSatisfy(\.pinned))
        XCTAssertFalse(sites.contains { $0.host == "portal.school.ac.kr" || $0.host == "youtube.com" })
    }

    func testPreferencesRoundTripThroughSettings() {
        var preferences = NativeHomeSitePreferences()
        preferences.custom = [(id: "custom:a", title: "Claude", url: "https://claude.ai/new")]
        preferences.pinned = ["custom:a"]; preferences.hidden = ["example.com"]
        XCTAssertEqual(NativeHomeSitePreferences(settings: [NativeHomeSitePreferences.key: preferences.json]), preferences)
    }
}
