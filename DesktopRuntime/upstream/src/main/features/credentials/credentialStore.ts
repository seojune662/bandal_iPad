import { runtimeSafeStorage } from '../../lib/safeStorageGate'
import { randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import { basename, join } from 'node:path'
import type {
  CredentialsAvailability,
  SaveLoginInput,
  SavedLoginSummary,
} from '../../../shared/types/credentials'
import { quarantineFile, writeFileAtomic } from '../../lib/atomicWrite'

export const CREDENTIALS_FILE_NAME = 'saved-logins.enc'

const ENVELOPE_FORMAT = 'bandal-saved-logins'
const ENVELOPE_VERSION = 2
const ENCRYPTION_UNAVAILABLE_REASON =
  'OS-backed encryption is unavailable; saved logins are disabled.'

export interface CredentialSafeStorage {
  isEncryptionAvailable(): boolean
  encryptString(plainText: string): Buffer
  decryptString(encrypted: Buffer): string
}

export interface CredentialStoreDeps {
  safeStorage: CredentialSafeStorage
  userDataPath: string
  now?: () => number
}

export interface ResolvedLogin {
  username: string
  password: string
  autoSubmit: boolean
}

export interface CredentialStore {
  availability(): CredentialsAvailability
  list(): SavedLoginSummary[]
  save(input: SaveLoginInput): SavedLoginSummary
  /** Main-only bulk path used by password CSV import; persists once. */
  importMany(
    inputs: readonly SaveLoginInput[],
    options?: { conflict?: 'keep' | 'replace' },
  ): {
    imported: number
    skipped: number
    added: number
    updated: number
    unchanged: number
    conflicts: number
    invalid: number
  }
  forget(origin: string, credentialId?: string): { ok: true }
  /** Main-process internal only. Never expose this method through IPC. */
  resolve(origin: string, credentialId?: string): ResolvedLogin | null
}

interface StoredLogin extends ResolvedLogin {
  id: string
  origin: string
  updatedAt: string
}

interface CredentialEnvelope {
  format: typeof ENVELOPE_FORMAT
  version: typeof ENVELOPE_VERSION
  logins: StoredLogin[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/** Canonical https scheme + host (+ non-default port), with no URL tail. */
export function normalizeCredentialOrigin(value: string): string {
  const parsed = new URL(value)
  if (parsed.protocol !== 'https:') {
    throw new TypeError('Saved login origin must use HTTPS')
  }
  if (parsed.username !== '' || parsed.password !== '') {
    throw new TypeError('Saved login origin must not contain URL credentials')
  }
  return parsed.origin
}

function parseLogin(value: unknown, legacy = false): StoredLogin {
  if (!isRecord(value)) throw new TypeError('Invalid saved login entry')
  if (
    typeof value['origin'] !== 'string' ||
    typeof value['username'] !== 'string' ||
    typeof value['password'] !== 'string' ||
    typeof value['autoSubmit'] !== 'boolean' ||
    typeof value['updatedAt'] !== 'string'
  ) {
    throw new TypeError('Invalid saved login entry')
  }

  const origin = normalizeCredentialOrigin(value['origin'])
  if (origin !== value['origin']) {
    throw new TypeError('Saved login origin is not canonical')
  }
  if (!Number.isFinite(Date.parse(value['updatedAt']))) {
    throw new TypeError('Invalid saved login timestamp')
  }
  return {
    id: legacy ? randomUUID() : requireId(value['id']),
    origin,
    username: value['username'],
    password: value['password'],
    autoSubmit: value['autoSubmit'],
    updatedAt: value['updatedAt'],
  }
}

function requireId(value: unknown): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > 100) {
    throw new TypeError('Invalid saved login identity')
  }
  return value
}

function accountKey(login: { origin: string; username: string }): string {
  return JSON.stringify([login.origin, login.username])
}

function parseEnvelope(plainText: string): {
  logins: StoredLogin[]
  legacy: boolean
} {
  const value: unknown = JSON.parse(plainText)
  if (
    !isRecord(value) ||
    value['format'] !== ENVELOPE_FORMAT ||
    (value['version'] !== 1 && value['version'] !== ENVELOPE_VERSION) ||
    !Array.isArray(value['logins'])
  ) {
    throw new TypeError('Invalid saved login file')
  }

  const legacy = value['version'] === 1
  const logins = value['logins'].map((login) => parseLogin(login, legacy))
  if (
    new Set(logins.map(accountKey)).size !== logins.length ||
    new Set(logins.map((login) => login.id)).size !== logins.length
  ) {
    throw new TypeError('Duplicate saved login account')
  }
  return { logins, legacy }
}

function summary(login: StoredLogin): SavedLoginSummary {
  return {
    id: login.id,
    origin: login.origin,
    username: login.username,
    autoSubmit: login.autoSubmit,
    updatedAt: login.updatedAt,
  }
}

function buildCredentialStore(deps: CredentialStoreDeps): CredentialStore {
  const filePath = join(deps.userDataPath, CREDENTIALS_FILE_NAME)
  const now = deps.now ?? Date.now
  let encryptionAvailable: boolean | undefined
  let cache: StoredLogin[] | undefined
  let quarantineReason: string | null = null

  const canEncrypt = (): boolean => {
    if (encryptionAvailable === undefined) {
      try {
        encryptionAvailable = deps.safeStorage.isEncryptionAvailable()
      } catch {
        encryptionAvailable = false
      }
    }
    return encryptionAvailable
  }

  const discard = (): void => {
    try {
      rmSync(`${filePath}.tmp`, { force: true })
      rmSync(filePath, { force: true })
    } catch {
      // Keep the cache unchanged until the encrypted file is actually gone.
      throw new Error('Saved login could not be deleted')
    }
  }

  const quarantine = (): string => {
    const quarantinePath = quarantineFile(filePath, new Date(now())) ?? filePath
    quarantineReason = `저장된 데이터를 읽지 못해 격리했습니다: ${basename(quarantinePath)}`
    return quarantinePath
  }

  const load = (): StoredLogin[] => {
    if (cache !== undefined) return cache

    // This plain fs check must precede every safeStorage call. On macOS even
    // checking availability may open the keychain UI; a first-run student has
    // no encrypted file to read and must not see that prompt at app launch.
    if (!existsSync(filePath)) {
      cache = []
      return cache
    }
    if (!canEncrypt()) {
      cache = []
      return cache
    }

    let legacy = false
    try {
      const parsed = parseEnvelope(
        deps.safeStorage.decryptString(readFileSync(filePath)),
      )
      cache = parsed.logins
      legacy = parsed.legacy
    } catch {
      cache = []
      const quarantinePath = quarantine()
      console.warn(`[credentials] 복호화 실패 — 격리: ${quarantinePath}`)
    }
    // Migration uses the same atomic encrypted write as normal saves. A write
    // failure must not quarantine an otherwise readable v1 file.
    if (legacy) persist(cache)
    return cache
  }

  const persist = (logins: StoredLogin[]): void => {
    if (logins.length === 0) {
      discard()
      cache = []
      quarantineReason = null
      return
    }

    const envelope: CredentialEnvelope = {
      format: ENVELOPE_FORMAT,
      version: ENVELOPE_VERSION,
      logins,
    }
    try {
      const encrypted = deps.safeStorage.encryptString(JSON.stringify(envelope))
      mkdirSync(deps.userDataPath, { recursive: true, mode: 0o700 })
      writeFileAtomic(filePath, encrypted, { mode: 0o600 })
      chmodSync(filePath, 0o600)
      cache = logins
      quarantineReason = null
    } catch {
      throw new Error('Saved login could not be persisted')
    }
  }

  return {
    availability(): CredentialsAvailability {
      if (
        quarantineReason === null &&
        cache === undefined &&
        existsSync(filePath) &&
        canEncrypt()
      ) {
        load()
      }
      if (quarantineReason !== null) {
        return { state: 'unavailable', reason: quarantineReason }
      }
      return canEncrypt()
        ? { state: 'ready' }
        : { state: 'unavailable', reason: ENCRYPTION_UNAVAILABLE_REASON }
    },

    list(): SavedLoginSummary[] {
      if (!existsSync(filePath) && cache === undefined) return []
      return load()
        .map(summary)
        .sort((left, right) => left.origin.localeCompare(right.origin))
    },

    save(input: SaveLoginInput): SavedLoginSummary {
      if (!canEncrypt()) {
        throw new Error(ENCRYPTION_UNAVAILABLE_REASON)
      }

      const origin = normalizeCredentialOrigin(input.origin)
      const current = load()
      const existing =
        input.id === undefined
          ? current.find(
              (login) =>
                login.origin === origin && login.username === input.username,
            )
          : current.find(
              (login) => login.id === input.id && login.origin === origin,
            )
      if (input.id !== undefined && existing === undefined) {
        throw new TypeError('Saved login account does not exist')
      }
      if (input.password === '' && input.id === undefined) {
        throw new TypeError('Account identity is required for metadata edits')
      }
      if (
        current.some(
          (login) =>
            login.id !== existing?.id &&
            login.origin === origin &&
            login.username === input.username,
        )
      ) {
        throw new TypeError('Saved login account already exists')
      }
      const password =
        input.password === '' && existing !== undefined
          ? existing.password
          : input.password
      if (password === '') {
        throw new TypeError('A password is required for a new saved login')
      }

      const login: StoredLogin = {
        id: existing?.id ?? randomUUID(),
        origin,
        username: input.username,
        password,
        autoSubmit: input.autoSubmit ?? false,
        updatedAt: new Date(now()).toISOString(),
      }
      persist([...current.filter((item) => item.id !== login.id), login])
      return summary(login)
    },

    importMany(inputs, options) {
      if (!canEncrypt()) throw new Error(ENCRYPTION_UNAVAILABLE_REASON)
      const accounts = new Map(
        load().map((login) => [accountKey(login), login]),
      )
      let added = 0,
        updated = 0,
        unchanged = 0,
        conflicts = 0,
        invalid = 0
      for (const input of inputs) {
        try {
          const origin = normalizeCredentialOrigin(input.origin)
          if (input.password === '') {
            invalid += 1
            continue
          }
          const key = accountKey({ origin, username: input.username })
          const existing = accounts.get(key)
          if (existing?.password === input.password) {
            unchanged++
            continue
          }
          if (existing !== undefined && options?.conflict !== 'replace') {
            conflicts++
            continue
          }
          accounts.set(key, {
            id: existing?.id ?? randomUUID(),
            origin,
            username: input.username,
            password: input.password,
            autoSubmit: false,
            updatedAt: new Date(now()).toISOString(),
          })
          if (existing === undefined) added++
          else updated++
        } catch {
          invalid += 1
        }
      }
      const imported = added + updated
      if (imported > 0) persist([...accounts.values()])
      return {
        imported,
        skipped: unchanged + conflicts + invalid,
        added,
        updated,
        unchanged,
        conflicts,
        invalid,
      }
    },

    forget(origin: string, credentialId?: string): { ok: true } {
      let normalized: string
      try {
        normalized = normalizeCredentialOrigin(origin)
      } catch {
        return { ok: true }
      }
      if (!existsSync(filePath) && cache === undefined) return { ok: true }

      const current = load()
      const matches = current.filter((login) => login.origin === normalized)
      const id =
        credentialId ?? (matches.length === 1 ? matches[0]!.id : undefined)
      const next = current.filter(
        (login) => !(login.origin === normalized && login.id === id),
      )
      if (next.length !== current.length) persist(next)
      return { ok: true }
    },

    resolve(origin: string, credentialId?: string): ResolvedLogin | null {
      let normalized: string
      try {
        normalized = normalizeCredentialOrigin(origin)
      } catch {
        return null
      }
      if (!existsSync(filePath) && cache === undefined) return null

      const matches = load().filter((item) => item.origin === normalized)
      const login =
        credentialId === undefined
          ? matches.length === 1
            ? matches[0]
            : undefined
          : matches.find((item) => item.id === credentialId)
      return login === undefined
        ? null
        : {
            username: login.username,
            password: login.password,
            autoSubmit: login.autoSubmit,
          }
    },
  }
}

let defaultStore: CredentialStore | undefined

export function createCredentialStore(
  deps?: CredentialStoreDeps,
): CredentialStore {
  if (deps !== undefined) return buildCredentialStore(deps)
  if (defaultStore !== undefined) return defaultStore

  // Lazy require keeps unit tests Electron-free. Construction does not touch
  // safeStorage; decryption is deferred until an encrypted file actually exists.
  const electron = require('electron') as typeof import('electron')
  defaultStore = buildCredentialStore({
    safeStorage: runtimeSafeStorage(),
    userDataPath: electron.app.getPath('userData'),
  })
  return defaultStore
}
