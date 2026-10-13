import Foundation
import WebKit

extension DesktopBrowserHost {
    func credentialTarget(guestID: Int, origin: String) throws -> DesktopCredentialTarget {
        let expected = try DesktopCredentialsService.origin(origin)
        guard expected == origin, let page = pages.values.first(where: { $0.id == guestID }), !page.isPrivate,
              !page.webView.isLoading, let address = page.webView.url,
              try DesktopCredentialsService.origin(address.absoluteString) == expected,
              isProfileAvailable(page.profileID) else {
            throw DesktopBrowserError.unavailable("현재 HTTPS 사이트의 일반 브라우저 탭에서만 로그인을 사용할 수 있습니다.")
        }
        return DesktopCredentialTarget(guestID: guestID, tabID: page.tabID, profileID: page.profileID, origin: expected, generation: agentGeneration(page))
    }
    private func credentialPage(_ target: DesktopCredentialTarget) throws -> DesktopBrowserPage {
        guard try credentialTarget(guestID: target.guestID, origin: target.origin) == target, let page = pages[target.tabID] else {
            throw DesktopBrowserError.unavailable("로그인할 페이지가 변경되었습니다. 다시 시도해 주세요.")
        }
        return page
    }
    func captureLogin(_ target: DesktopCredentialTarget) async throws -> [String: String]? {
        let page = try credentialPage(target)
        let captured = try await page.webView.callAsyncJavaScript(
            "if(window.top!==window || location.origin!==origin) return null; return globalThis.__bandalNativeLoginCapture?.() ?? null",
            arguments: ["origin": target.origin], in: nil, contentWorld: BrowserCredentialScripts.world)
        _ = try credentialPage(target)
        guard let result = captured as? [String: String], let username = result["username"], !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              username.utf8.count <= 10_000, let password = result["password"], !password.isEmpty, password.utf8.count <= 100_000 else { return nil }
        return ["username": username, "password": password]
    }
    func fillLogin(_ target: DesktopCredentialTarget, username: String, password: String, autoSubmit: Bool) async throws -> [String: Bool] {
        guard username.utf8.count <= 10_000, password.utf8.count <= 100_000, !password.isEmpty else { throw DesktopBrowserError.invalid("로그인 입력") }
        let page = try credentialPage(target)
        let result = try await page.webView.callAsyncJavaScript(BrowserCredentialScripts.fill,
            arguments: ["origin": target.origin, "username": username, "password": password, "autoSubmit": autoSubmit], in: nil, contentWorld: BrowserCredentialScripts.world)
        guard pages[target.tabID] === page, !page.isPrivate, page.profileID == target.profileID,
              let values = result as? [String: Bool], let filled = values["filled"], let submitted = values["submitted"] else {
            throw DesktopBrowserError.unavailable("로그인 페이지의 응답을 확인하지 못했습니다.")
        }
        // Submission may intentionally navigate. A fill-only operation must
        // still refer to the same native page generation after the JS await.
        if !submitted { _ = try credentialPage(target) }
        return ["filled": filled, "submitted": filled && submitted]
    }
}

enum BrowserCredentialScripts {
    static let world = WKContentWorld.world(name: "bandal-browser-credentials")
    /// The page world cannot replace this listener, mark synthetic events as
    /// trusted, or read its captured values. Only native Keychain code calls it.
    static let capture = #"""
    (() => {
      if (window.top !== window) return;
      let captured = null;
      const fields = () => {
        const password = document.querySelector('input[type="password"]');
        if (!(password instanceof HTMLInputElement) || password.disabled || password.readOnly) return null;
        const username = Array.from(document.querySelectorAll('input[type="text"], input[type="email"], input[type="tel"], input:not([type])')).filter(input =>
          input instanceof HTMLInputElement && !input.disabled && !input.readOnly && input.form === password.form &&
          (input.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0).at(-1);
        return username instanceof HTMLInputElement ? { username, password } : null;
      };
      document.addEventListener('input', event => {
        if (!event.isTrusted || !(event.target instanceof HTMLInputElement)) return;
        const found = fields();
        if (!found) { captured = null; return; }
        if (event.target === found.password) {
          captured = { username: found.username.value, password: found.password.value, usernameNode: found.username,
            passwordNode: found.password, origin: location.origin, expires: Date.now() + 60000 };
        } else if (captured && event.target === found.username && captured.passwordNode === found.password) {
          captured.username = found.username.value;
        }
      }, true);
      Object.defineProperty(globalThis, '__bandalNativeLoginCapture', { value: () => {
        const found = fields();
        if (!captured || captured.expires < Date.now() || captured.origin !== location.origin || !found ||
          found.password !== captured.passwordNode || found.username !== captured.usernameNode ||
          found.password.value !== captured.password || found.username.value !== captured.username) return null;
        return { username: captured.username, password: captured.password };
      }, configurable: false, writable: false });
    })();
    """#
    /// Same native-value setter, input/change events and optional requestSubmit
    /// behavior as desktop loginFiller; no secret crosses the shell IPC reply.
    static let fill = #"""
    if(window.top !== window || location.origin !== origin) return {filled:false,submitted:false};
    const passwordInput = document.querySelector('input[type="password"]');
    if (!(passwordInput instanceof HTMLInputElement) || passwordInput.disabled || passwordInput.readOnly) return {filled:false,submitted:false};
    const form = passwordInput.form;
    const usernameInput = Array.from(document.querySelectorAll('input[type="text"], input[type="email"], input[type="tel"], input:not([type])')).filter(input =>
      input instanceof HTMLInputElement && !input.disabled && !input.readOnly && input.form === form &&
      (input.compareDocumentPosition(passwordInput) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0).at(-1);
    if (!(usernameInput instanceof HTMLInputElement)) return {filled:false,submitted:false};
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (typeof setter !== 'function') return {filled:false,submitted:false};
    const setValue = (input,value) => { setter.call(input,value); input.dispatchEvent(new Event('input',{bubbles:true})); input.dispatchEvent(new Event('change',{bubbles:true})); };
    setValue(usernameInput,username); setValue(passwordInput,password);
    let submitted = false;
    if(autoSubmit && form && location.origin === origin) {
      try { if(typeof form.requestSubmit === 'function') form.requestSubmit(); else form.submit(); submitted = true; } catch {}
    }
    return {filled:true,submitted};
    """#
}
