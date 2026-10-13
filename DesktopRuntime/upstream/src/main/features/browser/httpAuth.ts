/**
 * HTTP authentication — Basic, Digest, NTLM, Negotiate, and proxy auth.
 *
 * There was no handler at all, and Electron's default with no `login`
 * listener is to **cancel the request**. So:
 *
 *  - 도서관 학외접속 프록시 / EZproxy and older 학사·행정 시스템 behind Basic
 *    auth rendered a blank rect with no prompt and no way in;
 *  - and any student behind an authenticating campus proxy got
 *    `ERR_PROXY_AUTH_REQUESTED` on **every request, app-wide** — a completely
 *    non-functional browser with nothing to explain it.
 *
 * Two rules keep this from becoming a phishing surface:
 *
 *  1. **The realm and host come from the request, never from the page.** A
 *     page cannot put words in this dialog.
 *  2. **Proxy auth is labelled as proxy auth.** The classic attack is a site
 *     that triggers a 407 so the dialog reads like a system prompt; saying
 *     which it is costs one line.
 *
 * Nothing is remembered. A password typed here is handed to Chromium for that
 * request and never touches disk — the credential store (`credentials/`) is a
 * separate, deliberate, per-origin feature and this is not a back door into it.
 */

import { BrowserWindow, dialog } from 'electron'

export interface AuthPromptRequest {
  isProxy: boolean
  host: string
  port: number
  realm: string
  scheme: string
}

export interface AuthPromptResult {
  username: string
  password: string
}

/** One dialog per (proxy, host, realm) at a time — a page can retry in a loop. */
const inFlight = new Set<string>()

export function authPromptKey(request: AuthPromptRequest): string {
  return `${request.isProxy ? 'proxy' : 'site'}|${request.host}:${request.port}|${request.realm}`
}

/**
 * What the dialog says. Pure so the wording — especially the proxy case — is
 * pinned by a test rather than by whoever edits the file next.
 */
export function authPromptCopy(request: AuthPromptRequest): {
  message: string
  detail: string
} {
  const where = request.port === 0 ? request.host : `${request.host}:${request.port}`
  if (request.isProxy) {
    return {
      message: `프록시 서버 ${where} 이(가) 로그인을 요구합니다.`,
      detail:
        '학교나 회사 네트워크의 프록시입니다. 웹사이트가 아니라 네트워크에 로그인하는 것입니다.'
    }
  }
  return {
    message: `${where} 이(가) 로그인을 요구합니다.`,
    detail:
      request.realm === ''
        ? '이 사이트가 요구하는 인증입니다.'
        : `영역: ${request.realm}`
  }
}

export interface AuthPromptDeps {
  /** Injected so the prompt can be tested without Electron. */
  ask: (request: AuthPromptRequest) => Promise<AuthPromptResult | null>
}

/**
 * Electron's `login` event, as a plain async function.
 *
 * Returns the credentials to retry with, or null to let the request fail the
 * way it would in a browser where the student pressed 취소.
 */
export async function resolveAuthPrompt(
  request: AuthPromptRequest,
  deps: AuthPromptDeps
): Promise<AuthPromptResult | null> {
  const key = authPromptKey(request)
  if (inFlight.has(key)) return null
  inFlight.add(key)
  try {
    return await deps.ask(request)
  } finally {
    inFlight.delete(key)
  }
}

/**
 * The native dialog.
 *
 * `showMessageBox` has no text inputs, and building an in-app modal for this
 * would put a password field on a surface a page can imitate — so the flow is
 * two prompts drawn by us in a real window, which the page cannot reach.
 */
export async function askForCredentials(
  request: AuthPromptRequest
): Promise<AuthPromptResult | null> {
  const owner = BrowserWindow.getFocusedWindow()
  if (owner === null) return null
  const copy = authPromptCopy(request)
  const { response } = await dialog.showMessageBox(owner, {
    type: 'question',
    noLink: true,
    buttons: ['취소', '로그인'],
    defaultId: 1,
    cancelId: 0,
    message: copy.message,
    detail: `${copy.detail}\n\n계속하면 아이디와 비밀번호를 차례로 입력합니다.`
  })
  if (response !== 1) return null

  const username = await promptLine(owner, '아이디', copy.message, false)
  if (username === null) return null
  const password = await promptLine(owner, '비밀번호', copy.message, true)
  if (password === null) return null
  return { username, password }
}

/**
 * One line of text from a real window.
 *
 * Electron has no native text-input dialog, so this renders a tiny local
 * page in its own window: no preload, no node integration, its own in-memory
 * partition, and it can only ever reach `about:blank` plus the data URL we
 * hand it. The page a student is browsing cannot script or read it.
 */
async function promptLine(
  owner: BrowserWindow,
  label: string,
  title: string,
  masked: boolean
): Promise<string | null> {
  return new Promise((resolve) => {
    const win = new BrowserWindow({
      parent: owner,
      modal: true,
      show: false,
      width: 420,
      height: 190,
      resizable: false,
      minimizable: false,
      maximizable: false,
      title,
      webPreferences: {
        partition: 'auth-prompt',
        sandbox: true,
        contextIsolation: true,
        nodeIntegration: false,
        webSecurity: true,
        webviewTag: false,
        plugins: false
      }
    })

    let settled = false
    const finish = (value: string | null): void => {
      if (settled) return
      settled = true
      resolve(value)
      if (!win.isDestroyed()) win.close()
    }

    // The answer comes back as a navigation to a sentinel scheme the guard
    // below intercepts — no preload and no IPC channel are involved.
    win.webContents.on('will-navigate', (event, url) => {
      if (!url.startsWith('bandal-auth:')) {
        event.preventDefault()
        return
      }
      event.preventDefault()
      const raw = url.slice('bandal-auth:'.length)
      if (raw === 'cancel') {
        finish(null)
        return
      }
      try {
        finish(decodeURIComponent(raw))
      } catch {
        finish(null)
      }
    })
    win.once('closed', () => finish(null))
    win.once('ready-to-show', () => win.show())
    void win.loadURL(promptDataUrl(label, masked)).catch(() => finish(null))
  })
}

function promptDataUrl(label: string, masked: boolean): string {
  const html = `<!doctype html><meta charset="utf-8">
<style>
 body{font:13px -apple-system,BlinkMacSystemFont,'Apple SD Gothic Neo',sans-serif;
      margin:0;padding:20px;background:#f6f6f7;color:#1c1c1e;
      display:flex;flex-direction:column;gap:12px}
 label{font-weight:600}
 input{font:inherit;padding:8px 10px;border:1px solid #c8c8cc;border-radius:6px}
 .row{display:flex;gap:8px;justify-content:flex-end}
 button{font:inherit;padding:6px 14px;border-radius:6px;border:1px solid #c8c8cc;background:#fff}
 button.primary{background:#0a66ff;border-color:#0a66ff;color:#fff}
 @media (prefers-color-scheme:dark){
   body{background:#1c1c1e;color:#f2f2f7}
   input{background:#2c2c2e;border-color:#48484a;color:#f2f2f7}
   button{background:#2c2c2e;border-color:#48484a;color:#f2f2f7}
   button.primary{background:#0a66ff;border-color:#0a66ff}
 }
</style>
<label for="v">${label}</label>
<input id="v" type="${masked ? 'password' : 'text'}" autofocus>
<div class="row">
  <button id="c">취소</button>
  <button id="o" class="primary">확인</button>
</div>
<script>
 const input = document.getElementById('v');
 const send = () => { location.href = 'bandal-auth:' + encodeURIComponent(input.value); };
 document.getElementById('o').addEventListener('click', send);
 document.getElementById('c').addEventListener('click', () => { location.href = 'bandal-auth:cancel'; });
 input.addEventListener('keydown', (e) => {
   if (e.key === 'Enter' && !e.isComposing) send();
   if (e.key === 'Escape') location.href = 'bandal-auth:cancel';
 });
 input.focus();
</script>`
  return `data:text/html;charset=utf-8,${encodeURIComponent(html)}`
}
