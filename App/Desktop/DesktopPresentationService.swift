import Foundation
import CryptoKit
import BandalCore

@MainActor
struct DesktopPresentationEnvironment {
    var configuration: () -> String = { UserDefaults.standard.string(forKey: "conversion.url") ?? "" }
    var request: (URLRequest, Int64) async throws -> (URL, HTTPURLResponse) = DesktopDownloadTransport.request
}

/// Legacy PPT is normalized to PPTX for the original desktop slide renderer.
/// Cached output is keyed by source bytes; no source document is overwritten.
@MainActor
final class DesktopPresentationService {
    private let root: URL
    private let token: () async throws -> String
    private let environment: DesktopPresentationEnvironment
    private var tasks: [String: Task<[String: Any], Error>] = [:]
    init(root: URL, token: @escaping () async throws -> String, environment: DesktopPresentationEnvironment? = nil) {
        self.root = root; self.token = token; self.environment = environment ?? DesktopPresentationEnvironment()
    }
    func canHandle(_ channel: String) -> Bool {
        ["native:presentationRuntime", "native:presentationConfigure", "native:presentationNormalize", "native:presentationCancel"].contains(channel)
    }
    func handle(channel: String, request: [String: Any]) async throws -> Any {
        switch channel {
        case "native:presentationRuntime": return state()
        case "native:presentationConfigure":
            guard endpoint() != nil else { throw DesktopRuntimeError("구형 PPT 변환 서버가 연결되지 않았습니다. 앱 구성의 conversion.url에 배포된 반달 변환 서버를 연결해 주세요.") }
            return state()
        case "native:presentationCancel":
            if let id = request["requestId"] as? String { tasks[id]?.cancel() }
            else { tasks.values.forEach { $0.cancel() } }
            return ["ok": true]
        case "native:presentationNormalize":
            guard let path = request["path"] as? String, let id = request["requestId"] as? String, !id.isEmpty, id.count <= 128, tasks[id] == nil else { throw DesktopRuntimeError("변환할 PPT를 확인해 주세요.") }
            guard tasks.count < 2 else { throw DesktopRuntimeError("진행 중인 PPT 변환이 끝난 뒤 다시 시도해 주세요.") }
            let task = Task { try await self.normalize(path: path) }; tasks[id] = task
            defer { tasks.removeValue(forKey: id) }
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        default: throw DesktopRuntimeError("Unknown presentation operation", code: "ENOSYS")
        }
    }
    private func endpoint() -> URL? {
        guard let url = URL(string: environment.configuration()), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url.appendingPathComponent("normalize")
    }
    private func state() -> [String: Any] {
        ["status": endpoint() == nil ? "missing" : "ready", "version": "PPT → PPTX", "receivedBytes": 0, "totalBytes": 0,
         "message": endpoint() == nil ? "구형 PPT를 열려면 반달 변환 서버 연결이 필요합니다. PPTX는 기기에서 바로 열 수 있습니다." : "구형 PPT는 최초 한 번 서버에서 변환하고, 이후 기기에 저장된 슬라이드를 엽니다."]
    }
    private func normalize(path: String) async throws -> [String: Any] {
        let source = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(base.path + "/") || DesktopFileAccess.shared(root: root).allows(source),
              source.pathExtension.lowercased() == "ppt" else { throw DesktopRuntimeError("PPT 자료 경로에 접근할 수 없습니다.") }
        let revision = try AssetHasher.revision(of: source)
        guard revision.byteCount >= 8, revision.byteCount <= 80 * 1024 * 1024 else { throw DesktopRuntimeError("구형 PPT는 80MB 이하의 파일을 열어 주세요.") }
        let folder = root.appendingPathComponent("ConvertedPresentations", isDirectory: true)
        let cached = folder.appendingPathComponent(revision.sha256 + ".pptx")
        if FileManager.default.fileExists(atPath: cached.path) {
            let bytes = try Data(contentsOf: cached)
            if bytes.count <= 160 * 1024 * 1024, bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return ["data": bytes.base64EncodedString()] }
            try FileManager.default.removeItem(at: cached)
        }
        guard let address = endpoint() else { throw DesktopRuntimeError("구형 PPT 변환 서버가 연결되지 않았습니다.") }
        let input = try Data(contentsOf: source)
        guard input.starts(with: [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]) else { throw DesktopRuntimeError("구형 PPT 형식을 확인하지 못했습니다.") }
        try AssetHasher.verify(revision, file: source)
        guard SHA256.hash(data: input).map({ String(format: "%02x", $0) }).joined() == revision.sha256 else { throw CoreError.assetIntegrity }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"; request.timeoutInterval = 150; request.httpBody = input
        request.setValue("application/vnd.ms-powerpoint", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        try Task.checkCancellation()
        let (file, response) = try await environment.request(request, 160 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode), response.mimeType == "application/vnd.openxmlformats-officedocument.presentationml.presentation" else {
            throw DesktopRuntimeError(response.statusCode == 401 ? "반달 계정 로그인을 다시 확인해 주세요." : "구형 PPT를 변환하지 못했습니다. 서버 연결과 파일 형식을 확인해 주세요.")
        }
        let output = try Data(contentsOf: file)
        guard output.count <= 160 * 1024 * 1024, output.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw DesktopRuntimeError("변환된 슬라이드를 확인하지 못했습니다.") }
        try AssetHasher.verify(revision, file: source)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try output.write(to: cached, options: .atomic)
        return ["data": output.base64EncodedString()]
    }
}
