// Host boundary replacement for the desktop module's eager SharedArrayBuffer
// Windows retry allocation. iPad keeps the same fsync-before-rename guarantees.
import { randomBytes } from './crypto'
import { basename, dirname, join } from './path'
import { existsSync, openSync, writeSync, fsyncSync, closeSync, renameSync, rmSync } from './fs'
import { Buffer } from './buffer'
export function writeFileAtomic(path: string, data: string | Uint8Array, options?: { mode?: number; beforePublish?: () => void }): void {
  const temporary = join(dirname(path), `.${basename(path)}.${randomBytes(8).toString('hex')}.tmp`)
  const bytes = typeof data === 'string' ? Buffer.from(data) : data
  let fd: number | undefined
  try {
    fd = openSync(temporary, 'wx', options?.mode ?? 0o666)
    let offset = 0
    while (offset < bytes.length) { const count = writeSync(fd, bytes, offset, bytes.length - offset); if (!count) throw new Error('Unable to complete atomic write'); offset += count }
    fsyncSync(fd); closeSync(fd); fd = undefined; options?.beforePublish?.(); renameSync(temporary, path)
  } catch (error) {
    if (fd !== undefined) { try { closeSync(fd) } catch {} }
    try { rmSync(temporary, { force: true }) } catch {}
    throw error
  }
}
export function quarantineFile(path: string, now = new Date()): string | null {
  if (!existsSync(path)) return null
  const base = `${path}.corrupt-${now.toISOString().replaceAll(':', '-')}`
  let target = base, index = 1
  while (existsSync(target)) target = `${base}-${index++}`
  renameSync(path, target); return target
}
