/**
 * What never reaches the audit log.
 *
 * The audit exists so a student can see what the agent did, which means it is
 * durable and readable — exactly the wrong place for a password or a 주민등록번호.
 * The existing invariant (`shared/types/credentials.ts`) is that a secret never
 * crosses IPC, never enters a log line and never appears in an error; this
 * extends it to the agent's own record of its actions.
 *
 * Pure and tested, because "we redact" is worth nothing if it is a convention.
 */

/**
 * Long digit runs: 학번, 주민등록번호, 카드번호, 계좌번호.
 *
 * Separators (space, hyphen) are part of the run because that is how people
 * actually type these — a card number entered as `4111 1111 1111 1111` is
 * four short groups, and a digits-only rule would let it through whole.
 * The threshold is on the DIGIT COUNT, not the match length, so `3주차 2026`
 * stays readable.
 */
const DIGIT_RUN = /\d[\d\s-]*\d/g
const MIN_DIGITS = 6

const MASK = '██████'

function digitCount(value: string): number {
  let count = 0
  for (const char of value) if (char >= '0' && char <= '9') count += 1
  return count
}

function maskRuns(text: string): string {
  return text.replace(DIGIT_RUN, (run) =>
    digitCount(run) >= MIN_DIGITS ? MASK : run
  )
}

export interface RedactContext {
  /** Field the value was typed into, when known. */
  fieldType?: string
  /** Username saved for this origin, so it is not echoed back either. */
  knownUsername?: string | null
}

/**
 * Returns the value as it may be audited, or `null` when it may not be
 * audited at all.
 */
export function redactValue(
  value: string,
  context: RedactContext = {}
): string | null {
  // A password field's contents are never recorded, in any form. Not masked,
  // not length-hinted: absent.
  if (context.fieldType === 'password') return null
  if (typeof value !== 'string') return null

  const trimmed = value.trim()
  if (trimmed === '') return ''

  // The saved username identifies the student; the audit already names the
  // origin, so repeating it adds nothing and leaks a login id.
  const username = context.knownUsername?.trim()
  if (username !== undefined && username !== '' && trimmed === username) {
    return null
  }

  return maskRuns(trimmed)
}

/** Same rules, applied to a free-text line (a tool summary, a page title). */
export function redactText(text: string): string {
  if (typeof text !== 'string') return ''
  return maskRuns(text)
}

/**
 * A URL is audited without its query and fragment. Portal URLs routinely
 * carry a session key or a 학번 there, and the path alone already answers
 * "which page did it touch".
 */
export function redactUrl(url: string): string {
  try {
    const parsed = new URL(url)
    return `${parsed.origin}${parsed.pathname}`
  } catch {
    return ''
  }
}
