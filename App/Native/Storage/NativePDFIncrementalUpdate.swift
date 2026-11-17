import Foundation
import CoreGraphics
import CryptoKit
import PDFKit

/// Page add, delete and move as a PDF incremental update (ISO 32000-1 §7.5.6).
/// The original bytes stay the first bytes of the result. Appended after them:
/// a new page tree under the original `/Pages` object number, the page
/// dictionaries that need a new `/Parent`, the new pages, and outline items or
/// annotation arrays that pointed at a deleted page. No content stream, font,
/// image, form field or annotation object is re-encoded, so the proof that the
/// kept pages are unchanged is structural, not a rendering or text comparison
/// (those differ between PDFKit versions; iPadOS 26 and 27 disagreed).
enum NativePDFIncrementalUpdate {
    typealias File = NativePDFObjectFile
    typealias Value = File.Value
    typealias Dict = File.Dictionary
    typealias Ref = File.Reference
    typealias Unsupported = File.Unsupported

    /// What a recipe `0` becomes: the preceding page's paper (app-made paper PDFs)
    /// or an empty page of the same size (imported PDFs: lecture slides, scans).
    enum NewPage: String { case template, blank }

    /// Inherited page attributes (§7.7.3.4).
    static let inheritable = ["Resources", "MediaBox", "CropBox", "Rotate"]
    /// Keys a template copy drops: it is a new, unannotated page.
    static let notCopied: Set<String> = ["Parent", "Annots", "StructParents", "Tabs", "B", "AA", "Thumb", "PieceInfo", "Metadata", "ID", "PZ", "SeparationInfo", "Trans", "Dur", "PresSteps", "VP", "AF", "OutputIntents", "DPart", "LastModified"]

    struct Page { let reference: Ref; let dictionary: Dict; let inherited: [String: Value]; let parent: Int? }

    static func pages(_ file: File) throws -> (catalog: Ref, root: Ref, pages: [Page]) {
        guard let catalogRef = file.trailer["Root"]?.reference, let catalog = try file.object(catalogRef).dictionary,
              let root = catalog["Pages"]?.reference else { throw Unsupported("no page tree") }
        var result: [Page] = [], seen = Set<Int>()
        func walk(_ reference: Ref, inherited: [String: Value], parent: Int?, depth: Int) throws {
            guard depth < 64, seen.insert(reference.number).inserted, result.count <= 20_000 else { throw Unsupported("page tree loop") }
            guard let node = try file.object(reference).dictionary else { throw Unsupported("page tree node is not a dictionary") }
            let isNode = node["Type"]?.name == "Pages" || (node["Type"]?.name != "Page" && node["Kids"] != nil)
            if isNode {
                var next = inherited
                for key in inheritable { if let value = node[key] { next[key] = value } }
                guard let kids = try file.resolve(node["Kids"])?.array else { throw Unsupported("page tree node without kids") }
                for kid in kids {
                    guard let ref = kid.reference else { throw Unsupported("direct page object") }
                    try walk(ref, inherited: next, parent: reference.number, depth: depth + 1)
                }
            } else {
                result.append(Page(reference: reference, dictionary: node, inherited: inherited, parent: parent))
            }
        }
        try walk(root, inherited: [:], parent: nil, depth: 0)
        guard !result.isEmpty else { throw Unsupported("no pages") }
        return (catalogRef, root, result)
    }

    /// A page as drawn: its own keys plus the attributes it inherits, without `/Parent`.
    static func effective(_ page: Page) -> Dict {
        var dictionary = page.dictionary.removing(["Parent"])
        for key in inheritable where dictionary[key] == nil { if let value = page.inherited[key] { dictionary[key] = value } }
        return dictionary
    }

    // MARK: destinations

    /// The page object a destination names: explicit `[page …]`, a name, or a GoTo action.
    final class Destinations {
        let file: File
        private var named: [Data: Value]?
        init(_ file: File) { self.file = file }
        func target(_ value: Value?, depth: Int = 0) throws -> Int? {
            guard depth < 8 else { return nil }
            switch try file.resolve(value) {
            case .array(let items)?: return items.first?.reference?.number
            case .name(let key)?, .string(let key)?: return try target(namedValue(key), depth: depth + 1)
            case .dictionary(let d)?: return try target(d["D"], depth: depth + 1)
            default: return nil
            }
        }
        func annotationTarget(_ annotation: Dict) throws -> Int? {
            if let dest = annotation["Dest"] { return try target(dest) }
            guard let action = try file.resolvedDictionary(annotation["A"]), action["S"]?.name == "GoTo" else { return nil }
            return try target(action["D"])
        }
        private func namedValue(_ key: Data) throws -> Value? {
            if named == nil {
                var map: [Data: Value] = [:]
                if let catalogRef = file.trailer["Root"]?.reference, let catalog = try file.object(catalogRef).dictionary {
                    if let dests = try file.resolvedDictionary(catalog["Dests"]) { for (k, v) in dests.entries { map[Data("/".utf8) + k] = v } }
                    if let names = try file.resolvedDictionary(catalog["Names"]), let tree = try file.resolvedDictionary(names["Dests"]) {
                        var visited = Set<Int>(), budget = 200_000
                        func walk(_ node: Dict, depth: Int) throws {
                            guard depth < 32 else { return }
                            if let pairs = try file.resolve(node["Names"])?.array {
                                for i in stride(from: 0, to: pairs.count - 1, by: 2) {
                                    budget -= 1; guard budget > 0 else { return }
                                    if case .string(let raw) = pairs[i] { map[Self.literal(raw)] = pairs[i + 1] }
                                }
                            }
                            for kid in try file.resolve(node["Kids"])?.array ?? [] {
                                guard let ref = kid.reference, visited.insert(ref.number).inserted, let child = try file.object(ref).dictionary else { continue }
                                try walk(child, depth: depth + 1)
                            }
                        }
                        try walk(tree, depth: 0)
                    }
                }
                named = map
            }
            if key.first == 40 || key.first == 60 { return named?[Self.literal(key)] }
            return named?[Data("/".utf8) + key] ?? named?[key]
        }
        /// The bytes a string token stands for, so `(a)` and `<61>` match.
        static func literal(_ raw: Data) -> Data {
            let bytes = [UInt8](raw)
            guard let first = bytes.first else { return raw }
            if first == 60 {
                let digits = bytes.dropFirst().dropLast().compactMap(File.Lexer.hex)
                var out = Data(); var i = 0
                while i < digits.count { out.append(digits[i] << 4 | (i + 1 < digits.count ? digits[i + 1] : 0)); i += 2 }
                return out
            }
            guard first == 40 else { return raw }
            var out = Data(), i = 1
            let end = bytes.count - 1
            while i < end {
                let c = bytes[i]
                if c == 92, i + 1 < end {
                    let n = bytes[i + 1]
                    switch n {
                    case 110: out.append(10); i += 2
                    case 114: out.append(13); i += 2
                    case 116: out.append(9); i += 2
                    case 98: out.append(8); i += 2
                    case 102: out.append(12); i += 2
                    case 48...55:
                        var value = 0, k = i + 1
                        while k < end, k < i + 4, (48...55).contains(bytes[k]) { value = value * 8 + Int(bytes[k] - 48); k += 1 }
                        out.append(UInt8(value & 255)); i = k
                    case 10: i += 2
                    case 13: i += (i + 2 < end && bytes[i + 2] == 10) ? 3 : 2
                    default: out.append(n); i += 2
                    }
                } else { out.append(c); i += 1 }
            }
            return out
        }
    }

    // MARK: write

    /// `source` is the parsed original, for the proof that follows.
    struct Output { let data: Data; let rewrittenPages: Int; let otherObjects: Int; let source: File }

    static func write(_ source: Data, pages recipe: [Int], newPage: NewPage) throws -> Output {
        let file = try File(source)
        let (catalogRef, root, pages) = try Self.pages(file)
        guard let rootNode = try file.object(root).dictionary else { throw Unsupported("page tree root") }
        let count = pages.count
        let kept = recipe.filter { $0 != 0 }
        guard !kept.isEmpty, Set(kept).count == kept.count, kept.allSatisfy({ (1...count).contains($0) }) else { throw Unsupported("recipe does not fit the page tree") }
        let deleted = Set(pages.indices.filter { !kept.contains($0 + 1) }.map { pages[$0].reference.number })

        var objects: [(Ref, [UInt8])] = [], next = file.size
        func add(_ reference: Ref, _ value: Value) throws { var out: [UInt8] = []; try File.serialize(value, into: &out); objects.append((reference, out)) }
        func allocate() -> Ref { defer { next += 1 }; return Ref(number: next, generation: 0) }

        // Link annotations that lead to a deleted page go, as PDFKit's editor removed them.
        let destinations = Destinations(file)
        var rewrittenArrays: [Int: [Value]] = [:]
        func filteredAnnots(_ page: Page) throws -> (direct: [Value]?, changed: Bool) {
            guard !deleted.isEmpty, let raw = page.dictionary["Annots"] else { return (nil, false) }
            guard let items = try file.resolve(raw)?.array else { return (nil, false) }
            let kept = try items.filter { item in
                guard let annotation = try file.resolvedDictionary(item), annotation["Subtype"]?.name == "Link",
                      let target = try destinations.annotationTarget(annotation) else { return true }
                return !deleted.contains(target)
            }
            guard kept.count != items.count else { return (nil, false) }
            if let ref = raw.reference { rewrittenArrays[ref.number] = kept; return (nil, true) }
            return (kept, true)
        }

        var kids: [Value] = [], rewrittenPages = 0
        let rootValue = Value.reference(root)
        var emptyContents: Ref?
        for (index, entry) in recipe.enumerated() {
            if entry != 0 {
                let page = pages[entry - 1]
                kids.append(.reference(page.reference))
                let annots = try filteredAnnots(page)
                guard page.parent != root.number || annots.direct != nil else { continue }
                // Under an intermediate node: the page moves to the root, keeping what it inherited.
                var dictionary = effective(page)
                dictionary["Parent"] = rootValue
                if let direct = annots.direct { dictionary["Annots"] = .array(direct) }
                try add(page.reference, .dictionary(dictionary)); rewrittenPages += 1
            } else {
                let template = pages[NativePDFPageDocument.template(recipe, at: index) - 1], reference = allocate()
                var dictionary: Dict
                switch newPage {
                case .template:
                    dictionary = effective(template).removing(notCopied)
                case .blank:
                    let source = effective(template)
                    dictionary = Dict()
                    dictionary["Type"] = .name(Data("Page".utf8))
                    for key in ["MediaBox", "CropBox", "Rotate", "UserUnit"] { if let value = source[key] { dictionary[key] = value } }
                    if dictionary["MediaBox"] == nil { dictionary["MediaBox"] = .array([.integer(0), .integer(0), .integer(612), .integer(792)]) }
                    dictionary["Resources"] = .dictionary(Dict())
                    let contents = emptyContents ?? allocate(); emptyContents = contents
                    dictionary["Contents"] = .reference(contents)
                }
                dictionary["Type"] = .name(Data("Page".utf8))
                dictionary["Parent"] = rootValue
                try add(reference, .dictionary(dictionary))
                kids.append(.reference(reference))
            }
        }
        for (number, items) in rewrittenArrays.sorted(by: { $0.key < $1.key }) {
            var generation = 0
            if case .offset(_, let g)? = file.entries[number] { generation = g }
            try add(Ref(number: number, generation: generation), .array(items))
        }
        var tree = rootNode.removing(["Kids", "Count", "Parent", "Type"])
        tree.entries.insert((Data("Type".utf8), .name(Data("Pages".utf8))), at: 0)
        tree["Kids"] = .array(kids); tree["Count"] = .integer(kids.count)
        try add(root, .dictionary(tree))

        if !deleted.isEmpty {
            for (reference, value) in try Outlines(file: file, destinations: destinations, deleted: deleted).rewritten() { try add(reference, value) }
            // A document that opens on a deleted page opens on its first page instead.
            if let catalog = try file.object(catalogRef).dictionary, let open = catalog["OpenAction"],
               let target = try destinations.target(open), deleted.contains(target) {
                try add(catalogRef, .dictionary(catalog.removing(["OpenAction"])))
            }
        }

        // Only the appended section is built; the original is never copied into it.
        let separator = source.last.map { $0 != 10 && $0 != 13 } ?? false, base = source.count + (separator ? 1 : 0)
        var out: [UInt8] = []
        var offsets: [Int: (Int, Int)] = [:]
        if let contents = emptyContents {
            offsets[contents.number] = (base + out.count, 0)
            out += Array("\(contents.number) 0 obj\n<< /Length 0 >>\nstream\n\nendstream\nendobj\n".utf8)
        }
        for (reference, body) in objects {
            offsets[reference.number] = (base + out.count, reference.generation)
            out += Array("\(reference.number) \(reference.generation) obj\n".utf8); out += body; out += Array("\nendobj\n".utf8)
        }
        var trailer = Dict()
        trailer["Root"] = .reference(catalogRef)
        if let info = file.trailer["Info"] { trailer["Info"] = info }
        if let ids = file.trailer["ID"]?.array, ids.count == 2 {
            var hash = SHA256(); hash.update(data: source); hash.update(data: Data(recipe.map(String.init).joined(separator: ",").utf8))
            let second = Data(hash.finalize().prefix(16)).map { String(format: "%02X", $0) }.joined()
            trailer["ID"] = .array([ids[0], .string(Data("<\(second)>".utf8))])
        }
        // A rebuilt (scanned) cross-reference is written out whole: the old one is wrong.
        var compressed: [Int: (stream: Int, index: Int)] = [:]
        if file.repaired {
            for (number, entry) in file.entries where offsets[number] == nil {
                switch entry {
                case .offset(let offset, let generation): offsets[number] = (offset, generation)
                case .compressed(let stream, let index): compressed[number] = (stream, index)
                case .free: break
                }
            }
        } else { trailer["Prev"] = .integer(file.startxref) }
        let xref = base + out.count
        if file.newestIsStream || !compressed.isEmpty {
            // Updates to a cross-reference-stream file continue in that format (§7.5.8.4).
            let own = next; next += 1
            offsets[own] = (xref, 0)
            let numbers = Set(offsets.keys).union(compressed.keys).sorted()
            var index: [Value] = [], data: [UInt8] = []
            for run in runs(numbers) { index += [.integer(run.lowerBound), .integer(run.count)] }
            for number in numbers {
                let (type, a, b) = offsets[number].map { (UInt8(1), $0.0, $0.1) } ?? (2, compressed[number]!.stream, compressed[number]!.index)
                data.append(type); for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((a >> shift) & 255)) }
                data.append(UInt8((b >> 8) & 255)); data.append(UInt8(b & 255))
            }
            var dictionary = Dict()
            dictionary["Type"] = .name(Data("XRef".utf8)); dictionary["Size"] = .integer(next)
            dictionary["W"] = .array([.integer(1), .integer(4), .integer(2)]); dictionary["Index"] = .array(index)
            for (key, value) in trailer.entries { dictionary.entries.append((key, value)) }
            dictionary["Length"] = .integer(data.count)
            out += Array("\(own) 0 obj\n".utf8); try File.serialize(.dictionary(dictionary), into: &out)
            out += Array("\nstream\n".utf8); out += data; out += Array("\nendstream\nendobj\n".utf8)
        } else {
            out += Array("xref\n".utf8)
            if file.repaired { out += Array("0 1\n0000000000 65535 f \n".utf8) }
            for run in runs(offsets.keys.sorted()) {
                out += Array("\(run.lowerBound) \(run.count)\n".utf8)
                for number in run { let (offset, generation) = offsets[number]!; out += Array(String(format: "%010d %05d n \n", offset, generation).utf8) }
            }
            trailer.entries.insert((Data("Size".utf8), .integer(next)), at: 0)
            out += Array("trailer\n".utf8); try File.serialize(.dictionary(trailer), into: &out); out.append(10)
        }
        out += Array("startxref\n\(xref)\n%%EOF\n".utf8)
        guard base + out.count < File.maximumBytes else { throw Unsupported("result too large") }
        var result = source
        if separator { result.append(10) }
        result.append(contentsOf: out)
        return Output(data: result, rewrittenPages: rewrittenPages, otherObjects: offsets.count - rewrittenPages, source: file)
    }
    private static func runs(_ numbers: [Int]) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        for n in numbers {
            if let last = result.last, last.upperBound + 1 == n { result[result.count - 1] = last.lowerBound...n } else { result.append(n...n) }
        }
        return result
    }

    /// Outline items that lead to a deleted page: a leaf goes (siblings relinked,
    /// counts recomputed); an item with children stays without its destination.
    struct Outlines {
        let file: File; let destinations: Destinations; let deleted: Set<Int>
        final class Node { let ref: Ref; let dictionary: Dict; var children: [Node] = []; var remove = false; var strip = false
            init(_ ref: Ref, _ dictionary: Dict) { self.ref = ref; self.dictionary = dictionary } }
        func rewritten() throws -> [(Ref, Value)] {
            guard let catalogRef = file.trailer["Root"]?.reference, let catalog = try file.object(catalogRef).dictionary,
                  let rootRef = catalog["Outlines"]?.reference, let rootDict = try file.object(rootRef).dictionary else { return [] }
            var seen: Set<Int> = [rootRef.number], budget = 100_000
            func children(of dictionary: Dict, depth: Int) throws -> [Node] {
                guard depth < 64 else { throw Unsupported("outline too deep") }
                var result: [Node] = [], cursor = dictionary["First"]?.reference
                while let ref = cursor {
                    budget -= 1
                    guard budget > 0, seen.insert(ref.number).inserted, let item = try file.object(ref).dictionary else { throw Unsupported("outline loop") }
                    let node = Node(ref, item)
                    node.children = try children(of: item, depth: depth + 1)
                    let target = try item["Dest"].map { try destinations.target($0) } ?? (try file.resolvedDictionary(item["A"]).flatMap { $0["S"]?.name == "GoTo" ? try destinations.target($0["D"]) : nil })
                    if let target, deleted.contains(target) { if node.children.isEmpty { node.remove = true } else { node.strip = true } }
                    result.append(node); cursor = item["Next"]?.reference
                }
                return result
            }
            let root = Node(rootRef, rootDict)
            root.children = try children(of: rootDict, depth: 0)
            func anyChange(_ node: Node) -> Bool { node.remove || node.strip || node.children.contains(where: anyChange) }
            guard root.children.contains(where: anyChange) else { return [] }
            var output: [(Ref, Value)] = []
            /// Visible descendants when `node` is open (§12.3.3 Count).
            func visible(_ node: Node) -> Int { node.children.reduce(0) { $0 + 1 + (($1.dictionary["Count"]?.integer ?? 0) > 0 ? visible($1) : 0) } }
            func rebuild(_ node: Node, prev: Ref?, nextRef: Ref?, isRoot: Bool) {
                node.children = node.children.filter { !$0.remove }
                for (i, child) in node.children.enumerated() {
                    rebuild(child, prev: i > 0 ? node.children[i - 1].ref : nil, nextRef: i + 1 < node.children.count ? node.children[i + 1].ref : nil, isRoot: false)
                }
                var d = node.dictionary
                if node.strip { d["Dest"] = nil; d["A"] = nil }
                d["First"] = node.children.first.map { .reference($0.ref) }; d["Last"] = node.children.last.map { .reference($0.ref) }
                if !isRoot { d["Prev"] = prev.map { .reference($0) }; d["Next"] = nextRef.map { .reference($0) } }
                if let count = d["Count"]?.integer {
                    let total = visible(node)
                    d["Count"] = node.children.isEmpty ? nil : .integer(isRoot || count > 0 ? total : -total)
                }
                if d != node.dictionary { output.append((node.ref, .dictionary(d))) }
            }
            rebuild(root, prev: nil, nextRef: nil, isRoot: true)
            return output
        }
    }

    // MARK: proof

    struct Proof { var keptPages = 0; var newPages = 0; var rewrittenPages = 0 }

    /// Structural proof that `target` is `source` with its pages arranged as `recipe`
    /// (target page i is source page recipe[i], or new when 0). One file must be a
    /// byte prefix of the other, and every object the longer one redefines must be
    /// page-tree, outline or annotation-list bookkeeping; kept pages must be the
    /// same objects drawing the same content. Works in both directions, so an
    /// undo (the shorter, older bytes) is proven against the edit it reverses.
    @discardableResult
    static func verify(source: Data, target: Data, pages recipe: [Int], parsedSource: File? = nil) throws -> Proof {
        let longer = target.count >= source.count ? target : source, shorter = target.count >= source.count ? source : target
        guard longer.count > shorter.count, longer.prefix(shorter.count) == shorter else { throw Unsupported("not an incremental update") }
        let s = try parsedSource ?? File(source), t = try File(target), long = longer == target ? t : s, short = longer == target ? s : t
        let (_, sRoot, sPages) = try pages(s), (_, tRoot, tPages) = try pages(t)
        guard sRoot == tRoot, tPages.count == recipe.count else { throw Unsupported("page tree differs") }
        let kept = recipe.filter { $0 != 0 }
        guard Set(kept).count == kept.count, kept.allSatisfy({ (1...sPages.count).contains($0) }) else { throw Unsupported("recipe") }
        let sNumbers = Set(sPages.map(\.reference.number)), tNumbers = Set(tPages.map(\.reference.number)), both = sNumbers.intersection(tNumbers)

        // 1. Every object the longer file redefines is bookkeeping.
        let annotsArrays = Set((sPages.compactMap { $0.dictionary["Annots"]?.reference?.number }) + tPages.compactMap { $0.dictionary["Annots"]?.reference?.number })
        for (number, entry) in long.entries where short.entries[number] != entry && number != 0 {
            let existed: Bool
            switch short.entries[number] { case .offset?, .compressed?: existed = true; default: existed = false }
            let old = existed ? try short.object(number) : .null, new = try long.object(number)
            func bookkeeping(_ value: Value) -> Bool {
                switch value {
                case .array: return annotsArrays.contains(number)
                case .stream(let d, let range): return d["Type"]?.name == "XRef" || !existed && range.isEmpty
                case .dictionary(let d):
                    switch d["Type"]?.name {
                    case "Pages", "Page", "Outlines": return true
                    case "Catalog": return true
                    default:
                        // Outline items and an untyped outline root; never annotations, fonts or resources.
                        return existed && d["Subtype"] == nil && d["Resources"] == nil && (d["Title"] != nil || d["First"] != nil || d["Last"] != nil || d["Count"] != nil)
                    }
                default: return false
                }
            }
            // An object that existed must not vanish: a kept page could draw it.
            guard existed ? bookkeeping(old) && bookkeeping(new) : (new == .null || bookkeeping(new)) else { throw Unsupported("object \(number) redefined") }
            if old.dictionary?["Type"]?.name == "Catalog" || new.dictionary?["Type"]?.name == "Catalog" {
                guard let a = old.dictionary, let b = new.dictionary, a.removing(["OpenAction"]) == b.removing(["OpenAction"]) else { throw Unsupported("catalog changed") }
            }
        }
        // 2. Kept pages: the same objects, the same effective dictionaries.
        let sDest = Destinations(s), tDest = Destinations(t)
        func links(_ file: File, _ dest: Destinations, _ page: Page) throws -> [Value] {
            try (file.resolve(page.dictionary["Annots"])?.array ?? []).filter { item in
                guard let annotation = try file.resolvedDictionary(item), annotation["Subtype"]?.name == "Link",
                      let target = try dest.annotationTarget(annotation) else { return true }
                return both.contains(target)
            }
        }
        var proof = Proof()
        for (index, entry) in recipe.enumerated() {
            let b = tPages[index]
            if entry == 0 {
                guard !sNumbers.contains(b.reference.number), b.dictionary["Annots"] == nil else { throw Unsupported("new page \(index + 1)") }
                let template = effective(sPages[NativePDFPageDocument.template(recipe, at: index) - 1]), page = effective(b).removing(["Type"])
                let copy = page == template.removing(notCopied.union(["Type"]))
                var blank = false
                if !copy, try t.resolve(page["Resources"])?.dictionary?.entries.isEmpty ?? true {
                    let contents = try t.resolve(page["Contents"])
                    if case .stream(_, let range)? = contents { blank = range.isEmpty } else { blank = contents == nil }
                    for key in ["MediaBox", "CropBox", "Rotate"] where page[key] != template[key] { blank = false }
                }
                guard copy || blank else { throw Unsupported("new page \(index + 1) is neither a copy nor blank") }
                proof.newPages += 1; continue
            }
            let a = sPages[entry - 1]
            guard a.reference == b.reference else { throw Unsupported("page \(index + 1) is another object") }
            if a.dictionary != b.dictionary {
                let x = effective(a).removing(["Annots"]), y = effective(b).removing(["Annots"])
                guard x == y, try links(s, sDest, a) == links(t, tDest, b) else { throw Unsupported("page \(index + 1) changed") }
                proof.rewrittenPages += 1
            } else if a.dictionary["Annots"]?.reference != nil, try links(s, sDest, a) != links(t, tDest, b) {
                throw Unsupported("page \(index + 1) annotations changed")
            }
            // Inherited values come from page-tree nodes, which are redefined: compare what they resolve to.
            for key in inheritable where a.dictionary[key] == nil && a.inherited[key] != b.inherited[key] && b.dictionary[key] == nil {
                throw Unsupported("page \(index + 1) inherits another \(key)")
            }
            proof.keptPages += 1
        }
        // 3. CoreGraphics reads the result the same way.
        try crossCheck(source: source, target: target, recipe: recipe)
        return proof
    }

    /// CGPDF opens the update to the same pages: count, boxes, rotation, and the
    /// content digest (contents, resources, groups) of every kept page.
    static func crossCheck(source: Data, target: Data, recipe: [Int]) throws {
        guard let a = CGDataProvider(data: source as CFData).flatMap(CGPDFDocument.init), let b = CGDataProvider(data: target as CFData).flatMap(CGPDFDocument.init),
              b.numberOfPages == recipe.count else { throw Unsupported("CoreGraphics page count") }
        let sourceDigest = NativePDFPageContentDigest(), targetDigest = NativePDFPageContentDigest()
        for (index, entry) in recipe.enumerated() {
            guard let page = b.page(at: index + 1) else { throw Unsupported("CoreGraphics page") }
            let from = a.page(at: entry == 0 ? NativePDFPageDocument.template(recipe, at: index) : entry)
            guard let from, page.getBoxRect(.mediaBox) == from.getBoxRect(.mediaBox), page.getBoxRect(.cropBox) == from.getBoxRect(.cropBox),
                  page.rotationAngle == from.rotationAngle else { throw Unsupported("CoreGraphics geometry of page \(index + 1)") }
            guard entry != 0 else { continue }
            let x = sourceDigest.digest(from), y = targetDigest.digest(page)
            if x != nil || y != nil { guard x == y else { throw Unsupported("CoreGraphics content of page \(index + 1)") } }
        }
        guard let document = PDFDocument(data: target), !document.isLocked, document.pageCount == recipe.count else { throw Unsupported("PDFKit page count") }
    }
}
