import Foundation

/// JSON from the sync root, read the way the desktop's `JSON.parse` reads it so
/// both apps accept the same files: strict RFC 8259 (no BOM, no trailing comma,
/// whitespace is space, tab, CR and LF only), every number a double, and a
/// repeated key keeps its last value. Foundation's parser differs on each of
/// these. Invalid UTF-8, unpaired surrogates and nesting deeper than `maxDepth`
/// are rejected, as spec v2.2 requires.
enum SyncJSON {
    static let maxDepth = 64

    struct Invalid: Error {}

    /// A larger `maxDepth` is for trusted data only, such as a fixture's `expected.json` that embeds a 64-deep drawing.
    static func parse(_ data: Data, maxDepth: Int = SyncJSON.maxDepth) throws -> Any {
        try data.withUnsafeBytes { raw in
            var reader = Reader(bytes: raw.bindMemory(to: UInt8.self), maxDepth: maxDepth)
            let value = try reader.value(depth: 0)
            reader.skipSpace()
            guard reader.index == reader.bytes.count else { throw Invalid() }
            return value
        }
    }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1; return true
        }

        mutating func value(depth: Int) throws -> Any {
            skipSpace()
            guard index < bytes.count else { throw Invalid() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth + 1)
            case UInt8(ascii: "["): return try array(depth: depth + 1)
            case UInt8(ascii: "\""): return try string()
            case UInt8(ascii: "t"): try literal("true"); return NSNumber(value: true)
            case UInt8(ascii: "f"): try literal("false"); return NSNumber(value: false)
            case UInt8(ascii: "n"): try literal("null"); return NSNull()
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 { guard consume(byte) else { throw Invalid() } }
        }

        mutating func object(depth: Int) throws -> [String: Any] {
            guard depth <= maxDepth else { throw Invalid() }
            index += 1
            var result: [String: Any] = [:]
            skipSpace()
            if consume(UInt8(ascii: "}")) { return result }
            repeat {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw Invalid() }
                let key = try string()
                skipSpace()
                guard consume(UInt8(ascii: ":")) else { throw Invalid() }
                result[key] = try value(depth: depth)
                skipSpace()
            } while consume(UInt8(ascii: ","))
            guard consume(UInt8(ascii: "}")) else { throw Invalid() }
            return result
        }

        mutating func array(depth: Int) throws -> [Any] {
            guard depth <= maxDepth else { throw Invalid() }
            index += 1
            var result: [Any] = []
            skipSpace()
            if consume(UInt8(ascii: "]")) { return result }
            repeat {
                result.append(try value(depth: depth))
                skipSpace()
            } while consume(UInt8(ascii: ","))
            guard consume(UInt8(ascii: "]")) else { throw Invalid() }
            return result
        }

        mutating func string() throws -> String {
            index += 1
            var buffer: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    guard let text = String(bytes: buffer, encoding: .utf8) else { throw Invalid() }
                    return text
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw Invalid() }
                    let escape = bytes[index]; index += 1
                    switch escape {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): buffer.append(escape)
                    case UInt8(ascii: "b"): buffer.append(0x08)
                    case UInt8(ascii: "f"): buffer.append(0x0C)
                    case UInt8(ascii: "n"): buffer.append(0x0A)
                    case UInt8(ascii: "r"): buffer.append(0x0D)
                    case UInt8(ascii: "t"): buffer.append(0x09)
                    case UInt8(ascii: "u"): buffer.append(contentsOf: String(try escapedScalar()).utf8)
                    default: throw Invalid()
                    }
                case 0x00..<0x20: throw Invalid()
                default: buffer.append(byte)
                }
            }
            throw Invalid()
        }

        /// `\uXXXX` after the `u`; a surrogate must come as a high-low pair.
        mutating func escapedScalar() throws -> Unicode.Scalar {
            let unit = try hex4()
            var value = UInt32(unit)
            if (0xD800...0xDBFF).contains(unit) {
                guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")) else { throw Invalid() }
                let low = try hex4()
                guard (0xDC00...0xDFFF).contains(low) else { throw Invalid() }
                value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(value) else { throw Invalid() }
            return scalar
        }

        mutating func hex4() throws -> UInt16 {
            guard index + 4 <= bytes.count else { throw Invalid() }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[index]; index += 1
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): value = value << 4 | UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): value = value << 4 | UInt16(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): value = value << 4 | UInt16(byte - UInt8(ascii: "A") + 10)
                default: throw Invalid()
                }
            }
            return value
        }

        mutating func digits() -> Bool {
            let start = index
            while index < bytes.count, UInt8(ascii: "0")...UInt8(ascii: "9") ~= bytes[index] { index += 1 }
            return index > start
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, rounded to the nearest double as JavaScript does.
        mutating func number() throws -> NSNumber {
            let start = index
            _ = consume(UInt8(ascii: "-"))
            if !consume(UInt8(ascii: "0")) {
                guard index < bytes.count, UInt8(ascii: "1")...UInt8(ascii: "9") ~= bytes[index], digits() else { throw Invalid() }
            }
            if consume(UInt8(ascii: ".")) { guard digits() else { throw Invalid() } }
            if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
                _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
                guard digits() else { throw Invalid() }
            }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
            guard let value = Double(text), value.isFinite else { throw Invalid() }
            return NSNumber(value: value)
        }
    }
}
