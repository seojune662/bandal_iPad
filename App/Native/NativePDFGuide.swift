import CoreGraphics
import Foundation
import UIKit

/// One step of 짚어주기: a page, a short passage copied from its text, and what to say beside it.
/// The model never gives coordinates; the PDF finds the passage itself.
struct NativePDFGuideStep: Equatable {
    let page: Int
    let quote: String
    let note: String
    static let maxSteps = 8, maxQuote = 200, maxNote = 400

    /// The steps a `present_steps` call (or its event) carries. A malformed list is refused, not repaired:
    /// the model reads why and can call again.
    static func list(_ raw: Any?) throws -> [Self] {
        guard let values = raw as? [[String: Any]], !values.isEmpty else { throw DesktopRuntimeError("단계 목록을 확인해 주세요.") }
        guard values.count <= maxSteps else { throw DesktopRuntimeError("단계는 \(maxSteps)개까지 보낼 수 있습니다.") }
        return try values.map { value in
            guard let page = value["page"] as? Int, page >= 1 else { throw DesktopRuntimeError("각 단계의 페이지를 1 이상의 정수로 적어 주세요.") }
            let quote = (value["quote"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let note = (value["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { throw DesktopRuntimeError("각 단계에 보여 줄 설명을 적어 주세요.") }
            return .init(page: page, quote: String(quote.prefix(maxQuote)), note: String(note.prefix(maxNote)))
        }
    }
    var payload: [String: Any] { ["page": page, "quote": quote, "note": note] }
}

/// The model's side of 짚어주기 (`NativeAssistantService`): the tool, the mode's instruction, and handing the
/// steps to the PDF on screen within the same turn.
enum NativePDFGuideTool {
    static let name = "present_steps"
    /// The workspace event the open PDF plays.
    static let event = "nativeWorkspace:guideSteps"
    static var definition: [String: Any] {
        ["name": name,
         "description": "Show the answer inside the PDF the user has open: the app scrolls to each step's passage, points at it and writes the note beside it. Call once with every step.",
         "inputSchema": ["type": "object", "required": ["steps"], "properties": [
            "steps": ["type": "array", "minItems": 1, "maxItems": NativePDFGuideStep.maxSteps, "items": ["type": "object", "required": ["page", "quote", "note"], "properties": [
                "page": ["type": "integer", "minimum": 1, "description": "1-based page of the open PDF."],
                "quote": ["type": "string", "description": "A short passage copied character for character from that page's text, one that occurs once on it."],
                "note": ["type": "string", "description": "One or two sentences shown beside the passage."]]]]]]]
    }
    static let instruction = "\n짚어주기 모드입니다. 채팅에 길게 설명하는 대신, 사용자가 열어 둔 PDF(현재 문서 참고 정보의 relPath) 안에서 위치를 짚으며 설명합니다. 필요한 페이지를 read_material로 읽은 뒤 present_steps를 한 번만 호출해 단계를 보내세요(최대 \(NativePDFGuideStep.maxSteps)개, 보통 2~5개). quote는 그 페이지 원문에서 글자 그대로 옮긴 한 줄 이내의 짧은 구절(8~40자)로, 그 페이지에서 한 번만 나오는 것을 고르세요. 원문 글자가 없는 페이지는 첨부 이미지에 보이는 글을 그대로 옮기세요. note는 그 위치 옆에 띄울 한두 문장입니다. 도구를 부른 뒤 채팅에는 한 문장으로만 답하세요."

    /// Guide mode with a PDF open offers `present_steps` beside the reads and adds its instruction; every other
    /// request never sees the tool.
    static func configure(_ input: inout [String: Any], mode: String?, document: [String: Any], course: String, workspace: [String: Any]) {
        var tools = (input["tools"] as? [[String: Any]] ?? []).filter { $0["name"] as? String != name }
        if mode == NativeAssistantMode.guide.rawValue, target(document, course: course, workspace: workspace) != nil {
            // Pointing is this mode's whole answer; the diagram tool would write on the page instead.
            tools.removeAll { $0["name"] as? String == NativeAIDiagram.toolName }
            tools.append(definition)
            input["system"] = (input["system"] as? String ?? "") + instruction
        }
        input["tools"] = tools
    }

    /// Validates the steps and sends them to the PDF on screen. Moving the user's own view is all it does.
    static func present(_ arguments: [String: Any], document: [String: Any], course: String, workspace: [String: Any], emit: ((String, Any) -> Void)?) throws -> String {
        guard let target = target(document, course: course, workspace: workspace) else { throw DesktopRuntimeError("짚어 줄 PDF가 열려 있지 않습니다.") }
        let steps = try NativePDFGuideStep.list(arguments["steps"])
        emit?(event, ["courseId": target.course, "relPath": target.path, "steps": steps.map(\.payload)])
        return "PDF 화면에서 \(steps.count)단계를 차례로 짚어 보여 주고 있습니다. 같은 설명을 채팅에 다시 쓰지 말고 한 문장으로만 마무리하세요."
    }

    /// The open document when it is a PDF of this conversation's folder.
    private static func target(_ document: [String: Any], course: String, workspace: [String: Any]) -> (course: String, path: String)? {
        guard let path = document["relPath"] as? String, let owner = document["courseId"] as? String,
              owner == course || owner == workspace["linkedCourseId"] as? String,
              document["kind"] as? String == "pdf" || (path as NSString).pathExtension.lowercased() == "pdf" else { return nil }
        return (owner, path)
    }
}

/// Plays 짚어주기 steps over one PDF: scrolls to each passage, points at it, writes its note beside it, and
/// goes back to where the reader was. Viewing only. While it plays it holds the reading position it started
/// from, so a flush in between saves that one and not wherever a step scrolled to. A touch, a scroll or the
/// Pencil stops it at once and leaves the page where it is.
@MainActor
@Observable
final class NativePDFGuidePlayer {
    struct Target: Equatable {
        /// The passage's lines in the PDF body's points.
        var frames: [CGRect]
        var union: CGRect { frames.dropFirst().reduce(frames.first ?? .null) { $0.union($1) } }
        /// Where the pointer sits: just left of the first line.
        var pointer: CGPoint { frames.first.map { CGPoint(x: $0.minX - 12, y: $0.midY) } ?? .zero }
    }
    private(set) var steps: [NativePDFGuideStep] = []
    private(set) var index = 0
    /// The current passage on screen; nil while the page moves to it, and for a passage that was not found.
    private(set) var target: Target?
    /// The current step's note is up.
    private(set) var captioned = false
    /// How much of the note is written so far, in characters.
    private(set) var revealed = 0
    private(set) var paused = false
    /// Steps are on screen. False once they end, are stopped, or the tab is hidden.
    private(set) var playing = false
    var step: NativePDFGuideStep? { playing && steps.indices.contains(index) ? steps[index] : nil }
    var typing: Bool { revealed < (step?.note.count ?? 0) }

    /// The PDF host (`pdfNative:guide`).
    @ObservationIgnored var host: ((String, [String: Any]) async throws -> Any)?
    /// The page's recognised handwritten lines, as `nativeGuide:handwritingLines` returns them.
    @ObservationIgnored var handwriting: ((Int) async -> [[String: Any]])?
    /// The reader took over: the latest position a step left the view at is real now.
    @ObservationIgnored var onRelease: (([String: Any]?) -> Void)?
    /// The tab was hidden mid-play: show it at this position next time.
    @ObservationIgnored var onRestoreLater: (([String: Any]) -> Void)?
    /// The reading position from before the first step, held until the view is back there.
    @ObservationIgnored private(set) var origin: [String: Any]?
    @ObservationIgnored private var heldViewport: [String: Any]?
    @ObservationIgnored private var pending: [NativePDFGuideStep]?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var placing: Task<Void, Never>?
    /// The current step's passage, normalised to its page.
    @ObservationIgnored private var rects: [[Double]] = []
    /// Where the last step on each page pointed (a UTF-16 offset of its text), to move on through repeats.
    @ObservationIgnored private var anchors: [Int: Int] = [:]
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private let documentPath: String

    static let tick = Duration.milliseconds(33), charactersPerSecond = 30.0
    init(documentPath: String) { self.documentPath = documentPath }

    // MARK: Control

    /// Plays from the first step. Steps that arrive while others play replace them; the held position stays the
    /// one from before the first. Not `ready` (hidden, still opening): they wait for the next layout.
    func play(_ steps: [NativePDFGuideStep], ready: Bool) {
        guard !steps.isEmpty else { return }
        guard ready else { pending = steps; return }
        pending = nil; self.steps = steps; anchors = [:]; paused = false
        start(at: 0)
    }
    /// The caption's next: on to the next step, or the end.
    func next() { guard playing else { return }; index + 1 < steps.count ? start(at: index + 1) : close() }
    func previous() { guard playing else { return }; start(at: max(0, index - 1)) }
    func togglePause() { guard playing else { return }; paused.toggle() }
    /// A tap on the note: the rest of it at once, or the next step when it is all there.
    func advance() { guard let step else { return }; if typing { revealed = step.note.count } else { next() } }
    /// Ends here and goes back to the reader's position.
    func close() {
        guard playing else { return }
        task?.cancel(); placing?.cancel()
        task = Task { [weak self] in await self?.finish() }
    }
    /// A touch, a scroll or a jump the reader asked for: stop now and leave the page where it is.
    func interrupt() {
        guard playing || origin != nil else { return }
        let latest = suspended ? nil : heldViewport
        stop(); origin = nil; heldViewport = nil; suspended = false
        onRelease?(latest)
    }
    /// The tab is hidden. The next showing goes back to the held position, and a flush meanwhile saves it.
    func suspend() {
        // Holding a position means playing or on the way back to it.
        guard let origin, !suspended else { return }
        stop(); suspended = true
        onRestoreLater?(origin)
    }
    /// While it holds the reading position the viewer's position reports wait here instead of being applied.
    func hold(_ viewport: [String: Any]) -> Bool {
        guard origin != nil else { return false }
        heldViewport = viewport; return true
    }
    /// The PDF body was laid out again (a panel opened, the window turned): put the pointer back on its passage.
    func layoutApplied(visible: Bool, ready: Bool) {
        guard visible, ready else { return }
        if let pending { play(pending, ready: true); return }
        if playing, captioned {
            placing?.cancel()
            placing = Task { [weak self] in await self?.place(scrolling: true) }
        }
        #if DEBUG
        if !playing, let steps = NativePDFGuideFixture.steps(for: documentPath) {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.play(steps, ready: true)
            }
        }
        #endif
    }

    // MARK: Playing

    private func start(at index: Int) {
        task?.cancel(); placing?.cancel()
        playing = true; suspended = false; paused = false
        self.index = index; captioned = false; revealed = 0
        task = Task { [weak self] in await self?.run(from: index) }
    }
    private func stop() {
        task?.cancel(); placing?.cancel(); task = nil; placing = nil
        playing = false; target = nil; captioned = false; revealed = 0; paused = false
    }
    private func run(from first: Int) async {
        if origin == nil {
            guard let held = await ask(["action": "origin"]), !Task.isCancelled else { return }
            origin = held
        }
        var index = first
        while index < steps.count {
            await show(index)
            guard !Task.isCancelled, let note = step?.note else { return }
            await write(note)
            guard !Task.isCancelled else { return }
            index += 1
        }
        await finish()
    }
    private func show(_ index: Int) async {
        placing?.cancel(); placing = nil
        self.index = index; captioned = false; revealed = 0
        let step = steps[index]
        var found: [[Double]] = []
        if !step.quote.isEmpty {
            var request: [String: Any] = ["action": "locate", "page": step.page, "quote": step.quote]
            if let after = anchors[step.page] { request["after"] = after }
            let located = await ask(request)
            found = located?["rects"] as? [[Double]] ?? []
            if let location = located?["location"] as? Int { anchors[step.page] = location }
            if found.isEmpty, !Task.isCancelled, let rows = await handwriting?(step.page) {
                let lines = rows.compactMap { row -> NativePDFGuideResolver.Line? in
                    guard let text = row["text"] as? String, let box = row["box"] as? [Double], box.count == 4 else { return nil }
                    return .init(text: text, box: CGRect(x: box[0], y: box[1], width: box[2], height: box[3]))
                }
                found = NativePDFGuideResolver.boxes(of: step.quote, in: lines).map { [$0.minX, $0.minY, $0.width, $0.height] }
            }
        }
        guard !Task.isCancelled else { return }
        rects = found
        await place(scrolling: true)
    }
    /// Brings the current passage into view when it is not, then puts the pointer on it and the note up.
    private func place(scrolling: Bool) async {
        guard let step else { return }
        if scrolling, let settle = await ask(["action": "show", "page": step.page, "rects": rects])?["settle"] as? Double, settle > 0 {
            // The pointer leaves while the page moves under it.
            target = nil
            try? await Task.sleep(for: .seconds(settle))
        }
        guard !Task.isCancelled else { return }
        let frames = (await ask(["action": "frames", "page": step.page, "rects": rects])?["frames"] as? [[Double]] ?? [])
            .filter { $0.count == 4 }.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
        guard !Task.isCancelled else { return }
        let next = frames.isEmpty ? nil : Target(frames: frames)
        if next != target { target = next }
        if !captioned { captioned = true }
    }
    /// Writes the note out, then lets it stand long enough to read. Pausing stops both clocks.
    private func write(_ note: String) async {
        let total = note.count
        if UIAccessibility.isReduceMotionEnabled { revealed = total }
        var written = 0.0
        while revealed < total {
            guard await tick() else { return }
            if !paused {
                written += 0.033 * Self.charactersPerSecond
                let shown = min(total, Int(written))
                if shown > revealed { revealed = shown }
            }
        }
        var waited = 0.0
        let dwell = min(9, 1.6 + Double(total) * 0.05)
        while waited < dwell {
            guard await tick() else { return }
            if !paused { waited += 0.033 }
        }
    }
    /// One host call. A failure means the surface closed or was replaced: the guide ends, holding nothing.
    private func ask(_ request: [String: Any]) async -> [String: Any]? {
        do { return try await host?("guide", request) as? [String: Any] }
        catch {
            if !Task.isCancelled { stop(); origin = nil; heldViewport = nil; suspended = false }
            return nil
        }
    }
    private func tick() async -> Bool {
        try? await Task.sleep(for: Self.tick)
        return !Task.isCancelled
    }
    /// Pointer and note leave, then the view goes back to the held position.
    private func finish() async {
        playing = false; target = nil; captioned = false; revealed = 0; paused = false
        guard let origin else { return }
        if let page = origin["page"] as? Int {
            let request: [String: Any] = ["action": "restore", "page": page, "progress": origin["progress"] as? Double ?? 0, "horizontalProgress": origin["horizontalProgress"] as? Double ?? 0.5]
            if let settle = await ask(request)?["settle"] as? Double, settle > 0 {
                try? await Task.sleep(for: .seconds(settle))
            }
        }
        // A touch during the return let go of the position already.
        guard !Task.isCancelled, self.origin != nil else { return }
        self.origin = nil; heldViewport = nil
    }
}

#if DEBUG
/// UI tests: a fixed list of steps played over the search fixture's lecture PDF once it opens
/// (`--native-ui-testing --native-search-fixture --native-guide-fixture`). One step's passage is not on its
/// page; one repeats over a line break.
enum NativePDFGuideFixture {
    private static var played = Set<String>()
    static func steps(for path: String) -> [NativePDFGuideStep]? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--native-ui-testing"), arguments.contains("--native-guide-fixture"), path == "열역학 강의자료.pdf",
              played.insert(path).inserted else { return nil }
        return [
            .init(page: 1, quote: "고립계의\n엔트로피는  감소하지 않는다", note: "고립계에서는 엔트로피가 줄어들지 않아요. 제2법칙의 핵심 문장이에요."),
            .init(page: 3, quote: "엔트로피는 상태 함수이므로", note: "상태 함수라서 처음과 끝 상태만 알면 변화량을 구할 수 있어요."),
            .init(page: 2, quote: "이 페이지에 없는 구절", note: "이 단계는 구절을 찾지 못해 설명만 보여요."),
            .init(page: 2, quote: "효율은 1 - Tc/Th", note: "카르노 효율은 두 열원의 온도만으로 정해져요.")
        ]
    }
}
#endif

