import Foundation
import CryptoKit

/// Same immutable dataset, normalization, aliases, result order and attribution
/// as main/features/learning/dictionary.ts. No network or AI fallback.
actor DesktopDictionaryService {
    private let directory: URL?
    private var database: DesktopSQLite?
    private var failed = false
    private var cache: [String: [String: Any]] = [:]
    private var order: [String] = []
    init(directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Dictionary")) { self.directory = directory }

    func lookup(_ input: String) -> [String: Any] {
        guard let key = Self.key(input) else { return ["status": "not-found", "entries": []] }
        if let found = cache[key] { return found }
        do {
            let database = try open()
            let rows = try database.query("""
              SELECT content FROM (
                SELECT e.id, e.content, 0 AS priority FROM entries e WHERE e.lookup_key = ?
                UNION ALL
                SELECT e.id, e.content, 1 AS priority FROM aliases a
                JOIN entries e ON e.lookup_key = a.headword_key
                WHERE a.lookup_key = ? AND e.lookup_key <> ?
              ) ORDER BY priority, id LIMIT ?
              """, params: [key, key, key, 16])
            let entries = try rows.map { row -> Any in
                guard let content = row["content"] as? String else { throw DesktopRuntimeError("Invalid dictionary entry") }
                return try JSONSerialization.jsonObject(with: Data(content.utf8))
            }
            let result: [String: Any] = ["status": entries.isEmpty ? "not-found" : "found", "entries": entries]
            if order.count >= 256 { cache.removeValue(forKey: order.removeFirst()) }
            order.append(key); cache[key] = result
            return result
        } catch { database = nil; cache = [:]; order = []; failed = true; return ["status": "unavailable", "entries": []] }
    }

    nonisolated static func key(_ input: String) -> String? {
        guard input.utf16.count <= 160 else { return nil }
        let value = input.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "[‘’]", with: "'", options: .regularExpression)
            .replacingOccurrences(of: "[‐‑–—]", with: "-", options: .regularExpression)
            .lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^["“”'\(\[\{]+|["“”'\]\)\}.,!?;:]+$"#, with: "", options: .regularExpression)
        guard !value.isEmpty, value.utf16.count <= 120, value.components(separatedBy: " ").count <= 5,
              value.range(of: #"^[\p{L}\p{N}]+(?:[ '-][\p{L}\p{N}]+)*$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    private func open() throws -> DesktopSQLite {
        if let database { return database }
        guard !failed, let directory else { throw DesktopRuntimeError("Dictionary resource unavailable") }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
        let file = manifest?["database"] as? [String: Any]
        guard manifest?["schemaVersion"] as? Int == 1, manifest?["datasetVersion"] as? String == "koreader-dicts-en-ko-v1.2.0", file?["file"] as? String == "en-ko.sqlite" else { throw DesktopRuntimeError("Unsupported dictionary resource") }
        let url = directory.appendingPathComponent("en-ko.sqlite")
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count == file?["bytes"] as? Int,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file?["sha256"] as? String else { throw DesktopRuntimeError("Dictionary integrity check failed") }
        let opened = try DesktopSQLite(url: url, readOnly: true)
        try opened.exec("PRAGMA query_only=ON")
        guard try (opened.query("PRAGMA user_version", params: nil).first?["user_version"] as? NSNumber)?.intValue == 1,
              try opened.query("SELECT value FROM metadata WHERE key='datasetVersion'", params: nil).first?["value"] as? String == "koreader-dicts-en-ko-v1.2.0" else { throw DesktopRuntimeError("Invalid dictionary schema") }
        database = opened; return opened
    }
}
