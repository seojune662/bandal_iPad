import { assertEquals } from '@std/assert'
import { createReferral, type Claimed, type Completion, type Status, type Store } from './service.ts'

const ACTOR = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
const STATUS: Status = { code: 'ABC234', completed: 3, limit: 5, creditMicrocents: 21_000_000, claim: { code: 'XYZ789', completed: false } }
const REWARDED: Completion = { status: 'rewarded', creditMicrocents: 7_000_000, referrerRewarded: true }

interface Options { exists?: boolean; claimed?: Claimed; completion?: Completion; status?: Status }
function harness(options: Options = {}) {
  const calls: unknown[][] = []
  const logged: unknown[][] = []
  const store: Store = {
    check: code => { calls.push(['check', code]); return Promise.resolve(options.exists ?? true) },
    claim: (actor, code) => { calls.push(['claim', actor, code]); return Promise.resolve({ status: options.claimed ?? 'claimed' }) },
    complete: actor => { calls.push(['complete', actor]); return Promise.resolve(options.completion ?? REWARDED) },
    status: actor => { calls.push(['status', actor]); return Promise.resolve(options.status ?? STATUS) },
  }
  const handle = createReferral({
    store,
    authenticate: token => Promise.resolve(token === 'good' ? ACTOR : null),
    log: (message, detail) => { logged.push([message, detail]) },
  })
  return { handle, calls, logged }
}

interface Call { method?: string; body?: unknown; token?: string | null; authorization?: string }
function call(handle: (r: Request) => Promise<Response>, path: string, options: Call = {}) {
  const { body, token = 'good' } = options
  const authorization = options.authorization ?? (token ? `Bearer ${token}` : null)
  return handle(new Request(`https://x.supabase.co/functions/v1/referral${path}`, {
    method: options.method ?? (body === undefined ? 'GET' : 'POST'),
    headers: authorization ? { authorization } : {},
    body: body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
  }))
}
const answer = async (response: Response) => [response.status, await response.json()]

Deno.test('check needs no sign-in, trims and upper-cases the code and says only whether it exists', async () => {
  const { handle, calls } = harness()
  const response = await call(handle, `/check?code=${encodeURIComponent('  abc234 ')}`, { token: null })
  assertEquals(await answer(response), [200, { valid: true }])
  assertEquals(response.headers.get('cache-control'), 'no-store')
  assertEquals(calls, [['check', 'ABC234']])
  assertEquals(await answer(await call(harness({ exists: false }).handle, '/check?code=ABC234', { token: null })), [200, { valid: false }])
})

Deno.test('check: anything that is not six characters of the alphabet is invalid without a lookup', async () => {
  const { handle, calls } = harness()
  for (const query of ['', '?code=', '?code=ABC23', '?code=ABC2345', '?code=ABC%20234', '?code=ABC-234', '?code=ABC23%00', '?other=ABC234',
    ...'01OILoil'.split('').map(c => `?code=ABC23${c}`), `?code=${encodeURIComponent('가나다라마바')}`, `?code=${encodeURIComponent('ＡＢＣ２３４')}`,
    // Characters that upper-case into the alphabet (ß → SS, ſ → S) or fold onto it (the Kelvin sign) are not in it.
    `?code=${encodeURIComponent('abcdß')}`, `?code=${encodeURIComponent('ſbcde2')}`, `?code=${encodeURIComponent('abc23\u212A')}`]) {
    assertEquals(await answer(await call(handle, `/check${query}`, { token: null })), [200, { valid: false }], query)
  }
  assertEquals(calls, [])
  // Every character of the alphabet is accepted, in either case.
  for (let at = 0; at < ALPHABET.length; at += 6) {
    const code = (ALPHABET + ALPHABET).slice(at, at + 6)
    assertEquals(await answer(await call(handle, `/check?code=${code.toLowerCase()}`, { token: null })), [200, { valid: true }])
    assertEquals(calls.at(-1), ['check', code])
  }
  assertEquals(new Set(calls.map(c => String(c[1])).join('')), new Set(ALPHABET))
})

Deno.test('claim, complete and status require a signed-in user', async () => {
  const { handle, calls } = harness()
  for (const auth of [{ token: null }, { token: 'bad' }, { authorization: 'good' }, { authorization: 'Basic good' }]) {
    // The body is not looked at first: a malformed one is still 401.
    for (const [path, body] of [['/claim', { code: 'ABC234' }], ['/claim', 'not json'], ['/complete', {}], ['/status', undefined]] as const) {
      assertEquals(await answer(await call(handle, path, { ...auth, body })), [401, { code: 'SIGN_IN_REQUIRED' }])
    }
  }
  assertEquals(calls, [])
})

Deno.test('claim enters the normalized code for the caller; the same answer whenever the database says claimed', async () => {
  const { handle, calls } = harness()
  assertEquals(await answer(await call(handle, '/claim', { body: { code: ' xyz789\n' } })), [200, { status: 'claimed' }])
  assertEquals(await answer(await call(handle, '/claim', { body: { code: 'XYZ789', extra: true } })), [200, { status: 'claimed' }])
  assertEquals(calls, [['claim', ACTOR, 'XYZ789'], ['claim', ACTOR, 'XYZ789']])
})

Deno.test('claim: an unknown code is 404, the caller\'s own code and a second code are 409', async () => {
  const refusals: [Claimed, number, string][] = [['invalid_code', 404, 'INVALID_CODE'], ['own_code', 409, 'OWN_CODE'], ['already_claimed', 409, 'ALREADY_CLAIMED']]
  for (const [claimed, status, code] of refusals) {
    assertEquals(await answer(await call(harness({ claimed }).handle, '/claim', { body: { code: 'XYZ789' } })), [status, { code }])
  }
})

Deno.test('claim: a code that cannot exist is 404 without a lookup, a malformed body is 400', async () => {
  const { handle, calls } = harness()
  for (const code of ['', 'XYZ78', 'XYZ7890', 'XYZ780', 'XYZ 789', '가나다라마바']) {
    assertEquals(await answer(await call(handle, '/claim', { body: { code } })), [404, { code: 'INVALID_CODE' }], code)
  }
  // A body may be 1,024 characters and no more.
  const sized = (length: number) => JSON.stringify({ code: 'XYZ789', pad: 'x'.repeat(length - JSON.stringify({ code: 'XYZ789', pad: '' }).length) })
  for (const body of [{}, { code: 7 }, { code: null }, { code: ['XYZ789'] }, { Code: 'XYZ789' }, ['XYZ789'], 'XYZ789', '', '{"code":"XYZ789"', 'null', sized(1025)]) {
    const response = await call(handle, '/claim', { method: 'POST', body })
    assertEquals(response.status, 400, JSON.stringify(body).slice(0, 40))
    assertEquals((await response.json()).code, 'INVALID_REQUEST')
    assertEquals(response.headers.get('cache-control'), 'no-store')
  }
  assertEquals(calls, [])
  assertEquals(await answer(await call(handle, '/claim', { body: sized(1024) })), [200, { status: 'claimed' }])
})

Deno.test('complete takes no body and returns what the database decided', async () => {
  for (const completion of [REWARDED, { status: 'rewarded', creditMicrocents: 7_000_000, referrerRewarded: false }, { status: 'none' }, { status: 'already' }] as Completion[]) {
    const { handle, calls } = harness({ completion })
    assertEquals(await answer(await call(handle, '/complete', { method: 'POST' })), [200, completion])
    assertEquals(await answer(await call(handle, '/complete', { body: 'not json, never read' })), [200, completion])
    assertEquals(calls, [['complete', ACTOR], ['complete', ACTOR]])
  }
})

Deno.test('status returns the caller\'s code, numbers and claim', async () => {
  const { handle, calls } = harness()
  const response = await call(handle, '/status')
  assertEquals(response.headers.get('cache-control'), 'no-store')
  assertEquals(await answer(response), [200, STATUS])
  assertEquals(calls, [['status', ACTOR]])
  const fresh: Status = { code: 'ABC234', completed: 0, limit: 5, creditMicrocents: 0, claim: null }
  assertEquals(await answer(await call(harness({ status: fresh }).handle, '/status')), [200, fresh])
})

Deno.test('unknown routes are 404 and a known route with another method is 405, before any sign-in check', async () => {
  const { handle, calls } = harness()
  for (const path of ['', '/', '/check/', '/claims', '/referral', '/status/ABC234', 'check', '/constructor']) {
    for (const method of ['GET', 'POST']) {
      assertEquals(await answer(await call(handle, path, { method, token: null })), [404, { code: 'NOT_FOUND' }], `${method} ${path}`)
    }
  }
  for (const [path, allowed, refused] of [['/check?code=ABC234', 'GET', ['POST', 'PUT', 'DELETE']], ['/claim', 'POST', ['GET', 'PUT', 'PATCH']],
    ['/complete', 'POST', ['GET', 'DELETE']], ['/status', 'GET', ['POST', 'PUT']]] as const) {
    for (const method of refused) {
      const response = await call(handle, path, { method, token: null })
      assertEquals(await answer(response), [405, { code: 'METHOD_NOT_ALLOWED' }], `${method} ${path}`)
      assertEquals(response.headers.get('allow'), allowed)
    }
  }
  assertEquals(calls, [])
})

Deno.test('a failing database is 503 and logged, whatever the route', async () => {
  const logged: unknown[][] = []
  const failing = () => Promise.reject(new Error('referral_status: connection refused'))
  const handle = createReferral({
    store: { check: failing, claim: failing, complete: failing, status: failing },
    authenticate: () => Promise.resolve(ACTOR),
    log: (message, detail) => { logged.push([message, detail]) },
  })
  for (const [path, body] of [['/check?code=ABC234', undefined], ['/claim', { code: 'ABC234' }], ['/complete', {}], ['/status', undefined]] as const) {
    assertEquals(await answer(await call(handle, path, { body })), [503, { code: 'REFERRAL_UNAVAILABLE' }])
  }
  assertEquals(logged.length, 4)
  assertEquals(logged[0], ['referral failed', { error: 'Error: referral_status: connection refused' }])
})
