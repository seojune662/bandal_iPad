// schools: the school catalogue behind "set up my school".
//   GET  /search?q=&country=                 no sign-in (first-run onboarding); {schools: [School]}
//   POST /setup    {query, country, locale}  signed in; {status: cached | found, school} or {status: not_found}
//   POST /suggest  {schoolId, links}         signed in; kept for review, the school is never changed
// Errors are {code, …}: SIGN_IN_REQUIRED 401, INVALID_REQUEST 400, NOT_FOUND 404, RATE_LIMITED 429 {limit}, AI_UNAVAILABLE 503.
import { ProxyError, type ModelRow } from '../ai/request.ts'
import { cleanText, parseLink, type LinkInput, type LinkKind } from './links.ts'
import { setupSchool, type Found, type Outcome } from './routine.ts'

export interface SchoolLink { id: string; kind: LinkKind; title: string; url: string; verified: boolean; order: number }
export interface School {
  id: string; name: string; nameEn: string | null; aliases: string[]; country: string; domain: string | null
  verified: boolean; source: 'bundled' | 'ai' | 'user'; links: SchoolLink[]
}
export type Begun =
  | { status: 'cached'; school: School }
  | { status: 'invalid' }
  | { status: 'limited'; limit: number }
  /** Every account together has used up the day's runs. */
  | { status: 'unavailable' }
  | { status: 'run'; run: string }

export interface Store {
  search(query: string, country: string | null): Promise<School[]>
  /** The Auto model (ai_settings.auto_model) with its prices; null when it is not listed. */
  model(): Promise<ModelRow | null>
  /** The known school for this query, or a newly opened run when today's limit allows one. */
  begin(actor: string, query: string, country: string): Promise<Begun>
  /** Closes the run with its cost; for a found school, stores it and returns it (or the one already there). */
  finish(actor: string, run: string, outcome: Outcome['outcome'], costUcents: number, school: Found | null): Promise<School | null>
  suggest(actor: string, schoolId: string, links: LinkInput[]): Promise<{ status: 'recorded' | 'not_found' } | { status: 'limited'; limit: number }>
}

export interface Deps {
  store: Store
  authenticate(token: string): Promise<string | null>
  /** Reaches the Anthropic API and the school sites being checked. */
  fetch: typeof fetch
  resolve(hostname: string): Promise<string[]>
  anthropic: { key?: string; baseURL: string }
  log?(message: string, detail: unknown): void
}

const HEADERS = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' }
const MAX_QUERY = 80
const MAX_BODY = 64 * 1024
const MAX_SUGGESTED_LINKS = 20
const MAX_ID = 64
const DEFAULT_LOCALE = 'ko'
const COUNTRY = /^[A-Za-z]{2}$/
const LOCALE = /^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8}){0,3}$/

const invalid = (field: string) => new ProxyError('INVALID_REQUEST', 400, { field })
const matching = (value: unknown, pattern: RegExp) => typeof value === 'string' && pattern.test(value) ? value : null

export function createSchools(deps: Deps): (request: Request) => Promise<Response> {
  const json = (value: unknown, status = 200) => Response.json(value, { status, headers: HEADERS })

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

  async function search(params: URLSearchParams) {
    const q = params.get('q') ?? '', country = params.get('country')
    if (country && !COUNTRY.test(country)) throw invalid('country')
    if (!q.trim()) return { schools: [] }
    const query = cleanText(q, MAX_QUERY)
    if (!query) throw invalid('q')
    return { schools: await deps.store.search(query, country ? country.toUpperCase() : null) }
  }

  async function setup(actor: string, input: Record<string, unknown>) {
    const query = cleanText(input.query, MAX_QUERY)
    if (!query) throw invalid('query')
    const country = matching(input.country, COUNTRY)?.toUpperCase()
    if (!country) throw invalid('country')
    const locale = input.locale === undefined ? DEFAULT_LOCALE : matching(input.locale, LOCALE)
    if (!locale) throw invalid('locale')

    const begun = await deps.store.begin(actor, query, country)
    if (begun.status === 'cached') return { status: 'cached', school: begun.school }
    if (begun.status === 'invalid') throw invalid('query')
    if (begun.status === 'limited') throw new ProxyError('RATE_LIMITED', 429, { limit: begun.limit })
    if (begun.status === 'unavailable') throw new ProxyError('AI_UNAVAILABLE', 503)

    // No model row (or no way to read it) ends the run as unavailable inside the routine.
    const model = await deps.store.model().catch(error => {
      deps.log?.('school setup model unreadable', { error: String(error) })
      return null
    })
    const result = await setupSchool({ fetch: deps.fetch, resolve: deps.resolve, key: deps.anthropic.key, baseURL: deps.anthropic.baseURL, log: deps.log }, model, { query, country, locale })
      .catch((error): Outcome => {
        deps.log?.('school setup failed', { run: begun.run, error: String(error) })
        return { outcome: 'failed', costUcents: 0 }
      })
    // ponytail: one attempt. If this write fails the run stays 'running' (it still counts for
    // today) and its cost is only in this log line; retry like the proxy's settle if that shows up.
    const school = await deps.store.finish(actor, begun.run, result.outcome, result.costUcents, result.outcome === 'found' ? result.school : null).catch(error => {
      deps.log?.('school setup not recorded', { run: begun.run, outcome: result.outcome, costUcents: result.costUcents, error: String(error) })
      throw error
    })
    if (result.outcome === 'found' && school) return { status: 'found', school }
    if (result.outcome === 'not_found') return { status: 'not_found' }
    throw new ProxyError('AI_UNAVAILABLE', 503)
  }

  async function suggest(actor: string, input: Record<string, unknown>) {
    const schoolId = input.schoolId
    if (typeof schoolId !== 'string' || schoolId.length < 1 || schoolId.length > MAX_ID) throw invalid('schoolId')
    if (!Array.isArray(input.links) || input.links.length < 1 || input.links.length > MAX_SUGGESTED_LINKS) throw invalid('links')
    const links = input.links.flatMap(link => parseLink(link) ?? [])
    if (links.length !== input.links.length) throw invalid('links')
    const result = await deps.store.suggest(actor, schoolId, links)
    if (result.status === 'not_found') throw new ProxyError('NOT_FOUND', 404)
    if (result.status === 'limited') throw new ProxyError('RATE_LIMITED', 429, { limit: result.limit })
    return { status: 'recorded' }
  }

  return async (request: Request): Promise<Response> => {
    try {
      const url = new URL(request.url)
      const path = url.pathname.replace(/^.*\/schools/, '') || '/'
      if (request.method === 'GET' && path === '/search') return json(await search(url.searchParams))
      if (request.method === 'POST' && path === '/setup') return json(await setup(await actorOf(request), await bodyOf(request)))
      if (request.method === 'POST' && path === '/suggest') return json(await suggest(await actorOf(request), await bodyOf(request)))
      throw new ProxyError('NOT_FOUND', 404)
    } catch (error) {
      if (error instanceof ProxyError) return json({ code: error.code, ...error.extra }, error.status)
      deps.log?.('schools failed', { error: String(error) })
      return json({ code: 'AI_UNAVAILABLE' }, 503)
    }
  }
}
