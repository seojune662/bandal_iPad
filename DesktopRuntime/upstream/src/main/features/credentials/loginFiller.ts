import { isManagedBrowserPage } from '../browser/managedPages'
import type { FillLoginResult } from '../../../shared/types/credentials'
import type { CredentialStore } from './credentialStore'
import { normalizeCredentialOrigin } from './credentialStore'
import { runGuestScript } from '../browserAgent/pageDriver'

export interface LoginFillRequest {
  origin: string
  guestWebContentsId: number
  credentialId?: string
  /** Main-only callers may promise to fill without submitting. */
  allowAutoSubmit?: boolean
}

export interface LoginGuestWebContents {
  getType(): string
  getURL(): string
  executeJavaScript(code: string, userGesture?: boolean): Promise<unknown>
  once?(event: 'destroyed', listener: () => void): this
}

export interface LoginFillerDeps {
  fromId(id: number): LoginGuestWebContents | null
}

function failed(): FillLoginResult {
  return { filled: false, submitted: false }
}

export function currentOrigin(guest: LoginGuestWebContents): string | null {
  try {
    return normalizeCredentialOrigin(guest.getURL())
  } catch {
    return null
  }
}

export function defaultFromId(id: number): LoginGuestWebContents | null {
  const electron = require('electron') as typeof import('electron')
  return electron.webContents.fromId(id) ?? null
}

/**
 * The guest must be a browser tab currently showing exactly `origin`, checked
 * here rather than taken from the renderer's word for it. HTTPS-only and the
 * canonical-origin rule both come from `normalizeCredentialOrigin`.
 */
export function resolveGuest(
  deps: LoginFillerDeps,
  request: { origin: string; guestWebContentsId: number }
): { guest: LoginGuestWebContents; origin: string } | null {
  let origin: string
  try {
    origin = normalizeCredentialOrigin(request.origin)
  } catch {
    return null
  }

  try {
    const guest = deps.fromId(request.guestWebContentsId)
    if (
      guest === null ||
      (guest.getType() !== 'webview' && !isManagedBrowserPage(request.guestWebContentsId)) ||
      currentOrigin(guest) !== origin
    ) {
      return null
    }
    return { guest, origin }
  } catch {
    return null
  }
}

function fillSource(
  origin: string,
  username: string,
  password: string,
  autoSubmit: boolean
): string {
  return `(() => {
    if (window.top !== window || location.origin !== ${JSON.stringify(origin)}) {
      return { filled: false, submitted: false };
    }
    const passwordInput = document.querySelector('input[type="password"]');
    const form = passwordInput instanceof HTMLInputElement ? passwordInput.form : null;
    if (!passwordInput || passwordInput.disabled || passwordInput.readOnly) {
      return { filled: false, submitted: false };
    }
    const candidates = Array.from(document.querySelectorAll(
      'input[type="text"], input[type="email"], input[type="tel"], input:not([type])'
    ));
    const usernameInput = candidates.filter((input) =>
      input instanceof HTMLInputElement &&
      !input.disabled &&
      !input.readOnly &&
      (input.compareDocumentPosition(passwordInput) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0
    ).at(-1);
    if (!(usernameInput instanceof HTMLInputElement)) {
      return { filled: false, submitted: false };
    }
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
    if (typeof setter !== 'function') return { filled: false, submitted: false };
    const setValue = (input, value) => {
      setter.call(input, value);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    };
    setValue(usernameInput, ${JSON.stringify(username)});
    setValue(passwordInput, ${JSON.stringify(password)});
    let submitted = false;
    if (${JSON.stringify(autoSubmit)} && form) {
      try {
        if (typeof form.requestSubmit === 'function') form.requestSubmit();
        else form.submit();
        submitted = true;
      } catch {}
    }
    return { filled: true, submitted };
  })()`
}

function parseResult(value: unknown): FillLoginResult {
  if (typeof value !== 'object' || value === null) return failed()
  const result = value as Record<string, unknown>
  if (
    typeof result['filled'] !== 'boolean' ||
    typeof result['submitted'] !== 'boolean'
  ) {
    return failed()
  }
  return {
    filled: result['filled'],
    submitted: result['filled'] && result['submitted']
  }
}

export function createLoginFiller(
  store: Pick<CredentialStore, 'resolve'>,
  deps?: LoginFillerDeps
): (request: LoginFillRequest) => Promise<FillLoginResult> {
  const resolved = deps ?? { fromId: defaultFromId }

  return async (request): Promise<FillLoginResult> => {
    const target = resolveGuest(resolved, request)
    if (target === null) return failed()
    const { guest } = target
    const requestedOrigin = target.origin

    let login: ReturnType<typeof store.resolve>
    try {
      login = store.resolve(requestedOrigin, request.credentialId)
    } catch {
      return failed()
    }
    if (login === null) return failed()

    // Re-check immediately before injection. Navigation can race every await
    // and the source itself repeats the origin/top-frame checks.
    if (currentOrigin(guest) !== requestedOrigin) return failed()
    const autoSubmit = request.allowAutoSubmit !== false && login.autoSubmit
    try {
      const result = await runGuestScript(() =>
        guest.executeJavaScript(
          fillSource(
            requestedOrigin,
            login.username,
            login.password,
            autoSubmit
          ),
          autoSubmit
        )
      )
      return parseResult(result)
    } catch {
      return failed()
    }
  }
}
