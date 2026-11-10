// What a school link may look like (for the AI routine and for user suggestions alike) and the
// server-side check that a URL answers.
export const KINDS = ['home', 'portal', 'lms', 'library', 'calendar', 'mail', 'registration', 'other'] as const
export type LinkKind = typeof KINDS[number]
export interface LinkInput { kind: LinkKind; title: string; url: string }

export interface Net {
  fetch: typeof fetch
  /** Every address (A and AAAA) the host name resolves to. */
  resolve(hostname: string): Promise<string[]>
}

const MAX_TITLE = 60
const MAX_URL = 500
const CHECK_TIMEOUT_MS = 5000
const USER_AGENT = 'Mozilla/5.0 (compatible; BandalLinkCheck/1.0)'

/** Text from outside (a student, the model): NFKC, single spaces, and nothing invisible. Control,
 *  format (zero-width, direction overrides) and unassigned characters refuse it. */
export function cleanText(value: unknown, max: number): string | null {
  if (typeof value !== 'string') return null
  const text = value.normalize('NFKC').replace(/\s+/g, ' ').trim()
  return text.length > 0 && text.length <= max && !/\p{C}/u.test(text) ? text : null
}

/** An https URL on a named host: no credentials, no port, no IP literal, no single-label name. */
function httpsURL(value: unknown): URL | null {
  if (typeof value !== 'string' || value.length > MAX_URL) return null
  let url: URL
  try { url = new URL(value.trim()) } catch { return null }
  const host = url.hostname
  if (url.protocol !== 'https:' || url.username || url.password || url.port) return null
  // The URL parser has already turned every spelling of an IPv4 address into dotted decimal.
  if (!host.includes('.') || host.endsWith('.') || host.startsWith('[') || /^[\d.]+$/.test(host)) return null
  return url.href.length <= MAX_URL ? url : null
}

export function parseLink(value: unknown): LinkInput | null {
  if (!value || typeof value !== 'object') return null
  const raw = value as Record<string, unknown>
  const kind = KINDS.find(k => k === raw.kind), title = cleanText(raw.title, MAX_TITLE), url = httpsURL(raw.url)
  return kind && title && url ? { kind, title, url: url.href } : null
}

// ponytail: not the public suffix list. Under an academic suffix (.edu, ac.kr, edu.au, hs.kr…)
// the school's domain is the label in front of it. Anywhere else only "www." is dropped, so such
// a school keeps its homepage but loses links on sister hosts (and a school on shared hosting
// cannot claim the whole platform). Bring in the real list if that costs real links.
const ACADEMIC_DOMAIN = /[^.]+\.(?:edu|(?:ac|edu|hs|ms|es|sc|kg|k12)\.[a-z]{2})$/

/** What a school's own sites share: snu.ac.kr for www.snu.ac.kr, and so also my.snu.ac.kr. */
export function officialDomain(host: string): string {
  return ACADEMIC_DOMAIN.exec(host)?.[0] ?? host.replace(/^www\./, '')
}

export function within(url: string, domain: string): boolean {
  const host = new URL(url).hostname
  return host === domain || host.endsWith(`.${domain}`)
}

/** Globally routable addresses only: loopback, private, link-local (cloud metadata), CGNAT,
 *  reserved and multicast ranges are refused, and so is every IPv6 address outside 2000::/3 or
 *  inside a prefix that wraps another address (6to4, Teredo, documentation). */
export function isPublicAddress(ip: string): boolean {
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip)
  if (v4) {
    const [a, b, c, d] = v4.slice(1).map(Number) as [number, number, number, number]
    if (a > 255 || b > 255 || c > 255 || d > 255) return false
    return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 192 && b === 0 && (c === 0 || c === 2))
      || (a === 198 && (b === 18 || b === 19)))
  }
  return /^[23][0-9a-f]{3}:/i.test(ip) && !/^(2002:|2001:(0{1,4})?:|2001:0?db8:)/i.test(ip)
}

/** A page that is there: 2xx/3xx, or a refusal only a real site gives a script — 401/403 (a sign-in
 *  page or a bot wall: www.berkeley.edu answers every non-browser with Cloudflare's 403 challenge)
 *  and 429. 404, 410 and 5xx are dead links. Behind such a wall a wrong path looks the same as a
 *  right one, which is why AI links stay unverified and the student confirms them. */
const answers = (status: number) => (status >= 200 && status < 400) || status === 401 || status === 403 || status === 429

/** Whether the URL answers: HEAD, then GET for servers that refuse HEAD. The model chose
 *  this URL, so it must not become a way to reach something internal: the host has to resolve to
 *  public addresses only, redirects are not followed and the body is never read.
 *  (A name that re-resolves differently for the request itself would still need a certificate
 *  for that name on the internal host, since only https is asked.) */
export async function reachable(url: string, net: Net): Promise<boolean> {
  const addresses = await net.resolve(new URL(url).hostname).catch(() => [])
  if (addresses.length === 0 || !addresses.every(isPublicAddress)) return false
  for (const method of ['HEAD', 'GET']) {
    try {
      const response = await net.fetch(url, {
        method, redirect: 'manual', signal: AbortSignal.timeout(CHECK_TIMEOUT_MS), headers: { 'user-agent': USER_AGENT, accept: 'text/html,*/*' },
      })
      await response.body?.cancel().catch(() => {})
      if (answers(response.status)) return true
    } catch { /* refused, reset or timed out: the other method may still answer */ }
  }
  return false
}
