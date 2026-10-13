import type { SupabaseClient } from '@supabase/supabase-js'
import { ValidationError } from '../../db/errors'
import type {
  MarketplaceDashboard,
  MarketplaceRelease,
} from '../../../shared/types/marketplace'

export function marketplaceUrl(): string | null {
  const raw =
    process.env['BANDAL_MARKETPLACE_URL'] ??
    import.meta.env?.MAIN_VITE_MARKETPLACE_URL
  if (!raw?.trim()) return null
  try {
    const url = new URL(raw)
    if (
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      url.pathname !== '/'
    )
      return null
    if (
      url.protocol !== 'https:' &&
      !(url.protocol === 'http:' && url.hostname === '127.0.0.1')
    )
      return null
    return url.origin
  } catch {
    return null
  }
}

export function createMarketplaceClient(deps: {
  getClient(): SupabaseClient | null
  fetch: typeof fetch
  url?: () => string | null
}) {
  const url = deps.url ?? marketplaceUrl
  async function token(): Promise<string | null> {
    const client = deps.getClient()
    if (!client) return null
    const result = await client.auth.getSession()
    if (result.error) throw result.error
    return result.data.session?.access_token ?? null
  }
  async function request(
    path: string,
    body?: unknown,
    authenticated = true,
  ): Promise<Response> {
    const base = url()
    if (!base) throw new ValidationError('Marketplace is not configured')
    const access = authenticated ? await token() : null
    if (authenticated && !access)
      throw new ValidationError('Sign in to use the developer center')
    const response = await deps.fetch(`${base}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      redirect: 'error',
      signal: AbortSignal.timeout(30_000),
      headers: {
        ...(access ? { Authorization: `Bearer ${access}` } : {}),
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    })
    if (!response.ok) {
      const problem = (await response.json().catch(() => null)) as {
        error?: string
      } | null
      throw new ValidationError(
        problem?.error ?? `Marketplace HTTP ${response.status}`,
      )
    }
    return response
  }
  return {
    async release(id: string): Promise<MarketplaceRelease> {
      if (!/^[0-9a-f-]{36}$/.test(id))
        throw new ValidationError('Invalid release id')
      return (
        await request(`/releases/${id}`, undefined, false)
      ).json() as Promise<MarketplaceRelease>
    },
    async dashboard(): Promise<MarketplaceDashboard> {
      const empty = {
        configured: url() !== null,
        signedIn: false,
        publisher: null,
        reviewer: false,
        releases: [],
      }
      if (!empty.configured || !(await token())) return empty
      return (
        await request('/dashboard')
      ).json() as Promise<MarketplaceDashboard>
    },
    async register(id: string, displayName: string): Promise<void> {
      await request('/publishers', { id, displayName })
    },
    async submit(
      artifactBase64: string,
      changelog: string,
    ): Promise<MarketplaceRelease> {
      return (
        await request('/releases', { artifactBase64, changelog })
      ).json() as Promise<MarketplaceRelease>
    },
    async review(
      id: string,
      decision: 'approved' | 'rejected' | 'withdrawn',
      reason: string,
    ): Promise<void> {
      if (!/^[0-9a-f-]{36}$/.test(id))
        throw new ValidationError('Invalid release id')
      await request(`/releases/${id}/review`, { decision, reason })
    },
    async reviewBundle(id: string): Promise<Uint8Array> {
      if (!/^[0-9a-f-]{36}$/.test(id))
        throw new ValidationError('Invalid release id')
      const response = await request(`/releases/${id}/review-bundle`)
      const reader = response.body?.getReader()
      if (!reader) throw new ValidationError('Empty archive')
      const chunks: Uint8Array[] = []
      let size = 0
      while (true) {
        const result = await reader.read()
        if (result.done) break
        size += result.value.length
        if (size > 8 * 1024 * 1024) {
          await reader.cancel()
          throw new ValidationError('Archive too large')
        }
        chunks.push(result.value)
      }
      return Buffer.concat(chunks)
    },
    async report(releaseId: string, reason: string): Promise<void> {
      await request('/reports', { releaseId, reason })
    },
    async resolveReport(id: string, reason: string): Promise<void> {
      if (!/^[0-9a-f-]{36}$/.test(id))
        throw new ValidationError('Invalid report id')
      await request(`/reports/${id}/resolve`, { reason })
    },
  }
}
