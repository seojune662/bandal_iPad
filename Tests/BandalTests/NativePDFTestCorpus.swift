import Foundation
import CoreGraphics
import CoreText
import PDFKit
import UIKit
import zlib
@testable import Bandal

/// PDFs made in the test, one per producer shape lecture material comes in:
/// Quartz (Keynote, Pages, macOS print), PDFKit re-saves (Preview, note apps),
/// hand-written files with nested page trees, page labels, bookmarks, named
/// destinations and navigation links (LaTeX beamer, Acrobat), cross-reference
/// streams with object streams (Word, PowerPoint, pdfTeX), hybrid files, files
/// that already carry an incremental update, broken `startxref`, PDF 1.3 to 2.0,
/// scans, and a long document. Nothing here is a real user's file.
enum NativePDFTestCorpus {
    struct Item { let name: String; let data: Data }

    static func all() throws -> [Item] {
        [
            Item(name: "quartz-slides", data: try quartz(pages: 6, size: CGSize(width: 960, height: 540), links: true)),
            Item(name: "pdfkit-resaved", data: try pdfKitSaved()),
            Item(name: "nested-labels-outline-1.7", data: hand(version: "1.7")),
            Item(name: "nested-pdf-1.3", data: hand(version: "1.3")),
            Item(name: "nested-pdf-2.0", data: hand(version: "2.0")),
            Item(name: "object-streams", data: hand(version: "1.5", objectStreams: true)),
            Item(name: "hybrid-xref", data: hand(version: "1.5", objectStreams: true, hybrid: true)),
            Item(name: "already-updated", data: updated(hand(version: "1.6"))),
            Item(name: "broken-startxref", data: brokenStartXRef(hand(version: "1.4"))),
            Item(name: "scan-jpeg", data: try scan()),
            Item(name: "app-paper", data: try NativePDFRepository.paperData(title: "노트", paper: "grid", orientation: "portrait")),
        ]
    }

    // MARK: producers

    static func quartz(pages: Int, size: CGSize, links: Bool) throws -> Data {
        let data = NSMutableData(); var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let canvas = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "Lecture 18", kCGPDFContextCreator: "Keynote"] as CFDictionary) else { throw NSError(domain: "corpus", code: 1) }
        for n in 1...pages {
            canvas.beginPDFPage(nil)
            canvas.setFillColor(CGColor(red: 0.9, green: 0.95, blue: 1, alpha: 1)); canvas.fill(box)
            canvas.setFillColor(CGColor(red: CGFloat(n % 5) / 5, green: 0.3, blue: 0.6, alpha: 1)); canvas.fill(CGRect(x: size.width - 260, y: 40, width: 200, height: 120))
            draw("Lecture 18 · Basic Electromagnetics (\(n))", at: CGPoint(x: 48, y: size.height - 80), size: 30, in: canvas)
            draw("전기장과 자기장 — 패러데이 법칙 \(n)", at: CGPoint(x: 60, y: size.height - 140), size: 22, in: canvas)
            if links {
                canvas.addDestination("slide\(n)" as CFString, at: CGPoint(x: 0, y: size.height))
                if n < pages { canvas.setDestination("slide\(n + 1)" as CFString, for: CGRect(x: size.width - 90, y: 10, width: 70, height: 30)) }
                canvas.setURL(URL(string: "https://example.org/em")! as CFURL, for: CGRect(x: 60, y: size.height - 150, width: 320, height: 30))
            }
            canvas.endPDFPage()
        }
        canvas.closePDF()
        return data as Data
    }
    static func draw(_ text: String, at point: CGPoint, size: CGFloat, in canvas: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        canvas.setFillColor(CGColor(gray: 0, alpha: 1)); canvas.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])), canvas)
    }
    /// A Quartz file opened and saved by PDFKit with an outline, comments and a form field.
    static func pdfKitSaved() throws -> Data {
        guard let document = PDFDocument(data: try quartz(pages: 5, size: CGSize(width: 595, height: 842), links: false)) else { throw NSError(domain: "corpus", code: 2) }
        let root = PDFOutline()
        for index in 0..<document.pageCount {
            let item = PDFOutline(); item.label = "Section \(index + 1)"; item.destination = PDFDestination(page: document.page(at: index)!, at: CGPoint(x: 0, y: 842))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        let note = PDFAnnotation(bounds: CGRect(x: 500, y: 700, width: 24, height: 24), forType: .text, withProperties: nil); note.contents = "질문"
        document.page(at: 1)!.addAnnotation(note)
        let highlight = PDFAnnotation(bounds: CGRect(x: 60, y: 690, width: 300, height: 24), forType: .highlight, withProperties: nil); highlight.color = .yellow
        document.page(at: 2)!.addAnnotation(highlight)
        let field = PDFAnnotation(bounds: CGRect(x: 60, y: 200, width: 200, height: 30), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "answer"; field.widgetStringValue = "정답"
        document.page(at: 3)!.addAnnotation(field)
        let link = PDFAnnotation(bounds: CGRect(x: 60, y: 100, width: 120, height: 30), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: document.page(at: 1)!, at: .zero))
        document.page(at: 0)!.addAnnotation(link)
        guard let data = document.dataRepresentation() else { throw NSError(domain: "corpus", code: 3) }
        return data
    }
    static func scan() throws -> Data {
        let size = CGSize(width: 620, height: 877)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(white: 0.97, alpha: 1).setFill(); context.fill(CGRect(origin: .zero, size: size))
            for k in 0..<30 { ("scanned line \(k) " as NSString).draw(at: CGPoint(x: 40, y: 30 + k * 27), withAttributes: [.font: UIFont.systemFont(ofSize: 16)]) }
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.7), let provider = CGDataProvider(data: jpeg as CFData),
              let cg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw NSError(domain: "corpus", code: 4) }
        let data = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let canvas = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<3 { canvas.beginPDFPage(nil); canvas.draw(cg, in: box); canvas.endPDFPage() }
        canvas.closePDF()
        return data as Data
    }

    // MARK: hand-written files

    /// Seven pages under two intermediate nodes with inherited resources, media box and
    /// rotation; page labels; an outline (explicit and named destinations, a nested item);
    /// a name tree; GoTo, named-destination, Named and URI links; an open action.
    static func hand(version: String, objectStreams: Bool = false, hybrid: Bool = false) -> Data {
        var objects: [Int: String] = [:], streams: [Int: (String, Data)] = [:]
        objects[1] = "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /S /r >> 2 << /S /D >>] >> /Outlines 30 0 R /Names << /Dests 40 0 R >> /OpenAction [6 0 R /Fit] /PageMode /UseOutlines >>"
        objects[2] = "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 7 /MediaBox [0 0 720 405] /Resources << /Font << /F1 20 0 R >> >> >>"
        objects[3] = "<< /Type /Pages /Parent 2 0 R /Kids [5 0 R 6 0 R 7 0 R] /Count 3 >>"
        objects[4] = "<< /Type /Pages /Parent 2 0 R /Kids [8 0 R 9 0 R 10 0 R 11 0 R] /Count 4 /Rotate 90 >>"
        for page in 1...7 {
            let number = 4 + page, parent = page <= 3 ? 3 : 4
            var annots = ""
            if page == 1 { annots = " /Annots [50 0 R 51 0 R 52 0 R 53 0 R]" }
            if page == 3 { annots = " /Annots [54 0 R]" }
            objects[number] = "<< /Type /Page /Parent \(parent) 0 R /Contents \(60 + page) 0 R\(page == 6 ? " /CropBox [20 20 700 385]" : "")\(annots) >>"
            let content = "q \(Double(page) / 8) 0.4 0.7 rg 40 40 \(80 * page) 60 re f Q BT /F1 28 Tf 48 330 Td (Slide \(page)) Tj ET"
            streams[60 + page] = ("", Data(content.utf8))
        }
        objects[20] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        objects[30] = "<< /Type /Outlines /First 31 0 R /Last 34 0 R /Count 4 >>"
        objects[31] = "<< /Title (Introduction) /Parent 30 0 R /Next 32 0 R /Dest [5 0 R /Fit] >>"
        objects[32] = "<< /Title (Field theory) /Parent 30 0 R /Prev 31 0 R /Next 34 0 R /First 33 0 R /Last 33 0 R /Count 1 /Dest (sec2) >>"
        objects[33] = "<< /Title (Gauss) /Parent 32 0 R /A << /S /GoTo /D [7 0 R /XYZ 0 405 0] >> >>"
        objects[34] = "<< /Title (Summary) /Parent 30 0 R /Prev 32 0 R /Dest [11 0 R /Fit] >>"
        objects[40] = "<< /Names [(sec2) [6 0 R /Fit] (summary) << /D [11 0 R /Fit] >>] >>"
        objects[50] = "<< /Type /Annot /Subtype /Link /Rect [600 10 640 40] /Border [0 0 0] /Dest [6 0 R /Fit] >>"
        objects[51] = "<< /Type /Annot /Subtype /Link /Rect [550 10 590 40] /Border [0 0 0] /A << /S /GoTo /D (sec2) >> >>"
        objects[52] = "<< /Type /Annot /Subtype /Link /Rect [500 10 540 40] /Border [0 0 0] /A << /S /Named /N /NextPage >> >>"
        objects[53] = "<< /Type /Annot /Subtype /Link /Rect [40 360 300 390] /Border [0 0 0] /A << /S /URI /URI (https://example.org/em) >> >>"
        objects[54] = "<< /Type /Annot /Subtype /Text /Rect [650 300 670 320] /Contents <BFE8AE38> /Open false >>"
        objects[80] = "<< /Title (Electromagnetics) /Producer (pdfTeX-1.40.25) >>"
        return assemble(version: version, objects: objects, streams: streams, root: 1, info: 80, objectStreams: objectStreams, hybrid: hybrid)
    }

    static func assemble(version: String, objects: [Int: String], streams: [Int: (String, Data)], root: Int, info: Int?, objectStreams: Bool, hybrid: Bool) -> Data {
        var out = Data("%PDF-\(version)\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int: Int] = [:], compressed: [Int: (Int, Int)] = [:]
        func append(_ text: String) { out.append(Data(text.utf8)) }
        for (number, (extra, data)) in streams.sorted(by: { $0.key < $1.key }) {
            offsets[number] = out.count
            let packed = deflate(data)
            append("\(number) 0 obj\n<< /Length \(packed.count) /Filter /FlateDecode\(extra) >>\nstream\n"); out.append(packed); append("\nendstream\nendobj\n")
        }
        let packedNumbers = objectStreams ? objects.keys.filter { $0 != root || !hybrid }.sorted() : []
        for (number, body) in objects.sorted(by: { $0.key < $1.key }) where !packedNumbers.contains(number) {
            offsets[number] = out.count; append("\(number) 0 obj\n\(body)\nendobj\n")
        }
        let size = (Set(objects.keys).union(streams.keys).max() ?? 0) + 3
        if objectStreams {
            let stream = size - 2
            var header = "", bodies = ""
            for (index, number) in packedNumbers.enumerated() {
                header += "\(number) \(bodies.utf8.count) "; bodies += objects[number]! + "\n"
                compressed[number] = (stream, index)
            }
            let data = deflate(Data((header + bodies).utf8))
            offsets[stream] = out.count
            append("\(stream) 0 obj\n<< /Type /ObjStm /N \(packedNumbers.count) /First \(header.utf8.count) /Length \(data.count) /Filter /FlateDecode >>\nstream\n"); out.append(data); append("\nendstream\nendobj\n")
        }
        let trailerKeys = "/Root \(root) 0 R" + (info.map { " /Info \($0) 0 R" } ?? "") + " /ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>]"
        func xrefStream(_ number: Int, entries: [Int]) -> Int {
            // Columns of 1+4+2 bytes, PNG "Up" predictor, as Word and pdfTeX write them.
            var rows = Data(), previous = [UInt8](repeating: 0, count: 7)
            let at = out.count
            for n in entries {
                var row: [UInt8]
                if n == number { row = [1] + bytes(at, 4) + [0, 0] }
                else if let offset = offsets[n] { row = [1] + bytes(offset, 4) + [0, 0] }
                else if let (stream, index) = compressed[n] { row = [2] + bytes(stream, 4) + bytes(index, 2) }
                else { row = [0, 0, 0, 0, 0, 255, 255] }
                rows.append(2); rows.append(contentsOf: zip(row, previous).map { $0 &- $1 }); previous = row
            }
            let data = deflate(rows)
            append("\(number) 0 obj\n<< /Type /XRef /Size \(size) /W [1 4 2] /Index [0 \(size)] /DecodeParms << /Columns 7 /Predictor 12 >> /Filter /FlateDecode /Length \(data.count) \(trailerKeys) >>\nstream\n")
            out.append(data); append("\nendstream\nendobj\n")
            return at
        }
        if objectStreams && !hybrid {
            let at = xrefStream(size - 1, entries: Array(0..<size))
            append("startxref\n\(at)\n%%EOF\n")
        } else {
            var stm: Int?
            if hybrid { stm = xrefStream(size - 1, entries: Array(0..<size)) }
            let xref = out.count
            append("xref\n0 \(size)\n0000000000 65535 f \n")
            for n in 1..<size { append(offsets[n].map { String(format: "%010d 00000 n \n", $0) } ?? "0000000000 65535 f \n") }
            append("trailer\n<< /Size \(size) \(trailerKeys)\(stm.map { " /XRefStm \($0)" } ?? "") >>\nstartxref\n\(xref)\n%%EOF\n")
        }
        return out
    }
    /// An earlier save added a comment to page 1 as an incremental update, as Preview and Acrobat do.
    static func updated(_ source: Data) -> Data {
        let text = String(decoding: source, as: UTF8.self)
        let startxref = Int(text.components(separatedBy: "startxref\n").last!.components(separatedBy: "\n")[0])!
        var out = source
        let page = out.count
        out.append(Data("5 0 obj\n<< /Type /Page /Parent 3 0 R /Contents 61 0 R /Annots [50 0 R 51 0 R 52 0 R 53 0 R 90 0 R] >>\nendobj\n".utf8))
        let annot = out.count
        out.append(Data("90 0 obj\n<< /Type /Annot /Subtype /Text /Rect [10 300 30 320] /Contents (later) >>\nendobj\n".utf8))
        let xref = out.count
        out.append(Data("xref\n0 1\n0000000000 65535 f \n5 1\n\(String(format: "%010d", page)) 00000 n \n90 1\n\(String(format: "%010d", annot)) 00000 n \ntrailer\n<< /Size 91 /Root 1 0 R /Info 80 0 R /Prev \(startxref) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return out
    }
    static func brokenStartXRef(_ source: Data) -> Data {
        var text = String(decoding: source, as: UTF8.self)
        let marker = text.range(of: "startxref\n", options: .backwards)!
        let tail = text[marker.upperBound...], digits = tail.prefix { $0.isNumber }
        text.replaceSubrange(marker.upperBound..<tail.index(tail.startIndex, offsetBy: digits.count), with: String(Int(digits)! + 7))
        return Data(text.utf8)
    }

    static func bytes(_ value: Int, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * (count - 1 - $0))) & 255) } }
    static func deflate(_ data: Data) -> Data {
        var length = compressBound(uLong(data.count)), result = Data(count: Int(length))
        _ = result.withUnsafeMutableBytes { target in data.withUnsafeBytes { source in
            compress2(target.bindMemory(to: Bytef.self).baseAddress, &length, source.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), Z_BEST_COMPRESSION)
        } }
        result.count = Int(length); return result
    }

    // MARK: checks

    /// Page pixels as CoreGraphics draws them here: the same code on both sides, so equal content is exactly equal.
    static func pixels(_ page: CGPDFPage) -> [UInt8] {
        let box = page.getBoxRect(.cropBox), scale = min(1, 600 / max(box.width, box.height))
        let width = max(1, Int(box.width * scale)), height = max(1, Int(box.height * scale))
        var buffer = [UInt8](repeating: 255, count: width * height * 4)
        let context = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale); context.translateBy(x: -box.minX, y: -box.minY); context.drawPDFPage(page)
        return buffer
    }
}
