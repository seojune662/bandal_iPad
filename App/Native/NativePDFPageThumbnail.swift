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
    private let cache = NativeThumbnailImageCache(bytes: 24 * 1024 * 1024, count: 40)
    init(root: URL, revision: String) {
        self.revision = revision
        worker = Worker(url: root.appendingPathComponent("PDFOriginals/" + revision + ".pdf"))
    }
    func image(page: Int, rows: [[String: Any]], inkRevision: Int? = nil) async -> UIImage? {
        guard !rows.isEmpty else { return await image(page: page) }
        let snapshot = Rows(values: rows)
        guard let inkRevision else { return await worker.image(page: page, rows: snapshot)?.image }
        return await cache.image(key: "\(page):ink:\(inkRevision)") { [worker] in
            await worker.image(page: page, rows: snapshot)?.image
        }
    }
    func image(page: Int) async -> UIImage? {
        await cache.image(key: "\(page):original") { [worker] in
            await worker.image(page: page, rows: Rows(values: []))?.image
        }
    }
    private struct Rows: @unchecked Sendable { let values: [[String: Any]] }
    private final class Worker: @unchecked Sendable {
        let url: URL
        private let queue = NativeThumbnailWorkQueue(name: "bandal.pdf.page-thumbnails")
        private let originals = NSCache<NSNumber, UIImage>()
        private var document: PDFDocument?
        init(url: URL) {
            self.url = url
            originals.countLimit = 40
            originals.totalCostLimit = 16 * 1024 * 1024
        }
        func image(page: Int, rows: Rows) async -> NativeThumbnailWorkQueue.ImageBox? {
            await queue.image { [self] in
                let key = NSNumber(value: page)
                let base: UIImage
                if let cached = originals.object(forKey: key) { base = cached }
                else {
                    if document == nil { document = PDFDocument(url: url) }
                    guard let pdfPage = document?.page(at: page - 1) else { return nil }
                    let coordinates = NativePDFPageCoordinates(page: pdfPage)
                    let scale = min(260 / max(1, coordinates.width), 520 / max(1, coordinates.height))
                    base = pdfPage.thumbnail(of: CGSize(width: coordinates.width * scale, height: coordinates.height * scale), for: .cropBox)
                    let cost = base.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                    originals.setObject(base, forKey: key, cost: cost)
                }
                guard !rows.values.isEmpty else { return base }
                return NativeThumbnailCompositeInput(base: base, rows: rows.values).render()
            }
        }
    }
}

struct NativePDFPageThumbnail: View {
    let source: NativePDFPageThumbnailSource?
    let page: Int
    var rows: [[String: Any]] = []
    var inkRevision = 0
    @State private var image: UIImage?
    @State private var loadedIdentity = ""
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
        .task(id: (source?.revision ?? "") + ":" + String(page) + ":" + String(inkRevision)) {
            let identity = (source?.revision ?? "") + ":" + String(page)
            if loadedIdentity != identity { image = nil; loadedIdentity = identity }
            let next = await source?.image(page: page, rows: rows, inkRevision: inkRevision)
            guard !Task.isCancelled else { return }
            image = next
        }
    }
}
