import SwiftUI
import PDFKit

/// Original PPT bytes remain immutable. The first conversion requires the
/// configured authenticated LibreOffice service; its PDF is retained locally.
struct LegacyPPTView: View {
    @EnvironmentObject private var model: AppModel
    let material: Material
    let onExport: (URL) -> Void
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        Group {
            if let converted, FileManager.default.fileExists(atPath: model.fileURL(converted).path) {
                PDFWorkspaceView(documentURL: model.fileURL(converted), materialID: converted.id, revision: converted.revision,
                    loadPage: { model.ink(converted, page: $0) }, savePage: { model.saveInk(converted, page: $0, data: $1) }, onExport: onExport, onPageNote: { model.openPageNote(converted, page: $0) }, initialPage: model.readingPage(converted), onPageChange: { model.saveReadingPage(converted, page: $0) })
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("슬라이드를 준비해요", systemImage: "rectangle.on.rectangle", description: Text("구형 PPT는 최초 한 번 서버에서 PDF로 변환합니다. 변환 후에는 오프라인으로 열고 필기할 수 있어요."))
                    if busy { ProgressView("변환 중…") }
                    else { Button("슬라이드 변환", action: convert).buttonStyle(.borderedProminent) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
                    Spacer()
                }
            }
        }.task(id: material.revision) {
            let cached = destination
            if converted == nil, FileManager.default.fileExists(atPath: cached.path), PDFDocument(url: cached)?.pageCount ?? 0 > 0 { do { try model.registerConvertedPDF(cached, source: material) } catch { self.error = error.localizedDescription } }
        }
    }
    private var converted: Material? { model.materials.first { $0.kind == .pdf && $0.sourceMaterialID == material.id && $0.sourceRevision == material.revision && $0.sourcePage == nil } }
    private var destination: URL { model.root.appendingPathComponent("Converted/\(material.id)/\(material.revision).pdf") }
    private func convert() {
        guard !busy else { return }; busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await model.sync.convertLegacyPPT(from: model.fileURL(material), to: destination); try model.registerConvertedPDF(destination, source: material); try await model.flushChecked() }
            catch { self.error = error.localizedDescription }
        }
    }
}
