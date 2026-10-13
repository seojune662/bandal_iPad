/**
 * Every check a URL must pass before the agent may put a guest on it.
 *
 * ## Why this file exists at all
 *
 * `webContents.loadURL()` does NOT emit `will-navigate`. Electron only emits
 * it for user- or page-initiated navigation. So `hardenWebviews.ts`'s guard —
 * the one thing standing between a guest and a non-http scheme — is bypassed
 * by any host-initiated navigation, which is exactly what an agent navigate
 * tool is. Nothing calls `loadURL` from main today, so this is not currently
 * exploitable; it would become so with the first line of the first browser
 * tool anyone wrote.
 *
 * Therefore: the agent path re-applies the mode's own policy itself, rather
 * than trusting a guard that will not run. `webviewPolicy` stays the single
 * source of truth for what a guest may load; this only re-invokes it.
 */

import {
  isBlockedEmbeddedAuthUrl,
  isNavigationAllowed
} from '../browser/webviewPolicy'
import { denyReasonFor } from './denylist'
import { capabilitySatisfies, type BrowserCapability } from './grants'

export type NavigationVerdict =
  | { allowed: true; url: string }
  | { allowed: false; reason: NavigationDenial; message: string }

export type NavigationDenial =
  | 'malformed'
  | 'scheme'
  | 'external-auth'
  | 'registration'
  | 'payment'
  | 'no-grant'

export interface NavigationCheckInput {
  url: string
  /** Capability the caller needs on the target origin. */
  capability: BrowserCapability
  /** What the student has already allowed for this origin, if anything. */
  heldCapability: BrowserCapability | null
}

/**
 * Pure. Ordered so the most categorical refusal wins: a 수강신청 page is
 * refused even when the student granted the origin, because the grant was
 * never the thing standing in the way.
 */
export function checkNavigation(
  input: NavigationCheckInput
): NavigationVerdict {
  const raw = typeof input.url === 'string' ? input.url.trim() : ''
  if (raw === '') {
    return { allowed: false, reason: 'malformed', message: '주소가 비어 있습니다.' }
  }

  // 1. The same scheme guard `will-navigate` would have applied.
  if (!isNavigationAllowed(raw)) {
    return {
      allowed: false,
      reason: 'scheme',
      message: '웹 페이지가 아닌 주소는 열 수 없습니다.'
    }
  }

  // 2. Embedded auth is handed to the system browser, never loaded in-guest.
  if (isBlockedEmbeddedAuthUrl(raw)) {
    return {
      allowed: false,
      reason: 'external-auth',
      message: '이 로그인은 기본 브라우저에서 직접 해주세요.'
    }
  }

  // 3. Origins no grant can unlock.
  const denied = denyReasonFor(raw)
  if (denied !== null) {
    return { allowed: false, reason: denied.reason, message: denied.message }
  }

  // 4. Finally, the student's own decision.
  if (
    input.heldCapability === null ||
    !capabilitySatisfies(input.heldCapability, input.capability)
  ) {
    return {
      allowed: false,
      reason: 'no-grant',
      message: '이 사이트에 대한 접근 권한이 없습니다.'
    }
  }

  return { allowed: true, url: raw }
}
