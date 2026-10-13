/**
 * Supabase configuration, read from the MAIN bundle only.
 *
 * electron-vite exposes `MAIN_VITE_*` to the main process and `VITE_*` to the
 * renderer. We deliberately use the MAIN_ prefix (docs/phase2-community.md
 * §7.1): the renderer hosts arbitrary `<webview>` guests and remote markdown,
 * so it must never learn the Supabase URL, let alone hold a token.
 *
 * A build with no keys is a FIRST-CLASS state, not an error: `phase` becomes
 * 'unconfigured', account login is unavailable, and every local
 * feature behaves exactly as before. Contributors must be able to clone and
 * build without credentials.
 *
 * 🚨 The `service_role` key never appears here, in .env, in the bundle or in
 * logs. It bypasses RLS entirely.
 */

export interface SupabaseConfig {
  url: string
  publishableKey: string
}

/**
 * electron-vite inlines `MAIN_VITE_*` into `import.meta.env` at build time;
 * `process.env` is the escape hatch for tests and for a packaged app whose
 * operator wants to override the endpoint without a rebuild.
 */
function buildTimeEnv(): Record<string, string | undefined> {
  try {
    return import.meta.env as unknown as Record<string, string | undefined>
  } catch {
    return {}
  }
}

function readEnv(name: string): string {
  const runtime = process.env[name]
  if (typeof runtime === 'string' && runtime.trim() !== '') {
    return runtime.trim()
  }
  const compiled = buildTimeEnv()[name]
  return typeof compiled === 'string' ? compiled.trim() : ''
}

/**
 * Reads config at call time (never at module load) so nothing touches the
 * environment on the boot path and tests can vary it freely.
 *
 * `BANDAL_SUPABASE_URL=''` — the regression gate from §1.4-5 — forces the
 * unconfigured path even in a build that has keys compiled in.
 */
export function readSupabaseConfig(): SupabaseConfig | null {
  const override = process.env['BANDAL_SUPABASE_URL']
  if (override !== undefined && override.trim() === '') {
    return null
  }

  const url = override?.trim() ?? readEnv('MAIN_VITE_SUPABASE_URL')
  const publishableKey =
    readEnv('BANDAL_SUPABASE_PUBLISHABLE_KEY') ||
    readEnv('MAIN_VITE_SUPABASE_PUBLISHABLE_KEY')

  if (url === '' || publishableKey === '') {
    return null
  }
  if (!url.startsWith('https://') && !url.startsWith('http://127.0.0.1')) {
    // A non-TLS remote endpoint would ship bearer tokens in the clear.
    console.warn('[group] ignoring non-https MAIN_VITE_SUPABASE_URL')
    return null
  }
  return { url, publishableKey }
}
