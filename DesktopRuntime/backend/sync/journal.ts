import { env } from '../native'
import { randomUUID } from '../shims/crypto'
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, openSync, closeSync, fsyncSync } from '../shims/fs'
import { dirname, join } from '../shims/path'
import { writeFileAtomic } from '../shims/atomic-write'

export type FileChange = { target: string; source?: string; text?: string; remove?: boolean }
// File writes cannot join a SQLite transaction. Retain originals and a durable
// intent before touching files; a committed SQLite receipt decides recovery.
export function createFileJournal(db: any) {
  const root = join(env().userDataPath, 'SyncRecovery'); mkdirSync(root, { recursive: true })
  const restore = (entries: any[]) => { for (const item of entries) { if (item.existed) copyFileSync(item.backup, item.target); else rmSync(item.target, { force: true }) } }
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    const path = join(root, entry.name, 'intent.json')
    if (!existsSync(path)) continue
    const intent = JSON.parse(readFileSync(path, 'utf8') as string)
    if (!db.prepare('SELECT id FROM ipad_sync_commits WHERE id=?').get(intent.id)) restore(intent.entries)
    rmSync(path)
  }
  return (changes: FileChange[], commit: () => void) => {
    const id = randomUUID(), directory = join(root, id), intentPath = join(directory, 'intent.json')
    mkdirSync(directory, { recursive: true })
    const entries = changes.map((change, index) => {
      const existed = existsSync(change.target), backup = join(directory, `${index}.original`)
      if (existed) { copyFileSync(change.target, backup, 1); const fd = openSync(backup, 'r'); try { fsyncSync(fd) } finally { closeSync(fd) } }
      return { ...change, existed, backup }
    })
    writeFileAtomic(intentPath, JSON.stringify({ id, entries }))
    let committed = false
    try {
      db.transaction(() => {
        for (const item of entries) {
          mkdirSync(dirname(item.target), { recursive: true })
          if (item.remove) { rmSync(item.target, { force: true }); continue }
          if (item.source) {
            const temporary = `${item.target}.${id}.sync`; copyFileSync(item.source, temporary, 1)
            const fd = openSync(temporary, 'r'); try { fsyncSync(fd) } finally { closeSync(fd) }
            renameSync(temporary, item.target)
          } else writeFileAtomic(item.target, item.text ?? '')
        }
        commit(); db.prepare('INSERT INTO ipad_sync_commits(id) VALUES(?)').run(id)
      })()
      committed = true; rmSync(intentPath)
    } catch (error) {
      if (!committed) { restore(entries); rmSync(intentPath) }
      throw error
    }
  }
}
