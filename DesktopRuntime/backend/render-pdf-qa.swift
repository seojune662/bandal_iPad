import Foundation
import AppKit
import PDFKit

// Native PDFKit renders the same CropBox/rotation model as the iPad viewer.
// Used when Poppler is not installed on the development Mac.
for path in CommandLine.arguments.dropFirst() {
    guard let pdf = PDFDocument(url: URL(fileURLWithPath: path)) else { fatalError("Unreadable PDF: \(path)") }
    for index in 0..<pdf.pageCount {
        guard let page = pdf.page(at: index) else { fatalError("Missing page") }
        let preview = page.thumbnail(of: NSSize(width: 1000, height: 1000), for: .cropBox)
        guard let data = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
        try png.write(to: URL(fileURLWithPath: path + ".page-\(index + 1).png"))
        print("page \(index + 1): rotation=\(page.rotation), text=\(page.string ?? "")")
    }
}
