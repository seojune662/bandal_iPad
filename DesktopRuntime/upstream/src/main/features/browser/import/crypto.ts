import { spawn } from 'node:child_process'
import { createDecipheriv, createHash, pbkdf2Sync, timingSafeEqual } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { checkCancelled, ImportReadError } from './types'

export type SecretHelper = (request: { operation: 'keychain'; service: string } | { operation: 'unprotect'; data: string }, signal: AbortSignal) => Promise<Buffer>

/** Pipe only: no secrets in argv, environment, diagnostics or intermediate files. */
export function nativeSecretHelper(helperPath: string): SecretHelper {
  return (request, signal) => new Promise((resolve, reject) => {
    checkCancelled(signal)
    const child = spawn(helperPath, [], { stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true })
    const chunks: Buffer[] = []
    let size = 0
    let settled = false
    const finish = (error?: ImportReadError): void => {
      if (settled) return
      settled = true
      clearTimeout(timeout)
      signal.removeEventListener('abort', cancel)
      const output = Buffer.concat(chunks)
      for (const chunk of chunks) chunk.fill(0)
      if (error) { output.fill(0); reject(error); return }
      try {
        const result = JSON.parse(output.toString('utf8')) as { data?: string }
        if (typeof result.data !== 'string') throw new Error('invalid')
        resolve(Buffer.from(result.data, 'base64'))
      } catch { reject(new ImportReadError('helper')) } finally { output.fill(0) }
    }
    const cancel = (): void => { child.kill(); finish(new ImportReadError('cancelled')) }
    const timeout = setTimeout(() => { child.kill(); finish(new ImportReadError('helper')) }, 120_000)
    signal.addEventListener('abort', cancel, { once: true })
    child.on('error', () => finish(new ImportReadError('helper')))
    child.stdout.on('data', (chunk: Buffer) => {
      if (settled) { chunk.fill(0); return }
      size += chunk.length
      if (size > 1_048_576) { child.kill(); finish(new ImportReadError('helper')); return }
      chunks.push(chunk)
    })
    child.on('close', (code) => finish(code === 0 ? undefined : new ImportReadError('permission')))
    child.stdin.on('error', () => finish(new ImportReadError('helper')))
    child.stdin.end(JSON.stringify(request))
  })
}

export interface ChromiumDecryptor {
  decrypt(value: Buffer, host?: string): Promise<Buffer | null>
  dispose(): void
}

export function createChromiumDecryptor(options: {
  platform: NodeJS.Platform
  browser: 'chrome' | 'edge'
  root: string
  helper: SecretHelper
  signal: AbortSignal
  cookieVersion?: number
}): ChromiumDecryptor {
  let key: Buffer | null = null
  let keyAttempted = false
  let keyError: ImportReadError | null = null
  async function getKey(): Promise<Buffer | null> {
    if (keyAttempted) {
      if (keyError) throw keyError
      return key
    }
    keyAttempted = true
    try {
      if (options.platform === 'darwin') {
        const password = await options.helper({ operation: 'keychain', service: options.browser === 'chrome' ? 'Chrome Safe Storage' : 'Microsoft Edge Safe Storage' }, options.signal)
        try { key = pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1') } finally { password.fill(0) }
      } else if (options.platform === 'win32') {
        const state = JSON.parse(await readFile(join(options.root, 'Local State'), 'utf8')) as { os_crypt?: { encrypted_key?: string } }
        const encoded = state.os_crypt?.encrypted_key
        if (!encoded) return null
        const wrapped = Buffer.from(encoded, 'base64')
        if (wrapped.subarray(0, 5).toString() !== 'DPAPI') return null
        try { key = await options.helper({ operation: 'unprotect', data: wrapped.subarray(5).toString('base64') }, options.signal) } finally { wrapped.fill(0) }
        if (key.length !== 32) { key.fill(0); key = null; throw new ImportReadError('helper') }
      }
      return key
    } catch (error) {
      keyError = error instanceof ImportReadError ? error : new ImportReadError('helper')
      throw keyError
    }
  }
  return {
    async decrypt(value, host) {
      checkCancelled(options.signal)
      // Chrome's app-bound Windows key cannot be unwrapped by another app.
      // Never invoke elevation, injection, source executables or fallback key guesses.
      const version = value.subarray(0, 3).toString()
      if (version === 'v20' || version === 'v11') return null
      let decrypted: Buffer
      if (version === 'v10') {
        const secret = await getKey()
        if (!secret) return null
        try {
          if (options.platform === 'darwin') {
            const decipher = createDecipheriv('aes-128-cbc', secret, Buffer.alloc(16, 0x20))
            decrypted = Buffer.concat([decipher.update(value.subarray(3)), decipher.final()])
          } else if (options.platform === 'win32') {
            if (value.length < 31) return null
            const decipher = createDecipheriv('aes-256-gcm', secret, value.subarray(3, 15))
            decipher.setAuthTag(value.subarray(-16))
            decrypted = Buffer.concat([decipher.update(value.subarray(15, -16)), decipher.final()])
          } else return null
        } catch { return null }
      } else if (options.platform === 'win32') {
        try {
          decrypted = await options.helper({ operation: 'unprotect', data: value.toString('base64') }, options.signal)
        } catch {
          // Legacy DPAPI values may belong to another Windows account or be
          // corrupt. Skip that record without losing later supported records.
          checkCancelled(options.signal)
          return null
        }
      } else return null
      if (host !== undefined && (options.cookieVersion ?? 0) >= 24) {
        const digest = createHash('sha256').update(host).digest()
        if (decrypted.length < 32 || !timingSafeEqual(decrypted.subarray(0, 32), digest)) { decrypted.fill(0); return null }
        const plain = Buffer.from(decrypted.subarray(32))
        decrypted.fill(0)
        return plain
      }
      return decrypted
    },
    dispose() { key?.fill(0); key = null }
  }
}
