import Foundation

/// Incremental host scene updates. Only rows whose identity+updatedAt changed
/// travel again; the host keeps the rest. The same shape serves `drawingPatch`
/// (whole document) and `objectPatch` (one page).
enum NativePDFScenePatch {
    typealias Fingerprints = [String: String]

    /// `volatile` ids (gesture previews) carry no fresh updatedAt and are resent every time.
    /// `previous == nil` resets the host's rows; otherwise `baseRevision` must be its current revision.
    static func patch(rows: [[String: Any]], previous: Fingerprints?, baseRevision: Int, revision: Int,
                      volatile: Set<String> = []) -> (patch: [String: Any], fingerprints: Fingerprints) {
        var prints: Fingerprints = [:], order: [String] = [], upserts: [[String: Any]] = []
        prints.reserveCapacity(rows.count); order.reserveCapacity(rows.count)
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, prints[id] == nil else { continue }
            let print = volatile.contains(id) ? "volatile.\(revision)" : (row["updatedAt"] as? String ?? "unknown.\(revision)")
            prints[id] = print; order.append(id)
            if previous?[id] != print { upserts.append(row) }
        }
        let reset = previous == nil
        return (["reset": reset, "baseRevision": reset ? 0 : baseRevision, "revision": revision, "order": order, "upserts": upserts], prints)
    }
}
