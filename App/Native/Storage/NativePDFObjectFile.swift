import Foundation
import zlib

/// A read-only view of a PDF's objects by number: the lexer, the cross-reference
/// chain (tables, streams, hybrid files, `/Prev` updates) and object streams.
/// CGPDF hides object numbers, which an incremental update has to name.
/// Anything this reader does not understand throws; callers fall back.
final class NativePDFObjectFile {
    struct Unsupported: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    struct Reference: Hashable { let number: Int; let generation: Int }
    enum Entry: Equatable { case free, offset(Int, generation: Int), compressed(stream: Int, index: Int) }
    struct Dictionary: Equatable {
        var entries: [(key: Data, value: Value)] = []
        subscript(_ key: String) -> Value? {
            get { let name = Data(key.utf8); return entries.first { $0.key == name }?.value }
            set {
                let name = Data(key.utf8)
                if let index = entries.firstIndex(where: { $0.key == name }) {
                    if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
                } else if let newValue { entries.append((name, newValue)) }
            }
        }
        var keys: [String] { entries.map { String(decoding: $0.key, as: UTF8.self) } }
        func removing(_ keys: Set<String>) -> Dictionary {
            Dictionary(entries: entries.filter { !keys.contains(String(decoding: $0.key, as: UTF8.self)) })
        }
        static func == (a: Dictionary, b: Dictionary) -> Bool {
            guard a.entries.count == b.entries.count else { return false }
            let sorted = { (d: Dictionary) in d.entries.sorted { $0.key.lexicographicallyPrecedes($1.key) } }
            return zip(sorted(a), sorted(b)).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        }
    }
    indirect enum Value: Equatable {
        case null, boolean(Bool), integer(Int), real(Data), name(Data), string(Data)
        case array([Value]), dictionary(Dictionary), reference(Reference)
        /// A stream object: its dictionary and the raw (still encoded) data range in the file.
        case stream(Dictionary, Range<Int>)
        var dictionary: Dictionary? {
            switch self { case .dictionary(let d), .stream(let d, _): return d; default: return nil }
        }
        var reference: Reference? { if case .reference(let r) = self { return r }; return nil }
        var integer: Int? { if case .integer(let n) = self { return n }; return nil }
        var array: [Value]? { if case .array(let a) = self { return a }; return nil }
        var name: String? { if case .name(let n) = self { return String(decoding: n, as: UTF8.self) }; return nil }
        var number: Double? {
            switch self {
            case .integer(let n): return Double(n)
            case .real(let raw): return Double(String(decoding: raw, as: UTF8.self))
            default: return nil
            }
        }
    }

    static let maximumBytes = 512 * 1024 * 1024
    let bytes: [UInt8]
    private(set) var entries: [Int: Entry] = [:]
    private(set) var trailer = Dictionary()
    /// The newest section is a cross-reference stream (not a classic table).
    private(set) var newestIsStream = false
    /// `startxref` of the newest section: an update's `/Prev`.
    private(set) var startxref = 0
    private var cache: [Int: Value] = [:]
    private var objectStreams: [Int: (data: [UInt8], offsets: [Int: Int], first: Int)] = [:]
    private var resolving = Set<Int>()

    init(_ data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw Unsupported("file too large") }
        bytes = [UInt8](data)
        guard bytes.starts(with: Array("%PDF-".utf8)) || Self.find(Array("%PDF-".utf8), in: bytes, from: 0, limit: 1024) != nil else { throw Unsupported("no header") }
        do {
            startxref = try findStartXRef()
            var seen = Set<Int>(), offset: Int? = startxref, first = true
            while let at = offset {
                guard seen.insert(at).inserted, seen.count <= 4096 else { throw Unsupported("xref loop") }
                let (section, sectionTrailer, isStream) = try readSection(at: at)
                for (number, entry) in section where entries[number] == nil { entries[number] = entry }
                if first { trailer = sectionTrailer; newestIsStream = isStream; first = false }
                offset = sectionTrailer["Prev"]?.integer
            }
            guard trailer["Root"]?.reference != nil else { throw Unsupported("no root") }
            // A table that points at the wrong bytes is as broken as no table.
            if let root = trailer["Root"]?.reference { _ = try object(root) }
        } catch let error as Unsupported where error.description != "encrypted" {
            // PDFKit opens these silently by scanning; do the same, and the
            // update then carries a complete cross-reference (no /Prev).
            try repair(after: error)
        }
        guard trailer["Encrypt"] == nil else { throw Unsupported("encrypted") }
        guard trailer["Root"]?.reference != nil else { throw Unsupported("no root") }
    }
    /// True when the cross-reference was rebuilt by scanning for objects.
    private(set) var repaired = false

    private func repair(after error: Unsupported) throws {
        entries = [:]; cache = [:]; objectStreams = [:]; trailer = Dictionary(); repaired = true; startxref = 0
        var streams: [Int] = [], trailers: [(Int, Dictionary)] = [], at = 0
        let keyword = Array("obj".utf8)
        while let found = Self.find(keyword, in: bytes, from: at, limit: Self.maximumBytes) {
            at = found + keyword.count
            // "N G obj" with N and G right before the keyword.
            var cursor = found - 1
            func skipBack(_ predicate: (UInt8) -> Bool) -> Int { let end = cursor; while cursor >= 0, predicate(bytes[cursor]) { cursor -= 1 }; return end - cursor }
            guard skipBack(Lexer.isSpace) > 0, skipBack({ (48...57).contains($0) }) > 0, skipBack(Lexer.isSpace) > 0, skipBack({ (48...57).contains($0) }) > 0,
                  cursor < 0 || Lexer.isSpace(bytes[cursor]) || Lexer.isDelimiter(bytes[cursor]) else { continue }
            var lexer = Lexer(bytes, at: cursor + 1)
            guard case .integer(let number)? = try? lexer.token(), case .integer(let generation)? = try? lexer.token(),
                  case .keyword("obj")? = try? lexer.token(), number > 0, let value = try? lexer.value() else { continue }
            entries[number] = .offset(cursor + 1, generation: generation)
            let mark = lexer.position
            if case .keyword("stream")? = try? lexer.token(), case .dictionary(let d) = value, let range = try? streamRange(d, after: lexer.position, number: number) {
                if d["Type"]?.name == "ObjStm" { streams.append(number) }
                if d["Type"]?.name == "XRef", d["Root"] != nil { trailers.append((cursor, d)) }
                at = max(at, range.upperBound)
            } else { lexer.position = mark }
        }
        var search = 0
        let word = Array("trailer".utf8)
        while let found = Self.find(word, in: bytes, from: search, limit: Self.maximumBytes) {
            search = found + word.count
            var lexer = Lexer(bytes, at: search)
            if case .dictionary(let d)? = try? lexer.value(), d["Root"] != nil { trailers.append((found, d)) }
        }
        for number in streams {
            guard case .stream(let d, let range) = try object(number), let count = d["N"]?.integer, count >= 0, count < 1_000_000, let data = try? decode(d, range) else { continue }
            var lexer = Lexer(data, at: 0)
            for index in 0..<count {
                guard case .integer(let n)? = try? lexer.token(), case .integer? = try? lexer.token() else { break }
                if entries[n] == nil { entries[n] = .compressed(stream: number, index: index) }
            }
        }
        cache = [:]
        guard let last = trailers.max(by: { $0.0 < $1.0 })?.1 else { throw Unsupported("unrepairable (\(error.description))") }
        trailer = last.removing(["Prev", "XRefStm", "Type", "W", "Index", "Length", "Filter", "DecodeParms"])
        newestIsStream = !streams.isEmpty
    }

    var size: Int { max(trailer["Size"]?.integer ?? 0, (entries.keys.max() ?? 0) + 1) }

    // MARK: objects

    func object(_ reference: Reference) throws -> Value { try object(reference.number) }
    func object(_ number: Int) throws -> Value {
        if let cached = cache[number] { return cached }
        guard resolving.insert(number).inserted, resolving.count < 64 else { throw Unsupported("reference cycle") }
        defer { resolving.remove(number) }
        let value: Value
        switch entries[number] {
        case nil, .free?: value = .null
        case .offset(let offset, _)?: value = try indirect(at: offset, number: number)
        case .compressed(let stream, let index)?: value = try compressed(number, in: stream, index: index)
        }
        if cache.count > 50_000 { cache.removeAll() }
        cache[number] = value
        return value
    }
    func resolve(_ value: Value?) throws -> Value? {
        guard let value else { return nil }
        if case .reference(let r) = value { return try object(r) }
        return value
    }
    func resolvedDictionary(_ value: Value?) throws -> Dictionary? { try resolve(value)?.dictionary }

    private func indirect(at offset: Int, number: Int) throws -> Value {
        guard offset >= 0, offset < bytes.count else { throw Unsupported("offset out of range") }
        var lexer = Lexer(bytes, at: offset)
        guard case .integer(let found)? = try lexer.token(), found == number, case .integer? = try lexer.token(),
              case .keyword("obj")? = try lexer.token() else { throw Unsupported("object \(number) not at its offset") }
        let value = try lexer.value()
        let mark = lexer.position
        if case .keyword("stream")? = try lexer.token(), case .dictionary(let dictionary) = value {
            return .stream(dictionary, try streamRange(dictionary, after: lexer.position, number: number))
        }
        lexer.position = mark
        return value
    }
    private func streamRange(_ dictionary: Dictionary, after keyword: Int, number: Int?) throws -> Range<Int> {
        var start = keyword
        if start < bytes.count, bytes[start] == 13 { start += 1 }
        if start < bytes.count, bytes[start] == 10 { start += 1 }
        var length: Int?
        switch dictionary["Length"] {
        case .integer(let n)?: length = n
        case .reference(let r)? where r.number != number && !resolving.contains(r.number): length = try? object(r).integer
        default: length = nil
        }
        if let length, length >= 0, start + length <= bytes.count {
            var lexer = Lexer(bytes, at: start + length)
            if case .keyword("endstream")? = try? lexer.token() { return start..<(start + length) }
        }
        // A wrong /Length: the data runs to the EOL before `endstream`.
        guard let end = Self.find(Array("endstream".utf8), in: bytes, from: start, limit: Self.maximumBytes) else { throw Unsupported("unterminated stream") }
        var stop = end
        if stop > start, bytes[stop - 1] == 10 { stop -= 1 }
        if stop > start, bytes[stop - 1] == 13 { stop -= 1 }
        return start..<stop
    }
    private func compressed(_ number: Int, in stream: Int, index: Int) throws -> Value {
        if objectStreams[stream] == nil {
            guard case .stream(let dictionary, let range) = try object(stream), dictionary["Type"]?.name == "ObjStm",
                  let count = dictionary["N"]?.integer, let first = dictionary["First"]?.integer, count >= 0, count <= 1_000_000 else { throw Unsupported("bad object stream") }
            let data = try decode(dictionary, range)
            var lexer = Lexer(data, at: 0), offsets: [Int: Int] = [:]
            for _ in 0..<count {
                guard case .integer(let n)? = try lexer.token(), case .integer(let o)? = try lexer.token() else { throw Unsupported("bad object stream header") }
                if offsets[n] == nil { offsets[n] = o }
            }
            objectStreams[stream] = (data, offsets, first)
            if objectStreams.count > 256 { objectStreams = [stream: objectStreams[stream]!] }
        }
        guard let entry = objectStreams[stream], let offset = entry.offsets[number] else { throw Unsupported("object \(number) missing from its stream") }
        var lexer = Lexer(entry.data, at: entry.first + offset)
        return try lexer.value()
    }

    /// Stream bytes after its filters: Flate (with PNG/TIFF predictors) only.
    func decode(_ dictionary: Dictionary, _ range: Range<Int>) throws -> [UInt8] {
        var filters: [String] = [], parameters: [Dictionary?] = []
        switch try resolve(dictionary["Filter"]) {
        case nil, .null?: break
        case .name(let n)?: filters = [String(decoding: n, as: UTF8.self)]
        case .array(let a)?: filters = try a.map { guard let n = try resolve($0)?.name else { throw Unsupported("filter") }; return n }
        default: throw Unsupported("filter")
        }
        switch try resolve(dictionary["DecodeParms"]) {
        case nil, .null?: parameters = filters.map { _ in nil }
        case .dictionary(let d)?: parameters = [d]
        case .array(let a)?: parameters = try a.map { try resolvedDictionary($0) }
        default: throw Unsupported("decode parameters")
        }
        var data = Array(bytes[range])
        for (index, filter) in filters.enumerated() {
            guard filter == "FlateDecode" || filter == "Fl" else { throw Unsupported("filter \(filter)") }
            data = try Self.inflate(data)
            if let p = parameters.indices.contains(index) ? parameters[index] : nil { data = try Self.unpredict(data, p) }
        }
        return data
    }
    static func inflate(_ input: [UInt8]) throws -> [UInt8] {
        for windowBits: Int32 in [15, -15] {
            var stream = z_stream(), output: [UInt8] = []
            guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { continue }
            defer { inflateEnd(&stream) }
            var status: Int32 = Z_OK
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            input.withUnsafeBufferPointer { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
                stream.avail_in = uInt(source.count)
                repeat {
                    chunk.withUnsafeMutableBufferPointer { buffer in
                        stream.next_out = buffer.baseAddress; stream.avail_out = uInt(buffer.count)
                        status = zlib.inflate(&stream, Z_NO_FLUSH)
                        output.append(contentsOf: buffer[0..<(buffer.count - Int(stream.avail_out))])
                    }
                } while status == Z_OK && output.count < maximumBytes
            }
            // Truncated streams are common; keep what inflated.
            if status == Z_STREAM_END || (status == Z_BUF_ERROR && !output.isEmpty) { return output }
        }
        throw Unsupported("inflate")
    }
    static func unpredict(_ data: [UInt8], _ parameters: Dictionary) throws -> [UInt8] {
        let predictor = parameters["Predictor"]?.integer ?? 1
        guard predictor > 1 else { return data }
        let colors = parameters["Colors"]?.integer ?? 1, bits = parameters["BitsPerComponent"]?.integer ?? 8, columns = parameters["Columns"]?.integer ?? 1
        guard (1...32).contains(colors), [1, 2, 4, 8, 16].contains(bits), (1...1_000_000).contains(columns) else { throw Unsupported("predictor parameters") }
        let pixel = max(1, colors * bits / 8), row = (colors * bits * columns + 7) / 8
        if predictor == 2 {
            guard bits == 8 else { throw Unsupported("tiff predictor") }
            var out = data
            for start in stride(from: 0, to: out.count, by: row) {
                for i in (start + pixel)..<min(start + row, out.count) { out[i] = out[i] &+ out[i - pixel] }
            }
            return out
        }
        guard predictor >= 10 else { throw Unsupported("predictor \(predictor)") }
        var out: [UInt8] = [], previous = [UInt8](repeating: 0, count: row), at = 0
        out.reserveCapacity(data.count)
        while at < data.count {
            let type = data[at]; at += 1
            var line = Array(data[at..<min(at + row, data.count)]); at += row
            if line.count < row { line += [UInt8](repeating: 0, count: row - line.count) }
            for i in 0..<row {
                let left = i >= pixel ? line[i - pixel] : 0, up = previous[i], corner = i >= pixel ? previous[i - pixel] : 0
                switch type {
                case 0: break
                case 1: line[i] = line[i] &+ left
                case 2: line[i] = line[i] &+ up
                case 3: line[i] = line[i] &+ UInt8((Int(left) + Int(up)) / 2)
                case 4:
                    let p = Int(left) + Int(up) - Int(corner), pa = abs(p - Int(left)), pb = abs(p - Int(up)), pc = abs(p - Int(corner))
                    line[i] = line[i] &+ (pa <= pb && pa <= pc ? left : pb <= pc ? up : corner)
                default: throw Unsupported("png predictor \(type)")
                }
            }
            out += line; previous = line
        }
        return out
    }

    // MARK: cross-reference sections

    private func findStartXRef() throws -> Int {
        let keyword = Array("startxref".utf8)
        var at = bytes.count - keyword.count
        let stop = max(0, bytes.count - 64 * 1024)
        while at >= stop {
            if bytes[at] == keyword[0], Array(bytes[at..<(at + keyword.count)]) == keyword {
                var lexer = Lexer(bytes, at: at + keyword.count)
                if case .integer(let n)? = try? lexer.token(), n >= 0, n < bytes.count { return n }
                throw Unsupported("bad startxref")
            }
            at -= 1
        }
        throw Unsupported("no startxref")
    }
    private func readSection(at offset: Int) throws -> ([Int: Entry], Dictionary, Bool) {
        var lexer = Lexer(bytes, at: offset)
        let mark = lexer.position
        if case .keyword("xref")? = try lexer.token() {
            var section: [Int: Entry] = [:]
            while true {
                let at = lexer.position
                guard let token = try lexer.token() else { throw Unsupported("truncated xref") }
                if case .keyword("trailer") = token { break }
                guard case .integer(let first) = token, case .integer(let count)? = try lexer.token(), first >= 0, count >= 0, count <= 10_000_000 else {
                    lexer.position = at; throw Unsupported("bad xref subsection")
                }
                for index in 0..<count {
                    guard case .integer(let a)? = try lexer.token(), case .integer(let generation)? = try lexer.token(),
                          case .keyword(let kind)? = try lexer.token(), kind == "n" || kind == "f" else { throw Unsupported("bad xref entry") }
                    let number = first + index
                    if section[number] == nil { section[number] = kind == "n" && a > 0 ? .offset(a, generation: generation) : .free }
                }
            }
            guard case .dictionary(let trailer) = try lexer.value() else { throw Unsupported("bad trailer") }
            // Hybrid files list compressed objects only in the stream (§7.5.8.4).
            if let stream = trailer["XRefStm"]?.integer {
                let (extra, _, _) = try readSection(at: stream)
                for (number, entry) in extra where section[number] == nil || section[number] == .free { section[number] = entry }
            }
            return (section, trailer, false)
        }
        lexer.position = mark
        guard case .integer? = try lexer.token(), case .integer? = try lexer.token(), case .keyword("obj")? = try lexer.token(),
              case .dictionary(let dictionary) = try lexer.value(), case .keyword("stream")? = try lexer.token(),
              dictionary["Type"]?.name == "XRef" else { throw Unsupported("startxref points to neither a table nor a stream") }
        let data = try decode(dictionary, try streamRange(dictionary, after: lexer.position, number: nil))
        guard let widths = dictionary["W"]?.array?.compactMap(\.integer), widths.count == 3, widths.allSatisfy({ (0...8).contains($0) }),
              let size = dictionary["Size"]?.integer else { throw Unsupported("bad xref stream") }
        let index = dictionary["Index"]?.array?.compactMap(\.integer) ?? [0, size]
        guard index.count % 2 == 0 else { throw Unsupported("bad xref index") }
        let entryLength = widths.reduce(0, +)
        guard entryLength > 0 else { throw Unsupported("bad xref widths") }
        var section: [Int: Entry] = [:], at = 0
        func field(_ width: Int, default value: Int) -> Int {
            guard width > 0 else { return value }
            var result = 0
            for _ in 0..<width { result = result << 8 | Int(data[at]); at += 1 }
            return result
        }
        for pair in stride(from: 0, to: index.count, by: 2) {
            for number in index[pair]..<(index[pair] + index[pair + 1]) {
                guard at + entryLength <= data.count else { throw Unsupported("short xref stream") }
                let type = field(widths[0], default: 1), a = field(widths[1], default: 0), b = field(widths[2], default: 0)
                guard section[number] == nil else { continue }
                switch type {
                case 0: section[number] = .free
                case 1: section[number] = .offset(a, generation: b)
                case 2: section[number] = .compressed(stream: a, index: b)
                default: break // reserved: treat as absent
                }
            }
        }
        return (section, dictionary, true)
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int, limit: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var at = start
        let end = min(haystack.count - needle.count, start + limit)
        while at <= end {
            if haystack[at] == needle[0] {
                var match = true
                for k in 1..<needle.count where haystack[at + k] != needle[k] { match = false; break }
                if match { return at }
            }
            at += 1
        }
        return nil
    }

    // MARK: lexer

    enum Token: Equatable {
        case integer(Int), real(Data), name(Data), string(Data), keyword(String)
        case arrayOpen, arrayClose, dictionaryOpen, dictionaryClose
    }
    struct Lexer {
        let bytes: [UInt8]
        var position: Int
        private var depth = 0
        init(_ bytes: [UInt8], at position: Int) { self.bytes = bytes; self.position = position }
        static func isSpace(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
        static func isDelimiter(_ c: UInt8) -> Bool { [40, 41, 60, 62, 91, 93, 123, 125, 47, 37].contains(c) }
        mutating func skip() {
            while position < bytes.count {
                let c = bytes[position]
                if Self.isSpace(c) { position += 1 }
                else if c == 37 { while position < bytes.count, bytes[position] != 10, bytes[position] != 13 { position += 1 } }
                else { return }
            }
        }
        mutating func token() throws -> Token? {
            skip()
            guard position < bytes.count else { return nil }
            let start = position, c = bytes[position]
            switch c {
            case 91: position += 1; return .arrayOpen
            case 93: position += 1; return .arrayClose
            case 60:
                if position + 1 < bytes.count, bytes[position + 1] == 60 { position += 2; return .dictionaryOpen }
                guard let end = bytes[position...].firstIndex(of: 62) else { throw Unsupported("unterminated hex string") }
                position = end + 1; return .string(Data(bytes[start..<position]))
            case 62:
                guard position + 1 < bytes.count, bytes[position + 1] == 62 else { throw Unsupported("stray >") }
                position += 2; return .dictionaryClose
            case 40:
                var level = 0
                while position < bytes.count {
                    let b = bytes[position]
                    if b == 92 { position += 2; continue }
                    if b == 40 { level += 1 } else if b == 41 { level -= 1; if level == 0 { position += 1; return .string(Data(bytes[start..<position])) } }
                    position += 1
                }
                throw Unsupported("unterminated string")
            case 47:
                position += 1
                var name = Data()
                while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) {
                    if bytes[position] == 35, position + 2 < bytes.count, let h = Self.hex(bytes[position + 1]), let l = Self.hex(bytes[position + 2]) {
                        name.append(h << 4 | l); position += 3
                    } else { name.append(bytes[position]); position += 1 }
                }
                return .name(name)
            case 123, 125: position += 1; return .keyword(String(UnicodeScalar(c)))
            case 41: throw Unsupported("stray )")
            default:
                while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) { position += 1 }
                let raw = Data(bytes[start..<position])
                guard !raw.isEmpty else { position += 1; throw Unsupported("bad token") }
                let text = String(decoding: raw, as: UTF8.self)
                if raw.allSatisfy({ (48...57).contains($0) || $0 == 43 || $0 == 45 }), raw.contains(where: { (48...57).contains($0) }) {
                    if let n = Int(text) { return .integer(n) }
                    return .real(raw)
                }
                if raw.allSatisfy({ (48...57).contains($0) || $0 == 43 || $0 == 45 || $0 == 46 }), raw.contains(where: { (48...57).contains($0) }) { return .real(raw) }
                return .keyword(text)
            }
        }
        static func hex(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 65...70: return c - 55; case 97...102: return c - 87; default: return nil }
        }
        mutating func value() throws -> Value {
            guard let token = try token() else { throw Unsupported("unexpected end") }
            return try value(token)
        }
        mutating func value(_ token: Token) throws -> Value {
            depth += 1; defer { depth -= 1 }
            guard depth < 256 else { throw Unsupported("nesting too deep") }
            switch token {
            case .integer(let n):
                let mark = position
                if case .integer(let generation)? = try? self.token(), case .keyword("R")? = try? self.token(), n >= 0, generation >= 0 {
                    return .reference(Reference(number: n, generation: generation))
                }
                position = mark; return .integer(n)
            case .real(let raw): return .real(raw)
            case .name(let n): return .name(n)
            case .string(let raw): return .string(raw)
            case .keyword("true"): return .boolean(true)
            case .keyword("false"): return .boolean(false)
            case .keyword("null"): return .null
            case .arrayOpen:
                var items: [Value] = []
                while true {
                    guard let next = try self.token() else { throw Unsupported("unterminated array") }
                    if next == .arrayClose { return .array(items) }
                    items.append(try value(next))
                }
            case .dictionaryOpen:
                var dictionary = Dictionary()
                while true {
                    guard let next = try self.token() else { throw Unsupported("unterminated dictionary") }
                    if next == .dictionaryClose { return .dictionary(dictionary) }
                    guard case .name(let key) = next else { throw Unsupported("dictionary key") }
                    let mark = position
                    if let peek = try self.token(), peek == .dictionaryClose { dictionary.entries.append((key, .null)); return .dictionary(dictionary) }
                    position = mark
                    let item = try value()
                    if !dictionary.entries.contains(where: { $0.key == key }) { dictionary.entries.append((key, item)) }
                }
            default: throw Unsupported("unexpected token")
            }
        }
    }

    // MARK: serialization

    static func serialize(_ value: Value, into out: inout [UInt8]) throws {
        switch value {
        case .null: out += Array("null".utf8)
        case .boolean(let b): out += Array((b ? "true" : "false").utf8)
        case .integer(let n): out += Array(String(n).utf8)
        case .real(let raw), .string(let raw): out += raw
        case .name(let n): name(n, into: &out)
        case .reference(let r): out += Array("\(r.number) \(r.generation) R".utf8)
        case .array(let items):
            out.append(91)
            for (index, item) in items.enumerated() { if index > 0 { out.append(32) }; try serialize(item, into: &out) }
            out.append(93)
        case .dictionary(let d):
            out += Array("<<".utf8)
            for (key, item) in d.entries { out.append(32); name(key, into: &out); out.append(32); try serialize(item, into: &out) }
            out += Array(" >>".utf8)
        case .stream: throw Unsupported("streams are written by hand")
        }
    }
    static func name(_ bytes: Data, into out: inout [UInt8]) {
        out.append(47)
        for byte in bytes {
            if (33...126).contains(byte), ![35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) { out.append(byte) }
            else { out += Array(String(format: "#%02X", byte).utf8) }
        }
    }
}
