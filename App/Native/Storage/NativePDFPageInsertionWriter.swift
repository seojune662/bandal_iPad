import Foundation
import CoreGraphics
import zlib

/// Insertion does not require interpreting/repainting any original page. PDFKit's
/// writer does that and can change font encodings, image interpolation and groups.
/// This limited writer copies the parsed object graph, preserving sharing/cycles,
/// and changes only the page tree. Unsupported documents use the validated editor.
enum NativePDFPageInsertionWriter {
    static func write(_ source: Data, pages: [Int]) -> Data? {
        // CGPDF's C-name API cannot represent embedded NUL name bytes. A false
        // positive inside a stream only sends this document to the fallback.
        guard source.count <= 512 * 1024 * 1024, source.range(of: Data("#00".utf8)) == nil,
              pages.contains(0), let provider = CGDataProvider(data: source as CFData),
              let document = CGPDFDocument(provider), !document.isEncrypted,
              pages.filter({ $0 != 0 }) == Array(1...document.numberOfPages) else { return nil }
        return try? Writer(document: document, pages: pages).write()
    }

    private struct Unsupported: Error {}
    private final class Entries { var values: [(Data, CGPDFObjectRef)] = [] }
    private struct Identity: Hashable { let type: Int; let pointer: UInt }
    private enum Node {
        case catalog(CGPDFDictionaryRef), page(CGPDFDictionaryRef, inserted: Bool)
        case pages, dictionary(CGPDFDictionaryRef), array(CGPDFArrayRef), stream(CGPDFStreamRef)
    }
    private final class Writer {
        let document: CGPDFDocument
        let recipe: [Int]
        var nodes: [Node] = [.pages]
        var identities: [Identity: Int] = [:]
        var pageIDs: [Int] = []
        var output = Data()
        var decodedBytes = 0
        let maximumBytes = 512 * 1024 * 1024
        init(document: CGPDFDocument, pages: [Int]) { self.document = document; recipe = pages }

        func write() throws -> Data {
            guard let catalog = document.catalog else { throw Unsupported() }
            // Page labels/article threads need extra insertion semantics. Tagged
            // structure uses stable ParentTree keys and page object references;
            // those stay intact. New template pages intentionally have no tags.
            let supported: Set<String> = ["Type", "Pages", "Version", "Outlines", "Names", "Dests", "AcroForm", "Metadata", "ViewerPreferences", "PageLayout", "PageMode", "OpenAction", "Lang", "OCProperties", "StructTreeRoot", "MarkInfo"]
            guard entries(catalog).allSatisfy({ supported.contains(String(decoding: $0.0, as: UTF8.self)) }) else { throw Unsupported() }
            var names: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
               entries(names).contains(where: { $0.0 != Data("Dests".utf8) }) { throw Unsupported() }
            var major: Int32 = 0, minor: Int32 = 0
            document.getVersion(majorVersion: &major, minorVersion: &minor)
            guard major == 1, (0...7).contains(minor) else { throw Unsupported() }
            append("%PDF-\(major).\(minor)\n%\u{00e2}\u{00e3}\u{00cf}\u{00d3}\n")
            var originals: [(CGPDFDictionaryRef, Int)] = []
            for index in 1...document.numberOfPages {
                guard let dictionary = document.page(at: index)?.dictionary else { throw Unsupported() }
                let id = try register(.page(dictionary, inserted: false), identity: identity(dictionary))
                originals.append((dictionary, id))
            }
            for (index, page) in recipe.enumerated() {
                if page != 0 { pageIDs.append(originals[page - 1].1) }
                else {
                    let template = recipe[...index].last { $0 != 0 } ?? recipe.first { $0 != 0 } ?? 1
                    pageIDs.append(try register(.page(originals[template - 1].0, inserted: true)))
                }
            }
            let root = try register(.catalog(catalog), identity: identity(catalog))
            let info = try document.info.map { try reference(.dictionary($0), identity: identity($0)) }
            var offsets = [0], index = 0
            while index < nodes.count {
                guard output.count < maximumBytes else { throw Unsupported() }
                offsets.append(output.count); append("\(index + 1) 0 obj\n")
                try encode(nodes[index]); append("\nendobj\n"); index += 1
            }
            let xref = output.count
            append("xref\n0 \(nodes.count + 1)\n0000000000 65535 f \n")
            for offset in offsets.dropFirst() { append(String(format: "%010lld 00000 n \n", Int64(offset))) }
            append("trailer\n<< /Size \(nodes.count + 1) /Root \(root) 0 R")
            if let info { append(" /Info \(info)") }
            if let ids = document.fileIdentifier {
                // The trailer is emitted after xref; never enqueue new objects here.
                append(" /ID [")
                for index in 0..<CGPDFArrayGetCount(ids) {
                    var value: CGPDFStringRef?
                    guard CGPDFArrayGetString(ids, index, &value), let value else { throw Unsupported() }
                    try string(value); append(" ")
                }
                append("]")
            }
            append(" >>\nstartxref\n\(xref)\n%%EOF\n")
            return output
        }
        func register(_ node: Node, identity: Identity? = nil) throws -> Int {
            if let identity, let found = identities[identity] { return found }
            guard nodes.count < 200_000 else { throw Unsupported() }
            nodes.append(node); let id = nodes.count
            if let identity { identities[identity] = id }; return id
        }
        func reference(_ node: Node, identity: Identity) throws -> String { "\(try register(node, identity: identity)) 0 R" }
        func identity(_ ref: CGPDFDictionaryRef) -> Identity { Identity(type: 1, pointer: UInt(bitPattern: ref.rawValue)) }
        func identity(_ ref: CGPDFArrayRef) -> Identity { Identity(type: 2, pointer: UInt(bitPattern: ref.rawValue)) }
        func identity(_ ref: CGPDFStreamRef) -> Identity { Identity(type: 3, pointer: UInt(bitPattern: ref.rawValue)) }
        func append(_ text: String) { output.append(contentsOf: text.utf8) }
        func entries(_ dictionary: CGPDFDictionaryRef) -> [(Data, CGPDFObjectRef)] {
            let result = Entries()
            CGPDFDictionaryApplyFunction(dictionary, { key, value, raw in
                guard let raw else { return }
                Unmanaged<Entries>.fromOpaque(raw).takeUnretainedValue().values.append((Data(bytes: key, count: strlen(key)), value))
            }, Unmanaged.passUnretained(result).toOpaque())
            return result.values.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        }
        func dictionary(_ dictionary: CGPDFDictionaryRef, excluding: Set<String> = [], additional: () throws -> Void = {}) throws {
            append("<<")
            for (key, value) in entries(dictionary) where !excluding.contains(String(decoding: key, as: UTF8.self)) {
                append(" "); name(key); append(" "); try object(value)
            }
            try additional(); append(" >>")
        }
        func encode(_ node: Node) throws {
            switch node {
            case .pages:
                append("<< /Type /Pages /Count \(recipe.count) /Kids [")
                for id in pageIDs { append("\(id) 0 R ") }; append("] >>")
            case .catalog(let value):
                try dictionary(value, excluding: ["Pages"]) { append(" /Pages 1 0 R") }
            case .page(let value, let inserted):
                let inherited = ["Resources", "MediaBox", "CropBox", "Rotate"]
                var excluded: Set<String> = ["Parent"]
                if inserted { excluded.insert("Annots"); excluded.insert("StructParents"); excluded.insert("Tabs") }
                try dictionary(value, excluding: excluded) {
                    append(" /Parent 1 0 R")
                    for key in inherited {
                        var direct: CGPDFObjectRef?
                        if !CGPDFDictionaryGetObject(value, key, &direct), let object = try inheritedObject(key, page: value) {
                            append(" /\(key) "); try self.object(object)
                        }
                    }
                }
            case .dictionary(let value):
                var type: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(value, "Type", &type), let type,
                   String(cString: type) == "Pages" { throw Unsupported() }
                try dictionary(value)
            case .array(let value):
                let count = CGPDFArrayGetCount(value); guard count <= 200_000 else { throw Unsupported() }
                append("[")
                for index in 0..<count {
                    var child: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(value, index, &child), let child else { throw Unsupported() }
                    try object(child); append(" ")
                }; append("]")
            case .stream(let value): try stream(value)
            }
        }
        func inheritedObject(_ key: String, page: CGPDFDictionaryRef) throws -> CGPDFObjectRef? {
            var current = page, seen = Set<Identity>()
            for _ in 0..<64 {
                guard seen.insert(identity(current)).inserted else { throw Unsupported() }
                var object: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(current, key, &object) { return object }
                var parent: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return nil }
                current = parent
            }; throw Unsupported()
        }
        func object(_ object: CGPDFObjectRef) throws {
            switch CGPDFObjectGetType(object) {
            case .null: append("null")
            case .boolean:
                var value: CGPDFBoolean = 0; guard CGPDFObjectGetValue(object, .boolean, &value) else { throw Unsupported() }
                append(value == 0 ? "false" : "true")
            case .integer:
                var value: CGPDFInteger = 0; guard CGPDFObjectGetValue(object, .integer, &value) else { throw Unsupported() }; append("\(value)")
            case .real:
                var value: CGPDFReal = 0; guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw Unsupported() }
                append(try decimal(Double(value)))
            case .name:
                var value: UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(object, .name, &value), let value else { throw Unsupported() }; name(Data(bytes: value, count: strlen(value)))
            case .string:
                var value: CGPDFStringRef?; guard CGPDFObjectGetValue(object, .string, &value), let value else { throw Unsupported() }; try string(value)
            case .array:
                var value: CGPDFArrayRef?; guard CGPDFObjectGetValue(object, .array, &value), let value else { throw Unsupported() }
                append(try reference(.array(value), identity: identity(value)))
            case .dictionary:
                var value: CGPDFDictionaryRef?; guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw Unsupported() }
                append(try reference(.dictionary(value), identity: identity(value)))
            case .stream:
                var value: CGPDFStreamRef?; guard CGPDFObjectGetValue(object, .stream, &value), let value else { throw Unsupported() }
                append(try reference(.stream(value), identity: identity(value)))
            @unknown default: throw Unsupported()
            }
        }
        func name(_ bytes: Data) {
            append("/")
            for byte in bytes {
                if (33...126).contains(byte), ![35, 37, 40, 41, 47, 60, 62, 91, 93, 123, 125].contains(byte) { output.append(byte) }
                else { append(String(format: "#%02X", byte)) }
            }
        }
        func string(_ value: CGPDFStringRef) throws {
            let length = CGPDFStringGetLength(value)
            guard length <= (maximumBytes - output.count - 2) / 2, length == 0 || CGPDFStringGetBytePtr(value) != nil else { throw Unsupported() }
            append("<")
            if let bytes = CGPDFStringGetBytePtr(value) {
                let hex = Array("0123456789ABCDEF".utf8)
                var encoded = Data(count: length * 2)
                encoded.withUnsafeMutableBytes { buffer in
                    let target = buffer.bindMemory(to: UInt8.self)
                    for index in 0..<length { target[index * 2] = hex[Int(bytes[index] >> 4)]; target[index * 2 + 1] = hex[Int(bytes[index] & 15)] }
                }
                output.append(encoded)
            }
            append(">")
        }
        func decimal(_ value: Double) throws -> String {
            let text = String(value)
            guard let e = text.firstIndex(of: "e"), let exponent = Int(text[text.index(after: e)...]) else { return text }
            let negative = value < 0, mantissa = text[..<e].filter { $0 != "-" }
            let split = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            let digits = split.joined(), point = split[0].count + exponent
            guard abs(point) <= 400 else { throw Unsupported() }
            let expanded: String
            if point <= 0 { expanded = "0." + String(repeating: "0", count: -point) + digits }
            else if point >= digits.count { expanded = digits + String(repeating: "0", count: point - digits.count) }
            else { let at = digits.index(digits.startIndex, offsetBy: point); expanded = String(digits[..<at]) + "." + digits[at...] }
            return (negative ? "-" : "") + expanded
        }
        func stream(_ stream: CGPDFStreamRef) throws {
            var format = CGPDFDataFormat.raw
            guard let dictionary = CGPDFStreamGetDictionary(stream), let copied = CGPDFStreamCopyData(stream, &format) else { throw Unsupported() }
            for key in ["F", "FFilter", "FDecodeParms"] {
                var external: CGPDFObjectRef?
                guard !CGPDFDictionaryGetObject(dictionary, key, &external) else { throw Unsupported() }
            }
            let decoded = copied as Data; decodedBytes += decoded.count
            guard decodedBytes <= maximumBytes else { throw Unsupported() }
            let data: Data, filter: String
            switch format {
            case .raw:
                data = try compressed(decoded); filter = "FlateDecode"
            case .jpegEncoded, .JPEG2000:
                // CG may remove an outer ASCII85/Flate decoder. Until the final
                // decoder parameters can be proved, accept only a single codec.
                var sourceFilter: UnsafePointer<CChar>?, parameters: CGPDFObjectRef?
                guard CGPDFDictionaryGetName(dictionary, "Filter", &sourceFilter), let sourceFilter else { throw Unsupported() }
                filter = format == .jpegEncoded ? "DCTDecode" : "JPXDecode"
                guard String(cString: sourceFilter) == filter else { throw Unsupported() }
                if CGPDFDictionaryGetObject(dictionary, "DecodeParms", &parameters), let parameters,
                   CGPDFObjectGetType(parameters) != .null { throw Unsupported() }
                data = decoded
            @unknown default: throw Unsupported()
            }
            guard output.count + data.count < maximumBytes else { throw Unsupported() }
            try self.dictionary(dictionary, excluding: ["Length", "Filter", "DecodeParms"]) {
                append(" /Length \(data.count) /Filter /\(filter)")
            }
            append("\nstream\n"); output.append(data); append("\nendstream")
        }
        func compressed(_ data: Data) throws -> Data {
            var length = compressBound(uLong(data.count)), result = Data(count: Int(compressBound(uLong(data.count))))
            let status = result.withUnsafeMutableBytes { destination in data.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &length, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_SPEED)
            } }
            guard status == Z_OK else { throw Unsupported() }; result.count = Int(length); return result
        }
    }
}
