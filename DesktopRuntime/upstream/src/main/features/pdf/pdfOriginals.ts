import { createHash, randomUUID } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, renameSync, rmSync, openSync, fsyncSync, closeSync, readSync, fstatSync, statSync, type BigIntStats } from 'node:fs'
import { join } from 'node:path'

/** Bounded file hashing for the Electron host; iPad supplies its native SHA. */
export function pdfFileRevision(path: string): string {
  const descriptor = openSync(path, 'r')
  try { return hashDescriptor(descriptor) }
  finally { closeSync(descriptor) }
}
function hashDescriptor(descriptor: number): string {
  const hash = createHash('sha256'), buffer = new Uint8Array(256 * 1024)
  for (let offset = 0;;) { const length = readSync(descriptor, buffer, 0, buffer.length, offset); if (!length) break; hash.update(buffer.subarray(0, length)); offset += length }
  return hash.digest('hex')
}
function fileIdentity(stat: BigIntStats): string | undefined {
  const fields = [stat.dev, stat.ino, stat.size, stat.mtimeNs, stat.ctimeNs]
  // A partial/coarse platform stat is insufficient evidence for cached bytes.
  if (fields.some(value => typeof value !== 'bigint')) return undefined
  return fields.map(value => value.toString()).join(':')
}
/** Open and stat every time. Content is hashed once per unchanged inode and
 * nanosecond metadata, avoiding a full-file read for each completed stroke.
 * In-place writes with restored mtime still change ctime; atomic replacement
 * changes inode. A source changing during hashing is never put in the cache. */
export function createPDFRevisionReader(): (path: string) => string {
  const cache = new Map<string, { identity: string; revision: string }>()
  return path => {
    const descriptor = openSync(path, 'r')
    try {
      const before = fstatSync(descriptor, { bigint: true }), identity = fileIdentity(before), prior = cache.get(path)
      if (identity && prior?.identity === identity) return prior.revision
      const revision = hashDescriptor(descriptor), after = fstatSync(descriptor, { bigint: true }), current = statSync(path, { bigint: true })
      if (identity && (fileIdentity(after) !== identity || fileIdentity(current) !== identity)) throw new Error('PDF changed while checking its revision; retry after the file finishes saving')
      if (!identity && (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs)) throw new Error('PDF changed while checking its revision')
      if (identity) { cache.delete(path); cache.set(path, { identity, revision }); if (cache.size > 256) cache.delete(cache.keys().next().value!) }
      return revision
    } finally { closeSync(descriptor) }
  }
}

/** Recovery originals are not a disposable rendering cache. Keep the first
 * verified bytes so a replacement detected later does not orphan its ink. */
export function createPDFOriginalPreserver(directory: string, pathFor: (courseId: string, relPath: string) => string,
  revisionAt: (path: string) => string = pdfFileRevision) {
  const verified = new Set<string>()
  return (courseId: string, relPath: string, revision: string) => {
    if (verified.has(revision)) return
    const target = join(directory, `${revision}.pdf`)
    mkdirSync(directory, { recursive: true })
    if (existsSync(target)) {
      if (revisionAt(target) !== revision) throw new Error('Preserved PDF original failed its integrity check')
    } else {
      const temporary = join(directory, `${revision}.${randomUUID()}.tmp`)
      try {
        copyFileSync(pathFor(courseId, relPath), temporary)
        if (revisionAt(temporary) !== revision) throw new Error('PDF changed while preserving its original; no ink was applied')
        const descriptor = openSync(temporary, 'r')
        try { fsyncSync(descriptor) } finally { closeSync(descriptor) }
        renameSync(temporary, target)
      } finally { if (existsSync(temporary)) rmSync(temporary, { force: true }) }
    }
    verified.add(revision)
  }
}
