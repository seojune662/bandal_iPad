import SwiftUI

struct NativeBrowserFindBar: View {
    @ObservedObject var session: NativeBrowserSession
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(NativeDesktopTheme.muted)
            TextField("페이지에서 찾기", text: Binding(get: { session.findState.query }, set: { session.setFindQuery($0) }))
                .textFieldStyle(.plain).focused($focused).submitLabel(.search)
                .onSubmit { step(true) }.accessibilityIdentifier("native-browser-find")
            Text(result).font(.system(size: 12).monospacedDigit()).foregroundStyle(NativeDesktopTheme.muted)
                .fixedSize().accessibilityIdentifier("native-browser-find-count")
            Button("이전 결과", systemImage: "chevron.up") { step(false) }
                .disabled(session.findState.query.isEmpty || session.findState.count == 0).accessibilityIdentifier("native-browser-find-previous")
            Button("다음 결과", systemImage: "chevron.down") { step(true) }
                .disabled(session.findState.query.isEmpty || session.findState.count == 0).accessibilityIdentifier("native-browser-find-next")
            Button("검색 닫기", systemImage: "xmark") { session.setFindVisible(false) }.accessibilityIdentifier("native-browser-find-close")
        }.buttonStyle(NativeBrowserIconStyle()).padding(.leading, 12).background(NativeDesktopTheme.surface)
        .onAppear { focused = true }
        .onChange(of: session.findState.focusRevision) { _, _ in focused = true }
        .onKeyPress(.escape) { session.setFindVisible(false); return .handled }
        .onKeyPress(.return, phases: .down) { press in if press.modifiers.contains(.shift) { step(false); return .handled }; return .ignored }
    }
    private var result: String {
        guard !session.findState.query.isEmpty else { return "" }
        guard let count = session.findState.count else { return "…" }
        return "\(session.findState.ordinal) / \(count)"
    }
    private func step(_ forward: Bool) { Task { do { try await session.stepFind(forward: forward) } catch { session.error = error.localizedDescription } } }
}

struct NativeBrowserStartPage: View {
    @ObservedObject var session: NativeBrowserSession
    let navigate: (String) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: session.active?.isPrivate == true ? "hand.raised" : "globe").font(.system(size: 32)).foregroundStyle(NativeDesktopTheme.muted)
                    Text(session.active?.isPrivate == true ? "개인정보 보호 브라우징" : "웹에서 학습을 이어가세요").font(.system(size: 22, weight: .semibold))
                    Text(session.active?.isPrivate == true ? "이 탭의 방문 기록과 열린 주소는 저장하지 않습니다." : "주소를 입력하거나 즐겨찾기와 학교 사이트를 열어보세요.")
                        .font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                }
                if !session.favoriteLinks.isEmpty { links("즐겨찾기", rows: session.favoriteLinks, symbol: "star") }
                if !session.schoolLinks.isEmpty { links("학교 사이트", rows: session.schoolLinks, symbol: "building.columns") }
            }.frame(maxWidth: 720, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }.background(NativeDesktopTheme.bgApp).accessibilityElement(children: .contain).accessibilityIdentifier("native-browser-start-page")
    }
    private func links(_ title: String, rows: [NativeBrowserLink], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NativeDesktopTheme.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(rows) { row in
                    Button { navigate(row.url) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: symbol).foregroundStyle(NativeDesktopTheme.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(NativeBrowserAddress.display(row.url)).font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(12).frame(minHeight: 58).background(NativeDesktopTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

struct NativeBrowserHistoryPanel: View {
    @ObservedObject var session: NativeBrowserSession
    let navigate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [NativeBrowserLink] = []
    @State private var error: String?
    @State private var confirmClear = false
    @State private var loading = false
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                if loading { ProgressView() }
                if rows.isEmpty && !loading { ContentUnavailableView("방문 기록이 없습니다", systemImage: "clock", description: Text("현재 프로필의 방문 기록이 여기에 표시됩니다.")) }
                ForEach(rows) { row in
                    Button { dismiss(); navigate(row.url) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NativeBrowserAddress.title(row.title, url: row.url)).lineLimit(2)
                            Text(row.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                }
            }.navigationTitle("방문 기록 · " + session.activeProfileName)
                .searchable(text: $query, prompt: "주소 또는 제목 검색")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("기록 지우기", role: .destructive) { confirmClear = true }.disabled(session.active?.isPrivate == true) }
                    ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
                }
                .task(id: query) { await load() }
                .alert("이 프로필의 방문 기록을 모두 지울까요?", isPresented: $confirmClear) {
                    Button("취소", role: .cancel) {}
                    Button("기록 지우기", role: .destructive) { Task { await clear() } }
                } message: { Text("즐겨찾기와 웹사이트 로그인 상태는 유지됩니다.") }
        }
    }
    private func load() async {
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(120)); try Task.checkCancellation()
            let result = try await session.searchHistory(query)
            try Task.checkCancellation(); rows = result; error = nil; loading = false
        } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
    }
    private func clear() async {
        do { _ = try await session.host.handle(channel: "browser:clearHistory", request: ["profileId": session.active?.profileID ?? "default"]); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct NativeBrowserDownloadsPanel: View {
    @ObservedObject var session: NativeBrowserSession
    let action: (NativeBrowserDownloadItem, String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let error = session.error {
                    HStack(alignment: .top) {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("native-browser-download-error")
                        Spacer(minLength: 4)
                        Button("오류 안내 닫기", systemImage: "xmark") { session.error = nil }.buttonStyle(NativeBrowserIconStyle())
                    }
                }
                if session.visibleDownloads.isEmpty { ContentUnavailableView("다운로드가 없습니다", systemImage: "arrow.down.circle", description: Text("현재 프로필에서 내려받은 파일이 여기에 표시됩니다.")) }
                ForEach(session.visibleDownloads) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(item.fileName).font(.headline).lineLimit(2)
                            Spacer(minLength: 0)
                            if item.state != "progressing" { Button("목록에서 지우기", systemImage: "xmark") { action(item, "dismiss") }.buttonStyle(NativeBrowserIconStyle()) }
                        }
                        if item.state == "progressing" {
                            ProgressView(value: item.total > 0 ? min(1, Double(item.received) / Double(item.total)) : nil)
                        }
                        Text(item.status + byteCount(item)).font(.caption).foregroundStyle(.secondary)
                        if let error = item.error, !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
                        actions(item)
                    }.padding(.vertical, 6)
                }
            }.navigationTitle("다운로드")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
                .task { do { try await session.reloadDownloads() } catch { session.error = error.localizedDescription } }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("native-browser-downloads")
    }
    private func byteCount(_ item: NativeBrowserDownloadItem) -> String {
        guard item.received > 0 else { return "" }
        let received = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        return " · " + received + (item.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file) : "")
    }
    @ViewBuilder private func actions(_ item: NativeBrowserDownloadItem) -> some View {
        HStack(spacing: 18) {
            if item.state == "progressing" {
                Button(item.paused ? "계속" : "일시 정지") { action(item, item.paused ? "resume" : "pause") }
                Button("취소", role: .destructive) { action(item, "cancel") }
            } else if item.state == "completed" {
                Button("열기") { action(item, "open") }.accessibilityIdentifier("native-browser-download-open")
                Button("파일에 저장") { action(item, "saveAs") }
                if let title = item.retryTitle { Button(title) { action(item, "retry") } }
            } else if let title = item.retryTitle { Button(title) { action(item, "retry") } }
        }.buttonStyle(.borderless).font(.system(size: 13, weight: .medium)).frame(minHeight: 36)
    }
}

struct NativeBrowserIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.labelStyle(.iconOnly).font(.system(size: 14)).frame(width: 44, height: 44)
            .contentShape(Rectangle()).background(configuration.isPressed ? NativeDesktopTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
