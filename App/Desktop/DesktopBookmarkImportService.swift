import Foundation
import UIKit
import UniformTypeIdentifiers

/// Files are user-picked and bounded natively; the original TS parser and
/// favorites repository perform one atomic, profile-scoped import.
@MainActor
final class DesktopBookmarkImportService: NSObject, UIDocumentPickerDelegate {
    weak var presenter: UIViewController?
    var profileExists: (String) -> Bool = { $0 == "default" }
    private let invoke: (String, [String: Any]) async throws -> Any
    private let pickOverride: (() async throws -> URL?)?
    private var selection: CheckedContinuation<URL?, Error>?
    private var activeProfile: String?
    static let maximumBytes = 8 * 1024 * 1024

    init(invoke: @escaping (String, [String: Any]) async throws -> Any, pick: (() async throws -> URL?)? = nil) {
        self.invoke = invoke; pickOverride = pick
    }
    func isImporting(_ profile: String) -> Bool { activeProfile == profile }

    func handle(_ request: [String: Any]) async throws -> Any {
        guard activeProfile == nil else { throw DesktopRuntimeError("진행 중인 북마크 가져오기를 먼저 마쳐 주세요.") }
        let profile = request["profileId"] as? String ?? "default"
        guard (profile == "default" || UUID(uuidString: profile) != nil), profileExists(profile) else { throw DesktopRuntimeError("브라우저 프로필을 확인해 주세요.") }
        activeProfile = profile
        defer { activeProfile = nil }
        let picked: URL?
        if let pickOverride { picked = try await pickOverride() } else { picked = try await pickHTML() }
        guard let file = picked else { return ["imported": 0, "skipped": 0, "ignored": 0, "cancelled": true] }
        guard profileExists(profile) else { throw DesktopRuntimeError("브라우저 프로필이 삭제되었습니다.") }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard properties.isRegularFile == true, let bytes = properties.fileSize, bytes <= Self.maximumBytes else { throw DesktopRuntimeError("8MB 이하의 HTML 북마크 파일을 선택해 주세요.") }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes, let html = String(data: data, encoding: .utf8) else { throw DesktopRuntimeError("UTF-8 HTML 북마크 파일을 읽지 못했습니다.") }
        return try await invoke("nativeBookmark:import", ["profileId": profile, "html": html])
    }

    private func pickHTML() async throws -> URL? {
        guard selection == nil, let presenter, presenter.presentedViewController == nil else { throw DesktopRuntimeError("열린 파일 선택 창을 먼저 닫아 주세요.") }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.html], asCopy: true)
        picker.allowsMultipleSelection = false; picker.delegate = self
        return try await withCheckedThrowingContinuation { pending in
            selection = pending; presenter.present(picker, animated: true)
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { let pending = selection; selection = nil; pending?.resume(returning: urls.first) }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { let pending = selection; selection = nil; pending?.resume(returning: nil) }
}
