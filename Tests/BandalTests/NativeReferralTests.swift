import XCTest
@testable import Bandal

/// Friend invitations: the code's shape, what a link carries, the server contract and the invitee's
/// steps from a typed code to the reward. No server: `ReferralServiceFake` or a stubbed transport.
@MainActor
final class NativeReferralTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var hasCourse = false
    private var refreshes = 0

    override func setUp() async throws {
        suite = "referral-\(UUID())"; defaults = UserDefaults(suiteName: suite)
        hasCourse = false; refreshes = 0
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    /// The invitee's side over `service`, with this test's own defaults, courses and usage refresh.
    private func referral(_ service: ReferralServiceFake) -> NativeReferral {
        NativeReferral(service: service, defaults: defaults, hasCourse: { [unowned self] in self.hasCourse }, refreshUsage: { [unowned self] in self.refreshes += 1 })
    }
    /// What a sign-in does (after a sign-out, when someone was in): the account service's
    /// `auth:changed` reaches the invitation.
    private func signIn(_ service: ReferralServiceFake, _ referral: NativeReferral) async {
        service.signedIn = true
        referral.accountChanged(signedIn: false); referral.accountChanged(signedIn: true)
        await settle(referral)
    }
    /// Waits for every step, including one that a step started.
    private func settle(_ referral: NativeReferral) async {
        var last: Task<ReferralError?, Never>?
        while let work = referral.work, work != last { last = work; _ = await work.value }
    }

    // MARK: Code, link, credit

    func testTheCodeFieldKeepsCapitalsFromTheAlphabetAndTheTailOfAPastedLink() {
        XCTAssertEqual(Referral.alphabet.count, 31)
        for confusable in "ILO01" { XCTAssertFalse(Referral.alphabet.contains(confusable), "\(confusable)") }
        XCTAssertEqual(Referral.normalize("abc234"), "ABC234", "Typed in small letters")
        XCTAssertEqual(Referral.normalize(" abc-234 "), "ABC234", "Spaces and dashes go")
        XCTAssertEqual(Referral.normalize("bandal.io/r/abc234"), "ABC234", "A pasted link gives its code, not the letters of its host")
        XCTAssertEqual(Referral.normalize("https://bandal.io/r/ABC234"), "ABC234")
        XCTAssertEqual(Referral.normalize("https://bandal.io/r/ABC234/"), "ABC234")
        XCTAssertEqual(Referral.normalize("https://bandal.io/r/abc234?utm_source=kakao"), "ABC234")
        XCTAssertEqual(Referral.normalize("반달에서 같이 공부하자. 초대 코드 ABC234 넣으면 둘 다 AI 100회 받아요. https://bandal.io/r/ABC234"), "ABC234", "The whole share message")
        XCTAssertEqual(Referral.normalize("Let's study together on Bandal. Enter invite code ABC234 and we both get 100 AI uses. https://bandal.io/r/ABC234"), "ABC234")
        XCTAssertEqual(Referral.normalize("초대 코드 abc234"), "ABC234")
        XCTAssertEqual(Referral.normalize("a0b1cOdIeLf2gh"), "ABCDEF", "0, 1, O, I and L are dropped, not guessed at")
        XCTAssertEqual(Referral.normalize("ABCDEFGH"), "ABCDEF", "Six at most")
        XCTAssertEqual(Referral.normalize("AB\u{200B}C2\u{202E}34"), "ABC234", "Invisible characters in pasted text")
        XCTAssertEqual(Referral.normalize("ＡＢＣ２３４"), "", "Full-width look-alikes are not the alphabet")
        XCTAssertEqual(Referral.normalize("\u{00DF}bcde2"), "BCDE2", "Capitals never make letters that were not typed (ß is not SS)")
        for empty in ["", " ", "/", "한글", "0101"] { XCTAssertEqual(Referral.normalize(empty), "", empty) }
        XCTAssertEqual(Referral.normalize(Referral.alphabet), "ABCDEF")
        XCTAssertEqual(Referral.normalize(String(Referral.alphabet.suffix(6))), "456789")

        XCTAssertTrue(Referral.isCode("ABC234")); XCTAssertTrue(Referral.isCode(ReferralServiceFake.ownCode))
        for bad in ["", "abc234", "ABC23", "ABC2345", "ABCO23", "ABC 23", "ABC23\u{200B}4", "ABC23\n"] { XCTAssertFalse(Referral.isCode(bad), bad) }
    }

    func testOnlyABandalInviteLinkCarriesACode() throws {
        func code(_ address: String) throws -> String? { Referral.code(link: try XCTUnwrap(URL(string: address), address)) }
        XCTAssertEqual(Referral.link("ABC234"), "https://bandal.io/r/ABC234")
        for good in ["https://bandal.io/r/ABC234", "https://bandal.io/r/abc234", "https://BANDAL.IO/r/Abc234", "HTTPS://bandal.io/r/ABC234", "https://bandal.io/r/ABC234/",
                     "https://bandal.io/r/ABC234?utm_source=kakao", "https://bandal.io/r/ABC234#top"] {
            XCTAssertEqual(try code(good), "ABC234", good)
        }
        // Another place, another path, or a code that is not one: the link only opens the app.
        for bad in ["http://bandal.io/r/ABC234", "https://www.bandal.io/r/ABC234", "https://bandal.io.example.com/r/ABC234", "https://example.com/r/ABC234",
                    "https://bandal.io/R/ABC234", "https://bandal.io/x/ABC234", "https://bandal.io/r/ABC234/more", "https://bandal.io/ko/r/ABC234",
                    "https://bandal.io/r/", "https://bandal.io/r", "https://bandal.io/", "https://bandal.io/r/ABC23", "https://bandal.io/r/ABC2345",
                    "https://bandal.io/r/ABCO23", "https://bandal.io/r/ABC%2023", "https://bandal.io/r/..%2FABC234", "https://bandal.io/?r=ABC234",
                    "https://bandal.io/r/%C3%9FBCDE", "https://bandal.io/r/%C3%9FBCDEF",
                    "bandal://r/ABC234", "bandal://auth/callback?code=ABC234", "file:///r/ABC234"] {
            XCTAssertNil(try code(bad), bad)
        }
    }

    func testCreditReadsAsAIUses() {
        XCTAssertEqual(Referral.uses(7_000_000), 100, "The reward is AI 100회")
        XCTAssertEqual(Referral.uses(21_000_000), 300)
        XCTAssertEqual(Referral.uses(70_000), 1); XCTAssertEqual(Referral.uses(139_999), 1, "Whole uses only")
        XCTAssertEqual(Referral.uses(69_999), 0); XCTAssertEqual(Referral.uses(0), 0); XCTAssertEqual(Referral.uses(-70_000), 0)
    }

    func testNoticesAndEveryInvitationStringAreInTheAppLanguage() {
        let korean = Locale(identifier: "ko-KR"), english = Locale(identifier: "en-US")
        let lines: [(NativeReferral.Notice, String, String)] = [
            (.rewarded(uses: 100), "AI 100회가 들어왔어요", "100 AI uses added"),
            (.refused(.invalidCode), "없는 초대 코드예요.", "That invite code doesn't exist."),
            (.refused(.ownCode), "내 초대 코드는 내가 쓸 수 없어요.", "You can't use your own invite code."),
            (.refused(.alreadyClaimed), "이미 다른 초대 코드를 썼어요.", "You've already used an invite code."),
        ]
        for (notice, ko, en) in lines { XCTAssertEqual(notice.text(korean), ko); XCTAssertEqual(notice.text(english), en) }
        XCTAssertEqual(String(format: NativeAppLocale.string("반달에서 같이 공부하자. 초대 코드 %@ 넣으면 둘 다 AI 100회 받아요. https://bandal.io/r/%@", korean), "ABC234", "ABC234"),
                       "반달에서 같이 공부하자. 초대 코드 ABC234 넣으면 둘 다 AI 100회 받아요. https://bandal.io/r/ABC234")
        XCTAssertEqual(String(format: NativeAppLocale.string("반달에서 같이 공부하자. 초대 코드 %@ 넣으면 둘 다 AI 100회 받아요. https://bandal.io/r/%@", english), "ABC234", "ABC234"),
                       "Let's study together on Bandal. Enter invite code ABC234 and we both get 100 AI uses. https://bandal.io/r/ABC234")
        XCTAssertEqual(String(format: NativeAppLocale.string("%lld단계 중 %lld단계", english), 4, 3), "Step 3 of 4")
        XCTAssertEqual(String(format: NativeAppLocale.string("초대 %lld / %lld · 받은 AI %lld회", english), 3, 5, 300), "Invited 3 of 5 · 300 AI uses received")
        // Every Korean literal of the invitation's screens has its English.
        for key in ["%lld명까지", "6자리 코드", "AI %lld회", "공유", "내 초대 코드 %@ 복사", "다시 시도", "다시 확인", "로그인하면 AI 100회가 들어와요", "로그인하면 내 초대 코드를 받을 수 있어요",
                    "링크 복사", "복사했어요", "없어요, 건너뛰기", "이 코드 적용", "첫 과목을 만들면 AI 100회가 들어와요", "초대 정보를 불러오지 못했어요", "초대 코드", "초대 코드 입력", "초대 코드가 있나요?",
                    "초대 크레딧", "초대하기", "친구 초대", "친구 초대로 지금까지 받은 양이에요", "친구가 로그인하고 첫 과목을 만들면 둘 다 AI 100회", "코드 적용됨 — AI 100회를 받았어요",
                    "코드 적용됨 — 로그인하고 첫 과목을 만들면 AI 100회가 들어와요", "코드를 확인하지 못했어요. 연결을 확인해 주세요.", "확인하는 중…"] {
            XCTAssertNotEqual(NativeAppLocale.string(key, english), key, key)
        }
    }

    // MARK: Server contract

    private func live(status: Int = 200, _ body: String, signedIn: Bool = true, sent: @escaping (URLRequest) -> Void = { _ in }) -> LiveReferralService {
        LiveReferralService(configuration: { ("https://project.example/", "publishable") }, endpoint: {
            guard signedIn else { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
            return AIEndpoint(userID: "user", projectURL: URL(string: "https://project.example")!, publishableKey: "publishable", token: { "jwt" })
        }, send: { request in
            sent(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
    }
    /// The four calls on one service, each expected to end in `expected`.
    private func expect(_ expected: ReferralError, _ note: String, file: StaticString = #filePath, line: UInt = #line, _ call: () async throws -> Void) async {
        do { try await call(); XCTFail(note, file: file, line: line) }
        catch { XCTAssertEqual(error as? ReferralError, expected, note, file: file, line: line) }
    }

    func testCheckSendsOnlyThePublishableKeyAndReadsTheAnswerStrictly() async throws {
        var request: URLRequest?
        let exists = try await live(#"{"valid":true}"#, signedIn: false, sent: { request = $0 }).check("ABC234")
        XCTAssertTrue(exists)
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://project.example/functions/v1/referral/check?code=ABC234")
        XCTAssertEqual(sent.httpMethod, "GET"); XCTAssertNil(sent.httpBody)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "publishable")
        XCTAssertNil(sent.value(forHTTPHeaderField: "Authorization"), "Checking a code works signed out")
        let missing = try await live(#"{"valid":false}"#).check("XXXXXX")
        XCTAssertFalse(missing)

        // Anything but a plain true or false is no answer: a code is never kept on a guess.
        for (status, body) in [(200, #"{"valid":1}"#), (200, #"{"valid":"true"}"#), (200, "{}"), (200, "[true]"), (200, "not json"), (200, ""),
                               (404, #"{"valid":true}"#), (500, "oops"), (429, #"{"code":"RATE_LIMITED"}"#), (503, #"{"code":"REFERRAL_UNAVAILABLE"}"#),
                               (404, #"{"code":"NOT_FOUND"}"#), (405, #"{"code":"METHOD_NOT_ALLOWED"}"#), (400, #"{"code":"INVALID_REQUEST"}"#),
                               (200, #"{"valid":true,"pad":""# + String(repeating: "x", count: Referral.maxReplyBytes) + #""}"#)] {
            await expect(.unavailable, "\(status) \(body.prefix(40))") { _ = try await self.live(status: status, body).check("ABC234") }
        }
        var asked = false
        // What is not a code is not sent at all.
        for junk in ["", "abc234", "ABC23", "ABC234&x=1", "ABC2345"] {
            let exists = try await live(#"{"valid":true}"#, sent: { _ in asked = true }).check(junk)
            XCTAssertFalse(exists, junk)
            await expect(.invalidCode, junk) { try await self.live(#"{"status":"claimed"}"#, sent: { _ in asked = true }).claim(junk) }
        }
        let unconfigured = LiveReferralService(configuration: { ("", "") }, send: { _ in asked = true; throw URLError(.badURL) })
        await expect(.unavailable, "No project to ask") { _ = try await unconfigured.check("ABC234") }
        let insecure = LiveReferralService(configuration: { ("http://project.example", "publishable") }, send: { _ in asked = true; throw URLError(.badURL) })
        await expect(.unavailable, "http") { _ = try await insecure.check("ABC234") }
        XCTAssertFalse(asked)
        let offline = LiveReferralService(configuration: { ("https://project.example", "publishable") }, send: { _ in throw URLError(.notConnectedToInternet) })
        await expect(.unavailable, "Offline") { _ = try await offline.check("ABC234") }
    }

    func testClaimGoesAsTheSignedInUserAndMapsEveryReply() async throws {
        var request: URLRequest?
        try await live(#"{"status":"claimed"}"#, sent: { request = $0 }).claim("ABC234")
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://project.example/functions/v1/referral/claim"); XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer jwt"); XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "publishable")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: String], ["code": "ABC234"], "The code and nothing about the device")

        let replies: [(Int, String, ReferralError)] = [
            (401, #"{"code":"SIGN_IN_REQUIRED"}"#, .signInRequired), (401, "", .signInRequired),
            (404, #"{"code":"INVALID_CODE"}"#, .invalidCode), (409, #"{"code":"OWN_CODE"}"#, .ownCode), (409, #"{"code":"ALREADY_CLAIMED"}"#, .alreadyClaimed),
            // A function that is not deployed answers 404 too: that says nothing about the code.
            (404, "", .unavailable), (404, #"{"message":"Function not found"}"#, .unavailable), (409, #"{"code":"SOMETHING_NEW"}"#, .unavailable),
            (409, #"{"code":409}"#, .unavailable), (429, #"{"code":"RATE_LIMITED"}"#, .unavailable), (500, "oops", .unavailable),
            // The server's other refusals say nothing about the code: it waits, and nobody is told it is wrong.
            (503, #"{"code":"REFERRAL_UNAVAILABLE"}"#, .unavailable), (400, #"{"code":"INVALID_REQUEST"}"#, .unavailable),
            (404, #"{"code":"NOT_FOUND"}"#, .unavailable), (405, #"{"code":"METHOD_NOT_ALLOWED"}"#, .unavailable),
            (200, #"{"status":"pending"}"#, .unavailable), (200, #"{"status":true}"#, .unavailable), (200, "{}", .unavailable), (200, "not json", .unavailable),
        ]
        for (status, body, expected) in replies {
            await expect(expected, "\(status) \(body)") { try await self.live(status: status, body).claim("ABC234") }
        }
        var asked = false
        let signedOut = live(#"{"status":"claimed"}"#, signedIn: false, sent: { _ in asked = true })
        await expect(.signInRequired, "Signed out") { try await signedOut.claim("ABC234") }
        await expect(.signInRequired, "Signed out") { _ = try await signedOut.complete() }
        await expect(.signInRequired, "Signed out") { _ = try await signedOut.status() }
        XCTAssertFalse(asked, "Nothing is sent without a session")
        let signedOutState = await signedOut.isSignedIn(), signedInState = await live("{}").isSignedIn()
        XCTAssertFalse(signedOutState); XCTAssertTrue(signedInState)

        let insecure = LiveReferralService(endpoint: { AIEndpoint(userID: "user", projectURL: URL(string: "http://project.example")!, publishableKey: "publishable", token: { "jwt" }) },
                                           send: { _ in XCTFail("The token must not leave over http"); throw URLError(.badURL) })
        await expect(.unavailable, "http") { try await insecure.claim("ABC234") }
        let expired = LiveReferralService(endpoint: { AIEndpoint(userID: "user", projectURL: URL(string: "https://project.example")!, publishableKey: "publishable", token: { throw URLError(.userAuthenticationRequired) }) },
                                          send: { _ in XCTFail("No token, no request"); throw URLError(.badURL) })
        await expect(.signInRequired, "A session that cannot be refreshed") { try await expired.claim("ABC234") }
    }

    func testCompleteMapsEveryReply() async throws {
        var request: URLRequest?
        let paid = try await live(#"{"status":"rewarded","creditMicrocents":7000000,"referrerRewarded":true}"#, sent: { request = $0 }).complete()
        XCTAssertEqual(paid, .rewarded(creditMicrocents: 7_000_000))
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://project.example/functions/v1/referral/complete"); XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer jwt"); XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "publishable")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: try XCTUnwrap(sent.httpBody)) as? [String: String], [:], "Nothing about the course or the device")

        // The inviter may be past the limit; the invitee was paid all the same.
        let alone = try await live(#"{"status":"rewarded","creditMicrocents":7000000,"referrerRewarded":false}"#).complete()
        XCTAssertEqual(alone, .rewarded(creditMicrocents: 7_000_000))
        let nothing = try await live(#"{"status":"none"}"#).complete(), before = try await live(#"{"status":"already"}"#).complete()
        XCTAssertEqual(nothing, .none); XCTAssertEqual(before, .already)
        let huge = try await live(#"{"status":"rewarded","creditMicrocents":9000000000000000000}"#).complete()
        XCTAssertEqual(huge, .rewarded(creditMicrocents: 7_000_000_000), "An absurd amount is bounded")

        for body in [#"{"status":"rewarded"}"#, #"{"status":"rewarded","creditMicrocents":0}"#, #"{"status":"rewarded","creditMicrocents":-7000000}"#,
                     #"{"status":"rewarded","creditMicrocents":"7000000"}"#, #"{"status":"rewarded","creditMicrocents":7000000.5}"#, #"{"status":"rewarded","creditMicrocents":null}"#,
                     #"{"status":"paid","creditMicrocents":7000000}"#, #"{"status":null}"#, #"{"creditMicrocents":7000000}"#, "{}", "not json"] {
            await expect(.unavailable, body) { _ = try await self.live(body).complete() }
        }
        await expect(.signInRequired, "401") { _ = try await self.live(status: 401, #"{"code":"SIGN_IN_REQUIRED"}"#).complete() }
        await expect(.unavailable, "503") { _ = try await self.live(status: 503, "").complete() }
    }

    func testStatusIsReadDefensively() async throws {
        var request: URLRequest?
        let status = try await live(#"{"code":"BANDA2","completed":3,"limit":5,"creditMicrocents":21000000,"claim":{"code":"ABC234","completed":false}}"#, sent: { request = $0 }).status()
        XCTAssertEqual(status, ReferralStatus(code: "BANDA2", completed: 3, limit: 5, creditMicrocents: 21_000_000, claim: .init(completed: false)))
        XCTAssertEqual(Referral.uses(status.creditMicrocents), 300)
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.url?.absoluteString, "https://project.example/functions/v1/referral/status"); XCTAssertEqual(sent.httpMethod, "GET"); XCTAssertNil(sent.httpBody)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer jwt"); XCTAssertEqual(sent.value(forHTTPHeaderField: "apikey"), "publishable")

        let fresh = try await live(#"{"code":"BANDA2","completed":0,"limit":5,"creditMicrocents":0,"claim":null}"#).status()
        XCTAssertEqual(fresh, ReferralStatus(code: "BANDA2", completed: 0, limit: 5, creditMicrocents: 0, claim: nil))
        let paid = try await live(#"{"code":"BANDA2","completed":0,"limit":5,"creditMicrocents":7000000,"claim":{"code":"ABC234","completed":true}}"#).status()
        XCTAssertEqual(paid.claim, .init(completed: true))
        // A claim that cannot be read is no claim; the rest still stands.
        for claim in [#""yes""#, "{}", #"{"completed":"no"}"#, #"{"completed":1}"#, "[]"] {
            let odd = try await live(#"{"code":"BANDA2","completed":1,"limit":5,"creditMicrocents":7000000,"claim":\#(claim)}"#).status()
            XCTAssertNil(odd.claim, claim); XCTAssertEqual(odd.completed, 1, claim)
        }
        let absent = try await live(#"{"code":"BANDA2","completed":1,"limit":5,"creditMicrocents":7000000}"#).status()
        XCTAssertNil(absent.claim)
        // More friends than the limit can complete; the line counts up to the limit.
        let popular = try await live(#"{"code":"BANDA2","completed":7,"limit":5,"creditMicrocents":35000000,"claim":null}"#).status()
        XCTAssertEqual(popular.completed, 7); XCTAssertEqual(popular.counted, 5); XCTAssertEqual(Referral.uses(popular.creditMicrocents), 500)
        XCTAssertEqual(status.counted, 3)
        // Numbers stay inside what the screen can show.
        let wild = try await live(#"{"code":"BANDA2","completed":-3,"limit":123456,"creditMicrocents":-1}"#).status()
        XCTAssertEqual(wild, ReferralStatus(code: "BANDA2", completed: 0, limit: 999, creditMicrocents: 0, claim: nil))
        let rich = try await live(#"{"code":"BANDA2","completed":2,"limit":5,"creditMicrocents":9000000000000000000}"#).status()
        XCTAssertEqual(rich.creditMicrocents, 7_000_000_000)

        // The code is copied and shared: one that is not a code makes the whole reply unreadable.
        for code in [#""banda2""#, #""BANDA""#, #""BANDA22""#, #""BANDO2""#, #""BANDA2\n""#, #""BAN\u202EDA2""#, #""https://evil.example""#, #""""#, "null", "123456", #"["BANDA2"]"#] {
            await expect(.unavailable, code) { _ = try await self.live(#"{"code":\#(code),"completed":3,"limit":5,"creditMicrocents":21000000}"#).status() }
        }
        for body in [#"{"code":"BANDA2","completed":2.5,"limit":5,"creditMicrocents":0}"#, #"{"code":"BANDA2","completed":"3","limit":5,"creditMicrocents":0}"#,
                     #"{"code":"BANDA2","completed":true,"limit":5,"creditMicrocents":0}"#, #"{"code":"BANDA2","completed":3,"creditMicrocents":0}"#,
                     #"{"code":"BANDA2","completed":3,"limit":5}"#, #"{"code":"BANDA2","completed":3,"limit":5,"creditMicrocents":"lots"}"#, "{}", "[]", "not json"] {
            await expect(.unavailable, body) { _ = try await self.live(body).status() }
        }
        await expect(.signInRequired, "401") { _ = try await self.live(status: 401, "").status() }
    }

    // MARK: From a typed code to the reward

    func testACodeWaitsForSignInThenForTheFirstCourseAndThenBringsTheReward() async {
        let server = ReferralServiceFake(signedIn: false), invitee = referral(server)
        XCTAssertFalse(invitee.applied)
        let entry = await invitee.enter("ABC234")
        XCTAssertEqual(entry, .applied)
        XCTAssertEqual(invitee.pending, "ABC234"); XCTAssertFalse(invitee.awaiting); XCTAssertTrue(invitee.applied)
        XCTAssertEqual(server.calls, ["check ABC234"], "Signed out, the code is only checked")
        XCTAssertEqual(referral(server).pending, "ABC234", "It is still there after a relaunch")

        // Signing in claims it. Without a course nothing more is asked.
        await signIn(server, invitee)
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234"])
        XCTAssertNil(invitee.pending); XCTAssertTrue(invitee.awaiting); XCTAssertTrue(invitee.applied); XCTAssertNil(invitee.notice)
        XCTAssertTrue(referral(server).awaiting, "Claimed, and waiting across a relaunch")
        // Signed out and in again: the waiting reward left this iPad with the account and comes
        // back from the server's status. Nothing is claimed twice.
        await signIn(server, invitee)
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234", "status"])
        XCTAssertTrue(invitee.awaiting)

        // The first course asks for the reward, once; the numbers on screen follow.
        hasCourse = true
        _ = await invitee.advance().value
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234", "status", "complete", "status"])
        XCTAssertEqual(invitee.notice, .rewarded(uses: 100)); XCTAssertEqual(refreshes, 1, "The AI usage on screen follows")
        XCTAssertFalse(invitee.awaiting); XCTAssertFalse(invitee.applied)
        _ = await invitee.advance().value
        await signIn(server, invitee)
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("claim") }.count, 1); XCTAssertEqual(server.calls.filter { $0 == "complete" }.count, 1, "Settled: a later sign-in only reads the status")
        XCTAssertEqual(server.calls.last, "status"); XCTAssertFalse(invitee.awaiting)
        let relaunched = referral(server)
        XCTAssertNil(relaunched.pending); XCTAssertFalse(relaunched.awaiting)
    }

    func testSignedInACodeIsClaimedAtOnceAndWithACourseTheRewardComesRightAway() async {
        let server = ReferralServiceFake(), invitee = referral(server)
        hasCourse = true
        let entry = await invitee.enter("ABC234")
        XCTAssertEqual(entry, .idle, "Settled at once: the toast says so, and the field promises nothing more")
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234", "complete"])
        XCTAssertEqual(invitee.notice, .rewarded(uses: 100)); XCTAssertFalse(invitee.applied); XCTAssertEqual(refreshes, 1)

        // Signed in without a course: claimed now, rewarded when the course comes.
        hasCourse = false
        let later = ReferralServiceFake(), waiting = referral(later)
        let applied = await waiting.enter("DEF567")
        XCTAssertEqual(applied, .applied)
        XCTAssertEqual(later.calls, ["check DEF567", "claim DEF567"]); XCTAssertTrue(waiting.awaiting); XCTAssertNil(waiting.pending)
    }

    func testACodeThatDoesNotExistOrCannotBeCheckedIsNotKept() async {
        let server = ReferralServiceFake(), invitee = referral(server)
        for junk in ["", "abc234", "ABC23", "ABC2345", "bandal.io/r/ABC234"] {
            let entry = await invitee.enter(junk)
            XCTAssertEqual(entry, .invalid, junk)
        }
        XCTAssertEqual(server.calls, [], "What is not a code is never sent")
        let missing = await invitee.enter("XXXXXX")
        XCTAssertEqual(missing, .invalid)
        server.failure = .unavailable
        let offline = await invitee.enter("ABC234")
        XCTAssertEqual(offline, .unavailable)
        XCTAssertNil(invitee.pending); XCTAssertFalse(invitee.applied); XCTAssertNil(invitee.notice)
        XCTAssertEqual(server.calls, ["check XXXXXX", "check ABC234"], "Nothing is claimed on a guess")
    }

    func testARefusedClaimDropsTheCodeAndSaysWhyOnce() async {
        // Signed in at the field: the field says why, so there is no toast.
        let server = ReferralServiceFake(), invitee = referral(server)
        let own = await invitee.enter(ReferralServiceFake.ownCode)
        XCTAssertEqual(own, .refused(.ownCode))
        XCTAssertNil(invitee.pending); XCTAssertFalse(invitee.applied); XCTAssertNil(invitee.notice)

        // The account has used a code before.
        let first = await invitee.enter("ABC234"), second = await invitee.enter("DEF567")
        XCTAssertEqual(first, .applied); XCTAssertEqual(second, .refused(.alreadyClaimed))
        XCTAssertNil(invitee.pending); XCTAssertTrue(invitee.awaiting, "The first code is still claimed")
        // The server's order: the same code again is fine, one's own code is refused as one's own
        // whatever was claimed, and a code that does not exist is INVALID_CODE, not ALREADY_CLAIMED.
        try? await server.claim("ABC234")
        do { try await server.claim(ReferralServiceFake.ownCode); XCTFail("Own code") } catch { XCTAssertEqual(error as? ReferralError, .ownCode) }
        do { try await server.claim("XYZ234"); XCTFail("No such code") } catch { XCTAssertEqual(error as? ReferralError, .invalidCode) }

        // Signed out at the field, refused at sign-in: a toast says why.
        defaults.removePersistentDomain(forName: suite)
        let later = ReferralServiceFake(signedIn: false), waiting = referral(later)
        let entry = await waiting.enter(ReferralServiceFake.ownCode)
        XCTAssertEqual(entry, .applied, "Whose code it is shows only at the claim")
        await signIn(later, waiting)
        XCTAssertEqual(waiting.notice, .refused(.ownCode)); XCTAssertNil(waiting.pending); XCTAssertFalse(waiting.applied)
        XCTAssertEqual(later.calls, ["check " + ReferralServiceFake.ownCode, "claim " + ReferralServiceFake.ownCode, "status"])
        waiting.notice = nil
        await signIn(later, waiting)
        XCTAssertNil(waiting.notice); XCTAssertEqual(later.calls.filter { $0.hasPrefix("claim") }.count, 1, "Said once, asked once")

        // A code deleted between the check and the sign-in.
        defaults.set("XYZ234", forKey: NativeReferral.pendingKey)
        let gone = referral(later)
        XCTAssertEqual(gone.pending, "XYZ234")
        await signIn(later, gone)
        XCTAssertEqual(gone.notice, .refused(.invalidCode)); XCTAssertNil(gone.pending)
        XCTAssertNil(defaults.string(forKey: NativeReferral.pendingKey))
    }

    func testAServerThatCannotAnswerKeepsEverythingForTheNextTry() async {
        let server = ReferralServiceFake(signedIn: false), invitee = referral(server)
        _ = await invitee.enter("ABC234")
        server.failure = .unavailable
        await signIn(server, invitee)
        XCTAssertEqual(invitee.pending, "ABC234", "The claim did not go through: the code waits"); XCTAssertFalse(invitee.awaiting); XCTAssertNil(invitee.notice)
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("claim") }.count, 1, "One try per sign-in, no loop")
        // A session that expired between the check and the claim is the same: wait.
        server.failure = .signInRequired
        await signIn(server, invitee)
        XCTAssertEqual(invitee.pending, "ABC234"); XCTAssertNil(invitee.notice)
        server.failure = nil
        await signIn(server, invitee)
        XCTAssertNil(invitee.pending); XCTAssertTrue(invitee.awaiting)

        hasCourse = true; server.failure = .unavailable
        _ = await invitee.advance().value
        XCTAssertTrue(invitee.awaiting, "The reward is still owed"); XCTAssertNil(invitee.notice); XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(server.calls.filter { $0 == "complete" }.count, 1)
        server.failure = nil
        await signIn(server, invitee)
        XCTAssertEqual(invitee.notice, .rewarded(uses: 100)); XCTAssertFalse(invitee.awaiting)
    }

    func testCompleteAnsweringNoneOrAlreadyEndsQuietly() async {
        // Another account signed in on an iPad that was waiting: the server knows no claim.
        defaults.set(true, forKey: NativeReferral.awaitingKey)
        hasCourse = true
        let server = ReferralServiceFake(), invitee = referral(server)
        XCTAssertTrue(invitee.applied)
        _ = await invitee.advance().value
        XCTAssertEqual(server.calls, ["complete"]); XCTAssertFalse(invitee.applied); XCTAssertNil(invitee.notice); XCTAssertEqual(refreshes, 0)
        XCTAssertFalse(defaults.bool(forKey: NativeReferral.awaitingKey))

        // Paid from another iPad already.
        let paid = ReferralServiceFake()
        try? await paid.claim("ABC234"); _ = try? await paid.complete()
        defaults.set(true, forKey: NativeReferral.awaitingKey)
        let second = referral(paid)
        _ = await second.advance().value
        XCTAssertEqual(paid.calls.last, "complete"); XCTAssertFalse(second.applied); XCTAssertNil(second.notice); XCTAssertEqual(refreshes, 0)
    }

    func testSignedOutNothingIsClaimedOrCompleted() async {
        defaults.set("ABC234", forKey: NativeReferral.pendingKey); defaults.set(true, forKey: NativeReferral.awaitingKey)
        hasCourse = true
        let server = ReferralServiceFake(signedIn: false), invitee = referral(server)
        _ = await invitee.advance().value
        invitee.accountChanged(signedIn: false)
        _ = await invitee.work?.value
        XCTAssertEqual(server.calls, [], "Neither /claim nor /complete without an account")
        XCTAssertEqual(invitee.pending, "ABC234"); XCTAssertTrue(invitee.awaiting)

        // Without an invitation under way, a sign-in asks once what the account has open, and
        // neither claims nor completes.
        defaults.removePersistentDomain(forName: suite)
        let idle = ReferralServiceFake(), nobody = referral(idle)
        await signIn(idle, nobody)
        _ = await nobody.advance().value
        XCTAssertEqual(idle.calls, ["status"])
    }

    func testARewardTheServerCouldNotGiveIsAskedForAgainWhenTheAppReturns() async {
        // Signed in, code claimed, then the first course is made while the server cannot answer (offline, or the day's ceiling).
        let server = ReferralServiceFake(signedIn: false), invitee = referral(server)
        await signIn(server, invitee)
        _ = await invitee.enter("ABC234")
        server.failure = .unavailable; hasCourse = true
        _ = await invitee.advance().value
        XCTAssertTrue(invitee.awaiting, "Nothing was paid, so it keeps waiting"); XCTAssertNil(invitee.notice)
        let asked = server.calls.filter { $0 == "complete" }.count

        // Coming back to the app asks once more, and once the server answers the reward arrives.
        invitee.resume(); await settle(invitee)
        XCTAssertEqual(server.calls.filter { $0 == "complete" }.count, asked + 1); XCTAssertTrue(invitee.awaiting)
        server.failure = nil
        invitee.resume(); await settle(invitee)
        XCTAssertEqual(invitee.notice, .rewarded(uses: 100)); XCTAssertFalse(invitee.awaiting)

        // Settled, or signed out: returning asks nothing.
        let calls = server.calls.count
        invitee.resume(); await settle(invitee)
        XCTAssertEqual(server.calls.count, calls)
        defaults.set(true, forKey: NativeReferral.awaitingKey)
        let signedOut = ReferralServiceFake(signedIn: false), waiting = referral(signedOut)
        waiting.resume(); await settle(waiting)
        XCTAssertEqual(signedOut.calls, [])

        // Opening 친구 초대 is another try: an open claim on the server is taken up even when this iPad already knows it.
        defaults.removePersistentDomain(forName: suite)
        let again = ReferralServiceFake(signedIn: false), second = referral(again)
        await signIn(again, second)
        _ = await second.enter("ABC234")
        again.failure = .unavailable; hasCourse = true
        _ = await second.advance().value
        again.failure = nil
        _ = try? await second.loadStatus(); await settle(second)
        XCTAssertEqual(second.notice, .rewarded(uses: 100))
    }

    func testAClaimFollowsItsAccountWhenSomeoneElseUsesThisIPadInBetween() async {
        // A enters a friend's code signed in, before making a course.
        let accountA = ReferralServiceFake(signedIn: false), accountB = ReferralServiceFake(signedIn: false), invitee = referral(accountA)
        await signIn(accountA, invitee)
        let entry = await invitee.enter("ABC234")
        XCTAssertEqual(entry, .applied); XCTAssertTrue(invitee.awaiting)

        // A signs out: the waiting reward is A's, so it leaves this iPad.
        invitee.accountChanged(signedIn: false)
        XCTAssertFalse(invitee.awaiting); XCTAssertFalse(invitee.applied)

        // B signs in here and makes the first course: B has no claim, so nothing is completed.
        invitee.service = accountB; hasCourse = true
        await signIn(accountB, invitee)
        _ = await invitee.advance().value
        XCTAssertEqual(accountB.calls, ["status"]); XCTAssertNil(invitee.notice)

        // A comes back: the claim is found on the server and, with a course here, paid.
        invitee.accountChanged(signedIn: false)
        invitee.service = accountA
        await signIn(accountA, invitee)
        XCTAssertEqual(invitee.notice, .rewarded(uses: 100))
        XCTAssertEqual(accountA.calls.filter { $0 == "complete" }.count, 1); XCTAssertFalse(invitee.awaiting)
    }

    func testAStoredCodeThatIsNotACodeIsIgnoredAndEditingTheFieldWithdrawsOnlyAWaitingCode() async {
        defaults.set("not a code", forKey: NativeReferral.pendingKey)
        XCTAssertNil(referral(ReferralServiceFake()).pending)

        let server = ReferralServiceFake(signedIn: false), invitee = referral(server)
        _ = await invitee.enter("ABC234")
        invitee.withdraw()
        XCTAssertNil(invitee.pending); XCTAssertFalse(invitee.applied); XCTAssertNil(defaults.string(forKey: NativeReferral.pendingKey))
        await signIn(server, invitee)
        XCTAssertEqual(server.calls, ["check ABC234", "status"], "A withdrawn code is never claimed")

        _ = await invitee.enter("ABC234")
        invitee.withdraw()
        XCTAssertTrue(invitee.awaiting, "A claimed code stays claimed")
    }

    func testStatusIsAskedOnlySignedInAndAClaimMadeElsewhereIsTakenUpHere() async throws {
        let server = ReferralServiceFake(signedIn: false), inviter = referral(server)
        let signedOut = try await inviter.loadStatus()
        XCTAssertFalse(signedOut); XCTAssertNil(inviter.status); XCTAssertEqual(server.calls, [], "Nothing is asked signed out")

        await signIn(server, inviter)
        let loaded = try await inviter.loadStatus()
        XCTAssertTrue(loaded)
        XCTAssertEqual(inviter.status, ReferralStatus(code: ReferralServiceFake.ownCode, completed: 3, limit: 5, creditMicrocents: 21_000_000, claim: nil))
        XCTAssertFalse(inviter.applied, "No claim, nothing to wait for")
        server.failure = .unavailable
        do { _ = try await inviter.loadStatus(); XCTFail("The view shows a retry") } catch { XCTAssertEqual(error as? ReferralError, .unavailable) }
        server.failure = .signInRequired
        let expired = try await inviter.loadStatus()
        XCTAssertFalse(expired); XCTAssertNil(inviter.status, "An expired session is signed out")
        server.failure = nil

        // The account claimed a code on another iPad (or before a reinstall) and has no course yet.
        try await server.claim("ABC234")
        _ = try await inviter.loadStatus()
        XCTAssertEqual(inviter.status?.claim, .init(completed: false)); XCTAssertTrue(inviter.awaiting); XCTAssertTrue(inviter.applied)
        _ = await inviter.work?.value
        XCTAssertFalse(server.calls.contains("complete"), "Still no course")
        hasCourse = true
        _ = await inviter.advance().value
        XCTAssertEqual(inviter.notice, .rewarded(uses: 100)); XCTAssertFalse(inviter.awaiting)
        XCTAssertEqual(inviter.status?.claim, .init(completed: true), "What is on screen follows the reward")
        XCTAssertEqual(Referral.uses(try XCTUnwrap(inviter.status).creditMicrocents), 400)
        _ = try await inviter.loadStatus()
        _ = await inviter.work?.value
        XCTAssertFalse(inviter.awaiting, "A paid claim is not taken up again")
        XCTAssertEqual(server.calls.filter { $0 == "complete" }.count, 1)

        inviter.accountChanged(signedIn: false)
        XCTAssertNil(inviter.status, "Signed out: the previous account's numbers leave the screen")

        // The account changes while the server answers: the answer is someone else's and is dropped.
        await signIn(server, inviter)
        server.during = { call in if call == "status" { inviter.accountChanged(signedIn: false) } }
        do { _ = try await inviter.loadStatus(); XCTFail("A stale answer is no answer") } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertNil(inviter.status)
    }

    func testTheAccountServiceRepeatingItsStateIsNotANewSignIn() async {
        let server = ReferralServiceFake(signedIn: false), invitee = referral(server)
        _ = await invitee.enter("ABC234")
        server.signedIn = true; server.failure = .unavailable
        // A restored session, then its profile, then a new nickname: the same "signed in" three times.
        for _ in 0..<3 { invitee.accountChanged(signedIn: true); _ = await invitee.work?.value }
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("claim") }.count, 1, "One try per sign-in")
        XCTAssertTrue(invitee.signedIn); XCTAssertEqual(invitee.pending, "ABC234")
        invitee.accountChanged(signedIn: false)
        XCTAssertFalse(invitee.signedIn)
        _ = await invitee.work?.value
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("claim") }.count, 1, "Signing out asks nothing")
    }

    func testACodeTypedWhileAnotherIsBeingClaimedGetsItsOwnAnswer() async {
        // The first claim is on its way when the field is edited and a second code goes in.
        let server = ReferralServiceFake(), invitee = referral(server)
        var second: Task<NativeReferral.Entry, Never>?
        server.during = { call in
            guard call == "claim ABC234", second == nil else { return }
            invitee.withdraw()
            second = Task { await invitee.enter("DEF567") }
            await Task.yield() // the second code is checked and waiting before the first claim answers
        }
        let first = await invitee.enter("ABC234")
        let later = await second?.value
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234", "check DEF567", "claim DEF567"], "The second code is asked about, not dropped")
        XCTAssertEqual(later, .refused(.alreadyClaimed), "The server took the first one")
        XCTAssertEqual(first, .applied)
        XCTAssertTrue(invitee.awaiting); XCTAssertNil(invitee.pending)

        // Withdrawn while its claim was on its way, and the server took it: it is claimed all the same.
        defaults.removePersistentDomain(forName: suite)
        let other = ReferralServiceFake(), hasty = referral(other)
        other.during = { call in if call == "claim ABC234" { hasty.withdraw() } }
        _ = await hasty.enter("ABC234")
        XCTAssertTrue(hasty.awaiting); XCTAssertNil(hasty.pending)
    }

    func testARefusalAnnouncedByAnEarlierStepIsNotThenShownAsApplied() async {
        // The code was waiting; the sign-in's own step and the field's step are queued together.
        defaults.set(ReferralServiceFake.ownCode, forKey: NativeReferral.pendingKey)
        let server = ReferralServiceFake(), invitee = referral(server)
        invitee.accountChanged(signedIn: true)
        let entry = await invitee.enter(ReferralServiceFake.ownCode)
        XCTAssertEqual(invitee.notice, .refused(.ownCode), "Said once, by the step that got the answer")
        XCTAssertEqual(entry, .idle, "The field does not then say it was applied")
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("claim") }.count, 1)
        XCTAssertFalse(invitee.applied)
    }

    func testAnInviteLinkHandsItsCodeToTheField() throws {
        let invitee = referral(ReferralServiceFake(signedIn: false))
        invitee.open(try XCTUnwrap(URL(string: "https://bandal.io/r/abc")))
        invitee.open(try XCTUnwrap(URL(string: "https://example.com/r/ABC234")))
        XCTAssertNil(invitee.linkedCode, "A malformed link does nothing")
        invitee.open(try XCTUnwrap(URL(string: "https://bandal.io/r/abc234")))
        XCTAssertEqual(invitee.linkedCode, "ABC234")
        XCTAssertNil(invitee.pending, "Nothing is kept until the field has checked it")
    }

    // MARK: The store

    func testTheFirstCourseOnTheStoreSettlesAWaitingInvitation() async throws {
        // The store's invitation lives in the app's own defaults.
        let keys = [NativeReferral.pendingKey, NativeReferral.awaitingKey]
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        defer { keys.forEach(UserDefaults.standard.removeObject(forKey:)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("referral-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeWorkspaceStore(storageRoot: root)
        await store.start()
        XCTAssertTrue(store.isReady, store.errorMessage ?? "The store did not start")
        let server = ReferralServiceFake()
        store.referral.service = server

        let entry = await store.referral.enter("ABC234")
        XCTAssertEqual(entry, .applied)
        XCTAssertFalse(store.hasCourse); XCTAssertTrue(store.referral.awaiting)
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234"], "No course yet")

        try await store.createCourse(name: "물리")
        _ = await store.referral.work?.value
        XCTAssertTrue(store.hasCourse)
        XCTAssertEqual(server.calls, ["check ABC234", "claim ABC234", "complete"], "Right after the first course")
        XCTAssertEqual(store.referral.notice, .rewarded(uses: 100)); XCTAssertFalse(store.referral.applied)

        try await store.createCourse(name: "화학")
        _ = await store.referral.work?.value
        XCTAssertEqual(server.calls.count, 3, "Only the first course asks")
    }
}
