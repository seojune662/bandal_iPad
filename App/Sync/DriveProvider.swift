import CryptoKit
import Foundation

/// Google Drive › Bandal as the root (design §1.4): Drive REST v3 under the `drive.file` scope,
/// which shows only what this app made. Text files are downloaded while listing, so a listed
/// one is readable; PDFs and assets download after it and count as there once they land, as
/// on iCloud. Folders of the same name (two devices made one at once) are read as one, and
/// writes go to the oldest.
final class DriveProvider: SyncProvider, @unchecked Sendable {
    typealias Transport = GoogleDriveAuth.Transport
    let account: GoogleDriveAuth.Account
    let changes: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let remote: Remote
    /// Root path → the downloaded bytes it has now; read without waiting, under the lock.
    private let lock = NSLock()
    private var readable: [String: URL] = [:]
    private var poller: Task<Void, Never>?

    /// `cache` holds downloads (under Caches: the system may clear it, and they come down again).
    /// `backoff` is the first wait after a busy answer; `window` the gap between uploads of one file.
    init(account: GoogleDriveAuth.Account, cache: URL, transport: @escaping Transport = GoogleDriveAuth.live, poll: Duration = .seconds(30),
         backoff: Double = 1, window: TimeInterval = 15) {
        self.account = account
        (changes, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        remote = Remote(account: account, cache: cache, transport: transport, backoff: backoff, window: window)
        let signal = signal, remote = remote
        // Drive does not push: changes are asked for while the app runs (design §1.4).
        // ponytail: one 30 s interval; slow it when idle if the request count matters.
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                if (try? await remote.pollChanges()) == true { signal.yield() }
            }
        }
    }
    deinit {
        poller?.cancel()
        let remote = remote
        Task { await remote.stop() }
    }

    /// The writes of the next few seconds skip the 15 s window ("지금 동기화").
    func hurry() async { await remote.hurry() }

    /// The folders the last listing looked at for the root, `id:createdTime:mark|name:bandal.json 1|0:chosen 1|0:name`
    /// each, and the one chosen (nil: none, so the first write makes one). For the connection log (spec v2.6).
    func lookup() async -> (folders: [String], chosen: String?) { await remote.looked }

    func list() async throws -> [String: SyncRemoteFile] {
        let listing = try await remote.list()
        lock.withLock { readable = listing.readable }
        // PDFs and assets come down after the listing, one at a time; each landing is a change.
        let signal = signal
        await remote.fetchLater(listing.blobs) { signal.yield() }
        return listing.files
    }

    func read(_ path: String) throws -> Data {
        guard let url = lock.withLock({ readable[path] }), let data = try? Data(contentsOf: url) else {
            throw DesktopRuntimeError("\(path) is not downloaded yet", code: "SYNC_DOWNLOADING")
        }
        return data
    }

    func write(_ content: SyncOutbox.Content, to path: String) async throws {
        let bytes: Data
        switch content {
        case .data(let data): bytes = data
        case .file(let url):
            // ponytail: whole files in memory, PDFs too; stream uploads from the file if large PDFs press memory.
            bytes = try Data(contentsOf: url)
            if SyncFormat.isBlob(path), SyncFormat.sha256(bytes) != String((path as NSString).lastPathComponent.prefix(64)) {
                throw DesktopRuntimeError("\(path) changed while syncing", code: "CONFLICT")
            }
        }
        let url = try await remote.upload(bytes, to: path)
        lock.withLock { readable[path] = url }  // nil drops an older download: the next listing gets the file again
    }

    static func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: Drive

    struct Meta {
        let id, name, mime: String
        let parents: [String]
        let md5: String?
        let size: Int64
        let created: String
        /// Marked as a 반달 root: `bandalRoot = "2"` in `properties` or `appProperties` (spec v2.5).
        let isRoot: Bool
        var isFolder: Bool { mime == DriveProvider.folder }

        init?(_ value: [String: Any]) {
            guard let id = value["id"] as? String, let name = value["name"] as? String, let mime = value["mimeType"] as? String else { return nil }
            self.id = id; self.name = name; self.mime = mime
            parents = value["parents"] as? [String] ?? []
            md5 = value["md5Checksum"] as? String
            size = Int64(value["size"] as? String ?? "") ?? 0
            created = value["createdTime"] as? String ?? ""
            isRoot = (value["appProperties"] as? [String: Any])?["bandalRoot"] as? String == "2"
                || (value["properties"] as? [String: Any])?["bandalRoot"] as? String == "2"
        }
        /// Same-name items are read oldest first, and the oldest is the one written.
        static func older(_ a: Meta, _ b: Meta) -> Bool { (a.created, a.id) < (b.created, b.id) }
    }
    static let folder = "application/vnd.google-apps.folder"
    static let fields = "id,name,mimeType,parents,size,md5Checksum,createdTime,appProperties,properties"
    static let api = "https://www.googleapis.com/drive/v3", uploadAPI = "https://www.googleapis.com/upload/drive/v3"

    /// Everything that talks to Drive. Its calls interleave only while one waits on the network.
    private actor Remote {
        private let account: GoogleDriveAuth.Account, cache: URL, transport: Transport
        private var access: (token: String, expires: Date)?
        /// Every file and folder of this app, by id: a full listing first, then `changes.list`.
        private var items: [String: Meta] = [:], pageToken: String?
        /// Paths under the root as last built: folders and files, oldest first.
        private var folders: [String: [Meta]] = [:], files: [String: [Meta]] = [:]
        private var spareIDs: [String] = [], queued: [Meta] = [], worker: Task<Void, Never>?
        /// The md5 each file id was last kept under, so its earlier download goes.
        private var kept: [String: String] = [:]
        private var uploaded: [String: Date] = [:], hurried: Date?
        private(set) var looked: (folders: [String], chosen: String?) = ([], nil)
        /// Rewrites of one file wait this long between uploads (design §1.4: 15 s), unless hurried.
        private let window: TimeInterval, backoff: Double

        init(account: GoogleDriveAuth.Account, cache: URL, transport: @escaping Transport, backoff: Double, window: TimeInterval) {
            self.account = account; self.cache = cache; self.transport = transport; self.backoff = backoff; self.window = window
        }

        func hurry() { hurried = Date() }

        struct Listing { let files: [String: SyncRemoteFile], readable: [String: URL], blobs: [Meta] }

        func list() async throws -> Listing {
            if pageToken != nil {
                // A page token Drive no longer knows starts the listing over.
                do { _ = try await pollChanges() } catch let error as DesktopRuntimeError where ["DRIVE_400", "DRIVE_404", "DRIVE_410"].contains(error.code) { pageToken = nil }
            }
            if pageToken == nil { try await listEverything() }
            build()
            let texts = files.filter { !SyncFormat.isBlob($0.key) && SyncFormat.isSpecFile($0.key) && cached($0.value[0]) == nil }.map { ($0.key, $0.value[0]) }
            // Text files come down before the listing returns, six at a time.
            for start in stride(from: 0, to: texts.count, by: 6) {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (_, file) in texts[start..<min(start + 6, texts.count)] { group.addTask { _ = try await self.fetch(file) } }
                    try await group.waitForAll()
                }
            }
            // What is listed as here is exactly what can be read.
            var listed: [String: SyncRemoteFile] = [:], readable: [String: URL] = [:], blobs: [Meta] = []
            for (path, entries) in files {
                let file = entries[0], url = cached(file)
                listed[path] = SyncRemoteFile(version: "\(file.md5 ?? file.id):\(file.size)", local: url != nil, size: file.size)
                if let url { readable[path] = url } else if SyncFormat.isBlob(path) { blobs.append(file) }
            }
            return Listing(files: listed, readable: readable, blobs: blobs)
        }

        /// PDFs and assets go to one worker, which calls `landed` after each download.
        func fetchLater(_ blobs: [Meta], landed: @escaping @Sendable () -> Void) {
            queued += blobs.filter { blob in !queued.contains { $0.id == blob.id } }
            guard worker == nil, !queued.isEmpty else { return }
            worker = Task {
                while let file = self.next(), !Task.isCancelled {
                    if self.cached(file) == nil, (try? await self.fetch(file)) != nil { landed() }
                }
                self.finish()
            }
        }
        private func next() -> Meta? { queued.isEmpty ? nil : queued.removeFirst() }
        private func finish() { worker = nil }
        func stop() { worker?.cancel(); worker = nil; queued = [] }

        /// True when Drive reports a change since the last look.
        func pollChanges() async throws -> Bool {
            guard var token = pageToken else { return false }
            var changed = false
            while true {
                let page = try await json("\(DriveProvider.api)/changes", query: [
                    "pageToken": token, "includeRemoved": "true", "spaces": "drive", "pageSize": "1000",
                    "fields": "nextPageToken,newStartPageToken,changes(fileId,removed,file(\(DriveProvider.fields),trashed))"])
                for change in page["changes"] as? [[String: Any]] ?? [] {
                    guard let id = change["fileId"] as? String else { continue }
                    let file = change["file"] as? [String: Any]
                    items[id] = change["removed"] as? Bool == true || file?["trashed"] as? Bool == true ? nil : file.flatMap(Meta.init)
                    changed = true
                }
                if let next = page["nextPageToken"] as? String { token = next; continue }
                pageToken = page["newStartPageToken"] as? String ?? token
                return changed
            }
        }

        private func listEverything() async throws {
            let start = try await json("\(DriveProvider.api)/changes/startPageToken", query: [:])["startPageToken"] as? String
            var all: [String: Meta] = [:], next: String?
            repeat {
                var query = ["q": "trashed = false", "pageSize": "1000", "spaces": "drive", "fields": "nextPageToken,files(\(DriveProvider.fields))"]
                if let next { query["pageToken"] = next }
                let page = try await json("\(DriveProvider.api)/files", query: query)
                for value in page["files"] as? [[String: Any]] ?? [] { if let meta = Meta(value) { all[meta.id] = meta } }
                next = page["nextPageToken"] as? String
            } while next != nil
            items = all
            pageToken = start
        }

        /// The root is a folder marked as one, wherever it is and whatever its name (spec v2.5 "저장소 루트").
        /// With none in sight, a "Bandal" folder holding `bandal.json`, for a folder without a mark (both
        /// marks show to every client of the project, spec v2.6). Of several, the one holding `bandal.json`,
        /// then the oldest. Under it, folders of one name are read together.
        private func build() {
            var children: [String: [Meta]] = [:]
            for item in items.values { for parent in item.parents { children[parent, default: []].append(item) } }
            let started = { (folder: Meta) in (children[folder.id] ?? []).contains { $0.name == "bandal.json" && !$0.isFolder } }
            let marked = items.values.filter { $0.isFolder && $0.isRoot }
            let candidates = (marked.isEmpty ? items.values.filter { $0.isFolder && $0.name == "Bandal" } : marked).sorted(by: Meta.older)
            let roots = marked.isEmpty ? candidates.filter(started) : candidates
            folders = [:]; files = [:]
            let chosen = roots.first(where: started) ?? roots.first
            looked = (candidates.map { "\($0.id):\($0.created):\(marked.isEmpty ? "name" : "mark"):\(started($0) ? 1 : 0):\($0.id == chosen?.id ? 1 : 0):\($0.name)" }, chosen?.id)
            guard let root = chosen else { return }
            folders[""] = [root]
            var queue: [(path: String, id: String)] = [("", root.id)]
            while let (path, id) = queue.popLast() {
                for child in children[id] ?? [] {
                    let full = path.isEmpty ? child.name : path + "/" + child.name
                    if !child.isFolder { files[full, default: []].append(child); continue }
                    folders[full, default: []].append(child)
                    queue.append((full, child.id))
                }
            }
            folders = folders.mapValues { $0.sorted(by: Meta.older) }
            files = files.mapValues { $0.sorted(by: Meta.older) }
        }

        /// The download the bytes are kept as, nil when Drive holds something else.
        func upload(_ bytes: Data, to path: String) async throws -> URL? {
            if pageToken == nil { try await listEverything(); build() }
            if let existing = files[path]?.first {
                // A blob is named by its bytes: the one there is it.
                if SyncFormat.isBlob(path) { return try remember(existing, bytes: bytes, path: path) }
                // bandal.json is written twice per root, marked then not (spec v2.6): the unmarking never waits.
                if path != "bandal.json", hurried.map({ Date().timeIntervalSince($0) > 10 }) ?? true, let last = uploaded[path], Date().timeIntervalSince(last) < window {
                    try await Task.sleep(for: .seconds(window - Date().timeIntervalSince(last)))
                }
                return try remember(try await send(bytes, url: "\(DriveProvider.uploadAPI)/files/\(existing.id)", method: "PATCH", metadata: nil), bytes: bytes, path: path)
            }
            let parent = try await folder((path as NSString).deletingLastPathComponent), id = try await spareID()
            let metadata: [String: Any] = ["id": id, "name": (path as NSString).lastPathComponent, "parents": [parent.id]]
            do {
                return try remember(try await send(bytes, url: "\(DriveProvider.uploadAPI)/files", method: "POST", metadata: metadata), bytes: bytes, path: path)
            } catch let error as DesktopRuntimeError where error.code == "DRIVE_409" {
                // A create retried after it went through: the file with that id is this one.
                guard let meta = Meta(try await json("\(DriveProvider.api)/files/\(id)", query: ["fields": DriveProvider.fields])),
                      meta.md5 == DriveProvider.md5(bytes) else { throw error }
                return try remember(meta, bytes: bytes, path: path)
            }
        }

        /// The oldest folder at `path`, made (with those above it) when there is none.
        private func folder(_ path: String) async throws -> Meta {
            if let existing = folders[path]?.first { return existing }
            let parent: Meta? = path.isEmpty ? nil : try await folder((path as NSString).deletingLastPathComponent)
            var body: [String: Any] = ["id": try await spareID(), "mimeType": DriveProvider.folder]
            if let parent { body["name"] = (path as NSString).lastPathComponent; body["parents"] = [parent.id] }
            else { body["name"] = "Bandal"; body["properties"] = ["bandalRoot": "2"]; body["appProperties"] = ["bandalRoot": "2"] }
            let created = try await json("\(DriveProvider.api)/files", query: ["fields": DriveProvider.fields], method: "POST", body: try JSONSerialization.data(withJSONObject: body))
            guard let meta = Meta(created) else { throw DesktopRuntimeError("Google Drive에 폴더를 만들지 못했습니다.") }
            items[meta.id] = meta
            folders[path] = [meta]
            return meta
        }

        /// Records what Drive now holds at `path` and keeps the bytes as its download when they are what Drive has.
        private func remember(_ meta: Meta, bytes: Data, path: String) throws -> URL? {
            items[meta.id] = meta
            files[path] = [meta] + (files[path] ?? []).filter { $0.id != meta.id }
            uploaded[path] = Date()
            return meta.md5 == DriveProvider.md5(bytes) ? try keep(bytes, as: meta) : nil
        }

        /// Ids made ahead (`files.generateIds`), so a create sent twice makes one file.
        private func spareID() async throws -> String {
            if spareIDs.isEmpty {
                spareIDs = try await json("\(DriveProvider.api)/files/generateIds", query: ["count": "100", "space": "drive", "type": "files"])["ids"] as? [String] ?? []
            }
            guard !spareIDs.isEmpty else { throw DesktopRuntimeError("Google Drive 파일 id를 받지 못했습니다.") }
            return spareIDs.removeFirst()
        }

        private func place(_ file: Meta) -> URL { cache.appendingPathComponent("\(file.id)-\(file.md5 ?? "none")") }
        private func cached(_ file: Meta) -> URL? {
            let url = place(file)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        /// One download per file id: an earlier version of a rewritten file goes.
        private func keep(_ bytes: Data, as file: Meta) throws -> URL {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let url = place(file)
            try bytes.write(to: url, options: .atomic)
            if let old = kept.updateValue(file.md5 ?? "none", forKey: file.id), old != file.md5 {
                try? FileManager.default.removeItem(at: cache.appendingPathComponent("\(file.id)-\(old)"))
            }
            return url
        }

        /// Bytes that do not match Drive's md5 are not kept: the next listing asks again.
        private func fetch(_ file: Meta) async throws -> URL {
            if let url = cached(file) { return url }
            // ponytail: whole downloads in memory; stream to a file with URLSession.download if large PDFs press memory.
            let data = try await request("\(DriveProvider.api)/files/\(file.id)", query: ["alt": "media"]).0
            guard file.md5 == nil || file.md5 == DriveProvider.md5(data) else { throw DesktopRuntimeError("\(file.name) came down damaged", code: "SYNC_DOWNLOADING") }
            return try keep(data, as: file)
        }

        // MARK: HTTP

        private func json(_ url: String, query: [String: String], method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
            let (data, _) = try await request(url, query: query, method: method, body: body, type: body == nil ? nil : "application/json; charset=UTF-8")
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        /// Multipart creates below 5 MB (Drive's limit for them), resumable at and above; media for updates.
        private func send(_ bytes: Data, url: String, method: String, metadata: [String: Any]?) async throws -> Meta {
            let data: Data
            if bytes.count >= 5 << 20 {
                // ponytail: one PUT per session; keep the session URI to resume if large uploads fail midway.
                let (_, start) = try await request(url, query: ["uploadType": "resumable", "fields": DriveProvider.fields], method: method,
                                                   body: try JSONSerialization.data(withJSONObject: metadata ?? [:]), type: "application/json; charset=UTF-8")
                guard let session = start.value(forHTTPHeaderField: "Location") else { throw DesktopRuntimeError("Google Drive 업로드를 시작하지 못했습니다.") }
                data = try await request(session, query: [:], method: "PUT", body: bytes, type: "application/octet-stream").0
            } else if let metadata {
                let boundary = "bandal-" + UUID().uuidString
                var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
                body += try JSONSerialization.data(withJSONObject: metadata)
                body += Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8) + bytes + Data("\r\n--\(boundary)--".utf8)
                data = try await request(url, query: ["uploadType": "multipart", "fields": DriveProvider.fields], method: method, body: body, type: "multipart/related; boundary=\(boundary)").0
            } else {
                data = try await request(url, query: ["uploadType": "media", "fields": DriveProvider.fields], method: method, body: bytes, type: "application/octet-stream").0
            }
            guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let meta = Meta(value) else {
                throw DesktopRuntimeError("Google Drive 업로드 응답을 확인하지 못했습니다.")
            }
            return meta
        }

        /// One call with the access token: a 401 renews it once, rate limits and server errors back off.
        private func request(_ url: String, query: [String: String], method: String = "GET", body: Data? = nil, type: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var components = URLComponents(string: url)!
            if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
            var renewed = false, delay = backoff
            for attempt in 0..<5 {
                var request = URLRequest(url: components.url!)
                request.httpMethod = method
                request.httpBody = body
                if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
                request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
                let (data, response) = try await transport(request)
                switch response.statusCode {
                case 200..<300: return (data, response)
                case 401 where !renewed: renewed = true; access = nil
                case 401: throw GoogleDriveAuth.signedOut
                case 409: throw DesktopRuntimeError("Google Drive conflict", code: "DRIVE_409")
                case 403, 429, 500...:
                    guard attempt < 4, response.statusCode != 403 || Self.rateLimited(data) else {
                        throw DesktopRuntimeError("Google Drive가 요청을 거절했습니다 (\(response.statusCode)).", code: "DRIVE_\(response.statusCode)")
                    }
                    try await Task.sleep(for: .seconds(delay)); delay *= 2
                default: throw DesktopRuntimeError("Google Drive가 요청을 거절했습니다 (\(response.statusCode)).", code: "DRIVE_\(response.statusCode)")
                }
            }
            throw DesktopRuntimeError("Google Drive가 응답하지 않습니다. 잠시 뒤 다시 시도해 주세요.", code: "DRIVE_BUSY")
        }

        private static func rateLimited(_ data: Data) -> Bool {
            let reasons = (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any])?["errors"] as? [[String: Any]] ?? []
            return reasons.contains { ["rateLimitExceeded", "userRateLimitExceeded"].contains($0["reason"] as? String ?? "") }
        }

        private func token() async throws -> String {
            if let access, access.expires > Date() { return access.token }
            let fresh = try await GoogleDriveAuth.accessToken(account, transport: transport)
            access = fresh
            return fresh.token
        }
    }
}
