import CryptoKit
import Foundation
import zlib

/// Common sync spec v2.1 (`Tests/Fixtures/sync-fixtures/SPEC.md`): which cloud-root
/// paths are Bandal's, and validation of each file as untrusted input. Mirrors the
/// desktop's `src/main/features/sync/format.ts` so both apps read a root alike.
///
/// A file that cannot be read at all (bad JSON or gzip, wrong shape, over its size
/// limit, wrong hash) is rejected whole. A single event or drawing with a bad value
/// is dropped on its own and counted, so it cannot hide its neighbours.
enum SyncFormat {
    static let version = 2
    /// `t` and `created` must be before 2100-01-01.
    static let maxStamp: Int64 = 4_102_444_800_000
    static let maxPage = 100_000
    static let mib = 1 << 20
    private static let knownOps: Set<String> = ["course.upsert", "course.delete", "doc.upsert", "doc.delete"]

    /// `index` is the position in the file's array; it settles a same-stamp tie in the merge.
    struct Event { let t: Int64; let op: String; let id: String; let fields: [String: Any]; let index: Int }
    /// One `pdf_drawings` row in spec form, kept whole. A minimal tombstone is `{id, page, t, del}`.
    struct InkObject { let id: String; let page: Int; let t: Int64; let index: Int; let value: [String: Any] }

    enum Content {
        case root(format: Int)
        case device(id: String, name: String)
        /// `dropped` counts entries that failed validation and were left out.
        case log(author: String, seq: Int, events: [Event], dropped: Int)
        case ink(author: String, seq: Int, doc: String, objects: [InkObject], dropped: Int)
        /// `assets` lists the `assets/<sha>.<ext>` files the snapshot links to.
        case note(author: String, seq: Int, doc: String, hash: String, assets: [String])
        case pdf, asset
    }

    struct File { let path: String; let content: Content }

    /// Root files sorted into parsed files, ignored paths, unreadable paths and iCloud
    /// placeholders (`pending`, listed by the path they stand for).
    struct Root { let files: [File]; let ignored: [String]; let errors: [String]; let pending: [String] }

    struct Unreadable: Error { let reason: String }

    static func readRoot(_ files: [(path: String, bytes: Data)]) -> Root {
        var parsed: [File] = [], ignored: [String] = [], errors: [String] = [], pending: [String] = []
        for file in files {
            if let target = placeholderTarget(file.path), pattern(target) != nil { pending.append(target); continue }
            do {
                if let result = try parse(path: file.path, bytes: file.bytes) { parsed.append(result) } else { ignored.append(file.path) }
            } catch { errors.append(file.path) }
        }
        return Root(files: parsed, ignored: sortedUTF16(ignored), errors: sortedUTF16(errors), pending: sortedUTF16(pending))
    }

    /// `nil` means the path is outside the spec's patterns and must be ignored.
    static func parse(path: String, bytes: Data) throws -> File? {
        guard let match = pattern(path) else { return nil }
        switch match {
        case .root:
            guard let root = try json(bytes, limit: mib) as? [String: Any], let format = safeInteger(root["format"]) else { throw Unreadable(reason: "bandal.json format") }
            return File(path: path, content: .root(format: format))
        case .device(let id):
            guard let device = try json(bytes, limit: mib) as? [String: Any], let name = device["name"] as? String else { throw Unreadable(reason: "device name") }
            return File(path: path, content: .device(id: id, name: name))
        case .log(let author, let seq):
            let (events, dropped) = try items(json(bytes, limit: 4 * mib), event)
            return File(path: path, content: .log(author: author, seq: seq, events: events, dropped: dropped))
        case .ink(let doc, let page, let author, let seq):
            guard let page, page <= maxPage else { throw Unreadable(reason: "ink page") }
            let (objects, dropped) = try items(json(gunzip(bytes, limit: 64 * mib), limit: 64 * mib), inkObject)
            return File(path: path, content: .ink(author: author, seq: seq, doc: doc, objects: objects, dropped: dropped))
        case .note(let doc, let author, let seq):
            guard bytes.count <= 16 * mib else { throw Unreadable(reason: "note is over its size limit") }
            return File(path: path, content: .note(author: author, seq: seq, doc: doc, hash: sha256(bytes), assets: noteAssets(bytes)))
        case .pdf(let hash), .asset(let hash):
            guard sha256(bytes) == hash else { throw Unreadable(reason: "content does not match its hash") }
            return File(path: path, content: path.hasPrefix("pdf/") ? .pdf : .asset)
        }
    }

    /// iCloud's `dir/.name.icloud` stands for `dir/name`. Same match as the desktop's
    /// `/^(.*\/)?\.(.+)\.icloud$/`: the last `/` followed by `.` and at least one character.
    static func placeholderTarget(_ path: String) -> String? {
        let scalars = Array(path.unicodeScalars), suffix = Array(".icloud".unicodeScalars)
        guard scalars.count >= suffix.count + 2, scalars.suffix(suffix.count).elementsEqual(suffix),
              !scalars.contains(where: { [0x0A, 0x0D, 0x2028, 0x2029].contains($0.value) }) else { return nil }
        let end = scalars.count - suffix.count
        guard let dot = stride(from: end - 2, through: 0, by: -1).first(where: { scalars[$0] == "." && ($0 == 0 || scalars[$0 - 1] == "/") }) else { return nil }
        var target = String.UnicodeScalarView()
        target.append(contentsOf: scalars[..<dot]); target.append(contentsOf: scalars[(dot + 1)..<end])
        return String(target)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func uuid(_ value: Any?) -> String? { (value as? String).flatMap { isUUID(Array($0.utf8)[...]) ? $0 : nil } }
    static func sha(_ value: Any?) -> String? { (value as? String).flatMap { isSHA(Array($0.utf8)[...]) ? $0 : nil } }
    static func ext(_ value: Any?) -> String? { (value as? String).flatMap { isExt(Array($0.utf8)[...]) ? $0 : nil } }

    static func sortedUTF16(_ values: [String]) -> [String] { values.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) } }

    // MARK: Paths

    private enum Pattern {
        case root, device(String), log(author: String, seq: Int), pdf(hash: String), asset(hash: String)
        /// `page` is nil when its digits overflow; that file is unreadable rather than ignored.
        case ink(doc: String, page: Int?, author: String, seq: Int)
        case note(doc: String, author: String, seq: Int)
    }

    /// Byte-wise so a path matches here exactly when it matches the desktop's ASCII patterns.
    private static func pattern(_ path: String) -> Pattern? {
        let parts = path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).map { Array($0)[...] }
        switch (parts.first.map(ascii), parts.count) {
        case ("bandal.json", 1):
            return .root
        case ("devices", 2):
            guard let id = strip(parts[1], ".json"), isUUID(id) else { return nil }
            return .device(ascii(id))
        case ("log", 3):
            guard isUUID(parts[1]), let file = strip(parts[2], ".json"), let seq = sequence(file) else { return nil }
            return .log(author: ascii(parts[1]), seq: seq)
        case ("pdf", 2):
            guard let hash = strip(parts[1], ".pdf"), isSHA(hash) else { return nil }
            return .pdf(hash: ascii(hash))
        case ("assets", 2):
            let file = parts[1], start = file.startIndex
            guard file.count > 65, isSHA(file.prefix(64)), file[start + 64] == UInt8(ascii: "."), isExt(file.dropFirst(65)) else { return nil }
            return .asset(hash: ascii(file.prefix(64)))
        case ("ink", 4):
            guard isUUID(parts[1]), isPage(parts[2]), let file = strip(parts[3], ".json.gz"), let writer = writer(file) else { return nil }
            return .ink(doc: ascii(parts[1]), page: Int(ascii(parts[2])), author: writer.author, seq: writer.seq)
        case ("notes", 3):
            guard isUUID(parts[1]), let file = strip(parts[2], ".md"), let writer = writer(file) else { return nil }
            return .note(doc: ascii(parts[1]), author: writer.author, seq: writer.seq)
        default:
            return nil
        }
    }

    private static func ascii(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

    private static func strip(_ part: ArraySlice<UInt8>, _ suffix: String) -> ArraySlice<UInt8>? {
        let tail = Array(suffix.utf8)
        return part.count > tail.count && part.suffix(tail.count).elementsEqual(tail) ? part.dropLast(tail.count) : nil
    }

    /// `<device_id>-<seq 8 digits>`
    private static func writer(_ stem: ArraySlice<UInt8>) -> (author: String, seq: Int)? {
        guard stem.count == 45, stem[stem.startIndex + 36] == UInt8(ascii: "-"), isUUID(stem.prefix(36)), let seq = sequence(stem.suffix(8)) else { return nil }
        return (ascii(stem.prefix(36)), seq)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { UInt8(ascii: "0")...UInt8(ascii: "9") ~= byte }
    private static func isHex(_ byte: UInt8) -> Bool { isDigit(byte) || UInt8(ascii: "a")...UInt8(ascii: "f") ~= byte }
    private static func isUUID(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.count == 36 && bytes.enumerated().allSatisfy { offset, byte in [8, 13, 18, 23].contains(offset) ? byte == UInt8(ascii: "-") : isHex(byte) }
    }
    private static func isSHA(_ bytes: ArraySlice<UInt8>) -> Bool { bytes.count == 64 && bytes.allSatisfy(isHex) }
    private static func isExt(_ bytes: ArraySlice<UInt8>) -> Bool { (1...16).contains(bytes.count) && bytes.allSatisfy { isDigit($0) || UInt8(ascii: "a")...UInt8(ascii: "z") ~= $0 } }
    private static func sequence(_ bytes: ArraySlice<UInt8>) -> Int? { bytes.count == 8 && bytes.allSatisfy(isDigit) ? Int(ascii(bytes)) : nil }
    private static func isPage(_ bytes: ArraySlice<UInt8>) -> Bool { bytes.first.map { UInt8(ascii: "1")...UInt8(ascii: "9") ~= $0 } == true && bytes.allSatisfy(isDigit) }

    // MARK: Values

    private enum Item<T> { case keep(T), drop, skip }

    private static func items<T>(_ value: Any, _ check: (Any, Int) -> Item<T>) throws -> ([T], Int) {
        guard let array = value as? [Any] else { throw Unreadable(reason: "not an array") }
        var kept: [T] = [], dropped = 0
        for (index, item) in array.enumerated() {
            switch check(item, index) {
            case .keep(let value): kept.append(value)
            case .drop: dropped += 1
            case .skip: break
            }
        }
        return (kept, dropped)
    }

    private static func json(_ data: Data, limit: Int) throws -> Any {
        guard data.count <= limit else { throw Unreadable(reason: "file is over its size limit") }
        do { return try SyncJSON.parse(data) } catch { throw Unreadable(reason: "invalid JSON") }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
    private static func whole(_ value: Any?) -> Double? { number(value).flatMap { $0.rounded(.towardZero) == $0 ? $0 : nil } }
    private static func safeInteger(_ value: Any?) -> Int? { whole(value).flatMap { abs($0) <= 9_007_199_254_740_991 ? Int($0) : nil } }
    private static func stamp(_ value: Any?) -> Int64? { whole(value).flatMap { $0 >= 0 && $0 < Double(maxStamp) ? Int64($0) : nil } }
    private static func isBoolean(_ value: Any?) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

    private static func validSegment<S: Collection>(_ segment: S) -> Bool where S.Element == Unicode.Scalar {
        !segment.isEmpty && !segment.elementsEqual(".".unicodeScalars) && !segment.elementsEqual("..".unicodeScalars)
            && !segment.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// File name with extension: one path segment. `\`, `:` and other names Windows cannot
    /// store are legal here; each platform's apply step maps them to safe local names.
    private static func isDocName(_ value: Any?) -> Bool {
        guard let name = value as? String else { return false }
        return !name.unicodeScalars.contains("/") && validSegment(name.unicodeScalars)
    }

    /// Folder inside the course: `""` or relative `/`-separated segments, never `..` or absolute.
    private static func isDocFolder(_ value: Any?) -> Bool {
        guard let folder = value as? String else { return false }
        return folder.isEmpty || folder.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).allSatisfy(validSegment)
    }

    private static func courseFields(_ fields: [String: Any]) -> [String: Any]? {
        if let name = fields["name"], !(name is String) { return nil }
        if let sort = fields["sort"], number(sort) == nil { return nil }
        if let color = fields["color"], !(color is String) { return nil }
        if let archived = fields["archived"], !isBoolean(archived) { return nil }
        return fields
    }

    private static func docFields(_ fields: [String: Any]) -> [String: Any]? {
        var result = fields
        if let name = fields["name"] as? String { result["name"] = name.precomposedStringWithCanonicalMapping }
        if let folder = fields["rel_path"] as? String { result["rel_path"] = folder.precomposedStringWithCanonicalMapping }
        if let course = fields["course_id"], uuid(course) == nil { return nil }
        if let type = fields["type"], type as? String != "pdf", type as? String != "md" { return nil }
        if let name = result["name"], !isDocName(name) { return nil }
        if let folder = result["rel_path"], !isDocFolder(folder) { return nil }
        if let hash = fields["pdf_sha256"], sha(hash) == nil { return nil }
        if let hash = fields["md_hash"], sha(hash) == nil { return nil }
        if let base = fields["md_base"], !(base is NSNull), sha(base) == nil { return nil }
        return result
    }

    /// A known op with a bad stamp, id or field value is dropped; unknown ops are skipped unread.
    private static func event(_ value: Any, index: Int) -> Item<Event> {
        guard let value = value as? [String: Any], let op = value["op"] as? String else { return .drop }
        guard knownOps.contains(op) else { return .skip }
        guard let t = stamp(value["t"]), let id = uuid(value["id"]) else { return .drop }
        guard let raw = (value["fields"].flatMap { $0 is NSNull ? nil : $0 } ?? [String: Any]()) as? [String: Any] else { return .drop }
        let fields = op == "course.upsert" ? courseFields(raw) : op == "doc.upsert" ? docFields(raw) : raw
        return fields.map { .keep(Event(t: t, op: op, id: id, fields: $0, index: index)) } ?? .drop
    }

    private static func inkObject(_ value: Any, index: Int) -> Item<InkObject> {
        guard let object = value as? [String: Any], let id = uuid(object["id"]), let t = stamp(object["t"]),
              let page = whole(object["page"]), page >= 1, page <= Double(maxPage) else { return .drop }
        if let del = object["del"] {
            guard isBoolean(del), (del as! NSNumber).boolValue else { return .drop }
        } else {
            guard object["kind"] is String, stamp(object["created"]) != nil,
                  let data = object["data"] as? [String: Any], object["style"] is [String: Any] else { return .drop }
            if let image = data["image"] {
                guard let image = image as? [String: Any], sha(image["sha256"]) != nil, ext(image["ext"]) != nil else { return .drop }
            }
        }
        return .keep(InkObject(id: id, page: Int(page), t: t, index: index, value: object))
    }

    // MARK: Content

    /// Reads gzip the way Node's `gunzipSync` does: concatenated members are read in
    /// turn, and trailing bytes that start with a zero byte are padding.
    private static func gunzip(_ data: Data, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Unreadable(reason: "gzip") }
        defer { inflateEnd(&stream) }
        var output = Data(), chunk = [UInt8](repeating: 0, count: 1 << 16)
        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: chunk[..<(chunk.count - Int(stream.avail_out))])
                guard output.count <= limit else { throw Unreadable(reason: "ink is over its size limit") }
                if status == Z_STREAM_END {
                    guard stream.avail_in > 0, stream.next_in.pointee != 0 else { return }
                    guard inflateReset(&stream) == Z_OK else { throw Unreadable(reason: "gzip") }
                } else if status != Z_OK {
                    throw Unreadable(reason: "gzip")
                }
            }
        }
        return output
    }

    /// Same matches as the desktop's global `/\.\.\/\.\.\/assets\/([0-9a-f]{64})\.([a-z0-9]{1,16})/`.
    private static func noteAssets(_ data: Data) -> [String] {
        let bytes = [UInt8](data), marker = Array("../../assets/".utf8)
        var found = Set<String>(), index = 0
        while index + marker.count + 66 <= bytes.count {
            let hash = index + marker.count, dot = hash + 64
            guard bytes[index] == UInt8(ascii: "."), bytes[index..<hash].elementsEqual(marker),
                  isSHA(bytes[hash..<dot]), bytes[dot] == UInt8(ascii: ".") else { index += 1; continue }
            var end = dot + 1
            while end < bytes.count, end - dot <= 16, isExt(bytes[end...end]) { end += 1 }
            guard end > dot + 1 else { index += 1; continue }
            found.insert("assets/" + ascii(bytes[hash..<end]))
            index = end
        }
        return found.sorted()
    }
}
