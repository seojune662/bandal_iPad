import Foundation
import PDFKit
import UIKit
import SwiftUI

/// Each source owns one PDFKit document on a dedicated serial queue. It reads
/// the immutable original for this revision, so a page replacement cannot mix
/// old and new thumbnails or share PDFKit objects with the ink compositor.
@MainActor
final class NativePDFPageThumbnailSource {
    let revision: String
    private let worker: Worker
    private let cache = NSCache<NSNumber, UIImage>()
    init(root: URL, revision: String) {
        self.revision = revision
        worker = Worker(url: root.appendingPathComponent("PDFOriginals/" + revision + ".pdf"))
        cache.countLimit = 40
    }
    func image(page: Int) async -> UIImage? {
        if let image = cache.object(forKey: NSNumber(value: page)) { return image }
        guard !Task.isCancelled, let data = await worker.image(page: page), !Task.isCancelled, let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: NSNumber(value: page)); return image
    }
    private final class Worker: @unchecked Sendable {
        let url: URL
        let queue = DispatchQueue(label: "bandal.pdf.page-thumbnails", qos: .utility)
        private var document: PDFDocument?
        init(url: URL) { self.url = url }
        func image(page: Int) async -> Data? {
            await withCheckedContinuation { completion in
                queue.async { [self] in
                    if document == nil { document = PDFDocument(url: url) }
                    guard let page = document?.page(at: page - 1) else { completion.resume(returning: nil); return }
                    let coordinates = NativePDFPageCoordinates(page: page)
                    let size = CGSize(width: coordinates.width, height: coordinates.height)
                    let width: CGFloat = 260
                    let height = min(520, max(64, width * size.height / max(size.width, 1)))
                    completion.resume(returning: page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox).pngData())
                }
            }
        }
    }
}

struct NativePDFPageThumbnail: View {
    let source: NativePDFPageThumbnailSource?
    let page: Int
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.white
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().controlSize(.small) }
        }
        .aspectRatio(1 / sqrt(2), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(NativeDesktopTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .accessibilityHidden(true)
        .task(id: (source?.revision ?? "") + ":" + String(page)) { image = await source?.image(page: page) }
    }
}
