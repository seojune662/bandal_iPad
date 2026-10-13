/**
 * Build-time environment injected into the MAIN bundle by electron-vite.
 *
 * Only the `MAIN_VITE_` prefix reaches this process. `VITE_`-prefixed values
 * would also reach the RENDERER, which must never learn the Supabase endpoint
 * (docs/phase2-community.md §7.1) — so the prefix is load-bearing, not
 * cosmetic.
 */
interface ImportMetaEnv {
  readonly MAIN_VITE_SUPABASE_URL?: string
  readonly MAIN_VITE_MARKETPLACE_URL?: string
  readonly MAIN_VITE_SUPABASE_PUBLISHABLE_KEY?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
