import { randomUUID } from 'node:crypto'
import {
  accessSync,
  chmodSync,
  constants,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync
} from 'node:fs'
import { spawnSync } from 'node:child_process'
import { basename, extname, isAbsolute, join } from 'node:path'
import type {
  McpAvailability,
  McpServerConfig,
  McpServerInput,
  McpServerSummary,
  McpTestResult
} from '../../../shared/types/mcp'
import {
  MCP_RESERVED_NAMES,
  MCP_SERVER_NAME_PATTERN
} from '../../../shared/types/mcp'
import {
  augmentedPathEnv,
  isWindows,
  LOGIN_SHELL_PATH_ARGS,
  splitPath,
  stripShellBanner
} from '../agent/platform'
import { quarantineFile, writeFileAtomic } from '../../lib/atomicWrite'

export const MCP_REGISTRY_FILE_NAME = 'mcp-servers.enc'

const ENVELOPE_FORMAT = 'bandal-mcp-servers'
const ENVELOPE_VERSION = 1
const MAX_SERVERS = 20
const ENCRYPTION_UNAVAILABLE_REASON =
  'OS 보안 저장소를 사용할 수 없어 MCP 서버 저장 기능이 비활성화되었습니다.'
const REMOTE_HTTP_URL_REASON =
  '원격 MCP 서버는 https:// 주소여야 합니다. http:// 는 내 컴퓨터(localhost)에만 쓸 수 있습니다.'

export interface McpRegistryDeps {
  safeStorage: {
    isEncryptionAvailable(): boolean
    encryptString(s: string): Buffer
    decryptString(b: Buffer): string
  }
  userDataPath: string
  now?: () => Date
  commandExists?: (command: string) => boolean
}

export interface McpRegistry {
  availability(): McpAvailability
  list(): McpServerSummary[]
  /** main 전용 — 연결 테스트용 비밀값 포함. 활성화 여부와 무관. */
  resolve(id: string): McpServerConfig | undefined
  /** main 전용 — 비밀값 포함. enabled 만. */
  resolveEnabled(): McpServerConfig[]
  save(input: McpServerInput): McpServerSummary
  delete(id: string): void
  /** main 전용 source — 검사 도중 연결이 바뀌거나 삭제되면 기록하지 않는다. */
  recordTest(id: string, result: McpTestResult, source?: McpServerConfig): boolean
}

interface McpRegistryEnvelope {
  format: typeof ENVELOPE_FORMAT
  version: typeof ENVELOPE_VERSION
  servers: McpServerConfig[]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseStringArray(value: unknown, field: string): string[] | undefined {
  if (value === undefined) return undefined
  if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
    throw new TypeError(`Invalid MCP ${field}`)
  }
  return [...value]
}

function parseStringMap(
  value: unknown,
  field: string
): Record<string, string> | undefined {
  if (value === undefined) return undefined
  if (!isRecord(value)) throw new TypeError(`Invalid MCP ${field}`)
  const entries = Object.entries(value)
  if (entries.some(([, item]) => typeof item !== 'string')) {
    throw new TypeError(`Invalid MCP ${field}`)
  }
  return Object.fromEntries(entries) as Record<string, string>
}

function parseHttpUrl(value: string): URL | null {
  try {
    return new URL(value)
  } catch {
    return null
  }
}

function isLocalHttpHost(hostname: string): boolean {
  return hostname === 'localhost' ||
    hostname === '[::1]' ||
    hostname === '0.0.0.0' ||
    /^127(?:\.\d{1,3}){3}$/u.test(hostname)
}

function validStoredHttpUrl(value: string): boolean {
  const url = parseHttpUrl(value)
  return url !== null && (url.protocol === 'http:' || url.protocol === 'https:')
}

function validHttpUrl(value: string): boolean {
  const url = parseHttpUrl(value)
  if (url === null) return false
  return url.protocol === 'https:' ||
    (url.protocol === 'http:' && isLocalHttpHost(url.hostname))
}

function parseLastTest(value: unknown): McpServerConfig['lastTest'] {
  if (value === undefined) return undefined
  if (
    !isRecord(value) ||
    typeof value['at'] !== 'string' ||
    !Number.isFinite(Date.parse(value['at'])) ||
    typeof value['ok'] !== 'boolean' ||
    !Array.isArray(value['tools']) ||
    value['tools'].some((tool) => typeof tool !== 'string') ||
    (value['error'] !== undefined && typeof value['error'] !== 'string')
  ) {
    throw new TypeError('Invalid MCP test result')
  }
  return {
    at: value['at'],
    ok: value['ok'],
    tools: [...value['tools']] as string[],
    ...(typeof value['error'] === 'string' ? { error: value['error'] } : {})
  }
}

function parseServer(value: unknown): McpServerConfig {
  if (!isRecord(value)) throw new TypeError('Invalid MCP server')
  if (
    typeof value['id'] !== 'string' ||
    value['id'] === '' ||
    typeof value['name'] !== 'string' ||
    !MCP_SERVER_NAME_PATTERN.test(value['name']) ||
    MCP_RESERVED_NAMES.includes(
      value['name'] as (typeof MCP_RESERVED_NAMES)[number]
    ) ||
    typeof value['description'] !== 'string' ||
    (value['transport'] !== 'stdio' && value['transport'] !== 'http') ||
    typeof value['enabled'] !== 'boolean' ||
    typeof value['createdAt'] !== 'string' ||
    !Number.isFinite(Date.parse(value['createdAt'])) ||
    typeof value['updatedAt'] !== 'string' ||
    !Number.isFinite(Date.parse(value['updatedAt']))
  ) {
    throw new TypeError('Invalid MCP server')
  }

  const args = parseStringArray(value['args'], 'args')
  const env = parseStringMap(value['env'], 'env')
  const headers = parseStringMap(value['headers'], 'headers')
  const lastTest = parseLastTest(value['lastTest'])
  const command = value['command']
  const url = value['url']
  if (
    (command !== undefined && typeof command !== 'string') ||
    (url !== undefined && typeof url !== 'string') ||
    (value['transport'] === 'stdio' &&
      (typeof command !== 'string' || command.trim() === '')) ||
    (value['transport'] === 'http' &&
      (typeof url !== 'string' || !validStoredHttpUrl(url)))
  ) {
    throw new TypeError('Invalid MCP transport')
  }

  return {
    id: value['id'],
    name: value['name'],
    description: value['description'],
    transport: value['transport'],
    enabled: value['enabled'],
    createdAt: value['createdAt'],
    updatedAt: value['updatedAt'],
    ...(typeof command === 'string' ? { command } : {}),
    ...(args === undefined ? {} : { args }),
    ...(env === undefined ? {} : { env }),
    ...(typeof url === 'string' ? { url } : {}),
    ...(headers === undefined ? {} : { headers }),
    ...(lastTest === undefined ? {} : { lastTest })
  }
}

function parseEnvelope(plainText: string): McpServerConfig[] {
  const value: unknown = JSON.parse(plainText)
  if (
    !isRecord(value) ||
    value['format'] !== ENVELOPE_FORMAT ||
    value['version'] !== ENVELOPE_VERSION ||
    !Array.isArray(value['servers']) ||
    value['servers'].length > MAX_SERVERS
  ) {
    throw new TypeError('Invalid MCP registry file')
  }
  const servers = value['servers'].map(parseServer)
  if (
    new Set(servers.map((server) => server.id)).size !== servers.length ||
    new Set(servers.map((server) => server.name)).size !== servers.length
  ) {
    throw new TypeError('Duplicate MCP server')
  }
  return servers
}

function cloneConfig(config: McpServerConfig): McpServerConfig {
  return {
    ...config,
    ...(config.args === undefined ? {} : { args: [...config.args] }),
    ...(config.env === undefined ? {} : { env: { ...config.env } }),
    ...(config.headers === undefined ? {} : { headers: { ...config.headers } }),
    ...(config.lastTest === undefined
      ? {}
      : {
          lastTest: {
            ...config.lastTest,
            tools: [...config.lastTest.tools]
          }
        })
  }
}

function sameConnection(left: McpServerConfig, right: McpServerConfig): boolean {
  const sameMap = (
    first: Record<string, string> | undefined,
    second: Record<string, string> | undefined
  ): boolean => {
    const keys = Object.keys(first ?? {})
    return keys.length === Object.keys(second ?? {}).length &&
      keys.every((key) => first?.[key] === second?.[key])
  }
  const leftArgs = left.args ?? []
  const rightArgs = right.args ?? []
  return left.transport === right.transport &&
    left.command === right.command &&
    left.url === right.url &&
    leftArgs.length === rightArgs.length &&
    leftArgs.every((argument, index) => argument === rightArgs[index]) &&
    sameMap(left.env, right.env) && sameMap(left.headers, right.headers)
}

export function toSummary(config: McpServerConfig): McpServerSummary {
  const { env, headers, ...summary } = cloneConfig(config)
  return {
    ...summary,
    envKeys: Object.keys(env ?? {}).sort(),
    headerKeys: Object.keys(headers ?? {}).sort()
  }
}

function loginShellPath(): string | null {
  if (isWindows()) return process.env['PATH'] ?? process.env['Path'] ?? null
  const result = spawnSync('/bin/zsh', [...LOGIN_SHELL_PATH_ARGS], {
    encoding: 'utf8',
    windowsHide: true,
    timeout: 10_000
  })
  if (result.status === 0) {
    const value = stripShellBanner(result.stdout)
    if (value !== '') return value
  }
  return process.env['PATH'] ?? null
}

function executableCandidates(command: string): string[] {
  if (!isWindows() || extname(command) !== '') return [command]
  const extensions = (process.env['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD')
    .split(';')
    .filter((extension) => extension !== '')
  return [command, ...extensions.map((extension) => `${command}${extension}`)]
}

function canExecute(path: string): boolean {
  try {
    accessSync(path, constants.X_OK)
    return true
  } catch {
    return false
  }
}

function defaultCommandExists(command: string): boolean {
  if (
    isAbsolute(command) ||
    command.includes('/') ||
    command.includes('\\')
  ) {
    return executableCandidates(command).some(canExecute)
  }
  const probe = isWindows()
    ? 'C:\\Windows\\System32\\where.exe'
    : '/usr/bin/env'
  const env = augmentedPathEnv(probe, loginShellPath())
  return splitPath(env['PATH'] ?? '').some((directory) =>
    executableCandidates(command).some((candidate) =>
      canExecute(join(directory, candidate))
    )
  )
}

function inputStringMap(
  value: Record<string, string> | undefined,
  label: string
): Record<string, string> | undefined {
  if (value === undefined) return undefined
  if (
    !isRecord(value) ||
    Object.entries(value).some(
      ([key, item]) => key === '' || typeof item !== 'string'
    )
  ) {
    throw new Error(`${label} 형식이 올바르지 않습니다.`)
  }
  return { ...value }
}

function validateInput(
  input: McpServerInput,
  servers: McpServerConfig[],
  commandExists: (command: string) => boolean
): void {
  if (
    typeof input.name !== 'string' ||
    !MCP_SERVER_NAME_PATTERN.test(input.name)
  ) {
    throw new Error(
      '서버 이름은 영문 소문자, 숫자, 밑줄, 하이픈으로 1~32자여야 합니다.'
    )
  }
  if (
    MCP_RESERVED_NAMES.includes(
      input.name as (typeof MCP_RESERVED_NAMES)[number]
    )
  ) {
    throw new Error(`${input.name}은 예약된 서버 이름입니다.`)
  }
  if (
    servers.some(
      (server) => server.name === input.name && server.id !== input.id
    )
  ) {
    throw new Error('같은 이름의 MCP 서버가 이미 등록되어 있습니다.')
  }
  if (typeof input.description !== 'string' || typeof input.enabled !== 'boolean') {
    throw new Error('MCP 서버 설정 형식이 올바르지 않습니다.')
  }
  if (input.transport === 'stdio') {
    if (typeof input.command !== 'string' || input.command.trim() === '') {
      throw new Error('stdio 서버에는 실행 명령어가 필요합니다.')
    }
    if (!commandExists(input.command)) {
      throw new Error(
        `실행 명령어를 찾을 수 없거나 실행할 수 없습니다: ${input.command}`
      )
    }
    if (
      input.args !== undefined &&
      (!Array.isArray(input.args) ||
        input.args.some((argument) => typeof argument !== 'string'))
    ) {
      throw new Error('명령어 인자 형식이 올바르지 않습니다.')
    }
  } else if (input.transport === 'http') {
    if (typeof input.url !== 'string' || !validHttpUrl(input.url)) {
      throw new Error(REMOTE_HTTP_URL_REASON)
    }
  } else {
    throw new Error('지원하지 않는 MCP 전송 방식입니다.')
  }
  inputStringMap(input.env, '환경 변수')
  inputStringMap(input.headers, 'HTTP 헤더')
}

export function createMcpRegistry(deps: McpRegistryDeps): McpRegistry {
  const filePath = join(deps.userDataPath, MCP_REGISTRY_FILE_NAME)
  const now = deps.now ?? (() => new Date())
  const commandExists = deps.commandExists ?? defaultCommandExists
  let encryptionAvailable: boolean | undefined
  let cache: McpServerConfig[] | undefined
  let quarantineReason: string | null = null

  const canEncrypt = (): boolean => {
    if (encryptionAvailable === undefined) {
      try {
        encryptionAvailable = deps.safeStorage.isEncryptionAvailable()
      } catch {
        encryptionAvailable = false
      }
    }
    return encryptionAvailable
  }

  const discard = (): void => {
    try {
      rmSync(`${filePath}.tmp`, { force: true })
      rmSync(filePath, { force: true })
    } catch {
      // Do not report success while a restart would restore the server.
      throw new Error('MCP 서버 설정을 삭제하지 못했습니다.')
    }
  }

  const quarantine = (): string => {
    const quarantinePath = quarantineFile(filePath, now()) ?? filePath
    quarantineReason =
      `저장된 데이터를 읽지 못해 격리했습니다: ${basename(quarantinePath)}`
    return quarantinePath
  }

  const disableRemoteHttp = (
    servers: McpServerConfig[]
  ): McpServerConfig[] => servers.map((server) => {
    if (
      server.transport !== 'http' ||
      typeof server.url !== 'string' ||
      validHttpUrl(server.url)
    ) {
      return server
    }
    console.warn(`[mcp] 원격 http 서버 비활성화: ${server.name}`)
    return server.enabled ? { ...server, enabled: false } : server
  })

  const load = (): McpServerConfig[] => {
    if (cache !== undefined) return cache
    // Avoid opening the OS keychain on first launch when there is no file.
    if (!existsSync(filePath)) {
      cache = []
      return cache
    }
    if (!canEncrypt()) {
      cache = []
      return cache
    }
    try {
      cache = disableRemoteHttp(parseEnvelope(
        deps.safeStorage.decryptString(readFileSync(filePath))
      ))
    } catch {
      cache = []
      const quarantinePath = quarantine()
      console.warn(`[mcp] 복호화 실패 — 격리: ${quarantinePath}`)
    }
    return cache
  }

  const persist = (servers: McpServerConfig[]): void => {
    if (servers.length === 0) {
      discard()
      cache = []
      quarantineReason = null
      return
    }
    const envelope: McpRegistryEnvelope = {
      format: ENVELOPE_FORMAT,
      version: ENVELOPE_VERSION,
      servers
    }
    try {
      const encrypted = deps.safeStorage.encryptString(JSON.stringify(envelope))
      mkdirSync(deps.userDataPath, { recursive: true, mode: 0o700 })
      writeFileAtomic(filePath, encrypted, { mode: 0o600 })
      chmodSync(filePath, 0o600)
      cache = servers
      quarantineReason = null
    } catch {
      throw new Error('MCP 서버 설정을 안전하게 저장하지 못했습니다.')
    }
  }

  return {
    availability(): McpAvailability {
      if (
        quarantineReason === null &&
        cache === undefined &&
        existsSync(filePath) &&
        canEncrypt()
      ) {
        load()
      }
      return canEncrypt()
        ? { available: true, reason: quarantineReason }
        : { available: false, reason: ENCRYPTION_UNAVAILABLE_REASON }
    },

    list(): McpServerSummary[] {
      if (!existsSync(filePath) && cache === undefined) return []
      if (!canEncrypt()) return []
      return load()
        .map(toSummary)
        .sort((left, right) => left.name.localeCompare(right.name))
    },

    resolve(id: string): McpServerConfig | undefined {
      if (!existsSync(filePath) && cache === undefined) return undefined
      if (!canEncrypt()) return undefined
      const server = load().find((item) => item.id === id)
      return server === undefined ? undefined : cloneConfig(server)
    },

    resolveEnabled(): McpServerConfig[] {
      if (!existsSync(filePath) && cache === undefined) return []
      if (!canEncrypt()) return []
      return load()
        .filter((server) => server.enabled)
        .map(cloneConfig)
        .sort((left, right) => left.name.localeCompare(right.name))
    },

    save(input: McpServerInput): McpServerSummary {
      if (!canEncrypt()) throw new Error(ENCRYPTION_UNAVAILABLE_REASON)
      const current = load()
      const existing = input.id === undefined
        ? undefined
        : current.find((server) => server.id === input.id)
      if (input.id !== undefined && existing === undefined) {
        throw new Error('수정할 MCP 서버를 찾을 수 없습니다.')
      }
      if (existing === undefined && current.length >= MAX_SERVERS) {
        throw new Error(`MCP 서버는 최대 ${MAX_SERVERS}개까지 등록할 수 있습니다.`)
      }
      validateInput(input, current, commandExists)

      const timestamp = now().toISOString()
      const env = input.env === undefined
        ? existing?.env
        : inputStringMap(input.env, '환경 변수')
      const headers = input.headers === undefined
        ? existing?.headers
        : inputStringMap(input.headers, 'HTTP 헤더')
      const server: McpServerConfig = {
        id: existing?.id ?? randomUUID(),
        name: input.name,
        description: input.description,
        transport: input.transport,
        enabled: input.enabled,
        createdAt: existing?.createdAt ?? timestamp,
        updatedAt: timestamp,
        ...(input.transport === 'stdio'
          ? {
              command: input.command as string,
              ...(input.args === undefined ? {} : { args: [...input.args] })
            }
          : { url: input.url as string }),
        ...(env === undefined ? {} : { env }),
        ...(headers === undefined ? {} : { headers })
      }
      if (existing?.lastTest !== undefined && sameConnection(existing, server)) {
        server.lastTest = { ...existing.lastTest, tools: [...existing.lastTest.tools] }
      }
      persist([
        ...current.filter((item) => item.id !== server.id),
        server
      ])
      return toSummary(server)
    },

    delete(id: string): void {
      if (!existsSync(filePath) && cache === undefined) return
      const current = load()
      const next = current.filter((server) => server.id !== id)
      if (next.length !== current.length) persist(next)
    },

    recordTest(id: string, result: McpTestResult, source?: McpServerConfig): boolean {
      if (!canEncrypt()) throw new Error(ENCRYPTION_UNAVAILABLE_REASON)
      const current = load()
      const existing = current.find((server) => server.id === id)
      if (existing === undefined) {
        if (source !== undefined) return false
        throw new Error('테스트 결과를 기록할 MCP 서버를 찾을 수 없습니다.')
      }
      if (source !== undefined && (source.id !== id || !sameConnection(source, existing))) {
        return false
      }
      const timestamp = now().toISOString()
      const updated: McpServerConfig = {
        ...existing,
        updatedAt: timestamp,
        lastTest: {
          at: timestamp,
          ok: result.ok,
          tools: [...result.tools],
          ...(result.error === undefined ? {} : { error: result.error })
        }
      }
      persist([
        ...current.filter((server) => server.id !== id),
        updated
      ])
      return true
    }
  }
}
