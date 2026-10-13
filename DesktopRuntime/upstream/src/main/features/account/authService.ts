/**
 * Auth state machine (docs/phase2-community.md §1.2–1.4).
 *
 * OAuth runs in the SYSTEM BROWSER, never in an app window. `signIn()` asks
 * Supabase for the provider URL with `skipBrowserRedirect`, opens it with
 * `shell.openExternal`, and returns immediately — the app then sits in
 * `signing-in` until the provider bounces the user back to
 * `bandal://auth/callback`, which `handleDeepLink()` finishes. An in-app
 * BrowserWindow would put us inside Google's "embedded user-agent" ban and
 * give the renderer a view of the auth code.
 *
 * THE NON-NEGOTIABLE RULE (§1.4): with auth unconfigured or signed out, every
 * Phase-1 feature works exactly as it does today. Which is why:
 *   - nothing here runs unless an `auth:*` invoke arrives
 *   - a missing key set is `phase: 'unconfigured'`, not an error
 *   - every session-restore failure (network, expiry, corrupt file) degrades
 *     to `signed-out` and the app boots normally
 *
 * ⚠ NEVER log the callback URL or a token. The URL carries a single-use
 * authorization code; `authCallbackUrl.ts` owns every look at it and
 * `describeAuthCallback()` is the only log-safe rendering.
 */

import { accountAvatarUrl } from '../../../shared/account/avatar'
import type { SupabaseClient } from '@supabase/supabase-js'
import type {
  AuthProvider,
  AuthSignInResult,
  AuthState,
  MyProfile
} from '../../../shared/types/auth'
import {
  SIGNED_OUT_AUTH_STATE,
  UNCONFIGURED_AUTH_STATE
} from '../../../shared/types/auth'
import {
  isPlaceholderNickname,
  isValidNickname,
  NICKNAME_RULE_TEXT
} from '../../../shared/account/nickname'
import {
  AUTH_CALLBACK_URL,
  describeAuthCallback,
  parseAuthCallbackUrl
} from './authCallbackUrl'

export interface AuthServiceDeps {
  /** null when the build has no Supabase keys → 'unconfigured' forever. */
  client: SupabaseClient | null
  /** Broadcast `auth:changed` to every window. */
  onChanged: (state: AuthState) => void
  /** Removes the encrypted session file on sign-out. */
  destroySession: () => void
  /**
   * `shell.openExternal`, injected rather than imported so this module stays
   * testable without an Electron runtime.
   */
  openExternal: (url: string) => Promise<void>
}

export interface AuthService {
  getState(): AuthState
  /** Restores a persisted session. Never throws; never blocks boot. */
  restore(): Promise<AuthState>
  signIn(provider: AuthProvider): Promise<AuthSignInResult>
  /**
   * Completes (or abandons) a sign-in from a `bandal://` deep link.
   * Never throws — every failure lands in the auth state instead.
   */
  handleDeepLink(url: string): Promise<void>
  signOut(): Promise<void>
  setNickname(nickname: string): Promise<MyProfile>
  /** Current access token for `realtime.setAuth()`. */
  accessToken(): string | null
  userId(): string | null
  setOnline(online: boolean): void
  dispose(): void
}

/** Shared nickname rules used by account settings. */
export { isValidNickname }

function profileFromRow(row: unknown, fallbackId: string): MyProfile {
  const record =
    typeof row === 'object' && row !== null ? (row as Record<string, unknown>) : {}
  const nickname = record['nickname']
  return {
    id: typeof record['id'] === 'string' ? record['id'] : fallbackId,
    // A freshly-created profile carries the temporary `user_<8hex>` handle;
    // treating it as "unset" is what triggers the nickname step in the UI.
    nickname:
      typeof nickname === 'string' && !isPlaceholderNickname(nickname)
        ? nickname
        : null,
    avatarColor:
      typeof record['avatar_color'] === 'string' ? record['avatar_color'] : 'moon',
    avatarEmoji:
      typeof record['avatar_emoji'] === 'string' ? record['avatar_emoji'] : '🌙'
  }
}

export function createAuthService(deps: AuthServiceDeps): AuthService {
  const configured = deps.client !== null
  let state: AuthState = configured
    ? { ...SIGNED_OUT_AUTH_STATE }
    : { ...UNCONFIGURED_AUTH_STATE }
  let token: string | null = null
  let uid: string | null = null
  let sessionVersion = 0
  let unsubscribe: (() => void) | null = null
  let signingOut = false
  /** The code currently being exchanged — the re-entrancy guard (§handleDeepLink). */
  let exchangingCode: string | null = null
  /** Codes already spent. A replayed callback must not burn a rate-limit slot. */
  const spentCodes = new Set<string>()

  function publish(next: AuthState): AuthState {
    state = next
    deps.onChanged(state)
    return state
  }

  function failed(errorCode: AuthState['errorCode']): AuthState {
    return publish({
      phase: 'error',
      profile: null,
      email: null,
      avatarUrl: null,
      online: state.online,
      errorCode
    })
  }

  /**
   * Idempotent. Both entry points (restore, deep link) need it: without a
   * listener the refreshed access token never reaches `realtime.setAuth()` and
   * every channel goes quiet an hour later.
   */
  function ensureAuthSubscription(client: SupabaseClient): void {
    if (unsubscribe !== null) return
    const { data: sub } = client.auth.onAuthStateChange((_event, session) => {
      if (signingOut) return
      if (session === null) {
        clearSession()
        publish({ ...SIGNED_OUT_AUTH_STATE })
        return
      }
      void adoptSession(
        session.access_token,
        session.user.id,
        session.user.email ?? null,
        session.user.user_metadata
      )
    })
    unsubscribe = () => {
      sub.subscription.unsubscribe()
    }
  }

  async function loadProfile(userId: string): Promise<MyProfile> {
    if (deps.client === null) {
      return { id: userId, nickname: null, avatarColor: 'moon', avatarEmoji: '🌙' }
    }
    const { data, error } = await deps.client
      .from('profiles')
      .select('id, nickname, avatar_color, avatar_emoji')
      .eq('id', userId)
      .maybeSingle()
    if (error !== null) throw error
    return profileFromRow(data, userId)
  }

  async function adoptSession(
    accessToken: string,
    userId: string,
    userEmail: string | null,
    metadata?: Record<string, unknown>
  ): Promise<AuthState> {
    const version = ++sessionVersion
    const avatarUrl = accountAvatarUrl(metadata)
    token = accessToken
    uid = userId
    try {
      const profile = await loadProfile(userId)
      if (version !== sessionVersion) return state
      return publish({
        phase: 'signed-in',
        profile,
        email: userEmail,
        avatarUrl,
        online: true,
        errorCode: null
      })
    } catch (error) {
      // Signed in but the profile row is unreachable (offline right after a
      // restore). That is not a sign-in failure: keep the session, show the
      // user as signed-in-but-offline and let the next fetch fill it in.
      if (version !== sessionVersion) return state
      console.error('[account] failed to load profile', error)
      return publish({
        phase: 'signed-in',
        profile: { id: userId, nickname: null, avatarColor: 'moon', avatarEmoji: '🌙' },
        email: userEmail,
        avatarUrl,
        online: false,
        errorCode: null
      })
    }
  }

  function clearSession(): void {
    token = null
    uid = null
    sessionVersion += 1
  }

  async function updateProfile(
    patch: Record<string, string>
  ): Promise<MyProfile> {
    if (deps.client === null || uid === null) {
      throw new Error('not-signed-in')
    }
    const userId = uid
    const version = sessionVersion
    const { data, error } = await deps.client
      .from('profiles')
      .update(patch)
      .eq('id', userId)
      .select('id, nickname, avatar_color, avatar_emoji')
      .single()
    // The DB is the authority on nicknames (unique index + CHECK). Translating
    // its two rejections here is what lets the renderer print the reason
    // verbatim instead of leaking `duplicate key value violates …` at a
    // student mid-signup.
    if (error !== null) {
      if (error.code === '23505') {
        throw new Error('이미 쓰고 있는 이름이에요. 다른 이름으로 해볼까요?')
      }
      if (error.code === '23514') throw new Error(NICKNAME_RULE_TEXT)
      throw error
    }
    if (version !== sessionVersion) throw new Error('account-changed')
    const profile = profileFromRow(data, userId)
    publish({ ...state, profile })
    return profile
  }

  return {
    getState: () => state,

    async restore() {
      if (deps.client === null) return state
      const version = sessionVersion
      try {
        const { data, error } = await deps.client.auth.getSession()
        if (version !== sessionVersion || signingOut) return state
        if (error !== null || data.session === null) {
          clearSession()
          return publish({ ...SIGNED_OUT_AUTH_STATE })
        }
        ensureAuthSubscription(deps.client)
        return await adoptSession(
          data.session.access_token,
          data.session.user.id,
          data.session.user.email ?? null,
          data.session.user.user_metadata
        )
      } catch (error) {
        if (version !== sessionVersion || signingOut) return state
        // Corrupt session file, expired refresh token, no network — all
        // non-fatal. The app is already running; we just stay signed out.
        console.error('[account] session restore failed (non-fatal)', error)
        clearSession()
        return publish({ ...SIGNED_OUT_AUTH_STATE })
      }
    },

    async signIn(provider) {
      const client = deps.client
      if (client === null) {
        publish({ ...UNCONFIGURED_AUTH_STATE })
        return { ok: false, reason: 'not-configured' } as const
      }
      if (state.phase === 'signed-in') {
        return { ok: false, reason: 'already-signed-in' } as const
      }
      if (signingOut) return { ok: false, reason: 'provider' } as const
      const version = ++sessionVersion
      try {
        // `skipBrowserRedirect` is what makes this usable from Electron: it
        // asks for the provider URL instead of navigating, so WE choose the
        // browser. `redirectTo` must match a Supabase dashboard Redirect URL
        // exactly or the callback silently never fires (docs/oauth-setup.md §3).
        const { data, error } = await client.auth.signInWithOAuth({
          provider,
          options: {
            redirectTo: AUTH_CALLBACK_URL,
            skipBrowserRedirect: true
          }
        })
        if (version !== sessionVersion) return { ok: true } as const
        if (error !== null || typeof data.url !== 'string' || data.url === '') {
          console.error('[account] signInWithOAuth returned no url', error)
          failed('provider')
          return { ok: false, reason: 'provider' } as const
        }
        await deps.openExternal(data.url)
        if (version !== sessionVersion) return { ok: true } as const
        // Nothing else happens until the deep link arrives. The renderer shows
        // "브라우저에서 계속해요" against this phase.
        publish({
          phase: 'signing-in',
          profile: null,
          email: null,
          avatarUrl: null,
          online: state.online,
          errorCode: null
        })
        return { ok: true } as const
      } catch (error) {
        if (version !== sessionVersion) return { ok: true } as const
        // No network to reach the auth endpoint, or the OS refused to open a
        // browser. Either way the user is still signed out, not broken.
        console.error('[account] sign-in failed', error)
        failed('network')
        return { ok: false, reason: 'network' } as const
      }
    },

    /**
     * The other half of `signIn()`. Robust against the four things that
     * actually happen in the field:
     *
     *  1. The user closes the consent screen → `error=access_denied` → back to
     *     `signed-out`. A cancellation is a decision, not a failure, so it must
     *     not render as an error.
     *  2. A malformed callback (no code / two different codes / junk) → an
     *     explicit `error` state. Staying in `signing-in` forever would be the
     *     worse failure: the login button is gone and nothing says why.
     *  3. A SECOND callback after a session already exists (macOS re-delivers
     *     `open-url` on relaunch; users click the link twice) → ignored. The
     *     code is already spent; exchanging it again fails and would tear down
     *     a perfectly good session.
     *  4. Two callbacks racing → the in-flight code is the guard.
     */
    async handleDeepLink(url) {
      if (signingOut) return
      const parsed = parseAuthCallbackUrl(url)
      if (parsed.kind === 'ignored') {
        if (parsed.why !== 'not-auth-callback') return
        console.info(`[account] ignoring deep link ${describeAuthCallback(url)}`)
        return
      }
      if (deps.client === null) {
        // No keys in this build — there is nothing to exchange the code with.
        publish({ ...UNCONFIGURED_AUTH_STATE })
        return
      }

      // ⚠ Before branching on the payload: a session that already exists wins
      // over ANY late callback. macOS re-delivers `open-url` on relaunch and
      // people click the browser's "return to app" twice — treating a stale
      // cancellation as a sign-out would evict a perfectly good session.
      if (uid !== null || state.phase === 'signed-in') {
        console.info('[account] auth callback ignored — a session already exists')
        return
      }

      if (parsed.kind === 'cancelled') {
        console.info('[account] sign-in cancelled by the user')
        clearSession()
        publish({
          ...SIGNED_OUT_AUTH_STATE,
          online: state.online,
          errorCode: 'oauth-cancelled'
        })
        return
      }

      if (parsed.kind === 'failed') {
        console.error(
          `[account] auth callback rejected: ${parsed.reason}${
            parsed.detail === null ? '' : ` (${parsed.detail})`
          }`
        )
        failed('provider')
        return
      }

      // ── kind === 'code' ────────────────────────────────────────────────────
      if (exchangingCode !== null || spentCodes.has(parsed.code)) {
        console.info('[account] auth callback ignored — code already in use')
        return
      }

      exchangingCode = parsed.code
      const version = ++sessionVersion
      try {
        const { data, error } = await deps.client.auth.exchangeCodeForSession(
          parsed.code
        )
        if (version !== sessionVersion || signingOut) return
        spentCodes.add(parsed.code)
        if (error !== null || data.session === null) {
          console.error('[account] code exchange failed', error)
          failed('provider')
          return
        }
        ensureAuthSubscription(deps.client)
        await adoptSession(
          data.session.access_token,
          data.session.user.id,
          data.session.user.email ?? null,
          data.session.user.user_metadata
        )
      } catch (error) {
        if (version !== sessionVersion || signingOut) return
        console.error('[account] code exchange threw', error)
        failed('network')
      } finally {
        exchangingCode = null
      }
    },

    async signOut() {
      signingOut = true
      unsubscribe?.()
      unsubscribe = null
      clearSession()
      if (deps.client !== null) {
        try {
          await deps.client.auth.signOut()
        } catch (error) {
          // Local sign-out must succeed even if the server call does not.
          console.error('[account] remote signOut failed', error)
        }
      }
      clearSession()
      signingOut = false
      spentCodes.clear()
      deps.destroySession()
      publish(
        deps.client === null
          ? { ...UNCONFIGURED_AUTH_STATE }
          : { ...SIGNED_OUT_AUTH_STATE }
      )
    },

    setNickname(nickname) {
      const trimmed = nickname.trim()
      if (!isValidNickname(trimmed)) {
        return Promise.reject(new Error(NICKNAME_RULE_TEXT))
      }
      return updateProfile({ nickname: trimmed })
    },

    accessToken: () => token,
    userId: () => uid,

    setOnline: (online) => {
      if (state.online === online) return
      publish({ ...state, online })
    },

    dispose: () => {
      clearSession()
      unsubscribe?.()
      unsubscribe = null
    }
  }
}
