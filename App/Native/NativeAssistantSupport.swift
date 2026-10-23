import Foundation

enum NativeAssistantMode: String, Codable, CaseIterable, Identifiable {
    case chat, quiz, flashcards, expectedExam = "expected-exam", summary, english
    var id: String { rawValue }
    var title: String { switch self { case .chat: "대화"; case .quiz: "퀴즈"; case .flashcards: "플래시카드"; case .expectedExam: "예상문제"; case .summary: "요약"; case .english: "영어 읽기" } }
    var pack: String? { switch self { case .chat, .english: nil; case .quiz, .expectedExam: "quiz"; case .flashcards: "flashcards"; case .summary: "summary" } }
    static let primary: [Self] = [.chat, .quiz, .flashcards, .expectedExam]
}

extension NativeAssistantAttachment {
    var request: [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    static func decode(_ value: [String: Any]) -> Self? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? JSONSerialization.data(withJSONObject: value)).flatMap { try? decoder.decode(Self.self, from: $0) }
    }
    var imageInput: [String: String]? { NativeAssistantPayload.image(imageDataURL) }
}

/// Capture completion can arrive after its workspace panel has disappeared.
/// Keep those immutable captures independently of a conversation's edited draft
/// until that draft has been written successfully.
enum NativeAssistantPendingCaptures {
    private static let lock = NSLock()
    private static func location(spaceID: String, root: URL) -> URL {
        root.appendingPathComponent("NativeAssistantPending/" + NativeSyncFormat.hash(Data(spaceID.utf8)) + ".json")
    }
    private static func read(_ url: URL) throws -> [NativeAssistantAttachment] {
        guard FileManager.default.fileExists(atPath:url.path) else { return [] }
        return try JSONDecoder().decode([NativeAssistantAttachment].self,from:Data(contentsOf:url))
    }
    private static func write(_ captures: [NativeAssistantAttachment], to url: URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(captures).write(to:url,options:.atomic)
    }
    static func load(spaceID: String, root: URL) throws -> [NativeAssistantAttachment] {
        try lock.withLock { try read(location(spaceID:spaceID,root:root)) }
    }
    static func enqueue(_ captures: [NativeAssistantAttachment], spaceID: String, root: URL) throws {
        guard !captures.isEmpty else { return }
        try lock.withLock {
            let url = location(spaceID:spaceID,root:root)
            var pending = try read(url)
            for capture in captures where !pending.contains(where:{ $0.id == capture.id }) { pending.append(capture) }
            try write(pending,to:url)
        }
    }
    static func acknowledge(_ ids: Set<String>, spaceID: String, root: URL) throws {
        guard !ids.isEmpty else { return }
        try lock.withLock {
            let url = location(spaceID:spaceID,root:root)
            guard FileManager.default.fileExists(atPath:url.path) else { return }
            // Re-read so captures added since delivery are never discarded.
            let remaining = try read(url).filter { !ids.contains($0.id) }
            if remaining.isEmpty { try FileManager.default.removeItem(at:url) }
            else { try write(remaining,to:url) }
        }
    }
}

/// Shared across persistence, history replay and generation. Image bytes remain
/// inside immutable message blocks, which the existing sync path preserves.
enum NativeAssistantPayload {
    static func learningSourceURL(_ target: NativeLearningDocumentTarget) -> String {
        var url = URLComponents()
        url.scheme = "bandal"; url.host = "learning"
        url.path = "/\(target.projectID)/\(target.kind.rawValue)/\(target.entityID)"
        return url.string ?? target.id
    }
    static func generationSource(document: NativeDocumentReference?, selection: String, attachments: [NativeAssistantAttachment]) throws -> [String: Any] {
        guard let document else { return ["kind":"course"] }
        if let target = document.learningTarget {
            switch target.kind {
            case .article: return ["kind":"article","articleIds":[target.entityID]]
            case .artifact:
                let captured = attachments.filter { $0.url == learningSourceURL(target) && !($0.text ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
                guard !captured.isEmpty else { throw DesktopRuntimeError("이 학습 자료의 본문 첨부가 제거되었습니다. 현재 자료를 다시 첨부해 주세요.") }
                return ["kind":"attachment","attachmentIds":captured.map(\.id),"projectId":target.projectID,"artifactId":target.entityID]
            case .overview: throw DesktopRuntimeError("본문이 있는 자료를 선택하거나 영역을 지목해 주세요.")
            }
        }
        return ["kind":"material","relPath":document.relativePath,"selection":selection]
    }
    static func image(_ dataURL: String?) -> [String: String]? {
        guard let value = dataURL, value.hasPrefix("data:"), let separator = value.range(of: ";base64,"),
              let bytes = Data(base64Encoded: String(value[separator.upperBound...])), !bytes.isEmpty else { return nil }
        let type = String(value[value.index(value.startIndex, offsetBy: 5)..<separator.lowerBound])
        guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(type) else { return nil }
        return ["mediaType": type, "dataBase64": String(value[separator.upperBound...])]
    }
    static func assetURL(root: URL, hash: String, mediaType: String) -> URL {
        let suffix = ["image/png":"png","image/jpeg":"jpg","image/webp":"webp","image/gif":"gif"][mediaType] ?? "bin"
        return root.appendingPathComponent("NativeChatAttachments/" + hash + "." + suffix)
    }
    static func cacheImage(_ payload: [String: Any], context: NativeRepositoryContext) throws -> [String: Any]? {
        guard let image = image(payload["imageDataURL"] as? String), let raw = image["dataBase64"], let bytes = Data(base64Encoded:raw), let type = image["mediaType"] else { return nil }
        let hash = NativeSyncFormat.hash(bytes), url = assetURL(root:context.root,hash:hash,mediaType:type)
        if !context.files.fileExists(atPath:url.path) {
            try context.files.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try context.atomicWrite(bytes,to:url)
        }
        guard try context.contentHash(url) == hash else { throw DesktopRuntimeError("첨부 이미지 원본을 확인하지 못했습니다.") }
        var asset = try NativeSyncFormat.asset(materialID:"chat-attachment:" + hash,url:url,hash:hash)
        asset["contentType"] = type
        return asset
    }
    static func validatedAttachments(_ raw: Any?) throws -> [[String: Any]] {
        guard let raw else { return [] }
        guard let values = raw as? [[String: Any]], values.count <= 12,
              values.allSatisfy({ NativeAssistantAttachment.decode($0) != nil }) else { throw DesktopRuntimeError("첨부 형식을 확인해 주세요.") }
        let images = values.compactMap { image($0["imageDataURL"] as? String) }
        guard values.allSatisfy({ $0["imageDataURL"] == nil || image($0["imageDataURL"] as? String) != nil }),
              images.count <= 6, images.reduce(0, { $0 + ($1["dataBase64"]?.utf8.count ?? 0) }) <= 28_000_000,
              values.reduce(0, { $0 + ($1["text"] as? String ?? "").utf8.count }) <= 200_000 else { throw DesktopRuntimeError("첨부 이미지는 최대 6장, 합계 20MB까지 사용할 수 있습니다.") }
        return values
    }
    static func messages(_ history: [[String: Any]]) -> [[String: Any]] {
        var output: [[String: Any]] = history.compactMap { message in
            let blocks = message["blocks"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { block -> String? in
                let payload = block["payload"] as? [String: Any] ?? [:]
                switch block["kind"] as? String {
                case "text": return payload["text"] as? String
                case "attachment":
                    var parts = ["[첨부: \(payload["title"] as? String ?? "선택 영역")]"]
                    for key in ["relativePath", "url", "text"] { if let value = payload[key] as? String, !value.isEmpty { parts.append(value) } }
                    if let page = payload["page"] as? Int { parts.append("페이지 \(page)") }
                    return parts.joined(separator: "\n")
                case "artifact": return "[보관한 자료: \(payload["title"] as? String ?? "학습 자료")]\n" + (payload["contentText"] as? String ?? "")
                default: return nil
                }
            }.joined(separator: "\n\n")
            guard !text.isEmpty else { return nil }
            let images = blocks.filter { $0["kind"] as? String == "attachment" }.compactMap { image(($0["payload"] as? [String: Any])?["imageDataURL"] as? String) }
            return ["role": message["role"] ?? "user", "text": text, "images": images]
        }
        // Keep the newest captures within the providers' aggregate image budget;
        // older turns still retain their text and source provenance in replay.
        var count = 0, bytes = 0
        for index in output.indices.reversed() {
            let images = output[index]["images"] as? [[String: String]] ?? []
            output[index]["images"] = images.filter { image in
                let size = image["dataBase64"]?.utf8.count ?? 0
                guard count < 6, bytes + size <= 28_000_000 else { return false }
                count += 1; bytes += size; return true
            }
        }
        return output
    }
    static func scopeID(_ policy: [String: Any], course: String) -> String {
        (policy["workspace"] as? [String: Any])?["id"] as? String ?? "course:" + course
    }
}
