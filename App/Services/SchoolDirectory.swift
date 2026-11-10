import Foundation

/// A school in the Bandal directory (`functions/v1/schools`): bundled, found by AI or entered by a user.
struct School: Codable, Equatable, Identifiable {
    struct Link: Codable, Equatable, Identifiable {
        static let kinds = ["home", "portal", "lms", "library", "calendar", "mail", "registration", "other"]
        var id: String
        var kind: String
        var title: String
        var url: String
        var verified: Bool
        var order: Int
    }
    var id: String
    var name: String
    var nameEn: String?
    var aliases: [String]
    var country: String
    var domain: String?
    var verified: Bool
    /// "bundled", "ai" or "user".
    var source: String
    var links: [Link]
}

/// One unreadable item is dropped instead of failing the list it is in.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// Server data is not trusted: ids and names must be there and ids are unique, unknown kinds become
// "other", and only http(s) addresses get in because a link opens in the browser. Text is shown in
// the UI and saved in settings, so it loses control and direction characters and has a length.
extension School {
    static let maxLinks = 20, maxListed = 50, maxReplyBytes = 256 * 1024
    static func clean(_ text: String, max: Int) -> String {
        let kept = text.unicodeScalars.filter { ![.control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned].contains($0.properties.generalCategory) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }
}

extension School.Link {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = School.clean(try values.decode(String.self, forKey: .title), max: 60)
        url = try values.decode(String.self, forKey: .url)
        guard !title.isEmpty, id.count <= 128 else { throw DecodingError.dataCorruptedError(forKey: .title, in: values, debugDescription: "A link needs a title and a short id") }
        let kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "other"
        self.kind = Self.kinds.contains(kind) ? kind : "other"
        verified = try values.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
}

extension School {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = Self.clean(try values.decode(String.self, forKey: .name), max: 80)
        guard !id.isEmpty, id.count <= 128, !name.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .name, in: values, debugDescription: "A school needs a short id and a name") }
        nameEn = try values.decodeIfPresent(String.self, forKey: .nameEn).map { Self.clean($0, max: 120) }
        aliases = (try values.decodeIfPresent([String].self, forKey: .aliases) ?? []).prefix(20).map { Self.clean($0, max: 80) }.filter { !$0.isEmpty }
        country = Self.clean(try values.decodeIfPresent(String.self, forKey: .country) ?? "", max: 2)
        domain = try values.decodeIfPresent(String.self, forKey: .domain).map { Self.clean($0, max: 253) }
        verified = try values.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? "ai"
        var seen = Set<String>()
        links = (try values.decodeIfPresent([Lenient<Link>].self, forKey: .links) ?? []).compactMap(\.value)
            .filter { !$0.id.isEmpty && NativeSettingsSchema.webURL($0.url) && seen.insert($0.id).inserted }.sorted { $0.order < $1.order }.prefix(Self.maxLinks).map { $0 }
    }
}

extension School {
    /// Nobody has reviewed it (an AI finding): the picker says so wherever it shows the school,
    /// and its links are confirmed before they are saved.
    var unreviewed: Bool { !verified }
    /// The second line of a search result: the English name or the domain, then `mark` for an unreviewed AI school.
    func detail(mark: String) -> String? {
        let base = [nameEn, domain].compactMap { $0 }.first { !$0.isEmpty }
        return unreviewed ? [base, mark].compactMap { $0 }.joined(separator: " · ") : base
    }
}

enum SchoolDirectoryError: Error, Equatable {
    /// 401 `SIGN_IN_REQUIRED`, or nobody is signed in.
    case signInRequired
    /// 429 `RATE_LIMITED`: the account used its AI searches.
    case rateLimited(limit: Int)
    /// 503 `AI_UNAVAILABLE`, no connection, or a reply that cannot be read.
    case unavailable
}

/// The server's school search and AI setup. Views reach it through `NativeWorkspaceStore.schools`,
/// so tests and UI tests swap in `SchoolDirectoryFake`.
@MainActor
protocol SchoolDirectory {
    /// Whether `setup` and `suggest` can run now.
    func isSignedIn() async -> Bool
    func search(_ query: String, country: String) async throws -> [School]
    /// Finds the school's sites with AI. Nil: the server found no such school.
    func setup(query: String, country: String, locale: String) async throws -> School?
    /// Offers the user's edited links for review.
    func suggest(schoolID: String, links: [School.Link]) async throws
}

/// The directory on the Bandal Supabase project. Search sends only the publishable key; AI setup
/// and suggestions go as the signed-in user, through the endpoint the ai-proxy uses.
struct LiveSchoolDirectory: SchoolDirectory {
    var configuration: () -> (url: String, key: String) = {
        (UserDefaults.standard.string(forKey: "sync.url") ?? "", UserDefaults.standard.string(forKey: "sync.publishableKey") ?? "")
    }
    var endpoint: () async throws -> AIEndpoint = { throw AIError.server(code: "SIGN_IN_REQUIRED", info: [:]) }
    /// The app passes the ai-proxy's session, which refuses redirects: the user's token must not follow one.
    var send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    private struct Schools: Decodable { let schools: [Lenient<School>] }
    private struct Setup: Decodable { let status: String; let school: School? }

    func isSignedIn() async -> Bool { (try? await endpoint()) != nil }

    func search(_ query: String, country: String) async throws -> [School] {
        let value = configuration()
        guard let project = URL(string: value.url.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))), project.scheme == "https", project.host != nil, !value.key.isEmpty,
              var components = URLComponents(url: Self.url(project, "search"), resolvingAgainstBaseURL: false) else { throw SchoolDirectoryError.unavailable }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "country", value: country)]
        // URLComponents leaves "+" alone, and a server reads it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw SchoolDirectoryError.unavailable }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.httpShouldHandleCookies = false
        request.setValue(value.key, forHTTPHeaderField: "apikey")
        var seen = Set<String>()
        return Array(try Self.decode(Schools.self, try await perform(request)).schools.compactMap(\.value).filter { seen.insert($0.id).inserted }.prefix(School.maxListed))
    }

    func setup(query: String, country: String, locale: String) async throws -> School? {
        // The server searches the web and asks a model: far slower than a lookup.
        let reply = try Self.decode(Setup.self, try await post("setup", ["query": query, "country": country, "locale": locale], timeout: 90))
        switch reply.status {
        case "found", "cached":
            guard let school = reply.school else { throw SchoolDirectoryError.unavailable }
            return school
        case "not_found": return nil
        default: throw SchoolDirectoryError.unavailable
        }
    }

    func suggest(schoolID: String, links: [School.Link]) async throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(links))
        _ = try await post("suggest", ["schoolId": schoolID, "links": encoded], timeout: 20)
    }

    private static func url(_ project: URL, _ path: String) -> URL {
        project.appendingPathComponent("functions/v1/schools").appendingPathComponent(path)
    }
    private static func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw SchoolDirectoryError.unavailable }
    }
    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> Data {
        let endpoint: AIEndpoint
        do { endpoint = try await self.endpoint() }
        catch is CancellationError { throw CancellationError() }
        catch { throw SchoolDirectoryError.signInRequired }
        guard endpoint.projectURL.scheme == "https" else { throw SchoolDirectoryError.unavailable }
        var request = URLRequest(url: Self.url(endpoint.projectURL, path)); request.httpMethod = "POST"; request.timeoutInterval = timeout
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { try await endpoint.authorize(&request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw SchoolDirectoryError.signInRequired }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw SchoolDirectoryError.unavailable }
        guard let http = response as? HTTPURLResponse, data.count <= School.maxReplyBytes else { throw SchoolDirectoryError.unavailable }
        if (200..<300).contains(http.statusCode) { return data }
        let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch info["code"] as? String ?? (http.statusCode == 401 ? "SIGN_IN_REQUIRED" : http.statusCode == 429 ? "RATE_LIMITED" : "") {
        case "SIGN_IN_REQUIRED": throw SchoolDirectoryError.signInRequired
        case "RATE_LIMITED": throw SchoolDirectoryError.rateLimited(limit: info["limit"] as? Int ?? 3)
        default: throw SchoolDirectoryError.unavailable
        }
    }
}

extension NativeUniversityCatalog {
    /// The schools shipped in universities.json (all Korean): the first suggestions and the offline fallback.
    static let schools: [School] = universities.compactMap { item in
        guard let id = item["id"] as? String, let name = item["nameKo"] as? String else { return nil }
        let links = (item["services"] as? [[String: Any]] ?? []).enumerated().compactMap { index, service -> School.Link? in
            guard let id = service["id"] as? String, let url = service["url"] as? String else { return nil }
            let kind = service["kind"] as? String ?? "other"
            return School.Link(id: id, kind: kind == "homepage" ? "home" : School.Link.kinds.contains(kind) ? kind : "other", title: service["label"] as? String ?? url,
                               url: url, verified: service["verification"] as? String == "verified", order: index)
        }
        return School(id: id, name: name, nameEn: item["nameEn"] as? String, aliases: item["aliases"] as? [String] ?? [], country: "KR",
                      domain: item["domain"] as? String, verified: true, source: "bundled", links: links)
    }
    /// Name, English name, aliases or domain contain `query`; an empty query lists the country's schools.
    static func matching(_ query: String, country: String, in schools: [School] = schools) -> [School] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return schools.filter { school in
            school.country == country && (query.isEmpty || ([school.name, school.nameEn ?? "", school.domain ?? ""] + school.aliases).contains { $0.localizedStandardContains(query) })
        }
    }
}

#if DEBUG
/// A directory with no server behind it. Unit tests set the closures; UI tests and screenshots get
/// the defaults with `--native-school-fixture`: signed in, the bundled list, and an AI search that
/// finds four unverified sites for any name, nothing for one containing "없는", and takes
/// 40 s over one containing "느린".
struct SchoolDirectoryFake: SchoolDirectory {
    static let argument = "--native-school-fixture"
    var signedIn: () async -> Bool = { true }
    var onSearch: (String, String) async throws -> [School] = { query, country in NativeUniversityCatalog.matching(query, country: country) }
    var onSetup: (String, String, String) async throws -> School? = { query, country, _ in
        try await Task.sleep(for: .seconds(query.contains("느린") ? 40 : 1))
        if query.contains("없는") { return nil }
        let sites = [("home", "홈페이지", "https://www.bandal.example"), ("portal", "포털", "https://portal.bandal.example"),
                     ("lms", "강의실", "https://lms.bandal.example"), ("library", "도서관", "https://library.bandal.example")]
        return School(id: "fixture-school", name: query, nameEn: nil, aliases: [], country: country, domain: "bandal.example", verified: false, source: "ai",
                      links: sites.enumerated().map { index, site in School.Link(id: site.0, kind: site.0, title: site.1, url: site.2, verified: false, order: index) })
    }
    var onSuggest: (String, [School.Link]) async throws -> Void = { _, _ in }

    func isSignedIn() async -> Bool { await signedIn() }
    func search(_ query: String, country: String) async throws -> [School] { try await onSearch(query, country) }
    func setup(query: String, country: String, locale: String) async throws -> School? { try await onSetup(query, country, locale) }
    func suggest(schoolID: String, links: [School.Link]) async throws { try await onSuggest(schoolID, links) }
}
#endif
