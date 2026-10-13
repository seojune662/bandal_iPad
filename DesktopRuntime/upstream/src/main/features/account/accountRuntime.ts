import { app, shell } from 'electron'
import { runtimeSafeStorage } from '../../lib/safeStorageGate'
import { createAuthService } from './authService'
import { createSessionStore, destroySessionFile, sessionFilePath } from './sessionStore'
import { createSupabaseClient } from './supabaseClient'
import type { AuthState } from '../../../shared/types/auth'
/** Account authentication has no social subscriptions, message outbox, or shared boards. */
export function createAccountRuntime(onChanged: (state: AuthState) => void) {
  let runtime: ReturnType<typeof build> | undefined
  function build() {
    const filePath = sessionFilePath(app.getPath('userData'))
    const storage = createSessionStore({ filePath, encryptor: runtimeSafeStorage() })
    const client = createSupabaseClient({ storage })
    const auth = createAuthService({ client, onChanged, destroySession: () => destroySessionFile(filePath), openExternal: url => shell.openExternal(url) })
    void auth.restore()
    return { client, auth }
  }
  const get = () => runtime ??= build()
  return { auth: () => get().auth, getClient: () => get().client, dispose: () => runtime?.auth.dispose() }
}
