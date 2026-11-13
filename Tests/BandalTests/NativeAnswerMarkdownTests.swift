import XCTest
@testable import Bandal

/// The AI answer's Markdown: what each block becomes, what a half-written streaming answer shows,
/// and that the incremental cache gives exactly what a full read gives.
final class NativeAnswerMarkdownTests: XCTestCase {
    typealias M = NativeAnswerMarkdown

    // MARK: Blocks

    func testHeadingsParagraphsRulesAndQuotes() {
        XCTAssertEqual(M.parse("# 제목\n## 소제목 ##\n본문 첫 줄\n둘째 줄\n\n---\n> 인용\n> 둘째"), [
            .heading(level: 1, text: "제목"), .heading(level: 2, text: "소제목"),
            .paragraph("본문 첫 줄\n둘째 줄"), .rule,
            .quote([.paragraph("인용\n둘째")]),
        ])
        XCTAssertEqual(M.parse("#해시태그"), [.paragraph("#해시태그")], "A heading needs a space after its hashes")
        XCTAssertEqual(M.parse("문단\n---"), [.paragraph("문단"), .rule], "No setext headings: --- under a line is a rule")
    }

    func testListsNumberNestAndTick() {
        XCTAssertEqual(M.parse("3. 셋\n4. 넷"), [.list(ordered: true, start: 3, items: [.init(blocks: [.paragraph("셋")]), .init(blocks: [.paragraph("넷")])])])
        XCTAssertEqual(M.parse("- 하나\n  - 안쪽\n- 둘"), [.list(ordered: false, start: 1, items: [
            .init(blocks: [.paragraph("하나"), .list(ordered: false, start: 1, items: [.init(blocks: [.paragraph("안쪽")])])]),
            .init(blocks: [.paragraph("둘")]),
        ])])
        // Two spaces under "1." nest as well, though CommonMark wants three.
        XCTAssertEqual(M.parse("1. 단계\n  - 세부"), [.list(ordered: true, start: 1, items: [
            .init(blocks: [.paragraph("단계"), .list(ordered: false, start: 1, items: [.init(blocks: [.paragraph("세부")])])]),
        ])])
        XCTAssertEqual(M.parse("- [x] 끝\n- [ ] 할 일"), [.list(ordered: false, start: 1, items: [.init(checked: true, blocks: [.paragraph("끝")]), .init(checked: false, blocks: [.paragraph("할 일")])])])
        XCTAssertEqual(M.parse("1. **제목**\n\n   설명 문단\n\n2. 다음"), [.list(ordered: true, start: 1, items: [
            .init(blocks: [.paragraph("**제목**"), .paragraph("설명 문단")]), .init(blocks: [.paragraph("다음")]),
        ])], "A paragraph indented under an item after a blank line stays in the item")
        XCTAssertEqual(M.parse("설명:\n- 가\n- 나"), [.paragraph("설명:"), .list(ordered: false, start: 1, items: [.init(blocks: [.paragraph("가")]), .init(blocks: [.paragraph("나")])])],
                       "A bullet interrupts a paragraph")
        XCTAssertEqual(M.parse("올해는\n2024. 11월에"), [.paragraph("올해는\n2024. 11월에")], "Only 1. starts a list inside a paragraph")
        XCTAssertEqual(M.parse("- 가\n\n문단"), [.list(ordered: false, start: 1, items: [.init(blocks: [.paragraph("가")])]), .paragraph("문단")])
    }

    func testFencedCode() {
        XCTAssertEqual(M.parse("```swift\nlet a = 1\n\n  b()\n```\n뒤"), [.code(language: "swift", code: "let a = 1\n\n  b()"), .paragraph("뒤")])
        XCTAssertEqual(M.parse("~~~\n```\n~~~"), [.code(language: "", code: "```")])
        XCTAssertEqual(M.parse("```py\nprint(1)"), [.code(language: "py", code: "print(1)")], "Unclosed, it runs to the end")
        XCTAssertEqual(M.parse("1. 설치\n   ```sh\n   npm i\n   ```\n2. 실행"), [.list(ordered: true, start: 1, items: [
            .init(blocks: [.paragraph("설치"), .code(language: "sh", code: "npm i")]), .init(blocks: [.paragraph("실행")]),
        ])])
    }

    func testTables() {
        XCTAssertEqual(M.parse("앞 문단\n| 이름 | 값 | 비고 |\n|:---|---:|:-:|\n| a \\| b | `x|y` |\n| 1 | 2 | 3 | 4 |\n\n뒤"), [
            .paragraph("앞 문단"),
            .table(header: ["이름", "값", "비고"], alignments: [.leading, .trailing, .center], rows: [["a \\| b", "`x|y`", ""], ["1", "2", "3"]]),
            .paragraph("뒤"),
        ])
        XCTAssertEqual(M.parse("a | b\n--- | ---\nc | d"), [.table(header: ["a", "b"], alignments: [.leading, .leading], rows: [["c", "d"]])])
        XCTAssertEqual(M.parse("A | B 비교\n다음 줄"), [.paragraph("A | B 비교\n다음 줄")], "A pipe without a separator row is text")
    }

    func testDisplayMath() {
        XCTAssertEqual(M.parse("$$\nE = mc^2\n$$"), [.math("E = mc^2")])
        XCTAssertEqual(M.parse("$$ a+b $$"), [.math("a+b")])
        XCTAssertEqual(M.parse("\\[\n\\frac{1}{2}\n\\]"), [.math("\\frac{1}{2}")])
        XCTAssertEqual(M.parse("$$x$$ 이므로 성립"), [.paragraph("$$x$$ 이므로 성립")], "A formula that starts a sentence is inline")
    }

    func testCarriageReturns() {
        XCTAssertEqual(M.parse("# 제목\r\n\r\n본문\r끝"), [.heading(level: 1, text: "제목"), .paragraph("본문\n끝")])
    }

    // MARK: Inline

    func testEmphasisCodeAndStrike() {
        XCTAssertEqual(M.inlines("앞 **굵게** *기울임* ***둘 다*** `코드` ~~취소~~"), [
            .init(text: "앞 "), .init(text: "굵게", bold: true), .init(text: " "), .init(text: "기울임", italic: true), .init(text: " "),
            .init(text: "둘 다", bold: true, italic: true), .init(text: " "), .init(text: "코드", code: true), .init(text: " "), .init(text: "취소", strike: true),
        ])
        XCTAssertEqual(M.inlines("**반달(Bandal)**은"), [.init(text: "반달(Bandal)", bold: true), .init(text: "은")], "Korean after a closing ** still closes it")
        XCTAssertEqual(M.inlines("snake_case_name 2 * 3"), [.init(text: "snake_case_name 2 * 3")])
        XCTAssertEqual(M.inlines("3~5일, 7~9일"), [.init(text: "3~5일, 7~9일")], "A single tilde is a range, not a strike")
        XCTAssertEqual(M.inlines("**굵게 `**` 안**"), [.init(text: "굵게 ", bold: true), .init(text: "**", bold: true, code: true), .init(text: " 안", bold: true)])
        XCTAssertEqual(M.inlines("\\*별표\\* a\\|b"), [.init(text: "*별표* a|b")])
        XCTAssertEqual(M.inlines("**닫히지 않음"), [.init(text: "**닫히지 않음")], "A finished answer shows an unclosed marker as typed")
    }

    func testLinks() {
        XCTAssertEqual(M.inlines("[반달](https://bandal.app/a_(b)) 참고"), [.init(text: "반달", link: "https://bandal.app/a_(b)"), .init(text: " 참고")])
        XCTAssertEqual(M.inlines("[**굵은** 링크](https://a.com \"제목\")"), [.init(text: "굵은", bold: true, link: "https://a.com"), .init(text: " 링크", link: "https://a.com")])
        XCTAssertEqual(M.inlines("https://bandal.app/help에서 확인하세요."), [.init(text: "https://bandal.app/help", link: "https://bandal.app/help"), .init(text: "에서 확인하세요.")],
                       "A bare address ends where the Korean starts")
        XCTAssertEqual(M.inlines("(https://a.com/x)."), [.init(text: "("), .init(text: "https://a.com/x", link: "https://a.com/x"), .init(text: ").")])
        XCTAssertEqual(M.inlines("<https://a.com> 줄<br>바꿈"), [.init(text: "https://a.com", link: "https://a.com"), .init(text: " 줄\n바꿈")])
        XCTAssertEqual(M.inlines("[웹](www.a.com) [메일](mailto:a@b.c)"), [.init(text: "웹", link: "https://www.a.com"), .init(text: " "), .init(text: "메일", link: "mailto:a@b.c")])
        XCTAssertEqual(M.inlines("[위험](javascript:alert(1)) [파일](file:///etc)"), [.init(text: "위험 파일")], "Only web, mail and phone links are tappable")
        XCTAssertEqual(M.destination("https://www.google.com/search?q=팔레트+디자인"), "https://www.google.com/search?q=팔레트+디자인")
        XCTAssertNotNil(URL(string: M.destination("https://www.google.com/search?q=팔레트+디자인")!), "A Korean search link opens")
    }

    func testInlineMath() {
        XCTAssertEqual(M.inlines("넓이는 $\\pi r^2$이고 \\(a+b\\) 또는 $$c$$"), [
            .init(text: "넓이는 "), .init(text: "\\pi r^2", math: true), .init(text: "이고 "), .init(text: "a+b", math: true), .init(text: " 또는 "), .init(text: "c", math: true),
        ])
        XCTAssertEqual(M.inlines("가격은 $5이고 할인가는 $3입니다"), [.init(text: "가격은 $5이고 할인가는 $3입니다")], "Money is not a formula")
        XCTAssertEqual(M.inlines("$5 and $10"), [.init(text: "$5 and $10")])
        XCTAssertEqual(M.inlines("\\[주의\\] 내용"), [.init(text: "[주의] 내용")], "Escaped brackets around Korean are not TeX")
    }

    // MARK: Streaming

    func testUnfinishedInlineMarkupWaitsOrRunsToTheEnd() {
        XCTAssertEqual(M.inlines("앞 **굵게 쓰는 중", tail: true), [.init(text: "앞 "), .init(text: "굵게 쓰는 중", bold: true)])
        XCTAssertEqual(M.inlines("앞 `code", tail: true), [.init(text: "앞 "), .init(text: "code", code: true)])
        XCTAssertEqual(M.inlines("앞 **", tail: true), [.init(text: "앞 ")], "A marker with nothing after it yet waits")
        XCTAssertEqual(M.inlines("[링크 이름", tail: true), [.init(text: "링크 이름")])
        XCTAssertEqual(M.inlines("[링크](https://exa", tail: true), [.init(text: "링크", link: "")], "The label shows; the half address does not")
        XCTAssertEqual(M.inlines("값은 $\\frac{1}{", tail: true), [.init(text: "값은 ")], "Half a formula waits")
        XCTAssertEqual(M.inlines("값은 \\(x^", tail: true), [.init(text: "값은 ")])
        XCTAssertEqual(M.inlines("가격은 $5이고", tail: true), [.init(text: "가격은 $5이고")], "Money with Korean after it does not wait")
        XCTAssertEqual(M.inlines("끝\\", tail: true), [.init(text: "끝")])
    }

    func testUnfinishedBlocks() {
        XCTAssertEqual(M.parse("문단\n#", streaming: true), [.paragraph("문단")], "A lone # waits")
        XCTAssertEqual(M.parse("문단\n1.", streaming: true), [.paragraph("문단")])
        XCTAssertEqual(M.parse("문단\n---", streaming: true), [.paragraph("문단")], "--- could still be a list or a rule")
        XCTAssertEqual(M.parse("```swift\nlet a = 1\n``", streaming: true), [.code(language: "swift", code: "let a = 1")], "A half closing fence is not code")
        XCTAssertEqual(M.parse("문단\n```pyt", streaming: true), [.paragraph("문단")], "The language is still being written")
        XCTAssertEqual(M.parse("$$\n\\frac{1}{2", streaming: true), [], "Display TeX shows once closed")
        XCTAssertEqual(M.parse("| 이름 | 값", streaming: true), [.table(header: ["이름", "값"], alignments: [.leading, .leading], rows: [])], "A header row is a table at once")
        XCTAssertEqual(M.parse("| 이름 | 값 |\n|:--", streaming: true), [.table(header: ["이름", "값"], alignments: [.leading, .leading], rows: [])])
        XCTAssertEqual(M.parse("| 이름 | 값 |\n|---|---|\n| a | b |\n|", streaming: true), [.table(header: ["이름", "값"], alignments: [.leading, .leading], rows: [["a", "b"]])],
                       "A row that has not started adds no empty row")
        XCTAssertEqual(M.parse("- 가\n- ", streaming: true), [.list(ordered: false, start: 1, items: [.init(blocks: [.paragraph("가")])])], "An empty streaming item waits")
        XCTAssertEqual(M.parse("1. 가\n2", streaming: true), [.list(ordered: true, start: 1, items: [.init(blocks: [.paragraph("가")])])], "\"2\" does not join item 1 as text")
        // Finished, the same text reads as written.
        XCTAssertEqual(M.parse("| 이름 | 값"), [.paragraph("| 이름 | 값")])
        XCTAssertEqual(M.parse("$$\n\\frac{1}{2"), [.math("\\frac{1}{2")])
    }

    // MARK: Incremental cache

    private static let samples = [
        NativeAnswerMarkdownFixture.answer,
        "문단 하나\n| 표 아님 |\n다음\n\n| a | b |\n|---|---|\n| 1 | 2 |\n끝 문단\n\n- 가\n\n  이어짐\n- 나\n  ```\n  코드\n  ```\n\n> 인용\n>\n> - 목록\n\n$$\nx\n$$\n",
        "1. 하나\n2. 둘\n10. 열\n\n* 별\n+ 더하기\n\n### 제목 ###\n~~~\n~~~~\n~~~\n텍스트 **굵게** `코드` [링크](https://a.com)",
    ]

    /// Every prefix of each sample, as it would stream: the cache must give what a full read gives.
    func testCacheMatchesAFullReadAtEveryPrefix() {
        for sample in Self.samples {
            let cache = NativeAnswerMarkdownCache()
            var prefix = ""
            for character in sample {
                prefix.append(character)
                XCTAssertEqual(cache.blocks(for: prefix, streaming: true), M.parse(prefix, streaming: true), "Streaming prefix:\n" + prefix)
            }
            XCTAssertEqual(cache.blocks(for: sample, streaming: false), M.parse(sample), "Finished")
        }
    }

    /// What is on screen only grows: a finished block never changes, a block never turns into
    /// something it was before (no table → text → table), and visible text is never taken back.
    func testStreamingNeverTakesBackWhatItShowed() {
        for sample in [Self.samples[0], Self.samples[2]] {
            let cache = NativeAnswerMarkdownCache()
            var previous: [M.Block] = [], kinds: [[String]] = [], prefix = ""
            for character in sample {
                prefix.append(character)
                let blocks = cache.blocks(for: prefix, streaming: true)
                XCTAssertGreaterThanOrEqual(blocks.count, previous.count, prefix)
                if previous.count > 1 { XCTAssertEqual(Array(blocks.prefix(previous.count - 1)), Array(previous.dropLast()), "A finished block changed:\n" + prefix) }
                for (index, block) in blocks.enumerated() {
                    if kinds.count <= index { kinds.append([]) }
                    if kinds[index].last != Self.kind(block) { kinds[index].append(Self.kind(block)) }
                }
                if let last = previous.last, blocks.indices.contains(previous.count - 1), Self.kind(last) == Self.kind(blocks[previous.count - 1]) {
                    let before = Self.visible(last), after = Self.visible(blocks[previous.count - 1])
                    XCTAssertTrue(after.hasPrefix(before), "Visible text went back from \"\(before)\" to \"\(after)\"")
                }
                previous = blocks
            }
            for sequence in kinds { XCTAssertEqual(Set(sequence).count, sequence.count, "A block flipped back: \(sequence)") }
        }
    }

    /// A long answer streamed in small pieces is read near its end only, not again from the top.
    func testCacheRereadsOnlyTheEnd() {
        let paragraph = "이 문단은 **길이를** 채우기 위한 문장입니다. `코드`와 [링크](https://a.com)도 있어요.\n\n"
        let answer = String(repeating: paragraph + "- 항목 하나\n- 항목 둘\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n", count: 60)
        let cache = NativeAnswerMarkdownCache()
        var prefix = "", steps = 0
        for character in answer {
            prefix.append(character)
            if prefix.count % 4 == 0 { _ = cache.blocks(for: prefix, streaming: true); steps += 1 }
        }
        let full = answer.utf8.count
        XCTAssertLessThan(cache.parsedBytes, steps * 400, "Each step reads about the last two blocks")
        XCTAssertLessThan(cache.parsedBytes * 20, steps * full / 2, "Reading from the top every time would be over 20 times more")
        XCTAssertEqual(cache.blocks(for: answer, streaming: false), M.parse(answer))
    }

    func testReplacedTextIsReadAgain() {
        let cache = NativeAnswerMarkdownCache()
        XCTAssertEqual(cache.blocks(for: "# 하나\n\n본문", streaming: true), [.heading(level: 1, text: "하나"), .paragraph("본문")])
        XCTAssertEqual(cache.blocks(for: "전혀 다른 답", streaming: false), [.paragraph("전혀 다른 답")])
        XCTAssertEqual(cache.blocks(for: "", streaming: false), [])
    }

    private static func kind(_ block: M.Block) -> String {
        switch block {
        case .heading(let level, _): "h\(level)"
        case .paragraph: "p"
        case .list(let ordered, _, _): ordered ? "ol" : "ul"
        case .code: "code"
        case .quote: "quote"
        case .table: "table"
        case .math: "math"
        case .rule: "rule"
        }
    }
    private static func visible(_ block: M.Block) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text): M.inlines(text, tail: true).map { $0.math ? "￼" : $0.text }.joined()
        case .list(_, _, let items): items.map { $0.blocks.map(visible).joined(separator: "\n") }.joined(separator: "\n")
        case .code(_, let code): code
        case .quote(let blocks): blocks.map(visible).joined(separator: "\n")
        // Cells not reached yet are blank, not text that was taken back.
        case .table(let header, _, let rows): ([header] + rows).map { Array($0.reversed().drop(while: \.isEmpty).reversed()).joined(separator: "\t") }.joined(separator: "\n")
        case .math(let latex): latex
        case .rule: "—"
        }
    }
}
