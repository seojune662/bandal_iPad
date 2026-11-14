import SwiftMath
import SwiftUI
import UIKit

/// An AI answer drawn from its Markdown (`NativeAnswerMarkdown`): headings, lists, tables, code,
/// quotes, rules and TeX, selectable like the plain answer was.
///
/// Every size here comes from the font and the width SwiftUI proposes; nothing is measured back
/// into state (a layout that fed its own measurements back froze the app on device, 74d434d).
struct NativeAnswerMarkdownView: View, Equatable {
    let text: String
    /// Still arriving: unfinished markup at the end waits instead of flashing.
    var streaming = false
    var size: CGFloat = 15
    var lineHeight: CGFloat = 1.45
    /// A tapped link, already checked to be web, mail or phone.
    var openLink: (URL) -> Void = { _ in }
    @State private var cache = NativeAnswerMarkdownCache()

    static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.streaming == b.streaming && a.size == b.size && a.lineHeight == b.lineHeight }

    var body: some View {
        let style = NativeAnswerStyle(size: size, lineHeight: lineHeight)
        NativeAnswerBlocks(blocks: cache.blocks(for: text, streaming: streaming), tail: streaming, style: style)
            .font(.system(size: size)).lineSpacing(style.lineSpacing).padding(.vertical, style.lineSpacing / 2)
            .foregroundStyle(NativeDesktopTheme.text).tint(NativeDesktopTheme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in openLink(url); return .handled })
    }
}

/// Opens an answer's link: a web page in a browser tab of the app (or Safari when
/// 설정 › 브라우저 sends links there), mail and phone through the system.
enum NativeAnswerLink {
    @MainActor static func open(_ url: URL, store: NativeWorkspaceStore) {
        switch url.scheme?.lowercased() {
        case "http", "https": store.events.send(.init(channel: "nativeWorkspace:openBrowserURL", payload: ["url": url.absoluteString]))
        case "mailto", "tel": UIApplication.shared.open(url)
        default: break
        }
    }
}

struct NativeAnswerStyle: Equatable {
    let size: CGFloat, lineHeight: CGFloat
    var lineSpacing: CGFloat { max(0, size * lineHeight - UIFont.systemFont(ofSize: size).lineHeight) }
    var code: CGFloat { (size * 0.87).rounded() }
    func heading(_ level: Int) -> CGFloat { (size * [1.33, 1.2, 1.07, 1, 1, 1][min(max(level, 1), 6) - 1]).rounded() }
    var itemGap: CGFloat { (size * 0.3).rounded() }
    /// Space above `block`: more before a heading, less right under one; inside a list item as little as between items.
    func gap(_ block: NativeAnswerMarkdown.Block, after previous: NativeAnswerMarkdown.Block, inList: Bool) -> CGFloat {
        if inList { return itemGap }
        if case .heading = block { return (size * 1.1).rounded() }
        if case .heading = previous { return (size * 0.4).rounded() }
        return (size * 0.7).rounded()
    }
}

private struct NativeAnswerListDepth: EnvironmentKey { static let defaultValue = 0 }
private extension EnvironmentValues {
    var answerListDepth: Int { get { self[NativeAnswerListDepth.self] } set { self[NativeAnswerListDepth.self] = newValue } }
}

struct NativeAnswerBlocks: View {
    let blocks: [NativeAnswerMarkdown.Block]
    /// The last block ends a streaming answer.
    let tail: Bool
    let style: NativeAnswerStyle
    @Environment(\.answerListDepth) private var depth
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                NativeAnswerBlockView(block: blocks[index], tail: tail && index == blocks.count - 1, style: style).equatable()
                    .padding(.top, index == 0 ? 0 : style.gap(blocks[index], after: blocks[index - 1], inList: depth > 0))
            }
        }
    }
}

/// One block. Equatable, so a streaming answer redraws its last block only.
struct NativeAnswerBlockView: View, Equatable {
    let block: NativeAnswerMarkdown.Block
    let tail: Bool
    let style: NativeAnswerStyle
    var body: some View {
        switch block {
        case .paragraph(let source):
            NativeAnswerInlineText(source: source, tail: tail, size: style.size)
        case .heading(let level, let source):
            NativeAnswerInlineText(source: source, tail: tail, size: style.heading(level), weight: level <= 3 ? .bold : .semibold)
                .accessibilityAddTraits(.isHeader)
        case .list(let ordered, let start, let items):
            NativeAnswerList(ordered: ordered, start: start, items: items, tail: tail, style: style)
        case .code(let language, let code):
            NativeAnswerCodeBlock(language: language, code: code, style: style)
        case .quote(let blocks):
            NativeAnswerBlocks(blocks: blocks, tail: tail, style: style)
                .foregroundStyle(NativeDesktopTheme.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Capsule().fill(NativeDesktopTheme.muted.opacity(0.5)).frame(width: 3) }
        case .table(let header, let alignments, let rows):
            NativeAnswerTable(header: header, alignments: alignments, rows: rows, tail: tail, style: style)
        case .math(let latex):
            NativeAnswerDisplayMath(latex: latex, size: style.size)
        case .rule:
            Rectangle().fill(NativeDesktopTheme.border).frame(height: 1).frame(maxWidth: .infinity).padding(.vertical, 4).accessibilityHidden(true)
        }
    }
}

/// A paragraph, heading or cell: one `Text`, so selection and links work as in any text.
struct NativeAnswerInlineText: View {
    let source: String
    var tail = false
    let size: CGFloat
    var weight: Font.Weight = .regular
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        NativeAnswerInline.text(NativeAnswerMarkdown.inlines(source, tail: tail), size: size, weight: weight, scheme: scheme)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor enum NativeAnswerInline {
    static func text(_ runs: [NativeAnswerMarkdown.Inline], size: CGFloat, weight: Font.Weight, scheme: ColorScheme) -> Text {
        var pieces: [Text] = [], pending = AttributedString()
        for run in runs {
            guard run.math else { pending.append(attributed(run, size: size, weight: weight)); continue }
            if let math = NativeAnswerMath.render(run.text, size: size * 1.05, display: false, scheme: scheme) {
                if !pending.characters.isEmpty { pieces.append(Text(pending)); pending = AttributedString() }
                pieces.append(Text(Image(uiImage: math.image)).baselineOffset(-math.descent))
            } else {
                var source = run; source.math = false; source.code = true
                pending.append(attributed(source, size: size, weight: weight))
            }
        }
        if !pending.characters.isEmpty || pieces.isEmpty { pieces.append(Text(pending)) }
        // `Text + Text` is deprecated from iOS 26; interpolation joins them the same way.
        return pieces.dropFirst().reduce(pieces[0]) { Text("\($0)\($1)") }
    }
    private static func attributed(_ run: NativeAnswerMarkdown.Inline, size: CGFloat, weight: Font.Weight) -> AttributedString {
        var value = AttributedString(run.text)
        var font: Font
        if run.code {
            font = .system(size: (size * 0.9).rounded(), weight: run.bold ? .semibold : .regular, design: .monospaced)
            value.backgroundColor = NativeDesktopTheme.raised
        } else {
            font = .system(size: size, weight: run.bold ? (weight == .regular ? .semibold : .heavy) : weight)
        }
        if run.italic { font = font.italic() }
        value.font = font
        if run.strike { value.strikethroughStyle = .single }
        if let link = run.link {
            if let url = URL(string: link) { value.link = url }
            value.underlineStyle = Text.LineStyle(pattern: .solid, color: NativeDesktopTheme.muted)
        }
        return value
    }
}

private struct NativeAnswerList: View {
    let ordered: Bool, start: Int
    let items: [NativeAnswerMarkdown.Item]
    let tail: Bool
    let style: NativeAnswerStyle
    @Environment(\.answerListDepth) private var depth
    private var markerWidth: CGFloat {
        guard ordered else { return style.size * 0.9 }
        return style.size * (0.62 * CGFloat(String(start + items.count - 1).count) + 0.45)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: style.itemGap) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    marker(index).frame(width: markerWidth, alignment: ordered ? .trailing : .center)
                    NativeAnswerBlocks(blocks: items[index].blocks, tail: tail && index == items.count - 1, style: style)
                        .environment(\.answerListDepth, depth + 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func marker(_ index: Int) -> Text {
        if let checked = items[index].checked {
            return Text(Image(systemName: checked ? "checkmark.square.fill" : "square")).foregroundStyle(NativeDesktopTheme.secondary)
        }
        if ordered { return Text(verbatim: "\(start + index).").monospacedDigit() }
        return Text(verbatim: ["•", "◦", "▪︎"][min(depth, 2)]).foregroundStyle(NativeDesktopTheme.secondary)
    }
}

private struct NativeAnswerCodeBlock: View {
    let language: String, code: String
    let style: NativeAnswerStyle
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(verbatim: language).font(.system(size: 12, weight: .medium)).foregroundStyle(NativeDesktopTheme.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button { UIPasteboard.general.string = code; copied = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                        Text(copied ? "복사했어요" : "복사").font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(NativeDesktopTheme.secondary).assistantHitArea(10)
                }.buttonStyle(NativeAssistantButtonStyle()).accessibilityLabel("코드 복사").accessibilityIdentifier("native-ai-code-copy")
            }.padding(.horizontal, 12).frame(height: 32)
            Rectangle().fill(NativeDesktopTheme.border).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code.isEmpty ? " " : code).font(.system(size: style.code, design: .monospaced)).lineSpacing(3)
                    .fixedSize().padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(NativeDesktopTheme.border) }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5)); copied = false
        }
    }
}

/// A table at its content's width, up to a cap per column: stretched to the answer's width
/// when it fits, scrolled sideways when it does not.
private struct NativeAnswerTable: View {
    let header: [String]
    let alignments: [NativeAnswerMarkdown.Alignment]
    let rows: [[String]]
    let tail: Bool
    let style: NativeAnswerStyle
    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal, showsIndicators: false) { grid }
        }
    }
    private var grid: some View {
        let columns = header.count
        return NativeAnswerTableLayout(columns: columns, maxColumn: (style.size * 16).rounded(), minColumn: (style.size * 3).rounded()) {
            ForEach(0..<(rows.count + 1) * columns, id: \.self) { index in cell(row: index / columns - 1, column: index % columns) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(NativeDesktopTheme.border) }
    }
    private func cell(row: Int, column: Int) -> some View {
        let source = row < 0 ? header[column] : rows[row][column]
        let alignment = alignments[column]
        // Only the last cell can still be arriving.
        let open = tail && column == header.count - 1 && row == rows.count - 1
        return NativeAnswerInlineText(source: source, tail: open, size: (style.size * 0.93).rounded(), weight: row < 0 ? .semibold : .regular)
            .lineSpacing(2)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment == .trailing ? .topTrailing : alignment == .center ? .top : .topLeading)
            .background(row < 0 ? NativeDesktopTheme.surface : .clear)
            .overlay(alignment: .bottom) { if row < rows.count - 1 { Rectangle().fill(NativeDesktopTheme.border).frame(height: 1) } }
    }
}

/// Columns as wide as their widest cell (between `minColumn` and `maxColumn`), rows as tall as
/// their tallest cell at that width. Pure layout: nothing it measures leaves it.
struct NativeAnswerTableLayout: Layout {
    let columns: Int
    let maxColumn: CGFloat
    let minColumn: CGFloat
    struct Cache { var natural: [CGFloat] }

    func makeCache(subviews: Subviews) -> Cache {
        let count = max(columns, 1)
        var widths = Array(repeating: minColumn, count: count)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            if ideal.isFinite { widths[index % count] = max(widths[index % count], min(maxColumn, ideal.rounded(.up))) }
        }
        return Cache(natural: widths)
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let widths = widths(proposal.width, cache)
        return CGSize(width: widths.reduce(0, +), height: heights(widths, subviews).reduce(0, +))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let widths = widths(bounds.width, cache), heights = heights(widths, subviews), count = max(columns, 1)
        var y = bounds.minY
        for row in heights.indices {
            var x = bounds.minX
            for column in 0..<count where row * count + column < subviews.count {
                subviews[row * count + column].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: widths[column], height: heights[row]))
                x += widths[column]
            }
            y += heights[row]
        }
    }
    func widths(_ available: CGFloat?, _ cache: Cache) -> [CGFloat] {
        let total = cache.natural.reduce(0, +)
        guard let available, available.isFinite, total > 0, available > total else { return cache.natural }
        return cache.natural.map { ($0 * available / total).rounded(.down) }
    }
    private func heights(_ widths: [CGFloat], _ subviews: Subviews) -> [CGFloat] {
        let count = max(columns, 1)
        var heights = Array(repeating: CGFloat(0), count: (subviews.count + count - 1) / count)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % count], height: nil)).height
            if height.isFinite { heights[index / count] = max(heights[index / count], height.rounded(.up)) }
        }
        return heights
    }
}

private struct NativeAnswerDisplayMath: View {
    let latex: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let math = NativeAnswerMath.render(latex, size: (size * 1.2).rounded(), display: true, scheme: scheme) {
            let image = Image(uiImage: math.image)
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { image }
            }
            .padding(.vertical, 2)
            .accessibilityElement().accessibilityLabel(Text(verbatim: latex)).accessibilityIdentifier("native-ai-math")
        } else {
            // TeX SwiftMath cannot set stays readable as its source.
            Text(verbatim: latex).font(.system(size: (size * 0.9).rounded(), design: .monospaced)).foregroundStyle(NativeDesktopTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// TeX typeset by SwiftMath into an image with its baseline, so an inline formula sits on the line.
@MainActor enum NativeAnswerMath {
    final class Rendered {
        let image: UIImage, descent: CGFloat
        init(image: UIImage, descent: CGFloat) { self.image = image; self.descent = descent }
    }
    private static let cache: NSCache<NSString, Rendered> = { let cache = NSCache<NSString, Rendered>(); cache.countLimit = 256; return cache }()
    private static var failures = Set<String>()

    static func render(_ latex: String, size: CGFloat, display: Bool, scheme: ColorScheme) -> Rendered? {
        let key = "\(display ? "d" : "t"):\(size):\(scheme == .dark ? 1 : 0):\(latex)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard !failures.contains(key), !latex.isEmpty, latex.utf16.count <= 4_096 else { return nil }
        let color = UIColor(NativeDesktopTheme.text).resolvedColor(with: UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light))
        let label = MTMathUILabel()
        label.labelMode = display ? .display : .text
        label.fontSize = size; label.textColor = color; label.displayErrorInline = false
        label.latex = latex
        let bounds = label.intrinsicContentSize
        guard label.error == nil, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0, bounds.width <= 4_000, bounds.height <= 1_000 else {
            if failures.count > 512 { failures.removeAll() }
            failures.insert(key); return nil
        }
        label.frame = CGRect(origin: .zero, size: bounds)
        label.layoutIfNeeded()
        guard let list = label.displayList else { failures.insert(key); return nil }
        let image = UIGraphicsImageRenderer(size: bounds).image { context in
            // CoreText draws upward from the baseline.
            context.cgContext.translateBy(x: 0, y: bounds.height); context.cgContext.scaleBy(x: 1, y: -1)
            list.draw(context.cgContext)
        }
        let rendered = Rendered(image: image, descent: list.descent)
        cache.setObject(rendered, forKey: key as NSString)
        return rendered
    }
}

#if DEBUG
/// UI tests: `--native-ai-markdown-fixture` makes the stored answer this one, and
/// `--native-ai-markdown-stream-fixture` types it into the panel as if it were arriving.
/// (`--native-ai-stream-fixture` is the floating panel's own slower, plain-text answer: NativeAssistantStreamFixture.swift.)
enum NativeAnswerMarkdownFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--native-ai-markdown-fixture") }
    static let answer = """
    ## 3주차 인터뷰 요약

    인터뷰 **5명 중 4명**이 *첫 화면이 복잡하다*고 답했어요. 기록 원본은 [인터뷰 기록](https://example.com/interviews)에 있어요.

    ### 핵심 발견
    - 첫 화면의 버튼이 많아 `새 노트`를 찾기 어려움
    - 팔레트 위치는 의견이 갈림
      - 왼쪽 2명, 오른쪽 2명
    - [x] 녹취 정리
    - [ ] 시안 공유

    1. 팔레트 시안 2종 비교
    2. 다음 주 수요일까지 공유

    | 응답 | 인원 | 비율 |
    |:---|---:|---:|
    | 복잡하다 | 4 | 80% |
    | 괜찮다 | 1 | 20% |

    > 첫 화면은 한눈에 들어와야 한다.

    만족도 평균은 $\\bar{x} = \\frac{1}{n}\\sum_{i=1}^{n} x_i$ 로 계산했어요.

    $$
    \\sigma = \\sqrt{\\frac{1}{n}\\sum_{i=1}^{n}(x_i - \\bar{x})^2}
    $$

    ```swift
    let ratio = 4.0 / 5.0
    print(ratio)
    ```

    ---

    더 찾아보려면 [팔레트 디자인 검색](https://www.google.com/search?q=팔레트+디자인)을 열어 보세요.
    """
}

extension NativeAssistantSession {
    /// Types the fixture answer into `stream` a few characters at a time, shows it finished for
    /// four seconds and starts over, so a test can catch a run from its beginning.
    func playMarkdownStreamFixture() {
        guard ProcessInfo.processInfo.arguments.contains("--native-ai-markdown-stream-fixture") else { return }
        Task { @MainActor [weak self] in
            let characters = Array(NativeAnswerMarkdownFixture.answer)
            try? await Task.sleep(for: .seconds(2))
            while let self {
                running = true; stream = ""
                var index = 0
                while index < characters.count {
                    let next = min(characters.count, index + 3)
                    stream += String(characters[index..<next]); index = next
                    try? await Task.sleep(for: .milliseconds(25))
                }
                running = false
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}
#endif
