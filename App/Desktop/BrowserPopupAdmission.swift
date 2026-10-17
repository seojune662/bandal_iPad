import Foundation

/// Same concurrent/burst limits as the desktop browser. Closing an opener does
/// not release children that are still visible in other tabs.
struct BrowserPopupAdmission {
    private struct Guest { var open = 0; var recent: [TimeInterval] = [] }
    private var guests: [Int: Guest] = [:]
    mutating func admit(owner: Int, now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> String? {
        guests = guests.filter { $0.value.open > 0 || $0.value.recent.contains(where: { now - $0 < 1 }) }
        var guest = guests[owner] ?? Guest()
        guest.recent.removeAll { now - $0 >= 1 }
        if guest.recent.count >= 2 { return "burst" }
        if guest.open >= 3 || guests.values.reduce(0, { $0 + $1.open }) >= 6 { return "limit" }
        guest.open += 1; guest.recent.append(now); guests[owner] = guest
        return nil
    }
    mutating func release(owner: Int) {
        guard var guest = guests[owner] else { return }
        guest.open = max(0, guest.open - 1); guests[owner] = guest
    }
    /// WKSecurityOrigin represents the creating frame even when its URL is
    /// about:blank with an inherited origin. Never infer a Blob origin from
    /// the address bar, which may describe a different frame or be opaque.
    static func sourceOrigin(scheme: String, host: String, port: Int) -> URL? {
        let scheme = scheme.lowercased(), host = host.lowercased()
        guard ["http", "https"].contains(scheme), !host.isEmpty, host != "null",
              (0...65_535).contains(port) else { return nil }
        var components = URLComponents()
        components.scheme = scheme; components.host = host
        if port != 0 && port != (scheme == "https" ? 443 : 80) { components.port = port }
        return components.url
    }
    static func accepts(_ url: URL, opener: URL?) -> Bool {
        guard url.absoluteString.utf8.count <= 20_000 else { return false }
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host != nil
        // WebKit supplies a bridged NSURL whose path is empty for an opaque
        // about:blank URL. Parse its spelling instead of URL.path so both URL
        // representations admit the same blank document, and no other about page.
        case "about": return URLComponents(string: url.absoluteString)?.path == "blank"
        case "blob":
            guard let source = opener.flatMap(origin), let target = origin(url) else { return false }
            return source == target
        default: return false
        }
    }
    private static func origin(_ url: URL) -> String? {
        if url.scheme?.lowercased() == "blob" { return URL(string: String(url.absoluteString.dropFirst(5))).flatMap(origin) }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
