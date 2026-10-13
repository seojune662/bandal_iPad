import { app, dialog, Menu, type MenuItemConstructorOptions } from 'electron'
import { spawn, type ChildProcess } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, mkdirSync, openSync, writeSync, fsyncSync, closeSync, renameSync } from 'node:fs'
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { Database } from 'better-sqlite3'
import type { SupabaseClient } from '@supabase/supabase-js'
import { PDFDocument } from 'pdf-lib'
import { readSupabaseConfig } from '../account/config'

interface Dependencies {
  db: Database
  userDataPath: string
  getClient(): SupabaseClient | null
  changed(courseIds: string[]): void
}
let runtime: IPadCompanion | undefined
const AUTO_ID = 'ipad-companion-auto'

/** This menu is available without granting renderer/webview access to tokens. */
export function iPadCompanionMenu(): MenuItemConstructorOptions {
  const run = (action: (service: IPadCompanion) => Promise<void>): void => {
    if (!runtime) return
    void action(runtime).catch(error => dialog.showMessageBox({ type: 'error', title: 'iPad 연결',
      message: error instanceof Error ? error.message : '작업을 완료하지 못했습니다.' }))
  }
  return { label: 'iPad', submenu: [
    { label: 'iPad로 자료 내보내기…', click: () => run(service => service.exportPack()) },
    { label: 'iPad 자료 가져오기…', click: () => run(service => service.importPack()) },
    { type: 'separator' },
    { id: AUTO_ID, label: '계정으로 자동 동기화', type: 'checkbox', checked: runtime?.enabled ?? false,
      click: item => run(service => service.setEnabled(item.checked)) },
    { label: '지금 동기화', click: () => run(service => service.synchronize()) },
    { label: '동기화 상태', click: () => {
      void dialog.showMessageBox({ title: 'iPad 연결', message: runtime?.status ?? '준비 중입니다.' })
    } }
  ] }
}

export function installIPadCompanion(deps: Dependencies): { dispose(): void; pause(): void } {
  runtime?.dispose()
  runtime = new IPadCompanion(deps)
  return runtime
}

class IPadCompanion {
  enabled = false
  status = '자동 동기화 꺼짐'
  private child: ChildProcess | null = null
  private busy = false
  private generation = 0
  private readonly directory: string
  private readonly timer: ReturnType<typeof setInterval>
  private userID: string | null = null
  private boundUserID: string | null = null

  constructor(private readonly deps: Dependencies) {
    this.directory = join(deps.userDataPath, 'ipad-companion')
    try {
      const preferences = JSON.parse(readFileSync(join(this.directory, 'preferences.json'), 'utf8'))
      this.boundUserID = typeof preferences.boundUserID === 'string' ? preferences.boundUserID : null
      this.enabled = preferences.enabled === true && this.boundUserID !== null
    } catch { /* First launch; no automatic upload without an explicit account binding. */ }
    this.timer = setInterval(() => {
      if (this.enabled && !this.busy) void this.synchronize().catch(error => {
        this.status = error instanceof Error ? error.message : '동기화 대기 중'
      })
    }, 15_000)
    this.timer.unref()
    const menu = Menu.getApplicationMenu()?.getMenuItemById(AUTO_ID)
    if (menu) menu.checked = this.enabled
  }

  dispose(): void { clearInterval(this.timer); this.cancel() }
  pause(): void { this.cancel(); this.status = '로그인 후 동기화를 계속합니다.' }
  private cancel(): void { this.generation += 1; this.child?.kill(); this.child = null }

  async setEnabled(enabled: boolean): Promise<void> {
    if (enabled) await this.session()
    this.enabled = enabled
    if (!enabled) this.cancel()
    this.savePreferences()
    this.status = enabled ? '자동 동기화 대기 중' : '자동 동기화 꺼짐'
    if (enabled) await this.synchronize()
  }

  private savePreferences(): void {
    mkdirSync(this.directory, { recursive: true })
    const target = join(this.directory, 'preferences.json')
    const temporary = `${target}.partial`
    const descriptor = openSync(temporary, 'w', 0o600)
    try { writeSync(descriptor, JSON.stringify({ enabled: this.enabled, boundUserID: this.boundUserID })); fsyncSync(descriptor) }
    finally { closeSync(descriptor) }
    renameSync(temporary, target)
  }

  private async session(): Promise<{ userID: string; token: string }> {
    const client = this.deps.getClient()
    if (!client) throw new Error('설정에서 반달 계정에 로그인해 주세요.')
    const { data, error } = await client.auth.getSession()
    if (error || !data.session) throw new Error('설정에서 반달 계정에 로그인해 주세요.')
    if (this.boundUserID !== null && this.boundUserID !== data.session.user.id) {
      this.cancel()
      throw new Error('이 데스크톱 자료는 다른 반달 계정에 연결되어 있습니다. 기존 계정으로 로그인하거나 별도 데스크톱 프로필을 사용해 주세요.')
    }
    if (this.boundUserID === null) {
      this.boundUserID = data.session.user.id
      try { this.savePreferences() } catch (error) { this.boundUserID = null; throw error }
    }
    if (this.userID !== null && this.userID !== data.session.user.id) this.cancel()
    this.userID = data.session.user.id
    return { userID: data.session.user.id, token: data.session.access_token }
  }

  private exchangeFor(userID: string | null): string {
    return join(this.directory, userID ?? 'offline')
  }

  async exportPack(): Promise<void> {
    const result = await dialog.showSaveDialog({ title: 'iPad로 자료 내보내기', defaultPath: '반달 자료.bandalpack',
      filters: [{ name: '반달 자료', extensions: ['bandalpack'] }] })
    if (result.canceled || !result.filePath) return
    await this.perform('export', this.exchangeFor(null), ['--pack', result.filePath])
    this.status = '자료 패키지를 저장했습니다.'
  }

  async importPack(): Promise<void> {
    const result = await dialog.showOpenDialog({ title: 'iPad 자료 가져오기', properties: ['openFile'],
      filters: [{ name: '반달 자료', extensions: ['bandalpack'] }] })
    const file = result.filePaths[0]
    if (result.canceled || !file) return
    const exchange = this.exchangeFor(null)
    // Capture local baselines first; the importer refuses intervening edits.
    await this.perform('export', exchange)
    await this.perform('import', exchange, ['--pack', file])
    this.refresh(); this.status = 'iPad 자료를 가져왔습니다. 충돌 사본과 원본 백업은 기기에 보관됩니다.'
  }

  async synchronize(): Promise<void> {
    if (this.busy) return
    const session = await this.session()
    const config = readSupabaseConfig()
    if (!config) throw new Error('동기화 서버가 구성되지 않았습니다.')
    const expected = this.generation
    this.status = 'iPad와 동기화 중…'
    await this.perform('cycle', this.exchangeFor(session.userID), [], {
      BANDAL_SUPABASE_URL: config.url, BANDAL_SUPABASE_KEY: config.publishableKey,
      BANDAL_USER_ID: session.userID, BANDAL_ACCESS_TOKEN: session.token
    })
    if (expected !== this.generation) return
    this.refresh(); this.status = `동기화 완료 · ${new Date().toLocaleTimeString()}`
  }

  private refresh(): void {
    const ids = this.deps.db.prepare('SELECT id FROM courses WHERE deleted_at IS NULL').all() as { id: string }[]
    this.deps.changed(ids.map(row => row.id))
  }

  private async prepareGeometry(exchange: string): Promise<void> {
    await mkdir(exchange, { recursive: true })
    const courses = this.deps.db.prepare('SELECT folder_path FROM courses WHERE deleted_at IS NULL').all() as { folder_path: string }[]
    const visit = async (directory: string): Promise<void> => {
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        if (entry.name.startsWith('.') || entry.isSymbolicLink()) continue
        const path = join(directory, entry.name)
        if (entry.isDirectory()) { await visit(path); continue }
        if (!entry.isFile() || !entry.name.toLowerCase().endsWith('.pdf')) continue
        const bytes = await readFile(path)
        const hash = createHash('sha256').update(bytes).digest('hex')
        const target = join(exchange, `geometry-${hash}.json`)
        if (existsSync(target)) continue
        const pdf = await PDFDocument.load(bytes)
        const geometry = pdf.getPages().map(page => {
          const box = page.getCropBox()
          return { cropX: box.x, cropY: box.y, width: box.width, height: box.height,
            rotation: ((page.getRotation().angle % 360) + 360) % 360 }
        })
        await writeFile(target, JSON.stringify(geometry))
      }
    }
    for (const course of courses) await visit(course.folder_path)
  }

  private async perform(command: string, exchange: string, extra: string[] = [], environment: NodeJS.ProcessEnv = {}): Promise<void> {
    if (this.busy) throw new Error('이전 자료 작업이 완료될 때까지 기다려 주세요.')
    this.busy = true
    try {
      if (command !== 'import') await this.prepareGeometry(exchange)
      const projectorDirectory = app.isPackaged
        ? join(process.resourcesPath, 'ipad-bridge')
        : join(app.getAppPath(), 'resources', 'ipad-bridge')
      const projector = join(projectorDirectory, 'projector-host.cjs')
      const projectionBackend = join(projectorDirectory, 'backend.js')
      if (!existsSync(projector) || !existsSync(projectionBackend)) throw new Error('공통 동기화 변환기가 없습니다. 앱 설치 파일을 확인해 주세요.')
      const helper = process.env['BANDAL_IPAD_BRIDGE'] ?? (app.isPackaged
        ? join(process.resourcesPath, 'ipad-bridge', 'bridge.py')
        : join(app.getAppPath(), 'resources', 'ipad-bridge', 'bridge.py'))
      const bundledExecutable = join(process.resourcesPath, 'ipad-bridge', process.platform === 'win32' ? 'bandal-ipad-bridge.exe' : 'bandal-ipad-bridge')
      const executable = process.env['BANDAL_IPAD_BRIDGE_EXECUTABLE'] ?? (app.isPackaged ? bundledExecutable : undefined)
      if (executable && !existsSync(executable)) throw new Error('번들 iPad 동기화 도우미가 없습니다. 앱 설치 파일을 확인해 주세요.')
      if (!executable && !existsSync(helper)) throw new Error('iPad 동기화 도우미를 찾을 수 없습니다.')
      const args = [command, '--desktop-db', join(this.deps.userDataPath, 'bandal.db'),
        '--exchange', exchange, '--course-root', join(this.deps.userDataPath, 'iPad Courses'), ...extra]
      await new Promise<void>((resolve, reject) => {
        const child = spawn(executable ?? process.env['BANDAL_PYTHON'] ?? (process.platform === 'win32' ? 'python' : 'python3'),
          executable ? args : [helper, ...args], { windowsHide: true, env: { ...process.env, ...environment,
            BANDAL_DESKTOP_PROJECTOR: projector,
            BANDAL_DESKTOP_RUNTIME: process.execPath,
            BANDAL_DESKTOP_MODULE_ROOT: app.getAppPath(),
            BANDAL_DESKTOP_BACKEND: projectionBackend } })
        this.child = child
        let detail = ''
        child.stderr?.on('data', (chunk: Buffer) => { detail = (detail + chunk.toString()).slice(-2000) })
        // Consume progress without recording file contents, tokens, or personal paths.
        child.stdout?.resume()
        child.once('error', () => reject(new Error('동기화 도우미를 실행할 수 없습니다. 앱 설치 파일을 확인해 주세요.')))
        child.once('exit', code => {
          this.child = null
          if (code === 0) resolve()
          else reject(new Error(detail.trim() || '동기화가 중단되었습니다. 기기 자료와 대기 중인 변경은 보관됩니다.'))
        })
      })
    } finally { this.busy = false }
  }
}
