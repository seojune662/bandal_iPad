import SwiftUI
import Foundation

private final class PublicArticleRequest: NSObject, URLSessionTaskDelegate {
    static func validate(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.validate) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    static func fetch(_ url: URL) async throws -> (String, URL) {
        guard validate(url) else { throw LearningError.message("올바른 http 또는 https 주소를 입력해 주세요.") }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: PublicArticleRequest(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let finalURL = response.url, validate(finalURL) else {
            throw LearningError.message("공개 문서를 불러오지 못했습니다. 로그인이 필요한 글은 본문을 직접 붙여 넣어 주세요.")
        }
        guard ["text/html", "application/xhtml+xml", "text/plain"].contains(response.mimeType ?? ""), response.expectedContentLength <= 2_000_000 else { throw LearningError.message("2MB 이하의 웹 문서만 읽기 자료로 저장할 수 있습니다.") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_000_000 else { throw LearningError.message("문서가 너무 큽니다. 필요한 본문을 직접 붙여 넣어 주세요.") }
            data.append(byte)
        }
        let encoding: String.Encoding = response.textEncodingName?.lowercased().contains("8859") == true ? .isoLatin1 : .utf8
        guard let text = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf16) else { throw LearningError.message("이 문서의 문자 형식을 읽을 수 없습니다. 본문을 붙여 넣어 주세요.") }
        // Plain text is escaped before passing through the static HTML extractor.
        if response.mimeType == "text/plain" { return ("<main>" + text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\n", with: "<br>") + "</main>", finalURL) }
        return (text, finalURL)
    }
}

struct LearningArticleImport: View {
    @Environment(\.dismiss) private var dismiss
    let courseID: String
    let onSave: (LearningArticle) -> Void
    @State private var mode = 0
    @State private var address = ""
    @State private var title = ""
    @State private var content = ""
    @State private var loading = false
    @State private var error: String?
    @State private var request: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Picker("가져오기", selection: $mode) { Text("웹 주소").tag(0); Text("본문 붙여 넣기").tag(1) }.pickerStyle(.segmented).disabled(loading)
                Section(mode == 0 ? "공개 문서 주소" : "원문 출처 (선택)") {
                    TextField("https://", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(loading)
                }
                if mode == 1 {
                    Section("글 제목") { TextField("제목", text: $title) }
                    Section("본문") { TextEditor(text: $content).frame(minHeight: 260) }
                } else {
                    Text("본문을 텍스트로 저장합니다. 로그인 정보는 사용하지 않으며, 이미지와 영상은 포함되지 않습니다. 본문을 찾지 못하면 붙여 넣기를 사용해 주세요.").font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if loading { HStack { ProgressView(); Text("읽을 수 있는 본문을 가져오는 중…") } }
            }.navigationTitle("읽기 자료 추가")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { request?.cancel(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(mode == 0 ? "가져오기" : "저장", action: save).disabled(loading || (mode == 0 ? address.isEmpty : title.isEmpty || content.isEmpty)) }
                }
        }.onDisappear { request?.cancel() }.presentationDetents([.large])
    }
    private func save() {
        error = nil
        if mode == 1 {
            guard content.utf8.count <= 1_000_000 else { error = "본문은 1MB 이하로 나누어 주세요."; return }
            let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.isEmpty || URL(string: url).map(PublicArticleRequest.validate) == true else { error = "출처 주소를 확인해 주세요."; return }
            let paragraphs = LearningArticleParser.pasted(content)
            guard !paragraphs.isEmpty else { error = "본문을 입력해 주세요."; return }
            onSave(LearningArticle(courseID: courseID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), sourceURL: url.isEmpty ? nil : url, paragraphs: paragraphs)); dismiss()
            return
        }
        let entered = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: entered.contains("://") ? entered : "https://" + entered), PublicArticleRequest.validate(url) else { error = "웹 주소를 확인해 주세요."; return }
        loading = true
        request = Task {
            do {
                let (html, finalURL) = try await PublicArticleRequest.fetch(url)
                try Task.checkCancellation()
                let parsed = LearningArticleParser.extract(html)
                guard parsed.paragraphs.joined().count >= 80 else { throw LearningError.message("본문이 충분하지 않습니다. 웹 페이지에서 본문을 복사해 붙여 넣어 주세요.") }
                onSave(LearningArticle(courseID: courseID, title: parsed.title.isEmpty ? finalURL.host ?? "읽기 자료" : parsed.title, sourceURL: finalURL.absoluteString, paragraphs: parsed.paragraphs)); dismiss()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct ReadingPositions: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { _, latest in latest }) }
}
private struct ArticleWordContext: Identifiable { var id = UUID(); var text: String }

struct LearningArticleReader: View {
    @EnvironmentObject private var model: AppModel
    let article: LearningArticle
    let initialProgress: LearningReadingProgress?
    let onBack: () -> Void
    let onProgress: (LearningReadingProgress) -> Void
    @AppStorage("learning.reader.fontSize") private var fontSize = 20.0
    @State private var currentIndex = 0
    @State private var lastSavedIndex = -1
    @State private var completed = false
    @State private var restoring = true
    @State private var saveTask: Task<Void, Never>?
    @State private var wordContext: ArticleWordContext?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("목록", systemImage: "chevron.left") { saveProgress(); onBack() }.frame(minHeight: 44)
                Spacer()
                Text("\(min(currentIndex + 1, article.paragraphs.count))/\(article.paragraphs.count)").font(.caption).monospacedDigit()
                Menu {
                    Button("글자 크게") { fontSize = min(32, fontSize + 2) }
                    Button("글자 작게") { fontSize = max(14, fontSize - 2) }
                    Button("노트로 저장") { model.createNote(title: article.title, markdown: "# \(article.title)\n\n" + article.paragraphs.joined(separator: "\n\n")) }
                    if let address = article.sourceURL, let url = URL(string: address) { Button("원문을 브라우저에서 열기") { model.open(.browser, url: url) } }
                } label: { Image(systemName: "textformat.size").frame(width: 44, height: 44) }.accessibilityLabel("읽기 설정과 원문")
            }.padding(.horizontal, 16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(article.title).font(.title.bold()).textSelection(.enabled)
                            Text(article.sourceURL.flatMap { URL(string: $0)?.host } ?? "직접 저장한 글").font(.caption).foregroundStyle(.secondary)
                            Text("\(article.createdAt.formatted(date: .abbreviated, time: .omitted)) 저장 · 오프라인 읽기").font(.caption).foregroundStyle(.secondary)
                        }.padding(.bottom, 12)
                        ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { index, text in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(text).font(.system(size: fontSize)).lineSpacing(fontSize * 0.3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Button("단어 저장", systemImage: "character.book.closed") { wordContext = ArticleWordContext(text: text) }
                                    Spacer()
                                    Button("여기까지 읽음", systemImage: "bookmark") { currentIndex = index; saveProgress(force: true) }
                                }.font(.caption).foregroundStyle(.secondary).buttonStyle(.borderless).frame(minHeight: 36)
                            }.id(index).background(GeometryReader { geometry in Color.clear.preference(key: ReadingPositions.self, value: [index: geometry.frame(in: .named("articleReader")).minY]) })
                        }
                        Button(completed ? "완독했어요" : "읽기 완료", systemImage: completed ? "checkmark.circle.fill" : "checkmark.circle") { completed = true; currentIndex = max(0, article.paragraphs.count - 1); saveProgress(force: true) }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).padding(.vertical, 20)
                    }.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.coordinateSpace(name: "articleReader")
                    .onPreferenceChange(ReadingPositions.self) { positions in
                        guard !restoring, !positions.isEmpty else { return }
                        let next = positions.filter { $0.value <= 100 }.max(by: { $0.key < $1.key })?.key ?? positions.min(by: { $0.value < $1.value })?.key ?? 0
                        guard next != currentIndex else { return }
                        currentIndex = next; saveTask?.cancel()
                        saveTask = Task { try? await Task.sleep(for: .milliseconds(900)); if !Task.isCancelled { saveProgress() } }
                    }
                    .task {
                        currentIndex = min(max(0, initialProgress?.paragraphIndex ?? 0), max(0, article.paragraphs.count - 1))
                        completed = initialProgress?.completed ?? false; lastSavedIndex = currentIndex
                        await Task.yield(); proxy.scrollTo(currentIndex, anchor: .top)
                        try? await Task.sleep(for: .milliseconds(250)); restoring = false
                    }
            }
        }.onDisappear { saveTask?.cancel(); saveProgress() }
            .sheet(item: $wordContext) { context in LearningArticleWordSheet(context: context.text, courseID: article.courseID) }
    }
    private func saveProgress(force: Bool = false) {
        guard force || currentIndex != lastSavedIndex else { return }
        onProgress(LearningReadingProgress(courseID: article.courseID, articleID: article.id, paragraphIndex: currentIndex, completed: completed)); lastSavedIndex = currentIndex
    }
}

private struct LearningArticleWordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let context: String
    let courseID: String
    @State private var word = ""
    @State private var meaning = ""
    @State private var results: [DictionaryMeaning] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("원문 문장") { Text(context).textSelection(.enabled) }
                Section("단어") {
                    HStack { TextField("저장할 단어", text: $word).textInputAutocapitalization(.never); Button("사전 검색") { do { results = try DictionaryService.lookup(word); error = results.isEmpty ? "검색 결과가 없습니다. 뜻을 직접 입력할 수 있어요." : nil } catch { self.error = error.localizedDescription } } }
                    ForEach(results) { entry in Button { meaning = entry.meaning } label: { VStack(alignment: .leading) { Text(entry.word).font(.headline); Text(entry.meaning).font(.subheadline) } } }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
                Section("뜻") { TextField("뜻 또는 나의 설명", text: $meaning, axis: .vertical) }
            }.navigationTitle("문장과 함께 단어 저장").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { model.saveVocabulary(VocabularyEntry(courseID: courseID, word: word.trimmingCharacters(in: .whitespacesAndNewlines), meaning: meaning.trimmingCharacters(in: .whitespacesAndNewlines), context: context)); dismiss() }.disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
