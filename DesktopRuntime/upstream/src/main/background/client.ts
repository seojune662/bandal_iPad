import { app, utilityProcess, type UtilityProcess } from 'electron'
import { join } from 'node:path'
import type { BackgroundTasks } from './protocol'

type Job = { id: number; kind: keyof BackgroundTasks; input: unknown; priority: number; resolve: (value: never) => void; reject: (error: Error) => void }

/** One bounded background lane. Interactive requests jump ahead of queued
 * refreshes; a hung filesystem cannot block the Electron event loop. */
export function createBackgroundClient() {
  let child: UtilityProcess | null = null
  let seq = 0
  let running: Job | null = null
  let timer: NodeJS.Timeout | null = null
  let stopped = false
  const queue: Job[] = []
  const fail = (message: string): void => {
    if (timer) clearTimeout(timer)
    timer = null
    const old = child
    child = null
    running?.reject(new Error(message))
    running = null
    for (const job of queue.splice(0)) job.reject(new Error(message))
    old?.kill()
  }
  const pump = (): void => {
    if (running || stopped || !queue.length) return
    try {
      if (!child) {
        const process = utilityProcess.fork(join(__dirname, 'backgroundHost.js'), [], { serviceName: 'Bandal Background', stdio: 'pipe' })
        child = process
        process.stdout?.on('data', () => undefined)
        process.stderr?.on('data', () => undefined)
        process.on('exit', () => { if (child === process) fail('자료 준비 프로세스가 종료됐습니다. 다시 시도해 주세요.') })
        process.on('message', (message: { id: number; value?: never; error?: string; code?: string }) => {
          if (child !== process || running?.id !== message.id) return
          const job = running
          running = null
          if (timer) clearTimeout(timer)
          timer = null
          if (message.error) job.reject(Object.assign(new Error(message.error), { code: message.code }))
          else job.resolve(message.value as never)
          pump()
        })
      }
      queue.sort((a, b) => a.priority - b.priority || b.id - a.id)
      running = queue.shift()!
      timer = setTimeout(() => fail('자료 준비 시간이 초과됐습니다. 폴더 연결을 확인해 주세요.'), 60_000)
      child.postMessage({ id: running.id, kind: running.kind, input: running.input })
    } catch (error) {
      fail(error instanceof Error ? error.message : String(error))
    }
  }
  const dispose = (): void => { stopped = true; fail('앱이 종료되었습니다.') }
  app.once('will-quit', dispose)
  return {
    request<K extends keyof BackgroundTasks>(kind: K, input: BackgroundTasks[K]['input'], priority = 1): Promise<BackgroundTasks[K]['output']> {
      if (stopped) return Promise.reject(new Error('앱이 종료되었습니다.'))
      return new Promise((resolve, reject) => { queue.push({ id: ++seq, kind, input, priority, resolve, reject }); pump() })
    },
    dispose
  }
}
