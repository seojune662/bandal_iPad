/**
 * safeStorage as the app should see it. With BANDAL_DISABLE_SAFE_STORAGE=1
 * (set by the e2e launcher) every call reports "encryption unavailable"
 * instead of touching the OS keychain: on macOS an unsigned Electron binary
 * blocks the main thread inside SecItemCopyMatching waiting for a keychain
 * prompt no test can answer, which froze the settings e2e on whichever panel
 * happened to ask first.
 *
 * Electron is required lazily so Electron-free unit tests can import callers.
 */
export interface SafeStorageLike {
  isEncryptionAvailable(): boolean
  encryptString(plainText: string): Buffer
  decryptString(encrypted: Buffer): string
}

const DISABLED: SafeStorageLike = {
  isEncryptionAvailable: () => false,
  encryptString: () => {
    throw new Error('safeStorage is disabled (BANDAL_DISABLE_SAFE_STORAGE)')
  },
  decryptString: () => {
    throw new Error('safeStorage is disabled (BANDAL_DISABLE_SAFE_STORAGE)')
  }
}

export function runtimeSafeStorage(): SafeStorageLike {
  if (process.env['BANDAL_DISABLE_SAFE_STORAGE'] === '1') return DISABLED
  const electron = require('electron') as typeof import('electron')
  return electron.safeStorage
}
