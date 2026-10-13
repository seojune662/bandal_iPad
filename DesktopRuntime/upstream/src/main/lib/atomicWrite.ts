import { randomBytes } from 'node:crypto'
import {
  closeSync,
  existsSync,
  fsyncSync,
  openSync,
  renameSync,
  rmSync,
  writeSync
} from 'node:fs'
import { basename, dirname, join } from 'node:path'

const WINDOWS_RENAME_RETRY_DELAYS_MS = [50, 100, 200, 400, 800] as const
const renameWait = new Int32Array(new SharedArrayBuffer(4))

function publishAtomicFile(temporaryPath: string, absPath: string): void {
  for (let attempt = 0; ; attempt += 1) {
    try {
      renameSync(temporaryPath, absPath)
      return
    } catch (error) {
      const code = (error as NodeJS.ErrnoException | null)?.code
      const delay = WINDOWS_RENAME_RETRY_DELAYS_MS[attempt]
      if (process.platform !== 'win32' || (code !== 'EPERM' && code !== 'EBUSY') || delay === undefined) throw error
      // Transient Windows file locks can reject an atomic replacement.
      // Keep both files intact while waiting; only rename publishes new bytes.
      Atomics.wait(renameWait, 0, 0, delay)
    }
  }
}

export function writeFileAtomic(
  absPath: string,
  data: string | Buffer,
  opts?: { mode?: number; retryWindowsLocks?: boolean }
): void {
  const temporaryPath = join(
    dirname(absPath),
    `.${basename(absPath)}.${process.pid}.${randomBytes(8).toString('hex')}.tmp`
  )
  const bytes = typeof data === 'string' ? Buffer.from(data, 'utf8') : data
  let descriptor: number | undefined

  try {
    descriptor = openSync(temporaryPath, 'wx', opts?.mode ?? 0o666)
    let offset = 0
    while (offset < bytes.length) {
      offset += writeSync(descriptor, bytes, offset, bytes.length - offset)
    }
    fsyncSync(descriptor)
    closeSync(descriptor)
    descriptor = undefined
    // Async transactions restore their own state and yield before retrying.
    // Avoid nesting a blocking wait inside that outer retry policy.
    if (opts?.retryWindowsLocks === false) renameSync(temporaryPath, absPath)
    else publishAtomicFile(temporaryPath, absPath)
  } catch (error) {
    if (descriptor !== undefined) {
      try {
        closeSync(descriptor)
      } catch {
        // Preserve the original atomic-write error.
      }
    }
    try {
      rmSync(temporaryPath, { force: true })
    } catch {
      // Preserve the original atomic-write error.
    }
    throw error
  }
}

export function quarantineFile(absPath: string, now = new Date()): string | null {
  if (!existsSync(absPath)) return null

  // Colons are illegal in Windows filenames (and can name an NTFS stream).
  const basePath = `${absPath}.corrupt-${now.toISOString().replaceAll(':', '-')}`
  let quarantinePath = basePath
  let suffix = 1
  while (existsSync(quarantinePath)) {
    quarantinePath = `${basePath}-${suffix}`
    suffix += 1
  }
  renameSync(absPath, quarantinePath)
  return quarantinePath
}
