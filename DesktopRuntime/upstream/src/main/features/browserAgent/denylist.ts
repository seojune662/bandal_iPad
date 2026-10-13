/**
 * Origins the agent may never touch — not even read.
 *
 * These are not "risky pages" but pages where a single wrong action costs the
 * student something they cannot undo:
 *
 *  - 수강신청 (course registration). One misclick costs a semester, seats are
 *    zero-sum against other students, and universities treat automation here
 *    as abuse. Refusing outright is the only defensible position.
 *  - Payment gateways. Nothing an agent does on a PG page can be worth it.
 *  - Google/YouTube auth, which is already handed to the system browser
 *    (webviewPolicy.isBlockedEmbeddedAuthUrl) — listed again so the agent
 *    path fails for its own reason rather than by accident.
 *
 * Matched on host SUFFIX, so a subdomain cannot slip past, and never on a
 * substring — `sugang.example.com` must not be caught by a `sugang` rule
 * while `notsugang.ac.kr` must not be caught either.
 */

/** Host labels that identify a registration system across schools. */
const REGISTRATION_LABELS = ['sugang', 'sugang1', 'sugang2', 'enroll', 'susi']

const DENIED_HOST_SUFFIXES = [
  // Payment gateways used by Korean universities.
  'inicis.com',
  'kcp.co.kr',
  'nicepay.co.kr',
  'tosspayments.com',
  'kakaopay.com',
  'settlebank.co.kr',
  // Already externalised, but the agent must refuse it explicitly.
  'accounts.google.com',
  'accounts.youtube.com'
]

export interface DenyReason {
  reason: 'registration' | 'payment' | 'external-auth'
  /** One line the tool hands back for the agent to relay to the student. */
  message: string
}

/** `null` = allowed. */
export function denyReasonFor(url: string): DenyReason | null {
  let host: string
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return {
        reason: 'external-auth',
        message: '웹 페이지가 아닌 주소는 열 수 없습니다.'
      }
    }
    host = parsed.hostname.toLowerCase()
  } catch {
    return {
      reason: 'external-auth',
      message: '주소를 이해하지 못했습니다.'
    }
  }

  const labels = host.split('.')
  if (labels.some((label) => REGISTRATION_LABELS.includes(label))) {
    return {
      reason: 'registration',
      message:
        '수강신청 사이트는 반달이 대신 열지 않습니다. 직접 진행해 주세요.'
    }
  }

  for (const suffix of DENIED_HOST_SUFFIXES) {
    if (host === suffix || host.endsWith(`.${suffix}`)) {
      return suffix.includes('google') || suffix.includes('youtube')
        ? {
            reason: 'external-auth',
            message: '이 로그인은 기본 브라우저에서 직접 해주세요.'
          }
        : {
            reason: 'payment',
            message: '결제 페이지는 반달이 대신 열지 않습니다.'
          }
    }
  }

  return null
}
