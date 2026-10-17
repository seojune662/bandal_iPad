import Foundation
import CryptoKit

/// App updates may move the data container. App-owned Documents paths therefore
/// use a relative identity; injected or external workspaces retain their full
/// path. No historical path is opened: predecessor paths are only hash inputs.
enum NativePDFPreferenceScope {
    private static func documents(_ override: URL?) -> URL {
        override ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/private/var/mobile/") ? String(path.dropFirst(8)) : path
    }
    private static func relativeRoot(_ root: URL, documentsRoot: URL?) -> String? {
        let base = canonicalPath(documents(documentsRoot)), path = canonicalPath(root)
        if path == base { return "" }
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }
    static func identity(root: URL, documentsRoot: URL? = nil) -> String {
        guard let relative = relativeRoot(root, documentsRoot: documentsRoot) else { return root.standardizedFileURL.path }
        return "app-documents/" + relative
    }
    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func predecessorKey(root: URL, documentsRoot: URL?) -> String {
        "native-pdf.preference-predecessor.v1." + hash(identity(root: root, documentsRoot: documentsRoot))
    }
    private static func containerPrefix(_ documents: URL) -> String? {
        let parts = (canonicalPath(documents) as NSString).pathComponents
        guard parts.count >= 5, Array(parts.suffix(5).prefix(3)) == ["Containers", "Data", "Application"],
              parts.last == "Documents", UUID(uuidString: parts[parts.count - 2]) != nil else { return nil }
        return NSString.path(withComponents: Array(parts.dropLast(2)))
    }
    private static func allowedPrevious(_ previous: String, root: URL, documentsRoot: URL?) -> Bool {
        guard previous.hasPrefix("/"), !previous.contains("\0"), !previous.contains("\\"),
              URL(fileURLWithPath: previous).standardizedFileURL.path == previous,
              let relative = relativeRoot(root, documentsRoot: documentsRoot) else { return false }
        let relativeParts = relative.split(separator: "/").map(String.init)
        var previousDocuments = URL(fileURLWithPath: previous, isDirectory: true)
        for part in relativeParts.reversed() {
            guard previousDocuments.lastPathComponent == part else { return false }
            previousDocuments.deleteLastPathComponent()
        }
        guard let currentPrefix = containerPrefix(documents(documentsRoot)),
              let previousPrefix = containerPrefix(previousDocuments) else { return false }
        return currentPrefix == previousPrefix
    }
    private static func registeredPredecessors(root: URL, documentsRoot: URL?, defaults: UserDefaults) -> [String] {
        let key = predecessorKey(root: root, documentsRoot: documentsRoot)
        let stored = defaults.stringArray(forKey: key) ?? defaults.string(forKey: key).map { [$0] } ?? []
        var seen = Set<String>()
        return stored.filter { path in
            allowedPrevious(path, root: root, documentsRoot: documentsRoot) &&
                seen.insert(canonicalPath(URL(fileURLWithPath: path))).inserted
        }
    }
    /// Capture the immediately preceding root before storage relocation rewrites
    /// settings.json. Keep the ordered chain of roots previously registered from
    /// that evidence, so an unopened document survives more than one update.
    static func registerPreviousRoot(root: URL, documentsRoot: URL? = nil, defaults: UserDefaults = .standard) {
        guard relativeRoot(root, documentsRoot: documentsRoot) != nil else { return }
        let settingsURL = root.appendingPathComponent("settings.json")
        guard let size = try? settingsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024,
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = settings["dataRoot"] as? String, path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else { return }
        let courses = URL(fileURLWithPath: path, isDirectory: true)
        guard courses.lastPathComponent == "Courses" else { return }
        let previous = courses.deletingLastPathComponent()
        guard allowedPrevious(previous.path, root: root, documentsRoot: documentsRoot),
              canonicalPath(previous) != canonicalPath(root) else { return }
        let previousIdentity = canonicalPath(previous)
        let earlier = registeredPredecessors(root: root, documentsRoot: documentsRoot, defaults: defaults)
            .filter { canonicalPath(URL(fileURLWithPath: $0)) != previousIdentity }
        defaults.set([previous.path] + earlier, forKey: predecessorKey(root: root, documentsRoot: documentsRoot))
    }
    private static func aliases(_ path: String) -> [String] {
        if path.hasPrefix("/private/var/mobile/Containers/Data/Application/") { return [path, String(path.dropFirst(8))] }
        if path.hasPrefix("/var/mobile/Containers/Data/Application/") { return [path, "/private" + path] }
        return [path]
    }
    static func storedData(root: URL, stableKey: String, documentsRoot: URL? = nil, defaults: UserDefaults,
                           legacyKeys: (String) -> [String], normalize: (Data) -> Data?) -> Data? {
        if let data = defaults.data(forKey: stableKey) { return normalize(data) == nil ? nil : data }
        let owned = relativeRoot(root, documentsRoot: documentsRoot) != nil
        var groups = [owned ? aliases(root.standardizedFileURL.path) : [root.standardizedFileURL.path]]
        if owned {
            groups += registeredPredecessors(root: root, documentsRoot: documentsRoot, defaults: defaults).map(aliases)
        }
        for paths in groups {
            let keys = paths.map(legacyKeys)
            for version in 0..<(keys.map(\.count).max() ?? 0) {
                let values = keys.compactMap { $0.indices.contains(version) ? defaults.data(forKey: $0[version]) : nil }.compactMap(normalize)
                let unique = Set(values)
                // /private aliases should be the same preference. A conflict is
                // preserved for recovery instead of selecting an arbitrary one.
                if unique.count > 1 { return nil }
                if let data = unique.first { defaults.set(data, forKey: stableKey); return data }
            }
        }
        return nil
    }
}
