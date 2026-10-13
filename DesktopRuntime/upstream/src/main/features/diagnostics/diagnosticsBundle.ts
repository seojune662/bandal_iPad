import { promises as fs } from 'node:fs'
import { join } from 'node:path'
import { AGENT_PROVIDERS } from '../../../shared/types/agent-events'
import type {
  AgentAvailability,
  AgentProvider
} from '../../../shared/types/agent-events'
import type { DiagnosticsBundle } from '../../../shared/types/permissions'
import type { PluginLogEntry, PluginSummary } from '../../../shared/types/plugin'
import type { Settings } from '../../../shared/types/settings'

const MAX_BUNDLE_BYTES = 2 * 1024 * 1024
const MAX_LOG_READ_BYTES = 2 * 1024 * 1024
const APP_LOG_SECTION_BYTES = 1024 * 1024
const LOG_LINES = 200
const REDACTED = '[가림]'
const CONTENTS = [
  '앱 및 시스템',
  '설정 스냅샷',
  'AI 제공자 가용성',
  '설치된 플러그인',
  '최근 플러그인 로그',
  '앱 로그'
] as const

interface DiagnosticsDeps {
  tempDir(): string
  now(): Date
  appVersion(): string
  electronVersion(): string
  platform: NodeJS.Platform
  osVersion(): string
  getSettings(): Settings
  getAgentAvailability(provider: AgentProvider): Promise<AgentAvailability>
  getPlugins(): PluginSummary[]
  getPluginLogs(): PluginLogEntry[]
  logsPath(): string
  reveal(path: string): void
}

const EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/giu
const URL_TOKEN = /([?&](?:(?:(?:access|refresh|id)[_-]?)?token|api[_-]?key|code|password|secret)=)[^&#\s"']+/giu
const BEARER_TOKEN = /\bBearer\s+[^\s"']+/giu
const SENSITIVE_KEY = /(?:e-?mail|token|secret|password|authorization|api[_-]?key)/iu
const JSON_SECRET = /("(?:access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|password|secret|authorization)"\s*:\s*")[^"\r\n]*/giu

function redactString(value: string): string {
  return value
    .replace(EMAIL, REDACTED)
    .replace(URL_TOKEN, `$1${REDACTED}`)
    .replace(BEARER_TOKEN, `Bearer ${REDACTED}`)
    .replace(JSON_SECRET, `$1${REDACTED}`)
}

function redactDataRoot(value: string): string {
  const leaf = value.replaceAll('\\', '/').split('/').filter(Boolean).at(-1)
  return `~/…/${redactString(leaf ?? '데이터')}`
}

function redactValue(value: unknown, path: readonly string[]): unknown {
  const key = path.at(-1) ?? ''
  if (key === 'dataRoot' && typeof value === 'string') {
    return redactDataRoot(value)
  }
  if (path.length === 2 && path[0] === 'notifications' && key === 'sent') {
    return typeof value === 'object' && value !== null
      ? Object.keys(value).length
      : 0
  }
  if (SENSITIVE_KEY.test(key)) return REDACTED
  if (typeof value === 'string') return redactString(value)
  if (Array.isArray(value)) {
    return value.map((item, index) => redactValue(item, [...path, String(index)]))
  }
  if (typeof value !== 'object' || value === null) return value
  return Object.fromEntries(
    Object.entries(value).map(([childKey, child]) => [
      childKey,
      redactValue(child, [...path, childKey])
    ])
  )
}

export function redactSettingsSnapshot(settings: unknown): unknown {
  return redactValue(settings, [])
}

function formatStamp(date: Date): string {
  const part = (value: number): string => String(value).padStart(2, '0')
  return [
    date.getFullYear(),
    part(date.getMonth() + 1),
    part(date.getDate()),
    '-',
    part(date.getHours()),
    part(date.getMinutes())
  ].join('')
}

function lastLines(text: string): string {
  const lines = text.replaceAll('\r\n', '\n').split('\n')
  if (lines.at(-1) === '') lines.pop()
  return lines.slice(-LOG_LINES).join('\n')
}

function truncateUtf8(text: string, maxBytes: number): string {
  const bytes = Buffer.from(text)
  if (bytes.length <= maxBytes) return text
  let end = maxBytes
  while (end > 0 && (bytes[end] ?? 0) >> 6 === 2) end -= 1
  return bytes.subarray(0, end).toString('utf8')
}

function truncateUtf8Tail(text: string, maxBytes: number): string {
  const bytes = Buffer.from(text)
  if (bytes.length <= maxBytes) return text
  const notice = '[파일 할당량에 따라 앞부분 생략]\n'
  const contentBytes = Math.max(0, maxBytes - Buffer.byteLength(notice))
  let start = bytes.length - contentBytes
  while (start < bytes.length && (bytes[start] ?? 0) >> 6 === 2) start += 1
  return `${notice}${bytes.subarray(start).toString('utf8')}`
}

async function readLogTail(path: string): Promise<string | null> {
  const handle = await fs.open(path, 'r')
  try {
    const stats = await handle.stat()
    const length = Math.min(stats.size, MAX_LOG_READ_BYTES)
    const buffer = Buffer.alloc(length)
    const start = Math.max(0, stats.size - length)
    let bytesRead = 0
    while (bytesRead < length) {
      const read = await handle.read(
        buffer,
        bytesRead,
        length - bytesRead,
        start + bytesRead
      )
      if (read.bytesRead === 0) break
      bytesRead += read.bytesRead
    }
    const content = buffer.subarray(0, bytesRead)
    if (content.includes(0)) return null
    let text = content.toString('utf8')
    if (start > 0) {
      const firstBreak = text.indexOf('\n')
      text =
        firstBreak < 0
          ? `[긴 로그 줄 앞부분 생략]\n${text}`
          : text.slice(firstBreak + 1)
    }
    return lastLines(text)
  } finally {
    await handle.close()
  }
}

function agentLine(
  provider: AgentProvider,
  availability: AgentAvailability
): string {
  return JSON.stringify({
    provider,
    installed: availability.installed,
    ...(availability.version === undefined
      ? {}
      : { version: availability.version }),
    loggedIn: availability.loggedIn
  })
}

async function agentSection(deps: DiagnosticsDeps): Promise<string> {
  const lines: string[] = []
  for (const provider of AGENT_PROVIDERS) {
    try {
      lines.push(agentLine(provider, await deps.getAgentAvailability(provider)))
    } catch {
      lines.push(
        JSON.stringify({ provider, installed: false, loggedIn: false })
      )
    }
  }
  return lines.join('\n')
}

function pluginSection(plugins: PluginSummary[]): string {
  return JSON.stringify(
    plugins.map((plugin) => ({
      id: plugin.manifest.id,
      version: plugin.manifest.version,
      state: plugin.state
    })),
    null,
    2
  )
}

function pluginLogSection(entries: PluginLogEntry[]): string {
  return entries
    .slice(-LOG_LINES)
    .map((entry) =>
      JSON.stringify({
        at: entry.at,
        pluginId: entry.pluginId,
        level: entry.level,
        message: redactString(entry.message)
      })
    )
    .join('\n')
}

async function appLogSection(logsPath: string): Promise<string> {
  let entries
  try {
    entries = await fs.readdir(logsPath, { withFileTypes: true })
  } catch {
    return '로그 폴더를 읽을 수 없음'
  }
  const files = entries.filter((entry) => entry.isFile()).sort((a, b) =>
    a.name.localeCompare(b.name)
  )
  if (files.length === 0) return '텍스트 로그 없음'
  const perFileBytes = Math.max(
    1024,
    Math.floor(APP_LOG_SECTION_BYTES / files.length)
  )
  const sections: string[] = []
  for (const file of files) {
    try {
      const tail = await readLogTail(join(logsPath, file.name))
      if (tail === null) continue
      // ponytail: 각 파일 몫을 넘는 단일/다수 장문 로그는 잘라냄, 역방향 줄 스트리머로 확장 가능.
      sections.push(`### ${file.name}\n${truncateUtf8Tail(tail, perFileBytes)}`)
    } catch {
      sections.push(`### ${file.name}\n읽기 실패`)
    }
  }
  return sections.length === 0 ? '텍스트 로그 없음' : sections.join('\n\n')
}

function section(title: string, body: string): string {
  return `## ${title}\n${body}`
}

function boundBundle(content: string): string {
  const notice = '\n\n[2MB 상한에 따라 나머지 내용 생략]\n'
  if (Buffer.byteLength(content) <= MAX_BUNDLE_BYTES) return content
  return `${truncateUtf8(
    content,
    MAX_BUNDLE_BYTES - Buffer.byteLength(notice)
  )}${notice}`
}

export function createDiagnosticsBundle(deps: DiagnosticsDeps) {
  return async function writeBundle(): Promise<DiagnosticsBundle> {
    const now = deps.now()
    const directory = join(
      deps.tempDir(),
      `bandal-diagnostics-${formatStamp(now)}`
    )
    const path = join(directory, 'bandal-diagnostics.txt')
    const system = [
      `앱 버전: ${deps.appVersion()}`,
      `Electron: ${deps.electronVersion()}`,
      `플랫폼: ${deps.platform}`,
      `OS 버전: ${deps.osVersion()}`
    ].join('\n')
    const content = boundBundle(
      redactString([
        '# 반달 진단 정보',
        `생성 시각: ${now.toISOString()}`,
        section(CONTENTS[0], system),
        section(
          CONTENTS[1],
          JSON.stringify(redactSettingsSnapshot(deps.getSettings()), null, 2)
        ),
        section(CONTENTS[2], await agentSection(deps)),
        section(CONTENTS[3], pluginSection(deps.getPlugins())),
        section(CONTENTS[4], pluginLogSection(deps.getPluginLogs())),
        section(CONTENTS[5], await appLogSection(deps.logsPath()))
      ].join('\n\n'))
    )
    await fs.mkdir(directory, { recursive: true, mode: 0o700 })
    await fs.writeFile(path, content, { encoding: 'utf8', mode: 0o600 })
    deps.reveal(path)
    return { path, bytes: Buffer.byteLength(content), contents: [...CONTENTS] }
  }
}
