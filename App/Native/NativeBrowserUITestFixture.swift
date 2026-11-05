#if DEBUG
import Foundation
import WebKit

@MainActor
extension NativeBrowserSession {
    func loadUITestFixture(id: String) async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--native-ui-testing"), args.contains("--native-browser-ui-fixture"), let page = host.pages[id] else { return }
        let title = args.contains("--native-browser-long-title-ui-fixture")
            ? "Native browser fixture — 아주 긴 학교 학습 자료 제목과 여러 강의 안내 및 학기별 과제 페이지를 동시에 확인하는 브라우저와 프로젝트별 참고 자료 상세 안내"
            : "Native browser fixture"
        guard page.liveWebView?.title != title else { return }
        if args.contains("--native-browser-login-ui-fixture") {
            // An https base URL gives the page a real https origin without a network.
            page.webView.loadHTMLString("""
                <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(title)</title><style>body{font:16px -apple-system;padding:20px}input,button{font:inherit;padding:12px;margin:8px 0;display:block}</style></head>
                <body><h1>Login fixture</h1><form onsubmit="event.preventDefault()"><input aria-label="Fixture username" name="username" autocomplete="off"><input aria-label="Fixture password" type="password" name="password"><button>Sign in</button></form>
                <button onclick="location.reload()">Reload fixture</button></body></html>
                """, baseURL: URL(string: "https://login.fixture.test/"))
            return
        }
        let parity = args.contains("--native-browser-parity-ui-fixture")
        let body = parity ? """
            <p>Bandal needle one.</p><p>Bandal needle two.</p><p>Bandal needle three.</p>
            <button id="download" onclick="downloadFixture()">Download local fixture</button>
            <script>function downloadFixture(){const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(['Native browser download fixture.'],{type:'text/plain'}));a.download='browser-fixture.txt';document.body.appendChild(a);a.click();a.remove();}</script>
            """ : args.contains("--native-browser-popup-ui-fixture") ? """
            <p><a id="blank" href="about:blank" target="_blank">Open blank tab</a></p>
            <p><button onclick="window.__fixturePopup=window.open('about:blank','fixture-popup')">Open popup</button></p>
            <p><button onclick="window.__fixturePopup?.close()">Close popup</button></p>
            """ : "<p>Local website content.</p>"
        page.webView.loadHTMLString("""
            <!doctype html><html lang="ko"><head><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'"><title>\(title)</title><style>body{font:16px -apple-system;padding:20px;overflow-wrap:anywhere}input,button{font:inherit;padding:12px;max-width:90%;margin:8px 0}h1{font-size:24px}</style></head><body><h1>Native browser fixture</h1><label>Website input <input aria-label="Website input"></label>\(body)</body></html>
            """, baseURL: nil)
        if parity && !page.isPrivate {
            _ = try? await host.handle(channel: "browser:recordVisit", request: ["profileId": page.profileID, "url": "https://fixture.example/lecture", "title": "Local fixture history", "courseId": effectiveCourseID as Any? ?? NSNull()])
        }
    }
}
#endif
