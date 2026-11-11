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
    @State private var query = ""
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: session.active?.isPrivate == true ? "hand.raised.fill" : "magnifyingglass")
                            .font(.system(size: 36, weight: .light)).foregroundStyle(NativeDesktopTheme.muted)
                        Text(session.active?.isPrivate == true ? "개인정보 보호 브라우징" : "새 탭")
                            .font(.system(size: 25, weight: .medium))
                        if session.active?.isPrivate == true {
                            Text("이 탭의 방문 기록과 열린 주소는 저장하지 않습니다.")
                                .font(.system(size: 13)).foregroundStyle(NativeDesktopTheme.secondary)
                        }
                    }.multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(NativeDesktopTheme.muted)
                        TextField("검색 또는 웹사이트 주소", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                            .keyboardType(.webSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .submitLabel(.go).onSubmit(submit).accessibilityIdentifier("native-browser-new-tab-search")
                        Button("이동", systemImage: "arrow.right") { submit() }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.padding(.leading, 20).padding(.trailing, 4).frame(height: 52)
                        .background(NativeDesktopTheme.overlay, in: Capsule())
                        .overlay(Capsule().strokeBorder(NativeDesktopTheme.border))
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                }.frame(maxWidth: 560).padding(28)
                    .frame(maxWidth: .infinity, minHeight: max(240, geometry.size.height * 0.7))
            }.background(NativeDesktopTheme.bgApp)
                .accessibilityElement(children: .contain).accessibilityIdentifier("native-browser-start-page")
        }
    }
    private func submit() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        focused = false
        navigate(value)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                BandalSectionHeader("방문 기록 · " + session.activeProfileName)
                Button(confirmClear ? "정말 지우기" : "기록 지우기") { if confirmClear { Task { await clear(); confirmClear = false } } else { confirmClear = true } }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.red).buttonStyle(.plain)
                    .disabled(session.active?.isPrivate == true).accessibilityIdentifier("native-browser-history-clear")
            }
            if confirmClear { Text("즐겨찾기와 사이트 로그인은 그대로 남아요.").font(.system(size: 11)).foregroundStyle(NativeDesktopTheme.muted) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            BandalSearchList(prompt: "주소 또는 제목 검색", query: $query, identifier: "native-browser-history-search") {
                if loading && rows.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(8) }
                if rows.isEmpty && !loading { Text("방문 기록이 없어요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(8) }
                ForEach(rows) { row in
                    BandalMenuRow(NativeBrowserAddress.title(row.title, url: row.url), detail: row.url) { dismiss(); navigate(row.url) }
                }
            }
        }
        .task(id: query) { await load() }
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
        VStack(alignment: .leading, spacing: 6) {
            BandalSectionHeader("다운로드")
            ScrollView { VStack(alignment: .leading, spacing: 8) {
                if let error = session.error {
                    HStack(alignment: .top) {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("native-browser-download-error")
                        Spacer(minLength: 4)
                        Button("오류 안내 닫기", systemImage: "xmark") { session.error = nil }.buttonStyle(NativeBrowserIconStyle())
                    }
                }
                if session.visibleDownloads.isEmpty { Text("내려받은 파일이 없어요").font(.system(size: 12)).foregroundStyle(NativeDesktopTheme.muted).padding(.vertical, 4) }
                ForEach(session.visibleDownloads) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(item.fileName).font(.system(size: BandalMetrics.bodySize, weight: .semibold)).lineLimit(2)
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
            } }.frame(maxHeight: 420).fixedSize(horizontal: false, vertical: true)
        }
        .task { do { try await session.reloadDownloads() } catch { session.error = error.localizedDescription } }
        .accessibilityElement(children: .contain).accessibilityIdentifier("native-browser-downloads")
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
