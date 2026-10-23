import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = BandalShareModel(context: extensionContext)
        let host = UIHostingController(rootView: BandalShareView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        preferredContentSize = CGSize(width: 540, height: 560)
    }
}

@MainActor
private final class BandalShareModel: ObservableObject {
    @Published var catalog: BandalShareCatalog?
    @Published var courseID = ""
    @Published var folderPath = ""
    @Published var errorMessage: String?
    @Published var saving = false
    @Published var progress = 0
    @Published var saved = false
    private let context: NSExtensionContext?
    private(set) var providers: [NSItemProvider] = []
    private var fallbackText: String?
    var itemCount: Int { providers.isEmpty && fallbackText != nil ? 1 : providers.count }
    var selectedCourse: BandalShareCatalog.Course? { catalog?.courses.first { $0.id == courseID } }

    init(context: NSExtensionContext?) {
        self.context = context
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        providers = items.flatMap { $0.attachments ?? [] }
        let text = items.compactMap { $0.attributedContentText?.string }.joined(separator: "\n\n")
        fallbackText = text.isEmpty ? nil : text
    }

    func load() async {
        guard let inbox = BandalShareInbox.connected() else {
            errorMessage = "반달 공유 저장소를 열 수 없습니다. 반달 앱을 먼저 연 뒤 다시 공유해 주세요."
            return
        }
        do {
            let value = try await Task.detached(priority: .userInitiated) { try inbox.readCatalog() }.value
            catalog = value
            courseID = value.courses.first?.id ?? ""
            if value.courses.isEmpty { errorMessage = "반달에서 과목을 만든 뒤 다시 공유해 주세요." }
            if itemCount == 0 { errorMessage = "가져올 파일이나 텍스트가 없습니다." }
            if itemCount > BandalShareInbox.maximumItems { errorMessage = "한 번에 최대 20개까지 공유할 수 있습니다." }
        } catch { errorMessage = "반달 앱을 한 번 열어 과목과 폴더 목록을 준비한 뒤 다시 공유해 주세요." }
    }

    func cancel() { context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
    func finish() { context?.completeRequest(returningItems: nil) }

    func save() async {
        guard !saving, let catalog, let selectedCourse, let inbox = BandalShareInbox.connected(),
              itemCount > 0, itemCount <= BandalShareInbox.maximumItems else { return }
        guard folderPath.isEmpty || selectedCourse.folders.contains(folderPath) else { return }
        saving = true; errorMessage = nil; progress = 0
        defer { saving = false }
        let batchID = UUID().uuidString.lowercased()
        do {
            let staging = try inbox.beginBatch(id: batchID)
            // A cancelled/failed request is never exposed as a partial batch.
            defer { try? FileManager.default.removeItem(at: staging) }
            var staged: [BandalShareBatch.Item] = []
            if providers.isEmpty, let fallbackText {
                staged.append(try inbox.stageText(fallbackText, name: "공유 텍스트.md", in: staging))
            } else {
                for provider in providers {
                    try Task.checkCancellation()
                    let item = try await Self.stage(provider, inbox: inbox, directory: staging)
                    staged.append(item)
                    guard staged.reduce(Int64(0), { $0 + $1.byteCount }) <= BandalShareInbox.maximumBatchBytes else {
                        throw BandalShareInbox.Failure(message: "한 번에 총 250MB까지 공유할 수 있습니다.")
                    }
                    progress = staged.count
                }
            }
            let batch = BandalShareBatch(id: batchID, workspaceID: catalog.workspaceID, courseID: selectedCourse.id,
                folderPath: folderPath, createdAt: Date(), items: staged)
            try await Task.detached(priority: .userInitiated) { try inbox.commit(batch, staging: staging) }.value
            saved = true
        } catch { errorMessage = error.localizedDescription }
    }

    /// loadFileRepresentation URLs disappear when their callback returns, so
    /// copy into our group container before resuming the continuation.
    nonisolated private static func stage(_ provider: NSItemProvider, inbox: BandalShareInbox, directory: URL) async throws -> BandalShareBatch.Item {
        let suggestedName = provider.suggestedName
        let fileType = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .image) || identifier == "net.daringfireball.markdown"
        }
        if let fileType {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: fileType) { source, error in
                    do {
                        if let error { throw error }
                        guard let source else { throw BandalShareInbox.Failure(message: "공유 파일을 불러오지 못했습니다.") }
                        let ext = UTType(fileType)?.preferredFilenameExtension ?? source.pathExtension
                        let suggested = suggestedName ?? source.lastPathComponent
                        let name = (suggested as NSString).pathExtension.isEmpty && !ext.isEmpty ? suggested + "." + ext : suggested
                        continuation.resume(returning: try inbox.stageFile(source, name: name, in: directory))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if provider.canLoadObject(ofClass: NSURL.self) {
                return try await withCheckedThrowingContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSURL.self) { object, error in
                        do {
                            if let error { throw error }
                            let url = (object as? NSURL).map { $0 as URL }
                            continuation.resume(returning: try stageFileURL(url, inbox: inbox, directory: directory))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
            }
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    do {
                        if let error { throw error }
                        let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        continuation.resume(returning: try stageFileURL(url, inbox: inbox, directory: directory))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let isURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        let type = isURL ? UTType.url.identifier : UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else {
            throw BandalShareInbox.Failure(message: "이 공유 항목의 형식을 지원하지 않습니다.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                do {
                    if let error { throw error }
                    if let url = value as? URL, url.isFileURL {
                        continuation.resume(returning: try inbox.stageFile(url, name: url.lastPathComponent, in: directory))
                        return
                    }
                    let text: String
                    if let url = value as? URL { text = url.absoluteString }
                    else if let string = value as? String { text = string }
                    else if let attributed = value as? NSAttributedString { text = attributed.string }
                    else if let data = value as? Data, data.count <= 5 * 1024 * 1024, let string = String(data: data, encoding: .utf8) { text = string }
                    else { throw BandalShareInbox.Failure(message: "공유 텍스트를 읽을 수 없습니다.") }
                    if isURL {
                        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                            throw BandalShareInbox.Failure(message: "웹 링크는 http 또는 https 주소여야 합니다.")
                        }
                    }
                    let content = isURL ? "# 공유 링크\n\n\(text)\n" : text
                    continuation.resume(returning: try inbox.stageText(content, name: isURL ? "공유 링크.md" : "공유 텍스트.md", in: directory))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    nonisolated private static func stageFileURL(_ source: URL?, inbox: BandalShareInbox, directory: URL) throws -> BandalShareBatch.Item {
        guard let source, source.isFileURL,
              let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .plainText) || ["md", "markdown"].contains(source.pathExtension.lowercased()) else {
            throw BandalShareInbox.Failure(message: "PDF, 이미지, Markdown, 텍스트 파일을 공유할 수 있습니다.")
        }
        return try inbox.stageFile(source, name: source.lastPathComponent, in: directory)
    }
}

private struct BandalShareView: View {
    @ObservedObject var model: BandalShareModel
    var body: some View {
        NavigationStack {
            Group {
                if model.saved {
                    ContentUnavailableView {
                        Label("공유 자료를 보관했어요", systemImage: "checkmark.circle.fill")
                    } description: {
                        Text("반달을 열면 선택한 과목과 폴더에 추가됩니다.")
                    } actions: { Button("완료") { model.finish() }.buttonStyle(.borderedProminent) }
                } else {
                    Form {
                        Section("저장 위치") {
                            Picker("과목", selection: $model.courseID) {
                                ForEach(model.catalog?.courses ?? []) { course in Text(course.name).tag(course.id) }
                            }
                            .accessibilityIdentifier("bandal-share-course")
                            .onChange(of: model.courseID) { _, _ in model.folderPath = "" }
                            Picker("폴더", selection: $model.folderPath) {
                                Text("과목 최상위").tag("")
                                ForEach(model.selectedCourse?.folders ?? [], id: \.self) { Text($0).tag($0) }
                            }
                            .accessibilityIdentifier("bandal-share-folder")
                        }.disabled(model.saving)
                        Section {
                            Label("\(model.itemCount)개 항목", systemImage: "doc.on.doc")
                            Text("반달을 열면 선택한 위치에 추가됩니다.").font(.footnote).foregroundStyle(.secondary)
                            if model.saving { ProgressView("자료 보관 중… \(model.progress)/\(model.itemCount)") }
                            if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
                        }
                    }
                }
            }
            .navigationTitle("반달에 저장")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !model.saved {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { model.cancel() }.disabled(model.saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") { Task { await model.save() } }
                            .accessibilityIdentifier("bandal-share-save")
                            .disabled(model.saving || model.selectedCourse == nil || model.itemCount == 0 || model.itemCount > BandalShareInbox.maximumItems)
                    }
                }
            }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(model.saving)
    }
}
