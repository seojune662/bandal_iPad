import { createRecordingRepo } from '../features/recordings/recordingRepo'
import { openDatabase } from '../db/database'
import { scanMaterialTree } from '../features/materials/scanMaterialTree'
import { createSearchIndex } from '../features/search/searchIndex'
import type { BackgroundTasks } from './protocol'
import type { Database } from 'better-sqlite3'
let db: Database | null = null
let search: ReturnType<typeof createSearchIndex> | null = null
const folders = new Map<string, string>()
async function run<K extends keyof BackgroundTasks>(kind: K, input: BackgroundTasks[K]['input']): Promise<unknown> {
  if (kind === 'checkpoint') {
    const opened = openDatabase((input as BackgroundTasks['checkpoint']['input']).dbPath, false)
    try { opened.pragma('wal_checkpoint(PASSIVE)') } finally { opened.close() }
    return null
  }
  if (kind === 'migrate') {
    const opened = openDatabase((input as BackgroundTasks['migrate']['input']).dbPath)
    try {
      createRecordingRepo(opened, id => {
        const row = opened.prepare('SELECT folder_path FROM courses WHERE id = ? AND deleted_at IS NULL').get(id) as { folder_path: string } | undefined
        if (!row) throw new Error('과목을 찾을 수 없습니다.')
        return row.folder_path
      }).recover()
    } finally { opened.close() }
    return null
  }
  if (kind === 'scan') {
    const req = input as BackgroundTasks['scan']['input']
    return scanMaterialTree(req.folder, req.limits)
  }
  const req = input as BackgroundTasks['searchQuery']['input']
  folders.set(req.courseId, req.folder)
  db ??= openDatabase(req.dbPath, false)
  search ??= createSearchIndex(db, { getCourseFolder: id => folders.get(id)!, refreshOnQuery: false })
  if (kind === 'searchIndexPdf') {
    search.indexPdfPages(input as BackgroundTasks['searchIndexPdf']['input'])
    return null
  }
  if (kind === 'searchRefresh') { await search.refreshInBackground(req.courseId); return null }
  if (req.fresh) await search.refreshInBackground(req.courseId)
  return search.query(req.courseId, req.query, req.limit)
}
process.parentPort?.on('message', ({ data }: { data: { id: number; kind: keyof BackgroundTasks; input: BackgroundTasks[keyof BackgroundTasks]['input'] } }) => {
  void run(data.kind, data.input).then(
    value => process.parentPort?.postMessage({ id: data.id, value }),
    (error: unknown) => process.parentPort?.postMessage({ id: data.id, error: error instanceof Error ? error.message : String(error), code: (error as NodeJS.ErrnoException)?.code })
  )
})
