import { randomUUID } from 'node:crypto'
import { ConflictError, ValidationError } from '../../db/errors'
import { assertMaterialPathAvailable, type MaterialPathLock } from '../materials/materialPathJournal'
import type { LearningRepointInput } from './learningRepo'

interface OutboxRow { sequence: number; operation_id: string; request_json: string }
interface Deps {
  db: any
  pathLock: MaterialPathLock
  repoint(input: LearningRepointInput): Promise<void>
  onError?: (error: unknown) => void
}
const table = 'learning_path_outbox'
function request(input: LearningRepointInput): Omit<LearningRepointInput, 'operationId'> {
  if (typeof input.courseId !== 'string' || !input.courseId || typeof input.isDirectory !== 'boolean') throw new ValidationError('Invalid learning path update')
  for (const path of [input.fromRelPath, input.toRelPath]) {
    if (typeof path !== 'string' || !path || path.length > 8_192 || path.startsWith('/') || path.includes('\\') || path.split('/').some(part => !part || part === '.' || part === '..') || /[\u0000-\u001f]/.test(path)) throw new ValidationError('Invalid learning relative path')
  }
  return { courseId: input.courseId, fromRelPath: input.fromRelPath, toRelPath: input.toRelPath, isDirectory: input.isDirectory }
}

/** The synchronous enqueue belongs to the material journal's canonical SQL
 * transaction. JSON and SQLite cannot commit together: a receipt in state.json
 * makes replay after JSON publish / before DELETE exactly once per project.
 * The same OS-backed lock as material moves also excludes other app processes. */
export function createLearningPathOutbox(deps: Deps) {
  const { db } = deps
  db.exec(`CREATE TABLE IF NOT EXISTS ${table} (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT UNIQUE NOT NULL,
    request_json TEXT NOT NULL, created_at TEXT NOT NULL
  )`)
  let running: Promise<void> | undefined
  const first = (): OutboxRow | undefined => db.prepare(`SELECT sequence,operation_id,request_json FROM ${table} ORDER BY sequence LIMIT 1`).get()
  function flush(): Promise<void> {
    if (running) return running
    if (!first()) return Promise.resolve()
    // Do not acquire until the synchronous caller's outer SQL transaction and
    // material lock have both completed. Never await while holding that SQL txn.
    const task = Promise.resolve().then(async () => {
      if (db.inTransaction === true) throw new ConflictError('Learning path replay cannot run inside a database transaction')
      const release = deps.pathLock.tryAcquire()
      if (!release) throw new ConflictError('자료 이동 또는 학습 저장이 진행 중입니다. 경로 변경 기록은 보존되어 있습니다.')
      try {
        for (let row = first(); row; row = first()) {
          const input = request(JSON.parse(row.request_json))
          // An unresolved material move must finish before any JSON can claim
          // the corresponding source path is authoritative.
          if (db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='material_path_intents'").get()) {
            const pending = db.prepare('SELECT course_id FROM material_path_intents LIMIT 1').get()
            if (pending) assertMaterialPathAvailable(db, pending.course_id)
          }
          await deps.repoint({ ...input, operationId: row.operation_id })
          db.transaction(() => {
            const current = first()
            if (current?.sequence !== row!.sequence || current.operation_id !== row!.operation_id || current.request_json !== row!.request_json) throw new ConflictError('Learning path queue changed during replay')
            db.prepare(`DELETE FROM ${table} WHERE sequence=? AND operation_id=?`).run(row!.sequence, row!.operation_id)
          })()
        }
      } finally { release() }
    })
    running = task
    void task.then(() => { if (running === task) running = undefined }, () => { if (running === task) running = undefined })
    return task
  }
  function schedule(): void { void Promise.resolve().then(flush).catch(error => deps.onError?.(error)) }
  return {
    /** Must be called in the same transaction which commits canonical paths. */
    enqueue(input: LearningRepointInput): string | undefined {
      if (db.inTransaction !== true) throw new ConflictError('Learning path enqueue requires the material database transaction')
      const value = request(input)
      if (value.fromRelPath === value.toRelPath) return undefined
      const id = randomUUID()
      db.prepare(`INSERT INTO ${table}(operation_id,request_json,created_at) VALUES(?,?,?)`).run(id, JSON.stringify(value), new Date().toISOString())
      return id
    },
    flush, schedule,
    pending(): number { return Number(db.prepare(`SELECT COUNT(*) count FROM ${table}`).get().count) }
  }
}
