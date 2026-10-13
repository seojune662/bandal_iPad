import { createHash, randomBytes } from 'node:crypto'
import { createServer } from 'node:http'
import { mkdir, readFile, rename, unlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { shell } from 'electron'
import { runtimeSafeStorage } from '../../lib/safeStorageGate'
import type { MailAccountState, MailList, MailMessage, MailModify, MailReply } from '../../../shared/types/mail'
import { gmailMessage, gmailSummary, replyMime, type GmailMessage } from './gmailModel'

const GMAIL_SCOPE = 'https://www.googleapis.com/auth/gmail.modify'
const API = 'https://gmail.googleapis.com/gmail/v1/users/me'
interface TokenSet { accessToken: string; refreshToken: string; expiresAt: number; email: string }
interface TokenResponse { access_token?: string; refresh_token?: string; expires_in?: number; scope?: string; error?: string }

function config(): { clientId: string; verified: boolean } {
  const env = import.meta.env as Record<string, string | undefined>
  const value = (key: string): string => process.env[key] ?? env[key] ?? ''
  return { clientId: value('MAIN_VITE_GMAIL_CLIENT_ID'), verified: value('MAIN_VITE_GMAIL_VERIFIED') === 'true' }
}
function validId(value: string): string {
  if (typeof value !== 'string' || !/^[a-zA-Z0-9_-]{1,200}$/.test(value)) throw new Error('메일 식별자가 올바르지 않아요.')
  return value
}

export function createGmailService(userData: string) {
  const safeStorage = runtimeSafeStorage()
  const tokenPath = join(userData, 'gmail', 'session.enc')
  let tokens: TokenSet | null = null
  let loaded: Promise<void> | null = null
  let authPromise: Promise<MailAccountState> | null = null
  let cancelAuth: (() => void) | null = null
  let refreshPromise: Promise<string> | null = null
  let disconnectPromise: Promise<void> | null = null
  let needsAuth = false
  let epoch = 0
  let storageQueue: Promise<void> = Promise.resolve()
  const bodies = new Map<string, MailMessage>()

  async function load(): Promise<void> {
    loaded ??= (async () => {
      const generation = epoch
      try {
        const encrypted = await readFile(tokenPath)
        if (!safeStorage.isEncryptionAvailable()) return
        const parsed: unknown = JSON.parse(safeStorage.decryptString(encrypted))
        const candidate = parsed as Partial<TokenSet> | null
        if (generation === epoch && candidate && typeof candidate.accessToken === 'string' && typeof candidate.refreshToken === 'string' && typeof candidate.email === 'string' && typeof candidate.expiresAt === 'number') tokens = candidate as TokenSet
      } catch { /* Missing/undecryptable session means disconnected, never plaintext fallback. */ }
    })()
    await loaded
  }
  function assertSession(generation: number): void {
    if (generation !== epoch) throw new Error('메일 연결이 변경되었어요.')
  }
  function persist(next: TokenSet, generation: number): Promise<void> {
    const pending = storageQueue.then(async () => {
      assertSession(generation)
      if (!safeStorage.isEncryptionAvailable()) throw new Error('안전한 인증 정보 저장소를 사용할 수 없어요.')
      await mkdir(join(userData, 'gmail'), { recursive: true, mode: 0o700 })
      const staging = `${tokenPath}.tmp`
      try {
        await writeFile(staging, safeStorage.encryptString(JSON.stringify(next)), { mode: 0o600 })
        assertSession(generation)
        await rename(staging, tokenPath)
      } finally { await unlink(staging).catch(() => {}) }
    })
    storageQueue = pending.catch(() => {})
    return pending
  }
  async function state(): Promise<MailAccountState> {
    await load()
    return { status: !config().clientId ? 'unconfigured' : authPromise ? 'connecting' : needsAuth ? 'reauth-required' : tokens ? 'connected' : 'disconnected', email: tokens?.email ?? null, experimental: !config().verified }
  }
  async function exchange(body: URLSearchParams, generation: number): Promise<TokenResponse> {
    const response = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', body, signal: AbortSignal.timeout(30_000) })
    const result = await response.json() as TokenResponse
    assertSession(generation)
    if (!response.ok || !result.access_token) {
      if (result.error === 'invalid_grant') needsAuth = true
      throw new Error(result.error === 'invalid_grant' ? '메일 연결이 만료되었어요. 다시 연결해 주세요.' : 'Google 메일 인증을 완료하지 못했어요.')
    }
    return result
  }
  async function accessToken(): Promise<string> {
    await load()
    if (disconnectPromise) throw new Error('메일 연결을 해제하고 있어요. 잠시 후 다시 시도해 주세요.')
    if (!tokens || needsAuth) throw new Error('Google 메일을 연결해 주세요.')
    if (tokens.expiresAt > Date.now() + 60_000) return tokens.accessToken
    if (refreshPromise) return refreshPromise
    const session = tokens, generation = epoch
    refreshPromise = (async () => {
      const cfg = config()
      const body = new URLSearchParams({ client_id: cfg.clientId, refresh_token: session.refreshToken, grant_type: 'refresh_token' })
      const result = await exchange(body, generation)
      if (generation !== epoch) throw new Error('메일 연결이 변경되었어요.')
      const next = { ...session, accessToken: result.access_token!, expiresAt: Date.now() + (result.expires_in ?? 3600) * 1000 }
      await persist(next, generation)
      assertSession(generation)
      tokens = next
      return tokens.accessToken
    })().finally(() => { refreshPromise = null })
    return refreshPromise
  }
  async function api<T>(path: string, init?: RequestInit, retry = true): Promise<T> {
    const generation = epoch
    const token = await accessToken()
    assertSession(generation)
    const response = await fetch(`${API}${path}`, { ...init, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(30_000) })
    if (generation !== epoch) throw new Error('메일 연결이 변경되었어요.')
    if (response.status === 401 && retry && tokens) { tokens.expiresAt = 0; return api<T>(path, init, false) }
    if (!response.ok) {
      if (response.status === 401) needsAuth = true
      throw new Error(response.status === 401 ? '메일을 다시 연결해 주세요.' : response.status === 403 ? '메일 접근 권한이나 학교 계정 정책을 확인해 주세요.' : response.status === 429 ? '요청이 많아요. 잠시 후 다시 시도해 주세요.' : '메일 요청을 완료하지 못했어요. 다시 시도해 주세요.')
    }
    const result = await response.json() as T
    assertSession(generation)
    return result
  }
  async function connect(): Promise<MailAccountState> {
    if (disconnectPromise) await disconnectPromise
    if (authPromise) return authPromise
    const cfg = config()
    if (!cfg.clientId) throw new Error('이 빌드에는 Google 메일 연결 설정이 아직 없어요.')
    if (!safeStorage.isEncryptionAvailable()) throw new Error('안전한 인증 정보 저장소를 사용할 수 없어요.')
    const generation = ++epoch
    authPromise = (async () => {
      const verifier = randomBytes(32).toString('base64url'), nonce = randomBytes(32).toString('base64url')
      const server = createServer()
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', () => resolve()) })
        assertSession(generation)
        const address = server.address()
        if (!address || typeof address === 'string') throw new Error('인증 창을 열지 못했어요.')
        const redirect = `http://127.0.0.1:${address.port}/oauth/callback`
        const codePromise = new Promise<string>((resolve, reject) => {
          cancelAuth = () => reject(new Error('메일 연결을 취소했어요.'))
          timer = setTimeout(() => reject(new Error('메일 연결 시간이 지났어요. 다시 시도해 주세요.')), 180_000)
          server.on('request', (request, response) => {
            const url = new URL(request.url ?? '/', redirect)
            if (request.method !== 'GET' || url.pathname !== '/oauth/callback' || url.searchParams.get('state') !== nonce) { response.writeHead(400).end(); return }
            response.setHeader('Content-Type', 'text/plain; charset=utf-8')
            response.setHeader('Cache-Control', 'no-store')
            const code = url.searchParams.get('code')
            if (url.searchParams.has('error') || !code) { response.end('메일 연결을 취소했어요. Bandal로 돌아가 주세요.'); reject(new Error('Google 메일 연결을 취소했어요.')); return }
            response.end('Bandal에서 메일 연결을 마무리하고 있어요. 앱으로 돌아가 주세요.')
            resolve(code)
          })
        })
        // Attach a rejection handler before opening the browser (which can itself fail).
        void codePromise.catch(() => {})
        const url = new URL('https://accounts.google.com/o/oauth2/v2/auth')
        url.search = new URLSearchParams({ client_id: cfg.clientId, redirect_uri: redirect, response_type: 'code', scope: GMAIL_SCOPE, state: nonce, code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256', access_type: 'offline', prompt: 'consent select_account' }).toString()
        await shell.openExternal(url.href)
        const body = new URLSearchParams({ client_id: cfg.clientId, code: await codePromise, code_verifier: verifier, redirect_uri: redirect, grant_type: 'authorization_code' })
        const result = await exchange(body, generation)
        if (!result.refresh_token || (result.scope && !result.scope.split(' ').includes(GMAIL_SCOPE))) throw new Error('메일 읽기·관리 권한을 허용해 주세요.')
        const response = await fetch(`${API}/profile`, { headers: { Authorization: `Bearer ${result.access_token}` }, signal: AbortSignal.timeout(30_000) })
        if (!response.ok) throw new Error('메일 계정을 확인하지 못했어요.')
        const profile = await response.json() as { emailAddress?: string }
        if (!profile.emailAddress || generation !== epoch) throw new Error('메일 연결이 취소되었어요.')
        const next = { accessToken: result.access_token!, refreshToken: result.refresh_token, email: profile.emailAddress, expiresAt: Date.now() + (result.expires_in ?? 3600) * 1000 }
        await persist(next, generation)
        assertSession(generation)
        tokens = next; needsAuth = false; bodies.clear(); loaded = Promise.resolve()
        return { status: 'connected', email: next.email, experimental: !cfg.verified } as MailAccountState
      } finally { if (timer) clearTimeout(timer); cancelAuth = null; server.closeAllConnections(); server.close() }
    })().finally(() => { authPromise = null })
    return authPromise
  }
  function disconnect(): Promise<void> {
    if (disconnectPromise) return disconnectPromise
    ++epoch; cancelAuth?.()
    disconnectPromise = (async () => {
      await load()
      const old = tokens
      await storageQueue
      await unlink(tokenPath).catch((error: NodeJS.ErrnoException) => { if (error.code !== 'ENOENT') throw error })
      // Keep the account visible if removal fails, so the user can retry and
      // the running app agrees with the credentials still saved on disk.
      tokens = null; needsAuth = false; bodies.clear()
      if (old) await fetch('https://oauth2.googleapis.com/revoke', { method: 'POST', body: new URLSearchParams({ token: old.refreshToken }), signal: AbortSignal.timeout(10_000) }).catch(() => {})
    })().finally(() => { disconnectPromise = null })
    return disconnectPromise
  }
  async function list(input: { pageToken?: string; filter?: 'inbox' | 'starred' | 'unread'; query?: string }): Promise<MailList> {
    const generation = epoch
    const params = new URLSearchParams({ maxResults: '20', labelIds: input.filter === 'starred' ? 'STARRED' : 'INBOX' })
    if (input.pageToken) params.set('pageToken', input.pageToken.slice(0, 1024))
    const query = [input.filter === 'unread' ? 'is:unread' : '', input.query?.slice(0, 300) ?? ''].filter(Boolean).join(' ')
    if (query) params.set('q', query)
    const page = await api<{ messages?: { id: string }[]; nextPageToken?: string }>(`/messages?${params}`)
    const messages: MailList['messages'] = []
    for (let i = 0; i < (page.messages?.length ?? 0); i += 5) {
      assertSession(generation)
      const batch = (page.messages ?? []).slice(i, i + 5)
      const fetched = await Promise.all(batch.map(({ id }) => api<GmailMessage>(`/messages/${validId(id)}?format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Subject`)))
      messages.push(...fetched.map(gmailSummary))
    }
    assertSession(generation)
    return { messages, nextPageToken: page.nextPageToken ?? null }
  }
  async function read(id: string): Promise<MailMessage> {
    const generation = epoch
    const message = gmailMessage(await api<GmailMessage>(`/messages/${validId(id)}?format=full`))
    assertSession(generation)
    if (bodies.size >= 30) bodies.delete(bodies.keys().next().value!)
    bodies.set(id, message)
    return message
  }
  async function modify(input: MailModify): Promise<void> {
    const labels: Record<MailModify['action'], { addLabelIds?: string[]; removeLabelIds?: string[] }> = {
      archive: { removeLabelIds: ['INBOX'] }, read: { removeLabelIds: ['UNREAD'] }, unread: { addLabelIds: ['UNREAD'] }, star: { addLabelIds: ['STARRED'] }, unstar: { removeLabelIds: ['STARRED'] }
    }
    if (!labels[input.action]) throw new Error('지원하지 않는 메일 작업이에요.')
    await api(`/messages/${validId(input.id)}/modify`, { method: 'POST', body: JSON.stringify(labels[input.action]) })
    bodies.delete(input.id)
  }
  async function reply(input: MailReply): Promise<void> {
    const generation = epoch
    const original = bodies.get(validId(input.messageId)) ?? await read(input.messageId)
    assertSession(generation)
    await api('/messages/send', { method: 'POST', body: JSON.stringify({ threadId: original.threadId, raw: replyMime(original, tokens?.email ?? '', input.text) }) })
  }
  return { state, connect, disconnect, list, read, modify, reply, cancelConnect: (): void => { ++epoch; cancelAuth?.() } }
}
