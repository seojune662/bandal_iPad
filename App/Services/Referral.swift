import Foundation

/// Friend invitations (`functions/v1/referral`): what a code looks like, what a link carries and
/// what the server's credit is worth in "AI N회".
enum Referral {
    /// Six characters from this set; I, L, O, 0 and 1 are left out because they read alike.
    static let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789", length = 6
    /// The server's credit (µ¢) behind one "AI 1회": the reward of 7,000,000 reads "AI 100회".
    static let microcentsPerUse: Int64 = 70_000
    static func uses(_ microcents: Int64) -> Int { Int(max(0, microcents) / microcentsPerUse) }

    static func isCode(_ text: String) -> Bool { text.count == length && text.allSatisfy(alphabet.contains) }
    /// What the code field keeps of typed or pasted text: whatever follows the last "/" (a pasted
    /// invite link), in capitals, without anything outside the alphabet, cut to six characters.
    /// Only ASCII is capitalised: "ß" must not turn into "SS".
    static func normalize(_ text: String) -> String {
        String((text.split(separator: "/").last ?? "").filter(\.isASCII).uppercased().filter(alphabet.contains).prefix(length))
    }

    static func link(_ code: String) -> String { "https://bandal.io/r/" + code }
    /// The code of an invite link, https://bandal.io/r/CODE in either case. Nil for any other
    /// address and for a code that is not one: such a link only opens the app.
    static func code(link url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "bandal.io", parts.count == 2, parts[0] == "r", parts[1].count == length else { return nil }
        let code = parts[1].uppercased()
        return isCode(code) ? code : nil
    }
    #if DEBUG
    /// `-native.referral.link <address>` at launch stands in for opening that invite link (UI tests).
    static var fixtureLink: URL? { UserDefaults.standard.string(forKey: "native.referral.link").flatMap(URL.init) }
    #endif

    // Server numbers are not trusted either: they stay inside what the UI can sensibly show.
    static let maxReplyBytes = 16 * 1024
    static func count(_ value: Int) -> Int { min(max(0, value), 999) }
    static func credit(_ value: Int64) -> Int64 { min(max(0, value), 1_000 * 7_000_000) }
}

/// `/status`: the signed-in account's own code and what its invitations have brought so far.
struct ReferralStatus: Decodable, Equatable {
    /// The account has used someone's code; `completed` once its reward was paid.
    struct Claim: Decodable, Equatable { var completed: Bool }
    var code: String
    /// Friends who completed their invitation. It can pass `limit`; only `limit` of them are rewarded.
    var completed: Int
    var limit: Int
    /// The N of "초대 N / 5".
    var counted: Int { min(completed, limit) }
    /// The invite credit this account has received in total (µ¢), not what is left of it.
    var creditMicrocents: Int64
    var claim: Claim?
}

// Server data is not trusted: the code goes into a link and onto the pasteboard, so it has to be
// one; the numbers are whole and bounded; a claim that cannot be read is no claim.
extension ReferralStatus {
    private enum CodingKeys: String, CodingKey { case code, completed, limit, creditMicrocents, claim }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(String.self, forKey: .code)
        guard Referral.isCode(code) else { throw DecodingError.dataCorruptedError(forKey: .code, in: values, debugDescription: "Not an invite code") }
        completed = Referral.count(try values.decode(Int.self, forKey: .completed))
        limit = Referral.count(try values.decode(Int.self, forKey: .limit))
        creditMicrocents = Referral.credit(try values.decode(Int64.self, forKey: .creditMicrocents))
        claim = try? values.decodeIfPresent(Claim.self, forKey: .claim)
    }
}

/// `/complete`: what became of the invitee's reward.
enum ReferralCompletion: Equatable {
    /// Paid just now: the credit this account received (µ¢).
    case rewarded(creditMicrocents: Int64)
    /// No invitation waits on this account.
    case none
    /// It was paid before.
    case already
}

enum ReferralError: Error, Equatable {
    /// 401 `SIGN_IN_REQUIRED`, or nobody is signed in.
    case signInRequired
    /// 404 `INVALID_CODE`: no such code.
    case invalidCode
    /// 409 `OWN_CODE`: the account's own code.
    case ownCode
    /// 409 `ALREADY_CLAIMED`: the account has used another code.
    case alreadyClaimed
    /// No connection, a server fault or a reply that cannot be read.
    case unavailable
}

/// The server's invitations. Views reach it through `NativeWorkspaceStore.referral`, so tests and
/// UI tests swap in `ReferralServiceFake`.
@MainActor
protocol ReferralService {
    /// Whether `claim`, `complete` and `status` can run now.
    func isSignedIn() async -> Bool
    /// Whether the code exists. Needs no account, and promises nothing about claiming it.
    func check(_ code: String) async throws -> Bool
    /// Binds the code to the signed-in account. Claiming the same code again is fine.
    func claim(_ code: String) async throws
    /// Asks for the reward of the account's claimed code; the app calls it once a course exists.
    func complete() async throws -> ReferralCompletion
    func status() async throws -> ReferralStatus
}

/// Invitations on the Bandal Supabase project. `check` sends only the publishable key; the rest go
/// as the signed-in user, through the endpoint the ai-proxy uses.
struct LiveReferralService: ReferralService {
    var configuration: () -> (url: String, key: String) = {
        (UserDefaults.standard.string(forKey: "sync.url") ?? "", UserDefaults.standard.string(forKey: "sync.publishableKey") ?? "")
    }
    var endpoint: () async throws -> AIEndpoint = { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
    /// The app passes the ai-proxy's session, which refuses redirects: the user's token must not follow one.
    var send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private struct Check: Decodable { let valid: Bool }
    private struct Outcome: Decodable { let status: String }
    private struct Reward: Decodable { let creditMicrocents: Int64 }

    func isSignedIn() async -> Bool { (try? await endpoint()) != nil }

    func check(_ code: String) async throws -> Bool {
        // What is not a code is never sent: there is no such code.
        guard Referral.isCode(code) else { return false }
        let value = configuration()
        guard let project = URL(string: value.url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))), project.scheme == "https", project.host != nil, !value.key.isEmpty,
              var components = URLComponents(url: Self.url(project, "check"), resolvingAgainstBaseURL: false) else { throw ReferralError.unavailable }
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = components.url else { throw ReferralError.unavailable }
        var request = URLRequest(url: url)
        request.setValue(value.key, forHTTPHeaderField: "apikey")
        return try Self.decode(Check.self, try await perform(request)).valid
    }

    func claim(_ code: String) async throws {
        guard Referral.isCode(code) else { throw ReferralError.invalidCode }
        guard try Self.decode(Outcome.self, try await signedIn("claim", body: ["code": code])).status == "claimed" else { throw ReferralError.unavailable }
    }

    func complete() async throws -> ReferralCompletion {
        let reply = try await signedIn("complete", body: [:])
        switch try Self.decode(Outcome.self, reply).status {
        case "rewarded":
            // The toast says how much came in, so a reward without an amount is not a readable reply.
            let credit = Referral.credit(try Self.decode(Reward.self, reply).creditMicrocents)
            guard credit > 0 else { throw ReferralError.unavailable }
            return .rewarded(creditMicrocents: credit)
        case "none": return .none
        case "already": return .already
        default: throw ReferralError.unavailable
        }
    }

    func status() async throws -> ReferralStatus { try Self.decode(ReferralStatus.self, try await signedIn("status")) }

    private static func url(_ project: URL, _ path: String) -> URL {
        project.appendingPathComponent("functions/v1/referral").appendingPathComponent(path)
    }
    private static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw ReferralError.unavailable }
    }
    /// A request as the signed-in user: a POST when there is a body, a GET otherwise.
    private func signedIn(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        let endpoint: AIEndpoint
        do { endpoint = try await self.endpoint() }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReferralError.signInRequired }
        guard endpoint.projectURL.scheme == "https" else { throw ReferralError.unavailable }
        var request = URLRequest(url: Self.url(endpoint.projectURL, path))
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do { try await endpoint.authorize(&request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ReferralError.signInRequired }
        return try await perform(request)
    }
    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 10; request.httpShouldHandleCookies = false
        let data: Data, response: URLResponse
        do { (data, response) = try await send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw ReferralError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= Referral.maxReplyBytes else { throw ReferralError.unavailable }
        if (200..<300).contains(http.statusCode) { return data }
        // Only the server's own `code` refuses an invite code: a bare 404 is a function that is not
        // there, and must not throw away a code that is waiting.
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch info["code"] as? String ?? (http.statusCode == 401 ? "SIGN_IN_REQUIRED" : "") {
        case "SIGN_IN_REQUIRED": throw ReferralError.signInRequired
        case "INVALID_CODE": throw ReferralError.invalidCode
        case "OWN_CODE": throw ReferralError.ownCode
        case "ALREADY_CLAIMED": throw ReferralError.alreadyClaimed
        default: throw ReferralError.unavailable
        }
    }
}

#if DEBUG
/// The invitation server in memory, with the contract's rules: a code that starts with X does not
/// exist, `ownCode` is this account's own, and an account claims one code. `--native-referral-fixture`
/// puts it behind the app for UI tests and screenshots, signed in unless `--native-referral-signed-out`
/// is there too. Unit tests read `calls` and set `failure`.
@MainActor
final class ReferralServiceFake: ReferralService {
    static let argument = "--native-referral-fixture", signedOutArgument = "--native-referral-signed-out"
    static let ownCode = "BANDA2"
    var signedIn: Bool
    /// Every call throws this instead of answering.
    var failure: ReferralError?
    /// Runs while the server is answering a call (tests change something meanwhile).
    var during: ((String) async -> Void)?
    private(set) var calls: [String] = []
    private(set) var claimed: String?
    private(set) var rewarded = false

    init(signedIn: Bool = true) { self.signedIn = signedIn }

    func isSignedIn() async -> Bool { signedIn }
    func check(_ code: String) async throws -> Bool {
        try await ask("check " + code, account: false)
        return !code.hasPrefix("X")
    }
    func claim(_ code: String) async throws {
        try await ask("claim " + code)
        // In the server's order: one's own code, the code already claimed, no such code, another claim.
        if code == Self.ownCode { throw ReferralError.ownCode }
        if code == claimed { return }
        if !Referral.isCode(code) || code.hasPrefix("X") { throw ReferralError.invalidCode }
        if claimed != nil { throw ReferralError.alreadyClaimed }
        claimed = code
    }
    func complete() async throws -> ReferralCompletion {
        try await ask("complete")
        guard claimed != nil else { return .none }
        if rewarded { return .already }
        rewarded = true
        return .rewarded(creditMicrocents: 7_000_000)
    }
    func status() async throws -> ReferralStatus {
        try await ask("status")
        return ReferralStatus(code: Self.ownCode, completed: 3, limit: 5, creditMicrocents: rewarded ? 28_000_000 : 21_000_000,
                              claim: claimed.map { _ in .init(completed: rewarded) })
    }
    private func ask(_ call: String, account: Bool = true) async throws {
        calls.append(call)
        await during?(call)
        if let failure { throw failure }
        if account, !signedIn { throw ReferralError.signInRequired }
    }
}
#endif
