import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { ValidationError } from '../../db/errors'
import { writeFileAtomic } from '../../lib/atomicWrite'
import {
  runtimeSafeStorage,
  type SafeStorageLike
} from '../../lib/safeStorageGate'

const FILE_NAME = 'gemini-api-key.enc'
const MIN_KEY_LENGTH = 20

function storageIsAvailable(storage: SafeStorageLike): boolean {
  try {
    return storage.isEncryptionAvailable()
  } catch {
    return false
  }
}

export function createGeminiApiKeyStore(
  userDataPath: string,
  storage: SafeStorageLike = runtimeSafeStorage()
) {
  const filePath = join(userDataPath, FILE_NAME)

  function readStoredKey(storageAvailable: boolean): string | null {
    if (!storageAvailable || !existsSync(filePath)) return null
    try {
      const key = storage.decryptString(readFileSync(filePath)).trim()
      return key.length >= MIN_KEY_LENGTH ? key : null
    } catch {
      return null
    }
  }

  function readKey(): string | null {
    return readStoredKey(storageIsAvailable(storage))
  }

  function get(): {
    configured: boolean
    hint: string | null
    storageAvailable: boolean
  } {
    const storageAvailable = storageIsAvailable(storage)
    const key = readStoredKey(storageAvailable)
    return {
      configured: key !== null,
      hint: key?.slice(-4) ?? null,
      storageAvailable
    }
  }

  function set(key: string | null): { configured: boolean; hint: string | null } {
    if (!storageIsAvailable(storage)) {
      throw new ValidationError('이 기기에서는 안전 저장소를 쓸 수 없어요')
    }
    if (key === null) {
      rmSync(filePath, { force: true })
      return { configured: false, hint: null }
    }

    const trimmed = key.trim()
    if (trimmed.length < MIN_KEY_LENGTH) {
      throw new ValidationError('키가 너무 짧아요')
    }
    mkdirSync(dirname(filePath), { recursive: true })
    writeFileAtomic(filePath, storage.encryptString(trimmed), { mode: 0o600 })
    chmodSync(filePath, 0o600)
    return { configured: true, hint: trimmed.slice(-4) }
  }

  return { get, set, readKey }
}
