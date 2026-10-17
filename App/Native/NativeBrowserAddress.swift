import Foundation

struct NativeBrowserLink: Identifiable, Equatable {
    var id: String { url }
    let title: String
    let url: String
}

struct NativeBrowserSuggestion: Identifiable, Equatable {
    enum Kind: String { case address, search, tab, favorite, history }
    var id: String { url }
    let kind: Kind
    let title: String
    let url: String
    var source: String {
        switch kind { case .address: "이동"; case .search: "검색"; case .tab: "열린 탭"; case .favorite: "즐겨찾기"; case .history: "방문 기록" }
    }
    var symbol: String {
        switch kind { case .address: "arrow.up.right"; case .search: "magnifyingglass"; case .tab: "square.on.square"; case .favorite: "star"; case .history: "clock" }
    }
}

/// Desktop urlInput/browserSearch rules, with credentials and non-web schemes
/// rejected before the value is used for either navigation or a suggestion.
enum NativeBrowserAddress {
    static func isWebAddress(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        let explicit = value.lowercased().hasPrefix("https://") || value.lowercased().hasPrefix("http://")
        guard let url = URLComponents(string: explicit ? value : "https://" + value), let host = url.host, !host.isEmpty else { return false }
        return explicit || host.contains(".") || host == "localhost" || host.contains(":")
    }
    static func resolve(_ text: String, engine: String = "google") throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DesktopRuntimeError("주소나 검색어를 입력하세요.") }
        if value == "about:blank" { return URL(string: value)! }
        if value.contains("://"), !["http", "https"].contains(URLComponents(string: value)?.scheme?.lowercased() ?? "") {
            throw DesktopRuntimeError("http 또는 https 웹 주소를 입력하세요.")
        }
        let candidate = value.contains("://") ? value : "https://" + value
        if let components = URLComponents(string: candidate), components.user != nil || components.password != nil {
            throw DesktopRuntimeError("사용자 이름과 비밀번호가 포함된 주소는 열 수 없습니다. 사이트의 로그인 화면을 이용하세요.")
        }
        if isWebAddress(value), let url = URL(string: candidate), url.host != nil { return url }
        let search: (String, String)
        switch engine {
        case "naver": search = ("https://search.naver.com/search.naver", "query")
        case "daum": search = ("https://search.daum.net/search", "q")
        case "duckduckgo": search = ("https://duckduckgo.com/", "q")
        default: search = ("https://www.google.com/search", "q")
        }
        var components = URLComponents(string: search.0)!
        components.queryItems = [URLQueryItem(name: search.1, value: value)]
        return components.url!
    }
    static func display(_ value: String) -> String {
        guard let url = URLComponents(string: value), let host = url.host else { return value == "about:blank" ? "" : value }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return (url.scheme == "https" ? "" : (url.scheme ?? "http") + "://") + name + (url.port.map { ":\($0)" } ?? "")
    }
    static func title(_ title: String, url: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = display(url)
        if trimmed.isEmpty { return host }
        let generic = Set(["home", "homepage", "dashboard", "login", "signin", "account", "welcome", "index", "마이페이지", "홈", "홈페이지", "메인", "로그인", "계정"])
        return generic.contains(trimmed.lowercased().replacingOccurrences(of: " ", with: "")) ? host + " · " + trimmed : trimmed
    }
    static func suggestions(_ input: String, engine: String, tabs: [NativeBrowserLink], favorites: [NativeBrowserLink], services: [NativeBrowserLink], history: [NativeBrowserLink]) -> [NativeBrowserSuggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).prefix(8).map(String.init)
        var result: [NativeBrowserSuggestion] = []
        if !query.isEmpty, let url = try? resolve(query, engine: engine), url.scheme != "about" {
            result.append(.init(kind: isWebAddress(query) ? .address : .search, title: query, url: url.absoluteString))
        }
        let candidates = tabs.map { (NativeBrowserSuggestion.Kind.tab, $0) }
            + (favorites + services).map { (NativeBrowserSuggestion.Kind.favorite, $0) }
            + history.map { (NativeBrowserSuggestion.Kind.history, $0) }
        let ranked = candidates.enumerated().compactMap { index, item -> (Int, Int, NativeBrowserSuggestion)? in
            guard let components = URLComponents(string: item.1.url), ["http", "https"].contains(components.scheme ?? ""), components.host != nil, components.user == nil, components.password == nil else { return nil }
            let label = normalized(item.1.title), address = normalized(item.1.url)
            guard terms.allSatisfy({ (label + " " + address).contains($0) }) else { return nil }
            let joined = terms.joined(separator: " "), host = normalized(display(item.1.url))
            let rank = terms.isEmpty || host.hasPrefix(joined) ? 0 : label.hasPrefix(joined) ? 1 : 2
            return (rank, index, .init(kind: item.0, title: title(item.1.title, url: item.1.url), url: item.1.url))
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var seen = Set(result.map { canonical($0.url) })
        for (_, _, item) in ranked where seen.insert(canonical(item.url)).inserted {
            result.append(item)
            if result.count >= 8 { break }
        }
        return result
    }
    static func canonical(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.scheme = components.scheme?.lowercased(); components.host = components.host?.lowercased()
        if components.path.isEmpty { components.path = "/" }
        return components.string ?? value
    }
    private static func normalized(_ value: String) -> String { (value.removingPercentEncoding ?? value).precomposedStringWithCanonicalMapping.lowercased() }
}

struct NativeBrowserSuggestionSelection: Equatable {
    private(set) var url: String?
    func index(in values: [NativeBrowserSuggestion]) -> Int {
        guard let url else { return 0 }
        return values.firstIndex { NativeBrowserAddress.canonical($0.url) == NativeBrowserAddress.canonical(url) } ?? 0
    }
    mutating func move(_ offset: Int, in values: [NativeBrowserSuggestion]) {
        guard !values.isEmpty else { url = nil; return }
        url = values[(index(in: values) + offset + values.count) % values.count].url
    }
}

struct NativeBrowserFindState: Equatable {
    var visible = false
    var focusRevision = 0
    var query = ""
    var searchedQuery: String?
    var count: Int?
    var ordinal = 0
}

struct NativeBrowserDownloadItem: Identifiable {
    let id: String, fileName: String, state: String, profileID: String
    let tabID: String?
    let isPrivate: Bool, paused: Bool, recoverable: Bool
    let received: Int64, total: Int64
    let courseID: String?, relativePath: String?, error: String?
    init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String else { return nil }
        self.id = id; fileName = value["fileName"] as? String ?? "다운로드"; state = value["state"] as? String ?? "interrupted"
        profileID = value["profileId"] as? String ?? "default"; tabID = value["tabId"] as? String
        isPrivate = value["isPrivate"] as? Bool ?? false; paused = value["paused"] as? Bool ?? false; recoverable = value["recoverable"] as? Bool ?? false
        received = (value["receivedBytes"] as? NSNumber)?.int64Value ?? 0; total = (value["totalBytes"] as? NSNumber)?.int64Value ?? 0
        courseID = value["courseId"] as? String; relativePath = value["relPath"] as? String; error = value["failureReason"] as? String
    }
    var retryTitle: String? {
        if state == "completed" { return recoverable ? "과목에 저장" : nil }
        return ["interrupted", "cancelled"].contains(state) ? "다시 받기" : nil
    }
    var status: String { paused ? "일시 정지" : state == "completed" ? "완료" : state == "cancelled" ? "취소됨" : state == "interrupted" ? "중단됨" : "내려받는 중" }
}
