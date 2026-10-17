import Foundation

/// Pass a Keychain-backed token supplier. Tokens and cookies never enter RecordStore.
public struct SupabaseSyncTransport: SyncTransport, AssetTransport, Sendable {
    public let userID: String
    private let projectURL: URL
    private let publishableKey: String
    private let token: @Sendable () async throws -> String
    private let session: URLSession

    public init(projectURL: URL, publishableKey: String, userID: String,
                session: URLSession = .shared,
                accessToken: @escaping @Sendable () async throws -> String) throws {
        guard projectURL.scheme == "https" ||
                (projectURL.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(projectURL.host ?? "")),
              projectURL.host != nil, UUID(uuidString: userID) != nil else {
            throw CoreError.invalidRecord("Invalid Supabase URL or user ID")
        }
        self.projectURL = projectURL; self.publishableKey = publishableKey
        self.userID = userID.lowercased(); self.session = session; self.token = accessToken
    }

    public func push(_ operation: SyncOperation) async throws -> PushResult {
        guard SyncPolicy.allowedKinds.contains(operation.record.kind) else { throw CoreError.invalidRecord("Local-only kind cannot sync") }
        try validate(operation.record)
        struct Parameters: Encodable { let p_operation: SyncOperation }
        return try await rpc("bandal_push", Parameters(p_operation: operation))
    }

    public func pull(after cursor: Int64, limit: Int) async throws -> PullPage {
        struct Parameters: Encodable { let p_after: Int64; let p_limit: Int }
        return try await rpc("bandal_pull", Parameters(p_after: cursor, p_limit: max(1, min(limit, 1000))))
    }

    public func syncStatus() async throws -> SyncAccessStatus {
        try await rpc("bandal_sync_status", [String: String]())
    }

    public func uploadAsset(_ revision: AssetRevision, from file: URL) async throws {
        try AssetHasher.verify(revision, file: file)
        var request = try await request(path: "storage/v1/object/bandal-assets/\(userID)/\(revision.sha256)")
        request.httpMethod = "POST"
        request.setValue(revision.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await session.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse else { throw CoreError.invalidResponse("Missing HTTP response") }
        if http.statusCode == 409 || (http.statusCode == 400 && String(decoding: data, as: UTF8.self).contains("Duplicate")) {
            // An existing object must be verified; a duplicate response alone is not proof of integrity.
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await downloadAsset(revision, to: temporary)
            return
        }
        try check(data, response)
    }

    public func downloadAsset(_ revision: AssetRevision, to destination: URL) async throws {
        try validateAsset(revision)
        let request = try await request(path: "storage/v1/object/authenticated/bandal-assets/\(userID)/\(revision.sha256)")
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try check(Data(), response)
        try AssetHasher.verify(revision, file: temporary)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            try AssetHasher.verify(revision, file: destination); return
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func rpc<Input: Encodable, Output: Decodable>(_ name: String, _ input: Input) async throws -> Output {
        var request = try await request(path: "rest/v1/rpc/\(name)")
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(input)
        let (data, response) = try await session.data(for: request)
        try check(data, response)
        do { return try JSONDecoder().decode(Output.self, from: data) }
        catch { throw CoreError.invalidResponse("Malformed \(name) response") }
    }

    private func request(path: String) async throws -> URLRequest {
        let accessToken = try await token()
        // A token supplier can change after sign-out. Bind every request to the
        // intended account rather than accidentally uploading the old outbox as
        // a newly signed-in user. Supabase still verifies the JWT signature.
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { throw CoreError.invalidRecord("Invalid access token") }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let claimsData = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              let subject = claims["sub"] as? String,
              subject.lowercased() == userID.lowercased() else {
            throw CoreError.invalidRecord("Access token belongs to another account")
        }
        var request = URLRequest(url: projectURL.appendingPathComponent(path))
        request.timeoutInterval = 60
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpShouldHandleCookies = false
        return request
    }
    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CoreError.invalidResponse("Missing HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            // Don't persist or expose raw server bodies, which can contain private payloads.
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let known = [body?["code"] as? String, body?["message"] as? String].compactMap { $0 }
            let code: SyncFailureCode
            if known.contains(where: { ["subscription_required", "sync_subscription_required"].contains($0) }) { code = .subscriptionRequired }
            else if known.contains(where: { ["storage_limit_exceeded", "sync_storage_limit_exceeded", "sync_quota_exceeded", "sync_storage_quota_exceeded"].contains($0) }) { code = .storageLimitExceeded }
            else if http.statusCode == 401 { code = .authenticationRequired }
            else if http.statusCode == 429 { code = .rateLimited }
            else if http.statusCode >= 500 { code = .unavailable }
            else { code = .requestRejected }
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).map { min(3600, max(1, $0)) }
            throw SyncRequestFailure(code: code, status: http.statusCode, retryAfter: retry)
        }
    }
}
