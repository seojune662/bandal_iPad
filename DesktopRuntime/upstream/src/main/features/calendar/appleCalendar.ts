import { app } from 'electron'
import { spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeFileAtomic } from '../../lib/atomicWrite'
import { createAppleCalendarService, type CalendarNative } from './appleCalendarService'
import type { BoardRepo } from '../board/boardRepo'

/** Async child process keeps EventKit/TCC off Electron's main thread. */
function nativeRequest<T>(request: Record<string, unknown>): Promise<T> {
  const executable = app.isPackaged
    ? join(process.resourcesPath, 'calendar/bandal-calendar')
    : join(app.getAppPath(), 'resources/native/calendar', process.arch, 'bandal-calendar')
  return new Promise((resolve, reject) => {
    const child = spawn(executable, [], { stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = '', stderr = ''
    const timer = setTimeout(() => { child.kill(); reject(new Error('캘린더 응답을 기다리는 시간이 초과되었습니다. 권한 설정을 확인하고 다시 시도해주세요.')) }, request.command === 'connect' ? 180000 : 20000)
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      stdout += chunk
      if (stdout.length > 8 * 1024 * 1024) { child.kill(); reject(new Error('캘린더 응답이 너무 큽니다. 선택한 캘린더 수를 줄여주세요.')) }
    })
    child.stderr.on('data', (chunk: string) => { stderr = (stderr + chunk).slice(-2000) })
    child.on('error', () => { clearTimeout(timer); reject(new Error('Apple 캘린더 연결 도구를 실행하지 못했습니다. 앱을 업데이트하고 다시 시도해주세요.')) })
    child.on('close', code => {
      clearTimeout(timer)
      if (code !== 0) { reject(new Error(`Apple 캘린더에 연결하지 못했습니다.${stderr ? ' macOS의 캘린더 접근 권한을 확인해주세요.' : ''}`)); return }
      try {
        const result = JSON.parse(stdout) as T & { error?: string }
        if (result.error) reject(new Error(result.error))
        else resolve(result)
      } catch { reject(new Error('Apple 캘린더 응답을 읽지 못했습니다.')) }
    })
    child.stdin.on('error', () => {}) // Spawn failure is reported by the child error handler.
    child.stdin.end(JSON.stringify(request))
  })
}

export function createAppleCalendar(board: BoardRepo, changed: () => void) {
  const file = join(app.getPath('userData'), 'apple-calendar.json')
  const native: CalendarNative = {
    state: (connect, includeCalendars) => nativeRequest({ command: connect ? 'connect' : 'status', includeCalendars }),
    events: input => nativeRequest({ command: 'events', ...input }),
    export: input => nativeRequest({ command: 'export', ...input })
  }
  return createAppleCalendarService({
    supported: process.platform === 'darwin', native, changed,
    load: () => { if (!existsSync(file)) return {}; try { return JSON.parse(readFileSync(file, 'utf8')) as unknown } catch { return {} } },
    save: config => writeFileAtomic(file, JSON.stringify(config)),
    task: id => board.list({ includeDone: true }).find(task => task.id === id)
  })
}
