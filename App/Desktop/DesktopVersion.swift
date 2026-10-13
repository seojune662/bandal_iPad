import Foundation

enum DesktopVersion {
    /// The version of the desktop sources actually embedded in this build.
    static let current: String = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Desktop/source-provenance.json"),
           let data = try? Data(contentsOf: url),
           let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = source["appVersion"] as? String, !version.isEmpty { return version }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }()
}
