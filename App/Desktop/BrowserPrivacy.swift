import Foundation
import WebKit
import CryptoKit

/// The same deterministic endpoint lists as desktop trackingProtection.ts.
@MainActor
enum BrowserPrivacy {
    static let balanced = ["doubleclick.net", "google-analytics.com", "googlesyndication.com", "googletagmanager.com", "facebook.net", "hotjar.com", "clarity.ms", "segment.io"]
    static let strictExtra = ["adnxs.com", "adsrvr.org", "criteo.com", "criteo.net", "mixpanel.com", "amplitude.com", "taboola.com", "outbrain.com", "scorecardresearch.com"]
    private static var compiled: [String: WKContentRuleList] = [:]
    static func rules(tracking: String, doNotTrack: Bool) throws -> String? {
        guard ["off", "balanced", "strict"].contains(tracking) else { throw DesktopBrowserError.invalid("추적 방지 설정") }
        var rules: [[String: Any]] = []
        for domain in tracking == "off" ? [] : balanced + (tracking == "strict" ? strictExtra : []) {
            rules.append(["trigger": ["url-filter": "^https?://([^/]+\\.)?" + domain.replacingOccurrences(of: ".", with: "\\.") + "\\.?(:[0-9]+)?/", "load-type": ["third-party"]], "action": ["type": "block"]])
        }
        if rules.isEmpty { return nil }
        return String(data: try JSONSerialization.data(withJSONObject: rules, options: .sortedKeys), encoding: .utf8)!
    }
    static func compile(tracking: String, doNotTrack: Bool) async throws -> WKContentRuleList? {
        guard let source = try rules(tracking: tracking, doNotTrack: doNotTrack) else { return nil }
        let identifier = "bandal-privacy-" + SHA256.hash(data: Data(source.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        if let existing = compiled[identifier] { return existing }
        let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source)
        guard let list else { throw DesktopBrowserError.unavailable("WebKit 추적 방지 규칙을 준비하지 못했습니다.") }
        compiled[identifier] = list; return list
    }
    static func signalScript(enabled: Bool) -> String {
        "(() => {for(const [key,value] of [['doNotTrack',\(enabled ? "'1'" : "null")],['globalPrivacyControl',\(enabled ? "true" : "false")]]) {try{Object.defineProperty(Navigator.prototype,key,{configurable:true,get:()=>value})}catch{}}})();"
    }
}
