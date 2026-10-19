import Foundation
import PDFKit
import UIKit

/// A vector PDF copy in displayed CropBox coordinates. It never writes to the
/// source. Existing PDF text and the versioned ink renderer remain vector data.
enum NativePDFExport {
    struct ImageSource { let drawingID: String; let bytes: Data }
    static func render(source: Data, drawings: [[String: Any]], annotations: [[String: Any]], images: [ImageSource]) throws -> Data {
        // UIKit text/font/image rendering owns main-thread caches. The runtime
        // calls this from its serial repository queue and awaits asynchronously.
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try draw(source: source, drawings: drawings, annotations: annotations, images: images) }
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated { try draw(source: source, drawings: drawings, annotations: annotations, images: images) }
        }
    }
    @MainActor private static func draw(source: Data, drawings: [[String: Any]], annotations: [[String: Any]], images: [ImageSource]) throws -> Data {
        let v = NativePDFRepositoryValidation.self
        guard let document = PDFDocument(data: source), !document.isLocked, document.pageCount > 0 else { throw v.error("PDF를 내보낼 수 없습니다.") }
        let pageCount = document.pageCount
        for row in drawings + annotations {
            let page = try v.integer(row["page"], "page")
            guard page <= pageCount else { throw v.error("필기 페이지와 PDF 원본의 페이지가 일치하지 않습니다.") }
        }
        var resolved: [String: UIImage] = [:]
        for image in images {
            guard let value = UIImage(data: image.bytes) else { throw v.error("PDF 이미지 자료를 읽지 못해 내보내기를 중단했습니다.") }
            resolved[image.drawingID] = value
        }
        let bytes = NSMutableData()
        var defaultBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        var metadata: [CFString: Any] = [kCGPDFContextCreator: "Bandal"]
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String { metadata[kCGPDFContextTitle] = title }
        if let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String { metadata[kCGPDFContextAuthor] = author }
        guard let consumer = CGDataConsumer(data: bytes), let context = CGContext(consumer: consumer, mediaBox: &defaultBox, metadata as CFDictionary) else { throw v.error("PDF 내보내기를 준비하지 못했습니다.") }
        for index in 0..<pageCount {
            guard let page = document.page(at: index), let reference = page.pageRef else { throw v.error("PDF 페이지를 읽지 못했습니다.") }
            let coordinates = NativePDFPageCoordinates(page: page)
            guard [0, 90, 180, 270].contains(coordinates.rotation), coordinates.width > 0, coordinates.height > 0 else { throw v.error("지원하지 않는 PDF 페이지 회전 또는 크기입니다.") }
            var box = CGRect(x: 0, y: 0, width: coordinates.width, height: coordinates.height)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.saveGState()
            context.translateBy(x: 0, y: coordinates.height); context.scaleBy(x: 1, y: -1)
            let mapper = InkCoordinateMapper.whiteboard(size: box.size)
            guard let transform = NativePDFBackdropRenderer.pdfToCanvas(page: page, mapper: mapper) else { throw v.error("PDF 좌표를 변환하지 못했습니다.") }
            context.saveGState(); context.concatenate(transform); context.clip(to: coordinates.crop)
            context.drawPDFPage(reference)
            if page.displaysAnnotations, !page.annotations.isEmpty {
                guard let annotationSpace = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw v.error("PDF 주석을 내보낼 수 없습니다.") }
                page.transform(annotationSpace, for: .cropBox)
                context.concatenate(annotationSpace.ctm.inverted())
                for annotation in page.annotations where annotation.shouldDisplay {
                    context.saveGState(); annotation.draw(with: .cropBox, in: context); context.restoreGState()
                }
            }
            context.restoreGState()
            for annotation in annotations where (annotation["page"] as? NSNumber)?.intValue == index + 1 {
                guard let rects = annotation["rects"] as? [[String: Any]] else { throw v.error("PDF 주석 좌표가 올바르지 않습니다.") }
                let color: UIColor
                switch annotation["color"] as? String {
                case "green": color = UIColor(red: 0.45, green: 0.83, blue: 0.56, alpha: 1)
                case "pink": color = UIColor(red: 1, green: 0.56, blue: 0.71, alpha: 1)
                case "blue": color = UIColor(red: 0.44, green: 0.73, blue: 1, alpha: 1)
                default: color = UIColor(red: 1, green: 0.9, blue: 0.35, alpha: 1)
                }
                context.saveGState(); context.setBlendMode(.multiply); context.setFillColor(color.withAlphaComponent(0.32).cgColor)
                for rect in rects {
                    let x = try v.number(rect["x"], "x"), y = try v.number(rect["y"], "y")
                    let width = try v.number(rect["width"], "width"), height = try v.number(rect["height"], "height")
                    context.fill(CGRect(x: x * coordinates.width, y: y * coordinates.height, width: width * coordinates.width, height: height * coordinates.height))
                }
                context.restoreGState()
            }
            for raw in drawings where (raw["page"] as? NSNumber)?.intValue == index + 1 {
                guard let kind = raw["kind"] as? String, v.kinds.contains(kind) else { throw v.error("지원하지 않는 PDF 필기가 있어 원본을 보존했습니다.") }
                var row = raw
                if ["ink", "highlighter"].contains(kind), (raw["data"] as? [String: Any])?["inkVersion"] == nil {
                    row["nativePath"] = try NativePDFLegacyInk.path(raw, aspect: coordinates.height / coordinates.width)
                }
                let image = resolved[row["id"] as? String ?? ""]
                if kind == "image", image == nil { throw v.error("PDF 이미지 자료를 찾지 못해 내보내기를 중단했습니다.") }
                NativePDFObjectRenderer.draw(row, in: context, mapper: mapper, image: image, compact: true)
            }
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF(); return bytes as Data
    }
}
