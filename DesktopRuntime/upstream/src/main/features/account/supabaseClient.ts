/** Main-process account client; tokens never enter the renderer. */
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { readSupabaseConfig, type SupabaseConfig } from './config'
import type { SupabaseStorageAdapter } from './sessionStore'

export interface SupabaseClientDeps {
  storage: SupabaseStorageAdapter
  config?: SupabaseConfig
}

/**
 * Builds a configured client, or returns null when the build has no keys.
 *
 * `detectSessionInUrl: false` — there is no browser URL bar here; the PKCE
 * code arrives through the `bandal://` deep link and is exchanged explicitly.
 */
export function createSupabaseClient(
  deps: SupabaseClientDeps
): SupabaseClient | null {
  const config = deps.config ?? readSupabaseConfig()
  if (config === null) return null

  return createClient(config.url, config.publishableKey, {
    auth: {
      flowType: 'pkce',
      detectSessionInUrl: false,
      persistSession: true,
      autoRefreshToken: true,
      storage: deps.storage
    },
    global: {
      headers: { 'x-bandal-client': 'desktop' }
    }
  })
}

