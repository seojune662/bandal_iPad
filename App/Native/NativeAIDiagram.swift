import CoreGraphics
import Foundation

/// `draw_diagram`: the model names boxes and arrows, the app lays them out and puts them on the open PDF page
/// as ordinary rect, textbox, arrow and line objects (one undo step), in free space found by NativeAINotePlacement.
enum NativeAIDiagram {
    static let toolName = "draw_diagram"
    static let maxNodes = 12, maxEdges = 24, maxLabel = 40, maxTitle = 60

    /// The model's usage instructions live here, not in the system prompt.
    static var tool: [String: Any] {
        let node: [String: Any] = ["type": "object", "properties": ["id": ["type": "string", "description": "Unique short id used by edges."],
                                                                       "label": ["type": "string", "description": "Box text, under \(maxLabel) characters."]], "required": ["id", "label"]]
        let edge: [String: Any] = ["type": "object", "properties": ["from": ["type": "string"], "to": ["type": "string"],
                                                                       "label": ["type": "string", "description": "Optional word or two on the arrow."]], "required": ["from", "to"]]
        return ["name": toolName,
                "description": "Draw a diagram (labelled boxes joined by arrows) on the PDF page the user has open, as shapes they can move, edit or undo. Use it only when the user asks for a diagram, flowchart, concept map, hierarchy, cycle or other picture of how ideas connect. Give 2–\(maxNodes) nodes with short labels in the user's language and directed edges between node ids. The app arranges the layout and finds empty space on the page: never give coordinates, sizes or colours. Keep it small and focused on what was asked. Afterwards tell the user in one sentence that the diagram was added to the page and can be undone. If the tool fails, say why instead of describing a diagram that is not there.",
                "inputSchema": ["type": "object", "properties": [
                    "title": ["type": "string", "description": "Optional heading above the diagram, under \(maxTitle) characters."],
                    "nodes": ["type": "array", "minItems": 1, "maxItems": maxNodes, "items": node],
                    "edges": ["type": "array", "maxItems": maxEdges, "items": edge]], "required": ["nodes", "edges"]]]
    }

    /// The tools for one turn: `base` without this one, plus this one when the turn's document is a PDF.
    /// The reference scope limits what the model may read; drawing on the open PDF reads nothing.
    static func offered(_ base: [[String: Any]], from all: [[String: Any]], document: [String: Any]) -> [[String: Any]] {
        let others = base.filter { $0["name"] as? String != toolName }
        guard canDraw(on: document), let tool = all.first(where: { $0["name"] as? String == toolName }) else { return others }
        return others + [tool]
    }
    static func canDraw(on document: [String: Any]) -> Bool {
        document["kind"] as? String == "pdf" && document["courseId"] is String && (document["relPath"] as? String)?.lowercased().hasSuffix(".pdf") == true
    }

    struct Node: Equatable { let id: String; let label: String }
    struct Edge: Equatable { let from: Int; let to: Int; let label: String? }
    struct Spec: Equatable {
        var title: String?
        var nodes: [Node]
        var edges: [Edge]
    }

    static func parse(_ arguments: [String: Any]) throws -> Spec {
        func clipped(_ value: Any?, _ limit: Int) -> String? {
            guard let text = (value as? String)?.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
        }
        guard let rawNodes = arguments["nodes"] as? [[String: Any]], !rawNodes.isEmpty else { throw DesktopRuntimeError("도식에 넣을 노드를 하나 이상 주세요.") }
        guard rawNodes.count <= maxNodes else { throw DesktopRuntimeError("도식의 노드는 \(maxNodes)개까지입니다. 핵심만 남겨 다시 시도하세요.") }
        var nodes: [Node] = [], index: [String: Int] = [:]
        for raw in rawNodes {
            guard let id = clipped(raw["id"], 64), let label = clipped(raw["label"], maxLabel) else { throw DesktopRuntimeError("노드마다 id와 label이 필요합니다.") }
            guard index[id] == nil else { throw DesktopRuntimeError("노드 id ‘\(id)’가 중복됩니다.") }
            index[id] = nodes.count; nodes.append(Node(id: id, label: label))
        }
        let rawEdges = arguments["edges"] as? [[String: Any]] ?? []
        guard rawEdges.count <= maxEdges else { throw DesktopRuntimeError("도식의 연결은 \(maxEdges)개까지입니다.") }
        var edges: [Edge] = []
        for raw in rawEdges {
            guard let from = clipped(raw["from"], 64), let to = clipped(raw["to"], 64) else { throw DesktopRuntimeError("연결마다 from과 to가 필요합니다.") }
            guard let a = index[from], let b = index[to] else { throw DesktopRuntimeError("연결이 없는 노드 id를 가리킵니다: \(index[from] == nil ? from : to)") }
            guard a != b, !edges.contains(where: { $0.from == a && $0.to == b }) else { continue }
            edges.append(Edge(from: a, to: b, label: clipped(raw["label"], 24)))
        }
        return Spec(title: clipped(arguments["title"], maxTitle), nodes: nodes, edges: edges)
    }

    // MARK: Layout

    enum Direction: Equatable { case down, right }
    enum Role { case node, edge, title }
    /// A text box's size for `text` in `role`'s style no wider than the given width: its natural width there and its height.
    /// All sizes in page widths.
    typealias Measure = (_ text: String, _ role: Role, _ maxWidth: Double) -> CGSize

    /// Everything in page widths, from the diagram's top-left corner (y grows down, in page widths too).
    struct Layout {
        struct Connector { let points: [CGPoint]; let edge: Int; var label: CGRect? }
        var title: CGRect?
        var nodes: [CGRect]
        var connectors: [Connector]
        var size: CGSize
    }

    static let maxWidth = 0.84
    private static let nodeGap = 0.035, layerGap = 0.07, wideLayerGap = 0.09, titleGap = 0.02, channelGap = 0.03, endGap = 0.006

    /// Layers by longest path (an edge that closes a cycle is drawn back, not used for layering), ordered within
    /// each layer by the mean position of their neighbours, then packed and centred. Nil when it does not fit
    /// `maxWidth` going this way at this size.
    static func layout(_ spec: Spec, direction: Direction, measure: Measure) -> Layout? {
        let count = spec.nodes.count
        guard count > 0 else { return nil }
        let back = backEdges(spec)
        var layer = [Int](repeating: 0, count: count)
        let forward = spec.edges.enumerated().filter { !back.contains($0.offset) }.map(\.element)
        for _ in 0..<count { for edge in forward where layer[edge.to] < layer[edge.from] + 1 { layer[edge.to] = layer[edge.from] + 1 } }
        let depth = (layer.max() ?? 0) + 1
        var layers = (0..<depth).map { level in (0..<count).filter { layer[$0] == level } }
        // Barycentre sweeps: each node moves toward the mean order of its neighbours in the layer before (then after).
        for sweep in 0..<4 {
            for level in (sweep % 2 == 0 ? Array(1..<max(1, depth)) : Array((0..<max(0, depth - 1)).reversed())) {
                let neighbour = sweep % 2 == 0 ? level - 1 : level + 1
                let order = Dictionary(uniqueKeysWithValues: layers.flatMap { $0.enumerated().map { ($0.element, Double($0.offset)) } })
                layers[level].sort { a, b in
                    func mean(_ node: Int) -> Double {
                        let linked = spec.edges.compactMap { edge -> Double? in
                            if edge.from == node, layer[edge.to] == neighbour { return order[edge.to] }
                            if edge.to == node, layer[edge.from] == neighbour { return order[edge.from] }
                            return nil
                        }
                        return linked.isEmpty ? order[node] ?? 0 : linked.reduce(0, +) / Double(linked.count)
                    }
                    return (mean(a), order[a] ?? 0) < (mean(b), order[b] ?? 0)
                }
            }
        }
        let widest = layers.map(\.count).max() ?? 1
        let across = direction == .down ? widest : depth
        let gap = direction == .down ? nodeGap : wideLayerGap
        let room = min(direction == .down ? 0.26 : 0.24, (maxWidth - Double(across - 1) * gap) / Double(across))
        guard room >= 0.09 else { return nil }
        let width = min(room, max(0.1, spec.nodes.map { Double(measure($0.label, .node, room).width) }.max() ?? 0.1))
        let heights = spec.nodes.map { Double(measure($0.label, .node, width).height) }

        let title = spec.title.map { measure($0, .title, maxWidth) }
        var boxes = [CGRect](repeating: .zero, count: count)
        if direction == .down {
            let span = Double(widest) * width + Double(widest - 1) * nodeGap
            var y = 0.0
            for members in layers {
                let tall = members.map { heights[$0] }.max() ?? 0
                let row = Double(members.count) * width + Double(members.count - 1) * nodeGap
                for (slot, node) in members.enumerated() {
                    boxes[node] = CGRect(x: (span - row) / 2 + Double(slot) * (width + nodeGap), y: y + (tall - heights[node]) / 2, width: width, height: heights[node])
                }
                y += tall + layerGap
            }
        } else {
            let columns = layers.map { members in members.map { heights[$0] }.reduce(0, +) + Double(max(0, members.count - 1)) * nodeGap }
            let span = columns.max() ?? 0
            for (level, members) in layers.enumerated() {
                var y = (span - columns[level]) / 2
                for node in members {
                    boxes[node] = CGRect(x: Double(level) * (width + wideLayerGap), y: y, width: width, height: heights[node])
                    y += heights[node] + nodeGap
                }
            }
        }

        // Neighbouring layers join facing sides, so the arrow stays in the gap between them. Any other edge goes
        // straight when nothing is in the way, otherwise round the outside in a channel of its own, on whichever
        // side passes the fewest boxes.
        var connectors: [Layout.Connector] = []
        let content = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
        var channels = [0, 0]
        func crossings(_ points: [CGPoint], _ edge: Edge) -> Int {
            boxes.indices.filter { index in
                index != edge.from && index != edge.to && zip(points, points.dropFirst()).contains { crosses($0.0, $0.1, boxes[index].insetBy(dx: -0.004, dy: -0.004)) }
            }.count
        }
        for (index, edge) in spec.edges.enumerated() {
            let a = boxes[edge.from], b = boxes[edge.to]
            // A pair of opposite arrows runs side by side instead of on top of each other.
            let reverse = spec.edges.contains { $0.from == edge.to && $0.to == edge.from }
            if abs(layer[edge.from] - layer[edge.to]) == 1 {
                let onward = layer[edge.to] > layer[edge.from], shift = reverse ? (onward ? -0.01 : 0.01) : 0
                let points = direction == .down
                    ? [CGPoint(x: a.midX + shift, y: onward ? a.maxY + endGap : a.minY - endGap), CGPoint(x: b.midX + shift, y: onward ? b.minY - endGap : b.maxY + endGap)]
                    : [CGPoint(x: onward ? a.maxX + endGap : a.minX - endGap, y: a.midY + shift), CGPoint(x: onward ? b.minX - endGap : b.maxX + endGap, y: b.midY + shift)]
                connectors.append(.init(points: points, edge: index)); continue
            }
            var straight: [CGPoint] = []
            if let from = boundary(a, toward: CGPoint(x: b.midX, y: b.midY), from: CGPoint(x: a.midX, y: a.midY)),
               let to = boundary(b, toward: CGPoint(x: a.midX, y: a.midY), from: CGPoint(x: b.midX, y: b.midY)) { straight = [from, to] }
            if !straight.isEmpty, crossings([CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY)], edge) == 0 {
                connectors.append(.init(points: straight, edge: index)); continue
            }
            func channel(_ far: Bool) -> [CGPoint] {
                let lane = channelGap * Double(channels[far ? 1 : 0] + 1)
                if direction == .down {
                    let x = far ? content.maxX + lane : content.minX - lane
                    let ax = far ? a.maxX + endGap : a.minX - endGap, bx = far ? b.maxX + endGap : b.minX - endGap
                    return [CGPoint(x: ax, y: a.midY), CGPoint(x: x, y: a.midY), CGPoint(x: x, y: b.midY), CGPoint(x: bx, y: b.midY)]
                }
                let y = far ? content.maxY + lane : content.minY - lane
                let ay = far ? a.maxY + endGap : a.minY - endGap, by = far ? b.maxY + endGap : b.minY - endGap
                return [CGPoint(x: a.midX, y: ay), CGPoint(x: a.midX, y: y), CGPoint(x: b.midX, y: y), CGPoint(x: b.midX, y: by)]
            }
            let leans = direction == .down ? a.midX + b.midX >= 2 * content.midX : a.midY + b.midY >= 2 * content.midY
            let options = [leans, !leans].map { ($0, channel($0)) }
            let best = options.min { crossings($0.1, edge) < crossings($1.1, edge) }!
            if !straight.isEmpty, crossings(straight, edge) < crossings(best.1, edge) { connectors.append(.init(points: straight, edge: index)); continue }
            channels[best.0 ? 1 : 0] += 1
            connectors.append(.init(points: best.1, edge: index))
        }
        var placed: [CGRect] = []
        for index in connectors.indices {
            guard let text = spec.edges[connectors[index].edge].label else { continue }
            let size = measure(text, .edge, 0.16), points = connectors[index].points
            // On the longest stretch, beside it rather than across it, wherever no box or other label is.
            let (p, q) = zip(points, points.dropFirst()).max { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) < hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } ?? (points[0], points[0])
            let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), w = Double(size.width), h = Double(size.height)
            let beside = [CGRect(x: mid.x + 0.006, y: mid.y - h / 2, width: w, height: h), CGRect(x: mid.x - 0.006 - w, y: mid.y - h / 2, width: w, height: h)]
            let across = [CGRect(x: mid.x - w / 2, y: mid.y - h - 0.004, width: w, height: h), CGRect(x: mid.x - w / 2, y: mid.y + 0.004, width: w, height: h)]
            let candidates = abs(q.x - p.x) < abs(q.y - p.y) ? beside + across : across + beside
            func clear(_ spot: CGRect) -> Bool { !(boxes + placed).contains { $0.intersects(spot) && !$0.intersection(spot).isEmpty } }
            let label = candidates.first { clear($0) && !crosses(p, q, $0) } ?? candidates.first(where: clear) ?? candidates[0]
            connectors[index].label = label; placed.append(label)
        }

        var extent = content
        for connector in connectors {
            for point in connector.points { extent = extent.union(CGRect(origin: point, size: .zero)) }
            if let label = connector.label { extent = extent.union(label) }
        }
        var titleBox: CGRect?
        if let title {
            titleBox = CGRect(x: extent.minX, y: extent.minY - titleGap - Double(title.height), width: Double(title.width), height: Double(title.height))
            extent = extent.union(titleBox!)
        }
        // Shift so the diagram starts at the origin.
        let dx = -extent.minX, dy = -extent.minY
        func moved(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: dx, dy: dy) }
        let result = Layout(title: titleBox.map(moved), nodes: boxes.map(moved),
                            connectors: connectors.map { .init(points: $0.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, edge: $0.edge, label: $0.label.map(moved)) },
                            size: CGSize(width: extent.width, height: extent.height))
        return result.size.width <= maxWidth + 0.0001 ? result : nil
    }

    /// Edges that close a cycle in a depth-first walk from the nodes in the order given.
    static func backEdges(_ spec: Spec) -> Set<Int> {
        var state = [Int](repeating: 0, count: spec.nodes.count), back = Set<Int>()
        func visit(_ node: Int) {
            state[node] = 1
            for (index, edge) in spec.edges.enumerated() where edge.from == node {
                if state[edge.to] == 1 { back.insert(index) } else if state[edge.to] == 0 { visit(edge.to) }
            }
            state[node] = 2
        }
        for node in spec.nodes.indices where state[node] == 0 { visit(node) }
        return back
    }

    /// Where the segment from `inside` toward `target` leaves `box`, pulled back by `endGap`.
    private static func boundary(_ box: CGRect, toward target: CGPoint, from inside: CGPoint) -> CGPoint? {
        let dx = target.x - inside.x, dy = target.y - inside.y
        guard hypot(dx, dy) > 0.0001 else { return nil }
        let tx = dx == 0 ? Double.infinity : (dx > 0 ? box.maxX - inside.x : box.minX - inside.x) / dx
        let ty = dy == 0 ? Double.infinity : (dy > 0 ? box.maxY - inside.y : box.minY - inside.y) / dy
        let t = max(0, min(tx, ty)), length = hypot(dx, dy)
        let s = min(1, t + endGap / length)
        return CGPoint(x: inside.x + dx * s, y: inside.y + dy * s)
    }

    /// Whether the segment touches `box` (Liang–Barsky).
    static func crosses(_ a: CGPoint, _ b: CGPoint, _ box: CGRect) -> Bool {
        var t0 = 0.0, t1 = 1.0
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - box.minX), (dx, box.maxX - a.x), (-dy, a.y - box.minY), (dy, box.maxY - a.y)] {
            if p == 0 { if q < 0 { return false }; continue }
            let r = q / p
            if p < 0 { if r > t1 { return false }; t0 = max(t0, r) } else { if r < t0 { return false }; t1 = min(t1, r) }
        }
        return t0 <= t1
    }

    // MARK: Objects

    /// The styles of the three roles; `scale` shrinks a diagram that does not fit at full size.
    static func style(_ role: Role, scale: Double) -> [String: Any] {
        var style = NativePDFTextStyle()
        switch role {
        case .node: style.fontSizePt = (11 * scale).rounded(); style.align = "center"; style.fill = "blue"
        case .edge: style.fontSizePt = max(6, (9 * scale).rounded()); style.align = "center"; style.color = "blue"
        case .title: style.fontSizePt = (13 * scale).rounded(); style.bold = true
        }
        return style.dictionary
    }

    /// The diagram as rows for `performObjectEdit("create")`, its top-left corner at `origin` (normalised).
    /// Arrows first so boxes sit over their ends; each box is a filled text box under a rect outline.
    static func rows(_ layout: Layout, spec: Spec, page: Int, origin: CGPoint, aspect: Double, scale: Double) -> [[String: Any]] {
        func box(_ rect: CGRect) -> [String: Any] {
            let x = min(max(0, origin.x + rect.minX), 1), y = min(max(0, origin.y + rect.minY / aspect), 1)
            return ["x": Double(x), "y": Double(y), "width": Double(min(rect.width, 1 - x)), "height": Double(min(rect.height / aspect, 1 - y))]
        }
        func point(_ value: CGPoint) -> [String: Any] {
            ["x": Double(min(max(0, origin.x + value.x), 1)), "y": Double(min(max(0, origin.y + value.y / aspect), 1)), "p": 0.5]
        }
        let line: [String: Any] = ["color": "ink", "width": 0.0022, "opacity": 1.0]
        var rows: [[String: Any]] = []
        if let title = layout.title, let text = spec.title {
            rows.append(["page": page, "kind": "textbox", "style": style(.title, scale: scale), "data": ["text": text, "box": box(title)]])
        }
        for connector in layout.connectors {
            let points = connector.points
            for (index, pair) in zip(points, points.dropFirst()).enumerated() {
                rows.append(["page": page, "kind": index == points.count - 2 ? "arrow" : "line", "style": line, "data": ["points": [point(pair.0), point(pair.1)]]])
            }
            if let label = connector.label, let text = spec.edges[connector.edge].label {
                rows.append(["page": page, "kind": "textbox", "style": style(.edge, scale: scale), "data": ["text": text, "box": box(label)]])
            }
        }
        for (index, node) in spec.nodes.enumerated() {
            rows.append(["page": page, "kind": "textbox", "style": style(.node, scale: scale), "data": ["text": node.label, "box": box(layout.nodes[index])]])
            rows.append(["page": page, "kind": "rect", "style": ["color": "blue", "width": 0.0022, "opacity": 1.0], "data": ["box": box(layout.nodes[index])]])
        }
        return rows
    }

    struct Plan {
        let layout: Layout
        let scale: Double
        let rect: CGRect
    }
    /// Downward first (a flowchart reads top to bottom and its boxes are wider, so labels wrap less), then sideways,
    /// at full size and then at 80 %: the first that fits, placed nearest the anchor.
    static func plan(_ spec: Spec, anchor: CGRect, obstacles: NativeAINotePlacement.Obstacles, aspect: Double, measure: (Double) -> Measure) -> Plan? {
        for scale in [1.0, 0.8] {
            for direction in [Direction.down, .right] {
                guard let layout = layout(spec, direction: direction, measure: measure(scale)) else { continue }
                // Layouts measure down the page in page widths; placement takes page heights.
                let size = CGSize(width: layout.size.width, height: layout.size.height / aspect)
                if let placed = NativeAINotePlacement.place(sizes: [size], anchor: anchor, obstacles: obstacles, aspect: aspect) {
                    return Plan(layout: layout, scale: scale, rect: placed.rect)
                }
            }
        }
        return nil
    }

    // MARK: Reaching the open PDF

    /// One `draw_diagram` call, handed to the PDF editor through the workspace's events. The first editor of the
    /// document that claims it draws it; a visible one claims first.
    @MainActor
    final class Request {
        let spec: Spec
        private var continuation: CheckedContinuation<String, Error>?
        private(set) var claimed = false
        var pending: Bool { continuation != nil }
        init(spec: Spec) { self.spec = spec }
        func claim() -> Bool {
            guard !claimed, continuation != nil else { return false }
            claimed = true; return true
        }
        func finish(_ result: Result<String, Error>) { continuation?.resume(with: result); continuation = nil }
        fileprivate func wait(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    }

    static let channel = "nativeWorkspace:drawDiagram"

    #if DEBUG
    /// What `--native-ai-diagram-fixture` draws for UI tests: a small cycle with a branch and a labelled arrow.
    static let fixture: [String: Any] = ["title": "고유값 문제 풀이 순서",
        "nodes": [["id": "a", "label": "특성방정식 세우기"], ["id": "b", "label": "고유값 λ 구하기"], ["id": "c", "label": "고유벡터 구하기"],
                  ["id": "d", "label": "대각화 확인"], ["id": "e", "label": "중근이면 다시 점검"]],
        "edges": [["from": "a", "to": "b", "label": "det = 0"], ["from": "b", "to": "c"], ["from": "c", "to": "d"], ["from": "b", "to": "e"], ["from": "e", "to": "a"]]]
    #endif

    @MainActor
    static func draw(_ arguments: [String: Any], document: [String: Any], emit: (String, Any) -> Void,
                     claimTimeout: Duration = .seconds(3), timeout: Duration = .seconds(45)) async throws -> String {
        let spec = try parse(arguments)
        guard canDraw(on: document), let course = document["courseId"] as? String, let path = document["relPath"] as? String else {
            throw DesktopRuntimeError("열려 있는 PDF가 없어 도식을 넣을 수 없습니다.")
        }
        let request = Request(spec: spec)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                request.wait(continuation)
                emit(channel, ["courseId": course, "relPath": path, "request": request])
                Task { @MainActor in
                    try? await Task.sleep(for: claimTimeout)
                    if !request.claimed { request.finish(.failure(DesktopRuntimeError("이 PDF가 화면에 열려 있지 않아 도식을 넣지 못했습니다."))) }
                    guard request.pending else { return }
                    try? await Task.sleep(for: timeout)
                    request.finish(.failure(DesktopRuntimeError("도식을 넣는 데 너무 오래 걸려 멈췄습니다.")))
                }
            }
        } onCancel: {
            Task { @MainActor in request.finish(.failure(CancellationError())) }
        }
    }
}
