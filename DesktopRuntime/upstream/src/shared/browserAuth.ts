/** Login state belongs to one browser profile; OAuth URLs cannot migrate it. */
function webUrl(value: string | undefined): URL | null {
  try {
    const url = new URL(value ?? '')
    return url.protocol === 'https:' || url.protocol === 'http:' ? url : null
  } catch { return null }
}

export function isEmbeddedAuthProviderUrl(value: string): boolean {
  const url = webUrl(value)
  return url?.protocol === 'https:' && ['accounts.google.com', 'accounts.youtube.com'].includes(url.hostname)
}

function serviceHome(url: URL): string | null {
  if (['chatgpt.com', 'chat.openai.com', 'auth.openai.com', 'auth0.openai.com'].includes(url.hostname)) return 'https://chatgpt.com/'
  if (['claude.ai', 'accounts.claude.ai'].includes(url.hostname)) return 'https://claude.ai/'
  if (url.hostname === 'gemini.google.com') return 'https://gemini.google.com/'
  return null
}

/** Recognise known service destinations without forwarding OAuth state/tokens. */
function linkedServiceHome(value: string, depth = 0): string | null {
  const url = webUrl(value)
  if (!url || depth > 4) return null
  const home = serviceHome(url)
  if (home) return home
  for (const key of ['continue', 'redirect_uri', 'redirect_url', 'return_to', 'returnTo']) {
    const target = url.searchParams.get(key)
    if (target) {
      const linked = linkedServiceHome(target, depth + 1)
      if (linked) return linked
    }
  }
  return null
}

export function isBrowserAuthFlowUrl(value: string): boolean {
  const url = webUrl(value)
  return isEmbeddedAuthProviderUrl(value) || !!url && ['auth.openai.com', 'auth0.openai.com', 'accounts.claude.ai'].includes(url.hostname)
}

/** Start a fresh login in the external browser, whose cookies are independent. */
export function externalAuthRestartUrl(authUrl: string, sourceUrl?: string): string {
  const destination = linkedServiceHome(authUrl)
  if (destination) return destination
  const source = webUrl(sourceUrl)
  if (source && !isBrowserAuthFlowUrl(source.href)) return serviceHome(source) ?? `${source.origin}/`
  const linked = source ? linkedServiceHome(source.href) : null
  return linked ?? 'https://accounts.google.com/'
}

/** Ordinary documents retain their URL; sign-in flows restart after switching. */
export function browserProfileStartUrl(currentUrl: string, fallbackUrl?: string): string {
  return isBrowserAuthFlowUrl(currentUrl) ? externalAuthRestartUrl(currentUrl, fallbackUrl) : currentUrl
}
