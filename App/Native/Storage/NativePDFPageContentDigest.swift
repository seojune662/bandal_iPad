import Foundation
import CoreGraphics
import CryptoKit

/// A sufficient (not necessary) proof that two pages paint the same content.
/// Any unsupported/cyclic graph returns nil and uses the raster comparison.
/// Instances belong to one immutable CGPDFDocument so shared font/image trees
/// are hashed once, without retaining decoded stream bytes for every page.
final class NativePDFPageContentDigest {
    private var cache: [UInt: Data] = [:]
    private var visiting = Set<UInt>()
    private var visitedCount = 0
    private struct Unsupported: Error {}
    private final class Entries {
        var values: [(Data, CGPDFObjectRef)] = []
    }

    func digest(_ page: CGPDFPage) -> Data? {
        do {
            guard let dictionary = page.dictionary else { return nil }
            var value = SHA256()
            // Unknown page-level rendering features cannot be silently ignored.
            let known = Set(["Type", "Parent", "Resources", "MediaBox", "CropBox", "Rotate", "Contents", "Group", "UserUnit", "Annots", "Metadata", "PieceInfo", "LastModified", "StructParents", "Tabs", "ID", "PZ", "Thumb", "B", "AA", "Dur", "Trans", "PresSteps", "BleedBox", "TrimBox", "ArtBox"])
            let fields = Entries()
            CGPDFDictionaryApplyFunction(dictionary, { key, object, raw in
                guard let raw else { return }
                Unmanaged<Entries>.fromOpaque(raw).takeUnretainedValue().values.append((Data(bytes: key, count: strlen(key)), object))
            }, Unmanaged.passUnretained(fields).toOpaque())
            guard fields.values.allSatisfy({ known.contains(String(decoding: $0.0, as: UTF8.self)) }) else { return nil }
            if let catalog = page.document?.catalog {
                for key in ["OCProperties", "OutputIntents"] {
                    value.update(data: Data(key.utf8))
                    value.update(data: try lookup(key, in: catalog, inherited: false).map { try digest($0, depth: 0) } ?? Data([0]))
                }
            }
            // Resources may be inherited. Group and UserUnit affect painting
            // independently of the content stream and cannot be omitted.
            for key in ["Contents", "Resources", "Group", "UserUnit"] {
                value.update(data: Data(key.utf8))
                let object = try lookup(key, in: dictionary, inherited: key == "Resources")
                value.update(data: try object.map { try digest($0, depth: 0) } ?? Data([0]))
            }
            return Data(value.finalize())
        } catch { return nil }
    }
    private func lookup(_ key: String, in dictionary: CGPDFDictionaryRef, inherited: Bool) throws -> CGPDFObjectRef? {
        var current = dictionary, seen = Set<UInt>()
        for _ in 0..<32 {
            guard seen.insert(UInt(bitPattern: current.rawValue)).inserted else { throw Unsupported() }
            var result: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(current, key, &result) { return result }
            guard inherited else { return nil }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent), let parent else { return nil }
            current = parent
        }
        throw Unsupported()
    }
    private func digest(_ object: CGPDFObjectRef, depth: Int) throws -> Data {
        let identity = UInt(bitPattern: object.rawValue)
        if let cached = cache[identity] { return cached }
        guard depth < 64, visitedCount < 200_000, visiting.insert(identity).inserted else { throw Unsupported() }
        visitedCount += 1
        defer { visiting.remove(identity) }
        var hash = SHA256()
        func token(_ text: String) { hash.update(data: Data(text.utf8)) }
        func bytes(_ bytes: Data) { token("\(bytes.count):"); hash.update(data: bytes) }
        switch CGPDFObjectGetType(object) {
        case .null: token("null")
        case .boolean:
            var value: CGPDFBoolean = 0
            guard CGPDFObjectGetValue(object, .boolean, &value) else { throw Unsupported() }
            token(value == 0 ? "false" : "true")
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, .integer, &value) else { throw Unsupported() }
            token("integer:\(value)")
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw Unsupported() }
            token("real:\(value)")
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value else { throw Unsupported() }
            token("name:"); bytes(Data(bytes: value, count: strlen(value)))
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else { throw Unsupported() }
            let length = CGPDFStringGetLength(value)
            guard length == 0 || CGPDFStringGetBytePtr(value) != nil else { throw Unsupported() }
            token("string:"); bytes(length == 0 ? Data() : Data(bytes: CGPDFStringGetBytePtr(value)!, count: length))
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { throw Unsupported() }
            let count = CGPDFArrayGetCount(value); guard count <= 100_000 else { throw Unsupported() }
            token("array:\(count):")
            for index in 0..<count {
                var child: CGPDFObjectRef?
                guard CGPDFArrayGetObject(value, index, &child), let child else { throw Unsupported() }
                hash.update(data: try digest(child, depth: depth + 1))
            }
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw Unsupported() }
            token("dictionary:"); hash.update(data: try digestDictionary(value, depth: depth + 1))
        case .stream:
            var value: CGPDFStreamRef?, format = CGPDFDataFormat.raw
            guard CGPDFObjectGetValue(object, .stream, &value), let value,
                  let data = CGPDFStreamCopyData(value, &format), let dictionary = CGPDFStreamGetDictionary(value) else { throw Unsupported() }
            token("stream:\(format.rawValue):")
            // Only decoded raw bytes permit removing compression descriptors.
            // JPEG/JPX bytes keep those descriptors as part of the proof.
            let ignored = format == .raw ? Set(["Length", "Filter", "DecodeParms"]) : Set(["Length"])
            hash.update(data: try digestDictionary(dictionary, depth: depth + 1, ignoring: ignored))
            bytes(data as Data)
        @unknown default: throw Unsupported()
        }
        let result = Data(hash.finalize()); cache[identity] = result; return result
    }
    private func digestDictionary(_ dictionary: CGPDFDictionaryRef, depth: Int, ignoring keys: Set<String> = []) throws -> Data {
        let entries = Entries()
        CGPDFDictionaryApplyFunction(dictionary, { key, value, raw in
            guard let raw else { return }
            let entries = Unmanaged<Entries>.fromOpaque(raw).takeUnretainedValue()
            entries.values.append((Data(bytes: key, count: strlen(key)), value))
        }, Unmanaged.passUnretained(entries).toOpaque())
        let ignored = Set(keys.map { Data($0.utf8) })
        let values = entries.values.filter { !ignored.contains($0.0) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        guard values.count <= 100_000 else { throw Unsupported() }
        var hash = SHA256(); hash.update(data: Data("\(values.count):".utf8))
        for (key, object) in values {
            hash.update(data: Data("\(key.count):".utf8)); hash.update(data: key)
            hash.update(data: try digest(object, depth: depth))
        }
        return Data(hash.finalize())
    }
}
