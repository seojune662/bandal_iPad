import SwiftUI
import WebKit

struct BrowserWorkspaceView: View {
    @ObservedObject var session: BrowserSession
    var onOpenTab: (URL, Bool) -> Void
    var onDownload: (URL) -> Void
    var onCreateSession: ((BrowserSession) -> Void)? = nil
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { session.webView.goBack() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(!session.canGoBack).accessibilityLabel("뒤로")
                Button { session.webView.goForward() } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(!session.canGoForward).accessibilityLabel("앞으로")
                HStack(spacing: 8) {
                    Image(systemName: session.isPrivate ? "hand.raised.fill" : (session.url?.scheme == "https" ? "lock.fill" : "globe")).font(.caption)
                    TextField("검색 또는 웹 주소", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.webSearch)
                        .submitLabel(.go).focused($addressFocused)
                        .onSubmit { session.submit(address); addressFocused = false }
                        .accessibilityIdentifier("browser.address")
                    if addressFocused && !address.isEmpty {
                        Button { address = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44) }.accessibilityLabel("주소 지우기")
                    }
                }.padding(.horizontal, 12).frame(minHeight: 44).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Button { session.isLoading ? session.stop() : session.reload() } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise").frame(width: 44, height: 44)
                }.accessibilityLabel(session.isLoading ? "불러오기 중지" : "새로고침")
                if let url = session.url { ShareLink(item: url) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }.accessibilityLabel("웹 주소 공유") }
            }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6)
            if session.isLoading { ProgressView(value: session.progress).progressViewStyle(.linear) }
            Divider()
            if let error = session.errorMessage {
                HStack {
                    Text(error).font(.callout)
                    Spacer()
                    Button("다시 열기") { session.reload() }.frame(minHeight: 44)
                    Button { session.errorMessage = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("알림 닫기")
                }.padding(.leading, 12).background(Color.orange.opacity(0.12))
            }
            ZStack {
                BrowserWebViewHost(session: session, onOpenTab: onOpenTab, onDownload: onDownload, onCreateSession: onCreateSession)
                if session.url == nil {
                    VStack(spacing: 16) {
                        Image(systemName: session.isPrivate ? "hand.raised" : "globe").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text(session.isPrivate ? "개인 브라우징" : "자료를 찾아보세요").font(.title2.weight(.semibold))
                        Text(session.isPrivate ? "이 탭의 방문 정보와 쿠키는 탭을 닫으면 사라집니다. 내려받은 자료는 과목에 남습니다." : "위 주소창에서 검색하거나 웹 주소를 입력하세요.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }.padding(28).allowsHitTesting(false)
                }
            }
        }
        .onAppear { address = session.url?.absoluteString ?? "" }
        .onChange(of: session.url) { _, url in if !addressFocused { address = url?.absoluteString ?? "" } }
        .onChange(of: addressFocused) { _, focused in if !focused { address = session.url?.absoluteString ?? "" } }
    }
}

private struct BrowserWebViewHost: UIViewControllerRepresentable {
    let session: BrowserSession
    let onOpenTab: (URL, Bool) -> Void
    let onDownload: (URL) -> Void
    let onCreateSession: ((BrowserSession) -> Void)?

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        attach(to: controller)
        return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) { attach(to: controller) }
    private func attach(to controller: UIViewController) {
        session.onOpenTab = onOpenTab
        session.onDownload = onDownload
        session.onCreateSession = onCreateSession
        session.presenter = controller
        guard session.webView.superview !== controller.view else { return }
        session.webView.removeFromSuperview()
        session.webView.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(session.webView)
        NSLayoutConstraint.activate([
            session.webView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            session.webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            session.webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            session.webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor)
        ])
    }
}
