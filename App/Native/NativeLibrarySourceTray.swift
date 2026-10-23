import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A provider retains its staged file for the full drag, even if the user closes
/// the tray before the destination has finished reading it.
final class NativeLibrarySourceAsset: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let ownedDirectory: URL
    var name: String { url.lastPathComponent }
    var type: UTType { UTType(filenameExtension: url.pathExtension) ?? .data }
    init(url: URL, ownedDirectory: URL) { self.url = url; self.ownedDirectory = ownedDirectory }
    deinit { try? FileManager.default.removeItem(at: ownedDirectory) }
    func provider() -> NSItemProvider { NativeLibraryAssetProvider.make(url: url, retaining: self) }

    static func stage(_ source: URL, under root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("BandalSourceTray", isDirectory: true)) throws -> NativeLibrarySourceAsset {
        guard source.isFileURL else { throw DesktopRuntimeError("파일을 선택해 주세요.") }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        let scope = source.startAccessingSecurityScopedResource()
        defer { if scope { source.stopAccessingSecurityScopedResource() } }
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { available in
                do {
                    let info = try available.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { throw DesktopRuntimeError("폴더 대신 파일을 선택해 주세요.") }
                    try FileManager.default.copyItem(at: available, to: target)
                } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            return NativeLibrarySourceAsset(url: target, ownedDirectory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func photo(from provider: NSItemProvider) async throws -> NativeLibrarySourceAsset {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? DesktopRuntimeError("사진을 불러오지 못했습니다.")); return
                }
                // The picker owns this URL until its callback returns. Copy now,
                // before resuming the UI task or the provider's lease expires.
                do { continuation.resume(returning: try stage(url)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
final class NativeLibrarySourceTrayModel: ObservableObject {
    @Published private(set) var assets: [NativeLibrarySourceAsset] = []
    @Published private(set) var working = false
    @Published var error: String?
    private let maximumAssets = 30
    var remainingCapacity: Int { max(0, maximumAssets - assets.count) }

    func add(files: [URL]) {
        guard !working else { return }
        let sources = Array(files.prefix(remainingCapacity))
        guard !sources.isEmpty else { error = "보관함에서 사용한 항목을 지운 뒤 다시 선택해 주세요."; return }
        working = true
        Task {
            defer { working = false }
            var failures: [String] = []
            for source in sources {
                do { assets.append(try await Task.detached(priority: .userInitiated) { try NativeLibrarySourceAsset.stage(source) }.value) }
                catch { failures.append(source.lastPathComponent + ": " + error.localizedDescription) }
            }
            if files.count > sources.count { failures.append("보관함에는 최대 30개까지 담을 수 있습니다.") }
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    func add(photos providers: [NSItemProvider]) {
        guard !working, !providers.isEmpty else { return }
        let selected = Array(providers.prefix(remainingCapacity))
        guard !selected.isEmpty else { error = "보관함에서 사용한 항목을 지운 뒤 다시 선택해 주세요."; return }
        working = true
        Task {
            defer { working = false }
            var failures: [String] = []
            for provider in selected {
                do { assets.append(try await NativeLibrarySourceAsset.photo(from: provider)) }
                catch { failures.append(error.localizedDescription) }
            }
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    func remove(_ asset: NativeLibrarySourceAsset) { assets.removeAll { $0.id == asset.id } }
    func clear() { assets.removeAll() }
    #if DEBUG
    private var fixtureLoaded = false
    func loadFixtureIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing"), arguments.contains("--native-library-source-fixture"), !fixtureLoaded else { return }
        fixtureLoaded = true
        guard assets.isEmpty else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BandalSourceFixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { renderer in
                UIColor.systemBlue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
                UIColor.white.setFill(); renderer.fill(CGRect(x: 25, y: 20, width: 70, height: 40))
            }
            let url = folder.appendingPathComponent("Drag Fixture.png")
            guard let data = image.pngData() else { return }
            try data.write(to: url)
            assets = [try NativeLibrarySourceAsset.stage(url)]
        } catch { self.error = error.localizedDescription }
    }
    #endif
}

struct NativeLibrarySourceTray: View {
    @ObservedObject var store: NativeWorkspaceStore
    let folderPath: String
    @ObservedObject var model: NativeLibrarySourceTrayModel
    @State private var expanded = false
    @State private var photosPresented = false
    @State private var filesPresented = false
    @State private var saving = false
    @State private var savedAssetID: UUID?

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: {
                    Label("사진 · 파일", systemImage: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .medium)).frame(minHeight: 30).contentShape(Rectangle())
                }.accessibilityIdentifier("native-library-sources-toggle")
                Spacer(minLength: 0)
                if model.working || saving { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 8) {
                sourceButton("사진", symbol: "photo.on.rectangle", identifier: "native-library-source-photos") {
                    expanded = true; photosPresented = true
                }
                .accessibilityLabel("사진 앱에서 선택")
                sourceButton("파일", symbol: "folder", identifier: "native-library-source-files") {
                    expanded = true; filesPresented = true
                }
                .accessibilityLabel("파일 앱에서 선택")
            }
            Text("사진·파일에서 골라 문서로 드래그")
                .font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            if expanded {
                if model.assets.isEmpty {
                    Text("사진이나 파일을 선택한 뒤\n문서로 끌어다 놓으세요.")
                        .font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).frame(height: 56)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(model.assets) { asset in sourceCard(asset) }
                        }.padding(.vertical, 2)
                    }.frame(height: 118)
                    HStack {
                        Text("문서로 드래그 · \(model.assets.count)개").font(.system(size: 10)).foregroundStyle(NativeDesktopTheme.muted)
                        Spacer()
                        Button("비우기") { model.clear() }.font(.system(size: 10)).disabled(saving)
                            .accessibilityLabel("사진 파일 보관함 비우기")
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .task {
            #if DEBUG
            model.loadFixtureIfRequested()
            #endif
            if !model.assets.isEmpty { expanded = true }
        }
        .onChange(of: model.assets.isEmpty) { _, isEmpty in
            if !isEmpty { expanded = true }
        }
        .overlay(alignment: .top) { NativeDesktopTheme.border.frame(height: 1) }
        .sheet(isPresented: $photosPresented) {
            NativeLibraryPhotoPicker(limit: max(1, model.remainingCapacity)) { providers in
                photosPresented = false
                model.add(photos: providers)
            }
        }
        .fileImporter(isPresented: $filesPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.add(files: urls)
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .alert("사진·파일을 처리하지 못했어요", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("확인", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private func sourceButton(_ title: String, symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(NativeDesktopTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .disabled(model.working || model.remainingCapacity == 0)
    }
    private func sourceCard(_ asset: NativeLibrarySourceAsset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NativeLibraryThumbnail(url: asset.url, symbol: asset.type.conforms(to: .image) ? "photo" : "doc")
                .frame(width: 84, height: 74)
                .onDrag { asset.provider() }
                .accessibilityElement(children: .ignore)
                .accessibilityHidden(false)
                .accessibilityLabel(asset.name + ", 문서로 드래그")
                .accessibilityIdentifier("native-library-source-asset-" + asset.name)
                .accessibilityValue(sourceIdentityForTesting(asset))
            Text(asset.name).font(.system(size: 10)).lineLimit(1).frame(width: 84, alignment: .leading)
            HStack(spacing: 5) {
                Button { save(asset) } label: {
                    Image(systemName: savedAssetID == asset.id ? "checkmark" : "tray.and.arrow.down")
                    Text(savedAssetID == asset.id ? "저장됨" : "저장")
                }.disabled(store.selectedCourseID == nil || saving)
                    .accessibilityLabel(asset.name + " 자료에 저장")
                Spacer(minLength: 0)
                Button { model.remove(asset) } label: { Image(systemName: "xmark") }
                    .disabled(saving).accessibilityLabel(asset.name + " 보관함에서 제거")
            }.font(.system(size: 10)).frame(width: 84)
        }
    }
    private func sourceIdentityForTesting(_ asset: NativeLibrarySourceAsset) -> String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-ui-testing") { return asset.id.uuidString }
        #endif
        return ""
    }
    private func save(_ asset: NativeLibrarySourceAsset) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do { try await store.importFiles([asset.url], parentPath: folderPath); savedAssetID = asset.id }
            catch { model.error = error.localizedDescription }
        }
    }
}

private struct NativeLibraryPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let onSelection: ([NSItemProvider]) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = limit
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelection: ([NSItemProvider]) -> Void
        init(onSelection: @escaping ([NSItemProvider]) -> Void) { self.onSelection = onSelection }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onSelection(results.map(\.itemProvider))
        }
    }
}
