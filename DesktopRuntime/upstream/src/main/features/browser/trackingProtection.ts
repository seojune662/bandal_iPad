import type { TrackingProtection } from '../../../shared/types/settings'

const BALANCED_TRACKERS = [
  'doubleclick.net',
  'google-analytics.com',
  'googlesyndication.com',
  'googletagmanager.com',
  'facebook.net',
  'hotjar.com',
  'clarity.ms',
  'segment.io'
] as const

const STRICT_EXTRA_TRACKERS = [
  'adnxs.com',
  'adsrvr.org',
  'criteo.com',
  'criteo.net',
  'mixpanel.com',
  'amplitude.com',
  'taboola.com',
  'outbrain.com',
  'scorecardresearch.com'
] as const

const ALL_TRACKERS = [...BALANCED_TRACKERS, ...STRICT_EXTRA_TRACKERS]

/**
 * Let Chromium skip the main-process callback for ordinary page/API/media
 * requests. Include every protection level so settings still take effect
 * immediately, and terminal-dot aliases accepted by the hostname policy.
 */
export const TRACKING_REQUEST_URLS = ALL_TRACKERS.flatMap(domain => [
  `*://*.${domain}/*`,
  `*://*.${domain}./*`
])

function hostname(value: string): string | null {
  try {
    const parsed = new URL(value)
    return parsed.protocol === 'http:' || parsed.protocol === 'https:'
      ? parsed.hostname.toLowerCase().replace(/\.$/, '')
      : null
  } catch {
    return null
  }
}

function matchesDomain(host: string, domain: string): boolean {
  return host === domain || host.endsWith(`.${domain}`)
}

function isSameSite(first: string, third: string): boolean {
  return first === third || first.endsWith(`.${third}`) || third.endsWith(`.${first}`)
}

export interface TrackingRequest {
  url: string
  referrer: string
  resourceType: string
}

/** A conservative, deterministic blocker for known third-party endpoints. */
export function shouldBlockTrackingRequest(
  request: TrackingRequest,
  protection: TrackingProtection
): boolean {
  if (protection === 'off' || request.resourceType === 'mainFrame') return false
  const target = hostname(request.url)
  const source = hostname(request.referrer)
  if (target === null || source === null || isSameSite(source, target)) return false
  const domains = protection === 'strict'
    ? ALL_TRACKERS
    : BALANCED_TRACKERS
  return domains.some((domain) => matchesDomain(target, domain))
}

export function privacyRequestHeaders(
  headers: Record<string, string>,
  enabled: boolean
): Record<string, string> {
  if (!enabled) return headers
  return { ...headers, DNT: '1', 'Sec-GPC': '1' }
}
