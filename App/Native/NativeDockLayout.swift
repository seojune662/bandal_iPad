import Foundation
import CoreGraphics

/// Resource identity belongs to the document; pane identity belongs to its course layout.
/// Keeping them separate lets an editor move without creating a second writer.
struct NativeDockGroup: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var tabs: [String] = []
    var activeID: String?

    mutating func remove(_ documentID: String) {
        let previous = tabs.firstIndex(of: documentID) ?? 0
        tabs.removeAll { $0 == documentID }
        if activeID == documentID || !tabs.contains(activeID ?? "") {
            activeID = tabs.isEmpty ? nil : tabs[min(previous, tabs.count - 1)]
        }
    }
}

enum NativeDockAxis: String, Codable { case horizontal, vertical }
enum NativeDockDirection: String, CaseIterable, Codable {
    case within, left, right, above, below
    var axis: NativeDockAxis { self == .above || self == .below ? .vertical : .horizontal }
    var before: Bool { self == .left || self == .above }
    var title: String {
        switch self { case .within: "이 영역으로"; case .left: "왼쪽으로 분할"; case .right: "오른쪽으로 분할"; case .above: "위로 분할"; case .below: "아래로 분할" }
    }
    var symbol: String { axis == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}
enum NativeDockPreset: String, CaseIterable { case single, columns, rows, grid
    var title: String { switch self { case .single: "단일 영역"; case .columns: "좌우 2분할"; case .rows: "상하 2분할"; case .grid: "2×2 4분할" } }
    var symbol: String { switch self { case .single: "rectangle"; case .columns: "rectangle.split.2x1"; case .rows: "rectangle.split.1x2"; case .grid: "square.grid.2x2" } }
}
struct NativeDockSplit: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var axis: NativeDockAxis
    var fraction: Double = 0.5
    var first: NativeDockNode
    var second: NativeDockNode
}
indirect enum NativeDockNode: Codable, Equatable {
    case group(NativeDockGroup)
    case split(NativeDockSplit)

    var groups: [NativeDockGroup] {
        switch self { case .group(let group): [group]; case .split(let split): split.first.groups + split.second.groups }
    }
    func mapGroups(_ transform: (NativeDockGroup) -> NativeDockGroup) -> NativeDockNode {
        switch self {
        case .group(let group): return .group(transform(group))
        case .split(var split):
            split.first = split.first.mapGroups(transform); split.second = split.second.mapGroups(transform)
            return .split(split)
        }
    }
    func replacing(_ groupID: String, with node: NativeDockNode) -> NativeDockNode {
        switch self {
        case .group(let group): return group.id == groupID ? node : self
        case .split(var split):
            split.first = split.first.replacing(groupID, with: node); split.second = split.second.replacing(groupID, with: node)
            return .split(split)
        }
    }
    func removing(_ groupID: String) -> NativeDockNode? {
        switch self {
        case .group(let group): return group.id == groupID ? nil : self
        case .split(var split):
            let first = split.first.removing(groupID), second = split.second.removing(groupID)
            guard let first else { return second }; guard let second else { return first }
            split.first = first; split.second = second; return .split(split)
        }
    }
    func resizing(_ splitID: String, fraction: Double) -> NativeDockNode {
        guard fraction.isFinite else { return self }
        switch self {
        case .group: return self
        case .split(var split):
            if split.id == splitID { split.fraction = min(0.9, max(0.1, fraction)) }
            else { split.first = split.first.resizing(splitID, fraction: fraction); split.second = split.second.resizing(splitID, fraction: fraction) }
            return .split(split)
        }
    }
    var minimumSize: CGSize {
        switch self {
        case .group: return CGSize(width: 280, height: 220)
        case .split(let split):
            let a = split.first.minimumSize, b = split.second.minimumSize
            return split.axis == .horizontal ? CGSize(width: a.width + b.width + 8, height: max(a.height, b.height))
                : CGSize(width: max(a.width, b.width), height: a.height + b.height + 8)
        }
    }
}

struct NativeDockLayout: Codable, Equatable {
    var root: NativeDockNode
    var focusedGroupID: String
    /// Only the old two-pane API uses automatic merge-on-close semantics.
    var legacyPair = false

    init(group: NativeDockGroup = NativeDockGroup()) { root = .group(group); focusedGroupID = group.id }
    var groups: [NativeDockGroup] { geometry(in: CGRect(x: 0, y: 0, width: 10000, height: 10000)).panes.sorted {
        abs($0.frame.minY - $1.frame.minY) > 0.1 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
    }.map(\.group) }
    var focused: NativeDockGroup? { root.groups.first { $0.id == focusedGroupID } ?? root.groups.first }
    var activeID: String? { focused?.activeID }

    mutating func updateGroup(_ id: String, _ update: (inout NativeDockGroup) -> Void) {
        root = root.mapGroups { item in var group = item; if group.id == id { update(&group) }; return group }
    }
    @discardableResult mutating func split(_ groupID: String, direction: NativeDockDirection, tabs: [String] = []) -> String? {
        guard direction != .within, let group = root.groups.first(where: { $0.id == groupID }) else { return nil }
        let added = NativeDockGroup(tabs: tabs, activeID: tabs.first)
        root = root.replacing(groupID, with: .split(NativeDockSplit(axis: direction.axis,
            first: .group(direction.before ? added : group), second: .group(direction.before ? group : added))))
        focusedGroupID = added.id; legacyPair = false; return added.id
    }
    @discardableResult mutating func move(_ documentID: String, to groupID: String, direction: NativeDockDirection = .within, index: Int? = nil) -> Bool {
        guard let source = root.groups.first(where: { $0.tabs.contains(documentID) }),
              let target = root.groups.first(where: { $0.id == groupID }) else { return false }
        var insertion = max(0, min(index ?? target.tabs.count, target.tabs.count))
        if source.id == groupID, let old = source.tabs.firstIndex(of: documentID), old < insertion { insertion -= 1 }
        updateGroup(source.id) { $0.remove(documentID) }
        if direction == .within {
            updateGroup(groupID) { $0.tabs.insert(documentID, at: min(insertion, $0.tabs.count)); $0.activeID = documentID }
            focusedGroupID = groupID
        } else { _ = split(groupID, direction: direction, tabs: [documentID]) }
        legacyPair = false; return true
    }
    mutating func removeEmptyGroup(_ id: String) {
        guard root.groups.count > 1, root.groups.first(where: { $0.id == id })?.tabs.isEmpty == true,
              let remaining = root.removing(id) else { return }
        root = remaining
        if focusedGroupID == id { focusedGroupID = root.groups.first!.id }
        legacyPair = false
    }
    mutating func merge(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID, let source = root.groups.first(where: { $0.id == sourceID }), root.groups.contains(where: { $0.id == targetID }) else { return }
        let active = focusedGroupID == sourceID ? source.activeID : nil
        updateGroup(targetID) { group in group.tabs += source.tabs.filter { !group.tabs.contains($0) }; if let active { group.activeID = active } }
        if let remaining = root.removing(sourceID) { root = remaining }
        focusedGroupID = targetID; legacyPair = false
    }
    mutating func apply(_ preset: NativeDockPreset) {
        let previous = groups, ids = previous.flatMap(\.tabs), selected = activeID
        let count = preset == .grid ? 4 : preset == .single ? 1 : 2
        var offset = 0
        let next = (0..<count).map { index -> NativeDockGroup in
            let length = ids.count / count + (index < ids.count % count ? 1 : 0)
            let tabs = Array(ids[offset..<(offset + length)]); offset += length
            return NativeDockGroup(id: index < previous.count ? previous[index].id : UUID().uuidString,
                tabs: tabs, activeID: selected.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first)
        }
        if preset == .single { root = .group(next[0]) }
        else if preset == .grid {
            root = .split(NativeDockSplit(axis: .horizontal,
                first: .split(NativeDockSplit(axis: .vertical, first: .group(next[0]), second: .group(next[2]))),
                second: .split(NativeDockSplit(axis: .vertical, first: .group(next[1]), second: .group(next[3])))))
        } else { root = .split(NativeDockSplit(axis: preset == .rows ? .vertical : .horizontal, first: .group(next[0]), second: .group(next[1]))) }
        focusedGroupID = next.first(where: { $0.tabs.contains(selected ?? "") })?.id ?? next[0].id; legacyPair = false
    }
    /// Sanitize persisted layouts after availability checks, path changes and old snapshots.
    mutating func reconcile(validIDs: Set<String>, replacements: [String: String] = [:]) {
        let oldActive = activeID.map { replacements[$0] ?? $0 }
        var seenTabs = Set<String>(), seenGroups = Set<String>()
        root = root.mapGroups { original in
            var group = original
            if !seenGroups.insert(group.id).inserted { group.id = UUID().uuidString }
            group.tabs = group.tabs.map { replacements[$0] ?? $0 }.filter { validIDs.contains($0) && seenTabs.insert($0).inserted }
            group.activeID = group.activeID.map { replacements[$0] ?? $0 }
            if !group.tabs.contains(group.activeID ?? "") { group.activeID = group.tabs.first }
            return group
        }
        if !root.groups.contains(where: { $0.id == focusedGroupID }) { focusedGroupID = root.groups.first!.id }
        if let oldActive, let group = root.groups.first(where: { $0.tabs.contains(oldActive) }) { focusedGroupID = group.id; updateGroup(group.id) { $0.activeID = oldActive } }
        if legacyPair, root.groups.contains(where: { $0.tabs.isEmpty }) { apply(.single) }
    }
}

struct NativeDockPaneFrame: Identifiable { var group: NativeDockGroup; var frame: CGRect; var id: String { group.id } }
struct NativeDockDividerFrame: Identifiable {
    var split: NativeDockSplit
    var frame: CGRect
    var bounds: CGRect
    var id: String { split.id }
    /// The seam remains eight points wide; only its transparent touch target
    /// overlaps the neighbouring editors.
    var hitFrame: CGRect {
        split.axis == .horizontal
            ? frame.insetBy(dx: -(max(44, frame.width) - frame.width) / 2, dy: 0)
            : frame.insetBy(dx: 0, dy: -(max(44, frame.height) - frame.height) / 2)
    }
    var displayedFraction: Double {
        let horizontal = split.axis == .horizontal
        let extent = max(1, (horizontal ? bounds.width - frame.width : bounds.height - frame.height))
        return Double((horizontal ? frame.minX - bounds.minX : frame.minY - bounds.minY) / extent)
    }
}
struct NativeDockGeometry { var panes: [NativeDockPaneFrame] = []; var dividers: [NativeDockDividerFrame] = [] }
extension NativeDockLayout {
    func geometry(in bounds: CGRect) -> NativeDockGeometry {
        var result = NativeDockGeometry()
        func walk(_ node: NativeDockNode, _ frame: CGRect) {
            switch node {
            case .group(let group): result.panes.append(NativeDockPaneFrame(group: group, frame: frame))
            case .split(let split):
                let horizontal = split.axis == .horizontal, extent = max(0, (horizontal ? frame.width : frame.height) - 8)
                let a = split.first.minimumSize, b = split.second.minimumSize
                let low = horizontal ? a.width : a.height, high = horizontal ? b.width : b.height
                let ratio = split.fraction.isFinite ? min(0.9, max(0.1, split.fraction)) : 0.5
                let length = extent >= low + high ? min(extent - high, max(low, extent * ratio)) : extent * ratio
                let first = CGRect(x: frame.minX, y: frame.minY, width: horizontal ? length : frame.width, height: horizontal ? frame.height : length)
                let divider = CGRect(x: horizontal ? first.maxX : frame.minX, y: horizontal ? frame.minY : first.maxY, width: horizontal ? 8 : frame.width, height: horizontal ? frame.height : 8)
                let second = CGRect(x: horizontal ? divider.maxX : frame.minX, y: horizontal ? frame.minY : divider.maxY, width: horizontal ? extent - length : frame.width, height: horizontal ? frame.height : extent - length)
                result.dividers.append(NativeDockDividerFrame(split: split, frame: divider, bounds: frame)); walk(split.first, first); walk(split.second, second)
            }
        }
        walk(root, bounds); return result
    }
}

extension NativeDocumentReference {
    var isWorkspaceTool: Bool { ["browser", "assistant", "recordings", "planner", "learning-home"].contains(kind) }
}

enum NativeDockRailSide {
    case left, right
    var minimum: Double { self == .left ? 176 : 220 }
    var maximum: Double { self == .left ? 400 : 520 }
    var defaultWidth: Double { self == .left ? 240 : 288 }
    func clamp(_ width: Double) -> Double {
        width.isFinite ? min(maximum, max(minimum, width.rounded())) : defaultWidth
    }
}
struct NativeDockRailWidths: Equatable {
    var left: Double
    var right: Double
    static func resolve(windowWidth: Double, leftRequested: Double, rightRequested: Double, showLeft: Bool, showRight: Bool) -> NativeDockRailWidths {
        var left = showLeft ? NativeDockRailSide.left.clamp(leftRequested) : 0
        var right = showRight ? NativeDockRailSide.right.clamp(rightRequested) : 0
        // Preserve a usable editor when a resized iPad window gets narrower.
        let budget = max(0, windowWidth - 48 - 280 - (showLeft ? 1 : 0) - (showRight ? 1 : 0))
        if left + right > budget, showRight { right = max(NativeDockRailSide.right.minimum, budget - left) }
        if left + right > budget, showLeft { left = max(NativeDockRailSide.left.minimum, budget - right) }
        return .init(left: left, right: right)
    }
}
