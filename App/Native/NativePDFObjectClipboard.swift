import UIKit
import UniformTypeIdentifiers

/// Images travel as bytes, never as a reference to another course's assets.
/// The original array format remains the fast path for ink-only selections.
enum NativePDFObjectClipboard {
    static let type = "com.bandal.pdf-objects-with-images"
    struct Encoded: Sendable { let data: Data; let png: Data? }
    struct Decoded: @unchecked Sendable {
        let rows: [[String: Any]]
        let images: [String: UIImage]
    }
    private struct Snapshot: @unchecked Sendable {
        let rows: [[String: Any]]
        let paths: [String: URL]
    }
    @MainActor static func encode(_ source: [[String: Any]], courseID: String, store: NativeWorkspaceStore) async throws -> Encoded {
        var rows: [[String: Any]] = [], paths: [String: URL] = [:], tokens: [String: String] = [:]
        for object in source {
            guard let kind = object["kind"], var data = object["data"] as? [String: Any], let style = object["style"] else {
                throw NativePDFError.invalid("선택한 개체를 복사하지 못했습니다.")
            }
            if kind as? String == "image" {
                guard let image = data["image"] as? [String: Any], let path = image["relPath"] as? String else {
                    throw NativePDFError.invalid("이미지 원본을 찾지 못했습니다.")
                }
                let token: String
                if let existing = tokens[path] { token = existing }
                else {
                    guard paths.count < NativeEditorMediaImport.maximumItems,
                          let resolved = try await store.invokePrivate("nativeMaterial:path", ["courseId": courseID, "relPath": path]) as? String else {
                        throw NativePDFError.invalid("한 번에 최대 20개의 이미지를 복사할 수 있습니다.")
                    }
                    token = String(paths.count); tokens[path] = token; paths[token] = URL(fileURLWithPath: resolved)
                }
                data["image"] = ["clipboardAsset": token, "label": image["label"] as? String ?? "이미지"]
            }
            rows.append(["page": object["page"] ?? 1, "kind": kind, "data": data, "style": style])
        }
        let snapshot = Snapshot(rows: rows, paths: paths)
        return try await Task.detached(priority: .userInitiated) {
            var assets: [String: String] = [:], png: Data?
            let budget = NativeEditorMediaImport.Budget()
            for (token, url) in snapshot.paths {
                let item = try NativeEditorMediaImport.readFile(url, imagesOnly: true, budget: budget)
                assets[token] = item.data.base64EncodedString()
                if snapshot.rows.count == 1, let image = item.image { png = try NativeEditorMediaImport.imageBytes(image) }
            }
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "objects": snapshot.rows, "assets": assets])
            guard data.count <= 150 * 1024 * 1024 else { throw NativePDFError.invalid("복사할 이미지가 너무 큽니다. 나누어 복사해 주세요.") }
            return Encoded(data: data, png: png)
        }.value
    }
    static func decode(_ data: Data) async throws -> Decoded {
        try await Task.detached(priority: .userInitiated) { try decodePayload(data) }.value
    }
    static func decodePayload(_ data: Data) throws -> Decoded {
        guard data.count <= 150 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["version"] as? Int == 1,
              let rows = value["objects"] as? [[String: Any]], !rows.isEmpty, rows.count <= 100_000,
              let assets = value["assets"] as? [String: String], assets.count <= NativeEditorMediaImport.maximumItems else {
            throw NativePDFError.invalid("복사한 개체 자료를 읽지 못했습니다.")
        }
        var images: [String: UIImage] = [:]
        let budget = NativeEditorMediaImport.Budget()
        for (token, encoded) in assets {
            guard let bytes = Data(base64Encoded: encoded),
                  let image = try NativeEditorMediaImport.decoded(bytes, name: "이미지", type: .data, imagesOnly: true, budget: budget).image else {
                throw NativePDFError.invalid("복사한 이미지 자료가 올바르지 않습니다.")
            }
            images[token] = image
        }
        for row in rows {
            let kind = try NativePDFRepositoryValidation.kind(row["kind"])
            _ = try NativePDFRepositoryValidation.style(row["style"])
            _ = try NativePDFRepositoryValidation.integer(row["page"], "page")
            var data = try NativePDFRepositoryValidation.object(row["data"], "data")
            if kind == "image" {
                guard let source = data["image"] as? [String: Any],
                      let token = source["clipboardAsset"] as? String, images[token] != nil else {
                    throw NativePDFError.invalid("복사한 이미지 원본이 빠져 있습니다.")
                }
                data["image"] = ["relPath": "clipboard.png", "label": source["label"] as? String ?? "이미지"]
            }
            _ = try NativePDFRepositoryValidation.data(data, kind: kind)
        }
        return Decoded(rows: rows, images: images)
    }
    static func replacingAssets(in rows: [[String: Any]], with paths: [String: String]) throws -> [[String: Any]] {
        try rows.map { source in
            var row = source
            // Clipboard content cannot choose an existing drawing's identity.
            for key in ["id", "courseId", "relPath", "nativePath", "_nativeInk"] { row.removeValue(forKey: key) }
            if row["kind"] as? String == "image" {
                guard var data = row["data"] as? [String: Any], let image = data["image"] as? [String: Any],
                      let token = image["clipboardAsset"] as? String, let path = paths[token] else {
                    throw NativePDFError.invalid("붙여넣을 이미지 원본을 확인하지 못했습니다.")
                }
                data["image"] = ["relPath": path, "label": image["label"] as? String ?? "이미지"]; row["data"] = data
            }
            return row
        }
    }
}
