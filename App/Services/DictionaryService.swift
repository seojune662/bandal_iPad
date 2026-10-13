import Foundation
import SQLite3

struct DictionaryMeaning: Identifiable { var id: String; var word: String; var meaning: String; var source: String }
enum DictionaryService {
    static func lookup(_ input: String) throws -> [DictionaryMeaning] {
        let key = input.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.count <= 120 else { return [] }
        guard let url = Bundle.main.url(forResource: "en-ko", withExtension: "sqlite", subdirectory: "Dictionary") else { throw AIError.message("오프라인 사전 파일이 없습니다.") }
        var db: OpaquePointer?; guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw AIError.message("사전을 열 수 없습니다.") }
        defer { sqlite3_close(db) }
        let sql = "SELECT content FROM (SELECT e.id,e.content,0 AS priority FROM entries e WHERE e.lookup_key = ? UNION ALL SELECT e.id,e.content,1 AS priority FROM aliases a JOIN entries e ON e.lookup_key = a.headword_key WHERE a.lookup_key = ? AND e.lookup_key <> ?) ORDER BY priority,id LIMIT 12"
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw AIError.message("사전 검색을 준비하지 못했습니다.") }
        defer { sqlite3_finalize(statement) }
        for index: Int32 in 1...3 { sqlite3_bind_text(statement, index, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        var results: [DictionaryMeaning] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let chars = sqlite3_column_text(statement, 0), let object = (try? JSONSerialization.jsonObject(with: Data(String(cString: chars).utf8))) as? [String: Any] else { continue }
            let word = object["headword"] as? String ?? object["word"] as? String ?? key
            let senses = object["senses"] as? [[String: Any]] ?? []
            let glosses = senses.flatMap { sense -> [String] in
                if let meaning = sense["meaning"] as? String { return [meaning] }
                if let meanings = sense["meanings"] as? [String] { return meanings }
                if let meaning = sense["gloss"] as? String { return [meaning] }
                if let korean = sense["korean"] as? [String] { return korean }
                return []
            }
            let direct = object["meanings"] as? [String] ?? []
            let meaning = (glosses + direct).joined(separator: "; ")
            if !meaning.isEmpty { results.append(DictionaryMeaning(id: object["id"] as? String ?? UUID().uuidString, word: word, meaning: meaning, source: (object["source"] as? [String: Any])?["url"] as? String ?? "https://en.wiktionary.org/wiki/\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)")) }
        }
        return results
    }
}
