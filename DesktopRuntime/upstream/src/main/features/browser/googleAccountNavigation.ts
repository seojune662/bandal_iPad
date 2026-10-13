/**
 * Carry an explicit Google account index to an app-opened YouTube page. This is
 * only a navigation hint: Chromium and the sites continue to own all cookies.
 * Session identity keeps normal, private, and other browser profiles separate.
 */
const selectedAccounts = new WeakMap<object, string>()
const accountGenerations = new WeakMap<object, number>()
const siteNavigations = new WeakMap<object, { url: string; inheritedPopup: boolean }>()

const GOOGLE_SERVICES = new Set([
  'google.com', 'www.google.com', 'google.co.kr', 'www.google.co.kr',
  'mail.google.com', 'drive.google.com', 'docs.google.com',
  'calendar.google.com', 'photos.google.com', 'meet.google.com',
  'gemini.google.com', 'myaccount.google.com'
])
const YOUTUBE_PAGES = new Set(['youtube.com', 'www.youtube.com', 'm.youtube.com'])
const ACCOUNT_PROVIDERS = new Set(['accounts.google.com', 'accounts.youtube.com'])
const ACCOUNT_PARAMETERS = new Set([
  'authuser', 'pageid', 'channel', 'channel_id', 'channelid', 'account', 'account_id',
  'session_index', 'login_hint', 'identifier', 'continue', 'next', 'return_to',
  'redirect_uri', 'redirect_url', 'code', 'state', 'scope', 'response_type',
  'client_id', 'service', 'action_handle_signin', 'skip_identity_prompt',
  'signature', 'sig'
])

// Chromium filters these before entering JS. Never route YouTube API, player,
// script, or media endpoints through an account-navigation callback.
export const YOUTUBE_NAVIGATION_REQUEST_URLS = [...YOUTUBE_PAGES].flatMap(host =>
  ['/', '/?*', '/watch*', '/results*', '/playlist*', '/feed/*', '/shorts/*', '/live/*']
    .map(path => `https://${host}${path}`))

function trustedUrl(value: string): URL | null {
  try {
    const url = new URL(value)
    return url.protocol === 'https:' && !url.username && !url.password && !url.port
      ? url : null
  } catch { return null }
}

function accountAction(url: URL): boolean {
  return /(?:^|\/)(?:accounts?|signin|signout|logout|servicelogin|servicelogout|switch_service_login|channel_switcher|oauth2?)(?:\/|$)/i.test(url.pathname)
}

function viewingPage(url: URL): boolean {
  return YOUTUBE_PAGES.has(url.hostname) &&
    /^(?:\/|\/(?:watch|results|playlist)\/?|\/feed\/[a-z_]+\/?|\/shorts\/[a-zA-Z0-9_-]+\/?|\/live\/[a-zA-Z0-9_-]+\/?)$/.test(url.pathname)
}

function accountIndex(url: URL): string | null {
  // Ambiguous/identity-valued hints are left entirely to the site. Never infer
  // an account from an email, cookie, hidden page data, or an auth callback.
  const query = url.searchParams.getAll('authuser')
  const path = /(?:^|\/)u\/(0|[1-9]\d{0,2})(?:\/|$)/.exec(url.pathname)?.[1]
  if (query.length > 1) return null
  if (query.length === 1) {
    const index = query[0]!
    return /^(?:0|[1-9]\d{0,2})$/.test(index) && (path === undefined || path === index) ? index : null
  }
  return path ?? null
}

function hasAccountParameters(url: URL, includeIndex = true): boolean {
  return [...url.searchParams.keys()].some(key => {
    const name = key.toLowerCase()
    return (includeIndex || name !== 'authuser') &&
      (ACCOUNT_PARAMETERS.has(name) || name.startsWith('action_'))
  })
}

/** Also clear this when a browser session's cookies/storage are removed. */
export function forgetGoogleAccountNavigation(session: object): void {
  selectedAccounts.delete(session)
  accountGenerations.set(session, (accountGenerations.get(session) ?? 0) + 1)
}

/** Hidden main frames return a deferred token without choosing an account. */
export function rememberGoogleAccountNavigation(session: object, value: string, allowSelection = true): number | null {
  const url = trustedUrl(value)
  if (!url) return null
  if (ACCOUNT_PROVIDERS.has(url.hostname) ||
    ((GOOGLE_SERVICES.has(url.hostname) || YOUTUBE_PAGES.has(url.hostname)) &&
      (accountAction(url) || hasAccountParameters(url, false))) ||
    (YOUTUBE_PAGES.has(url.hostname) && url.searchParams.has('authuser'))) {
    forgetGoogleAccountNavigation(session)
    return null
  }
  // YouTube owns subsequent account/channel selection. In particular, our
  // own handed-off URL must not re-arm another automatic account handoff.
  if (!GOOGLE_SERVICES.has(url.hostname)) return null
  const index = accountIndex(url)
  if (index !== null) {
    if (allowSelection) {
      forgetGoogleAccountNavigation(session)
      selectedAccounts.set(session, index)
    }
    return accountGenerations.get(session) ?? 0
  } else if (url.searchParams.has('authuser') || /(?:^|\/)u\/[^/]+(?:\/|$)/.test(url.pathname)) forgetGoogleAccountNavigation(session)
  return null
}

/** A logout, storage clear, handoff, or newer visible selection cancels it. */
export function applyDeferredGoogleAccountNavigation(session: object, value: string, generation: number): void {
  if ((accountGenerations.get(session) ?? 0) === generation) rememberGoogleAccountNavigation(session, value)
}

/**
 * Mark an original site navigation, not a redirect/reload/history replay.
 * The caller uses will-navigate or an adopted popup's original destination.
 */
export function prepareGoogleAccountSiteNavigation(page: object, source: string, destination: string, inheritedPopup = false): void {
  const pending = siteNavigations.get(page)
  const from = trustedUrl(source), target = trustedUrl(destination)
  siteNavigations.delete(page)
  // Chromium emits the adopted child's own initial navigation after its
  // opener has supplied the marker. Its blank document is not a new source.
  if (!inheritedPopup && (source === '' || source === 'about:blank') &&
    pending?.inheritedPopup && target?.href === pending.url) {
    siteNavigations.set(page, { ...pending, inheritedPopup: false })
    return
  }
  if (!from || !target || !GOOGLE_SERVICES.has(from.hostname) ||
    accountAction(from) || hasAccountParameters(from, false) || !viewingPage(target)) return
  siteNavigations.set(page, { url: target.href, inheritedPopup })
}

/** Only a marked original GET may receive a single native request redirect. */
export function googleAccountRequestUrl(session: object, page: object | undefined, request: {
  url: string; method: string; resourceType: string
}): string {
  if (!page || request.resourceType !== 'mainFrame') return request.url
  const target = siteNavigations.get(page)?.url
  siteNavigations.delete(page)
  if (request.method !== 'GET' || target === undefined) return request.url
  const requested = trustedUrl(request.url), marked = trustedUrl(target)
  if (!requested || !marked) return request.url
  // Fragments are navigation state, not part of an HTTP request. Match the
  // network address while retaining the link's original fragment in a handoff.
  requested.hash = ''; marked.hash = ''
  if (requested.href !== marked.href) return request.url
  const resolved = googleAccountNavigationUrl(session, target)
  return resolved === target ? request.url : resolved
}

/**
 * Resolve only an app-requested loadURL before its first request. Never call
 * this from redirects, reload, or history. A native request must first pass
 * the original-navigation marker above; YouTube canonicalization cannot loop.
 */
export function googleAccountNavigationUrl(session: object, value: string): string {
  const url = trustedUrl(value)
  if (!url || !YOUTUBE_PAGES.has(url.hostname)) return value
  if (accountAction(url) || hasAccountParameters(url)) {
    // Explicit destination intent supersedes a previous Google selection,
    // including nonnumeric hints we deliberately do not interpret.
    forgetGoogleAccountNavigation(session)
    return value
  }
  const index = selectedAccounts.get(session)
  if (index === undefined || !viewingPage(url)) return value
  forgetGoogleAccountNavigation(session)
  url.searchParams.set('authuser', index)
  return url.href
}
