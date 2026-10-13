import { app, utilityProcess, type UtilityProcess } from 'electron'
import { join } from 'node:path'
import type { MaterialChanges, MaterialsWatcher, MaterialsWatcherDeps } from '../features/materials/watcher'

/** Chokidar's initial walk and event bursts stay outside Electron's main loop. */
export function createBackgroundMaterialsWatcher(deps: MaterialsWatcherDeps): MaterialsWatcher {
  const folders = new Map<string, string>()
  const paused = new Map<string, { count: number; ready: Promise<void> }>()
  const retiring = new Set<UtilityProcess>()
  const pending = new Map<number, { child: UtilityProcess; timer: NodeJS.Timeout; resolve: () => void; reject: (error: Error) => void }>()
  let sequence = 0
  let child: UtilityProcess | null = null
  let retry: NodeJS.Timeout | null = null
  let stopped = false
  const rejectPending = (process: UtilityProcess, error: Error): void => {
    for (const [id, request] of pending) {
      if (request.child !== process) continue
      pending.delete(id)
      clearTimeout(request.timer)
      request.reject(error)
    }
  }
  const restart = (): void => {
    if (stopped || retry || !folders.size) return
    retry = setTimeout(() => { retry = null; start() }, 1000)
    retry.unref()
  }
  const unavailable = (process: UtilityProcess, error: Error): void => {
    if (child === process) child = null
    rejectPending(process, error)
    retiring.add(process)
    process.kill()
  }
  const start = (): void => {
    if (child || retiring.size || stopped || !folders.size) return
    try {
      const process = utilityProcess.fork(join(__dirname, 'watcherHost.js'), [], { serviceName: 'Bandal File Watcher', stdio: 'pipe' })
      child = process
      process.stdout?.on('data', () => undefined)
      process.stderr?.on('data', () => undefined)
      process.on('exit', () => {
        retiring.delete(process)
        rejectPending(process, new Error('자료 감시 프로세스가 종료되어 폴더 변경을 중단했습니다. 다시 시도해 주세요.'))
        if (child === process) child = null
        restart()
      })
      process.on('message', (message: (MaterialChanges & { courseId: string; folder: string }) | { requestId: number; error?: string }) => {
        if (child !== process) return
        if ('requestId' in message) {
          const request = pending.get(message.requestId)
          if (!request || request.child !== process) return
          pending.delete(message.requestId)
          clearTimeout(request.timer)
          if (message.error) {
            const error = new Error(message.error)
            request.reject(error)
            unavailable(process, error)
          } else request.resolve()
          return
        }
        if (paused.has(message.courseId) || !folders.has(message.courseId) || folders.get(message.courseId) !== message.folder) return
        if (message.structural || message.paths.some(path => !deps.ignoreContentChange?.(message.courseId, path))) {
          deps.onChange(message.courseId, message)
        }
      })
      for (const [courseId, folder] of folders) {
        if (!paused.has(courseId)) process.postMessage({ action: 'watch', courseId, folder })
      }
    } catch (error) {
      const failed = child
      if (failed) unavailable(failed, new Error('자료 감시 프로세스를 시작할 수 없습니다.'))
      else restart()
      console.warn('[materials] watcher process unavailable', error)
    }
  }
  const send = (action: 'watch' | 'unwatch', courseId: string, folder?: string): void => {
    if (!child) { start(); return }
    try { child.postMessage({ action, courseId, folder }) }
    catch {
      const failed = child
      unavailable(failed, new Error('자료 감시 프로세스에 연결할 수 없습니다.'))
    }
  }
  const control = (action: 'pause' | 'resume', courseId: string): Promise<void> => {
    if (!child) start()
    const process = child
    if (!process) return Promise.reject(new Error('자료 감시 프로세스를 시작할 수 없습니다.'))
    return new Promise<void>((resolve, reject) => {
      const requestId = ++sequence
      const timer = setTimeout(() => {
        unavailable(process, new Error('자료 감시 핸들 해제를 확인하지 못해 폴더 변경을 중단했습니다. 다시 시도해 주세요.'))
      }, 5000)
      pending.set(requestId, { child: process, timer, resolve, reject })
      try { process.postMessage({ action, courseId, folder: folders.get(courseId), requestId }) }
      catch (error) {
        unavailable(process, error instanceof Error ? error : new Error(String(error)))
      }
    })
  }
  const dispose = (): void => {
    stopped = true
    folders.clear()
    if (retry) clearTimeout(retry)
    const old = child
    child = null
    if (old) rejectPending(old, new Error('앱이 종료되었습니다.'))
    old?.kill()
  }
  app.once('will-quit', dispose)
  return {
    watch(courseId) {
      if (stopped) return
      let folder: string
      try { folder = deps.getCourseFolder(courseId) } catch { return }
      if (folders.get(courseId) === folder) return
      folders.set(courseId, folder)
      if (!paused.has(courseId)) send('watch', courseId, folder)
    },
    unwatch(courseId) { if (folders.delete(courseId)) send('unwatch', courseId) },
    async pause(courseId) {
      if (stopped) throw new Error('앱이 종료되었습니다.')
      if (retiring.size) throw new Error('자료 감시 프로세스의 종료를 기다리고 있습니다. 잠시 후 다시 시도해 주세요.')
      let state = paused.get(courseId)
      if (!state) {
        state = { count: 0, ready: Promise.resolve() }
        paused.set(courseId, state)
        // With no worker there are no native handles to release. A future
        // restart excludes every paused course from its initial watch list.
        if (child) state.ready = control('pause', courseId)
      }
      state.count += 1
      try { await state.ready } catch (error) {
        if (--state.count === 0) {
          paused.delete(courseId)
          // A delayed close ACK must still be followed by restoration.
          if (!stopped && (child || folders.has(courseId))) {
            void control('resume', courseId).catch(restoreError => console.warn(`[materials] watcher restoration failed for ${courseId}:`, restoreError))
          }
        }
        throw error
      }
      let resumed = false
      return async () => {
        if (resumed) return
        resumed = true
        if (--state.count > 0) return
        paused.delete(courseId)
        if (stopped) return
        if (!child && !folders.has(courseId)) return
        await control('resume', courseId)
      }
    },
    dispose
  }
}
