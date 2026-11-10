// referral: 친구 초대. Each side gets AI credit once the invitee has signed in and made a first course.
//   GET  /check?code=    no sign-in; {valid}: whether the code exists, and nothing else about it
//   POST /claim  {code}  signed in; {status: "claimed"}, also when the same code is entered again
//   POST /complete       signed in, no body; the app calls it once the first course is made:
//                        {status: "rewarded", creditMicrocents, referrerRewarded} | {status: "none"} | {status: "already"}
//   GET  /status         signed in; {code, completed, limit, creditMicrocents, claim: {code, completed} | null}
// Errors are {code, …}: SIGN_IN_REQUIRED 401, INVALID_REQUEST 400, INVALID_CODE 404, OWN_CODE 409, ALREADY_CLAIMED 409,
// NOT_FOUND 404, METHOD_NOT_ALLOWED 405, REFERRAL_UNAVAILABLE 503.
// The rules and the amounts are in the database (202611110001_referral.sql); nothing is decided or paid here.
import { ProxyError } from '../ai/request.ts'

export interface Status {
  /** The caller's own code. */
  code: string
  /** How many of the caller's invitees completed; the caller is paid for the first `limit`. */
  completed: number; limit: number
  /** Referral credit received as inviter and as invitee, in µ¢. */
  creditMicrocents: number
  /** The code the caller entered as an invitee. */
  claim: { code: string; completed: boolean } | null
}
export type Completion = { status: 'rewarded'; creditMicrocents: number; referrerRewarded: boolean } | { status: 'none' | 'already' }
export type Claimed = 'claimed' | 'invalid_code' | 'own_code' | 'already_claimed'

export interface Store {
  check(code: string): Promise<boolean>
  claim(actor: string, code: string): Promise<{ status: Claimed }>
  /** Pays both sides when the caller has an open claim. */
  complete(actor: string): Promise<Completion>
  /** Makes the caller's code the first time. */
  status(actor: string): Promise<Status>
}

export interface Deps {
  store: Store
  authenticate(token: string): Promise<string | null>
  log?(message: string, detail: unknown): void
}

const HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
const MAX_BODY = 1024
/** Six characters without 0/O and 1/I/L, in either case: the alphabet of referral_new_code() and the tables' checks. */
const CODE = /^[A-HJKMNP-Z2-9]{6}$/i
const ROUTES = new Map([['/check', 'GET'], ['/claim', 'POST'], ['/complete', 'POST'], ['/status', 'GET']])
const REFUSED = { invalid_code: ['INVALID_CODE', 404], own_code: ['OWN_CODE', 409], already_claimed: ['ALREADY_CLAIMED', 409] } as const

/** What was typed as the code it means, or null when no code looks like that. */
function codeOf(typed: string): string | null {
  // Matched before upper-casing: "ß" and "ſ" only become letters of the alphabet by being upper-cased.
  const code = typed.trim()
  return CODE.test(code) ? code.toUpperCase() : null
}

export function createReferral(deps: Deps): (request: Request) => Promise<Response> {
  const json = (value: unknown, status = 200, headers: Record<string, string> = {}) => Response.json(value, { status, headers: { ...HEADERS, ...headers } })

  async function actorOf(request: Request): Promise<string> {
    const header = request.headers.get('authorization') ?? ''
    const actor = header.startsWith('Bearer ') ? await deps.authenticate(header.slice(7)) : null
    if (!actor) throw new ProxyError('SIGN_IN_REQUIRED', 401)
    return actor
  }

  async function bodyOf(request: Request): Promise<Record<string, unknown>> {
    const text = await request.text()
    if (text.length > MAX_BODY) throw new ProxyError('INVALID_REQUEST', 400)
    try {
      const value = JSON.parse(text)
      if (value && typeof value === 'object' && !Array.isArray(value)) return value
    } catch { /* fall through */ }
    throw new ProxyError('INVALID_REQUEST', 400)
  }

  async function check(params: URLSearchParams) {
    const code = codeOf(params.get('code') ?? '')
    return { valid: code !== null && await deps.store.check(code) }
  }

  async function claim(actor: string, input: Record<string, unknown>) {
    if (typeof input.code !== 'string') throw new ProxyError('INVALID_REQUEST', 400, { field: 'code' })
    const code = codeOf(input.code)
    const status = code ? (await deps.store.claim(actor, code)).status : 'invalid_code'
    if (status === 'claimed') return { status }
    const [refusal, httpStatus] = REFUSED[status]
    throw new ProxyError(refusal, httpStatus)
  }

  return async (request: Request): Promise<Response> => {
    try {
      const url = new URL(request.url)
      const path = url.pathname.replace(/^.*\/referral/, '') || '/'
      const method = ROUTES.get(path)
      if (!method) throw new ProxyError('NOT_FOUND', 404)
      if (request.method !== method) return json({ code: 'METHOD_NOT_ALLOWED' }, 405, { Allow: method })
      if (path === '/check') return json(await check(url.searchParams))
      const actor = await actorOf(request)
      if (path === '/claim') return json(await claim(actor, await bodyOf(request)))
      if (path === '/complete') return json(await deps.store.complete(actor))
      return json(await deps.store.status(actor))
    } catch (error) {
      if (error instanceof ProxyError) return json({ code: error.code, ...error.extra }, error.status)
      deps.log?.('referral failed', { error: String(error) })
      return json({ code: 'REFERRAL_UNAVAILABLE' }, 503)
    }
  }
}
