import { createMaterialsWatcher } from '../features/materials/watcher'
const folders = new Map<string, string>()
const notify = (courseId: string, changes: { structural: boolean; paths: string[] }): void => {
  process.parentPort?.postMessage({ courseId, folder: folders.get(courseId), ...changes })
}
const watcher = createMaterialsWatcher({
  getCourseFolder: id => folders.get(id)!,
  onChange: notify,
  onReady: id => notify(id, { structural: true, paths: [] })
})
const resumes = new Map<string, () => Promise<void>>()
type Command = { action: 'watch' | 'unwatch' | 'pause' | 'resume'; courseId: string; folder?: string; requestId?: number }
async function command(data: Command): Promise<void> {
  if (data.action === 'unwatch') { watcher.unwatch(data.courseId); folders.delete(data.courseId); return }
  if (data.action === 'pause') {
    if (!resumes.has(data.courseId)) resumes.set(data.courseId, await watcher.pause(data.courseId))
    return
  }
  if (data.folder) {
    if (folders.get(data.courseId) !== data.folder) watcher.unwatch(data.courseId)
    folders.set(data.courseId, data.folder)
    watcher.watch(data.courseId)
  }
  if (data.action === 'resume') {
    const resume = resumes.get(data.courseId)
    resumes.delete(data.courseId)
    await resume?.()
  }
}
// A pause ACK must follow all earlier watch/unwatch commands and actual close.
let commands = Promise.resolve()
process.parentPort?.on('message', ({ data }: { data: Command }) => {
  commands = commands.then(async () => {
    try {
      await command(data)
      if (data.requestId !== undefined) process.parentPort?.postMessage({ requestId: data.requestId })
    } catch (error) {
      if (data.requestId !== undefined) process.parentPort?.postMessage({ requestId: data.requestId, error: error instanceof Error ? error.message : String(error) })
      else console.warn('[materials] watcher command failed', error)
    }
  })
})
