import Foundation

/// Conservative page-level merge for the app's versioned portable ink wrapper.
/// Independent new IDs merge; ambiguous same-object edits retain a conflict.
/// Native PencilKit caches are discarded after portable content changes.
enum DrawingMerge {
    private struct Wrapper: Codable {
        let materialID: String
        let documentRevision: String
        let page: Int
        let data: Data
    }

    static func merge(local: StoredRecord, remote: StoredRecord) throws -> StoredRecord? {
        guard local.kind == "drawing", remote.kind == "drawing", !local.deleted, !remote.deleted,
              let left = try? JSONDecoder().decode(Wrapper.self, from: local.payload),
              let right = try? JSONDecoder().decode(Wrapper.self, from: remote.payload),
              left.materialID == right.materialID, left.documentRevision == right.documentRevision,
              left.page == right.page,
              let a = try? JSONSerialization.jsonObject(with: left.data) as? [String: Any],
              var b = try? JSONSerialization.jsonObject(with: right.data) as? [String: Any],
              (a["schemaVersion"] as? Int) == 1, (b["schemaVersion"] as? Int) == 1,
              (a["coordinateSpace"] as? String) == "unrotated-crop-box-top-left-normalized",
              (a["coordinateSpace"] as? String) == (b["coordinateSpace"] as? String),
              let aGeometry = a["geometry"] as? NSDictionary,
              let bGeometry = b["geometry"] as? NSDictionary, aGeometry == bGeometry else { return nil }
        for (objectsKey, deletedKey) in [("objects", "deletedObjectIDs"), ("highlights", "deletedHighlightIDs")] {
            guard let leftObjects = a[objectsKey] as? [[String: Any]],
                  let rightObjects = b[objectsKey] as? [[String: Any]] else { return nil }
            let leftDeleted = Set(a[deletedKey] as? [String] ?? [])
            let rightDeleted = Set(b[deletedKey] as? [String] ?? [])
            let deleted = leftDeleted.union(rightDeleted)
            var merged: [String: [String: Any]] = [:]
            for object in rightObjects {
                guard let id = object["id"] as? String, merged[id] == nil else { return nil }
                // Without a shared base, deletion vs an active object may be an
                // edit/delete race. Preserve both versions for explicit recovery.
                if leftDeleted.contains(id) && !rightDeleted.contains(id) { return nil }
                if !deleted.contains(id) { merged[id] = object }
            }
            var leftIDs = Set<String>()
            for object in leftObjects {
                guard let id = object["id"] as? String, leftIDs.insert(id).inserted else { return nil }
                if rightDeleted.contains(id) && !leftDeleted.contains(id) { return nil }
                if deleted.contains(id) { continue }
                if let existing = merged[id] {
                    guard equivalent(object, existing) else { return nil }
                } else { merged[id] = object }
            }
            // Stable order also provides identical overlap order on both devices.
            b[objectsKey] = merged.values.sorted {
                let leftKey = ($0["createdAt"] as? String ?? "") + ($0["id"] as? String ?? "")
                let rightKey = ($1["createdAt"] as? String ?? "") + ($1["id"] as? String ?? "")
                return leftKey < rightKey
            }
            b[deletedKey] = deleted.sorted()
        }
        b.removeValue(forKey: "nativeCache")
        if var objects = b["objects"] as? [[String: Any]] {
            for index in objects.indices { objects[index].removeValue(forKey: "nativeKey") }
            b["objects"] = objects
        }
        let portable = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        let payload = try JSONEncoder().encode(Wrapper(materialID: right.materialID, documentRevision: right.documentRevision,
                                                       page: right.page, data: portable))
        let merged = StoredRecord(id: remote.id, kind: remote.kind, payload: payload, revision: remote.revision + 1)
        // Two individually valid pages can exceed the transport cap after union.
        // Retain the normal conflict copies instead of enqueueing an invalid page.
        guard (try? validate(merged)) != nil else { return nil }
        return merged
    }

    private static func equivalent(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        var a = a, b = b
        for key in ["nativeKey", "createdAt", "updatedAt"] { a.removeValue(forKey: key); b.removeValue(forKey: key) }
        return NSDictionary(dictionary: a) == NSDictionary(dictionary: b)
    }
}

enum SyncAcknowledgement { case accepted, conflict, merged }
