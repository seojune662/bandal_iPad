import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import type { CliModel } from '../claude/modelProbe'
import { probeExec } from '../platform'

const PROBE_TIMEOUT_MS = 10_000

export const CODEX_FALLBACK_MODELS: readonly CliModel[] = [
  { value: 'default', displayName: 'Codex 기본 모델' }
]

function defaultOption(configuredModel: string | null): CliModel {
  return {
    value: 'default',
    displayName: configuredModel === null
      ? 'Codex 기본 모델'
      : `기본 (${configuredModel})`
  }
}

export function parseCodexModelCatalog(
  json: string,
  configuredModel: string | null = null
): CliModel[] {
  let value: unknown
  try {
    value = JSON.parse(json)
  } catch {
    return [...CODEX_FALLBACK_MODELS]
  }
  if (typeof value !== 'object' || value === null) {
    return [...CODEX_FALLBACK_MODELS]
  }
  const entries = (value as Record<string, unknown>)['models']
  if (!Array.isArray(entries)) return [...CODEX_FALLBACK_MODELS]

  const models: CliModel[] = []
  for (const entry of entries) {
    if (typeof entry !== 'object' || entry === null) continue
    const model = entry as Record<string, unknown>
    if (
      model['visibility'] !== 'list' ||
      typeof model['slug'] !== 'string' ||
      typeof model['display_name'] !== 'string'
    ) {
      continue
    }
    const efforts = Array.isArray(model['supported_reasoning_levels'])
      ? model['supported_reasoning_levels'].flatMap((entry: unknown) => {
          if (typeof entry !== 'object' || entry === null) return []
          const effort = (entry as Record<string, unknown>)['effort']
          return typeof effort === 'string' && /^[a-z]+$/.test(effort) ? [effort] : []
        }) : []
    models.push({
      value: model['slug'],
      displayName: model['display_name'],
      ...(efforts.length > 0 ? { supportedEfforts: efforts } : {}),
      ...(typeof model['default_reasoning_level'] === 'string' ? { defaultEffort: model['default_reasoning_level'] } : {})
    })
  }
  if (models.length === 0) return [...CODEX_FALLBACK_MODELS]
  const configured = models.find((model) => model.value === configuredModel)
  return [{
    ...defaultOption(configuredModel),
    ...(configured?.supportedEfforts ? { supportedEfforts: configured.supportedEfforts } : {}),
    ...(configured?.defaultEffort ? { defaultEffort: configured.defaultEffort } : {})
  }, ...models]
}

function configuredModel(configPath: string): string | null {
  try {
    const config = readFileSync(configPath, 'utf8')
    return /^\s*model\s*=\s*["']([^"']+)["']/mu.exec(config)?.[1] ?? null
  } catch {
    return null
  }
}

interface CodexModelProbeOptions {
  binaryPath: string
  configPath?: string
  env?: NodeJS.ProcessEnv
  exec?: typeof probeExec
  cachePath?: string | null
}

export interface CodexModelDiscovery {
  models: CliModel[]
  source: 'live' | 'cache' | 'fallback'
  status: 'ready' | 'unverified' | 'unavailable'
  fetchedAt?: string
  cliVersion?: string
  error?: string
}

/** CLI refresh first; a local catalog remains explicitly unverified for this account. */
export async function discoverCodexModels(options: CodexModelProbeOptions): Promise<CodexModelDiscovery> {
  const configured = configuredModel(options.configPath ?? join(homedir(), '.codex', 'config.toml'))
  try {
    const { stdout } = await (options.exec ?? probeExec)(options.binaryPath, ['debug', 'models'], {
      timeoutMs: PROBE_TIMEOUT_MS, ...(options.env === undefined ? {} : { env: options.env })
    })
    const models = parseCodexModelCatalog(stdout, configured)
    if (models.some(model => model.value !== 'default')) return { models, source: 'live', status: 'ready', fetchedAt: new Date().toISOString() }
  } catch { /* Older CLIs and offline connections can still offer cached candidates. */ }
  if (options.cachePath !== null) {
    try {
      const raw = readFileSync(options.cachePath ?? join(homedir(), '.codex', 'models_cache.json'), 'utf8')
      const models = parseCodexModelCatalog(raw, configured)
      const metadata = JSON.parse(raw) as Record<string, unknown>
      if (models.some(model => model.value !== 'default')) return { models, source: 'cache', status: 'unverified',
        ...(typeof metadata['fetched_at'] === 'string' ? { fetchedAt: metadata['fetched_at'] } : {}),
        ...(typeof metadata['client_version'] === 'string' ? { cliVersion: metadata['client_version'] } : {}),
        error: '현재 연결에서 목록을 새로 받지 못했어요. 캐시의 모델은 이 계정에서 실행이 거절될 수 있어요.' }
    } catch { /* Missing/malformed cache is not a usable explicit model. */ }
  }
  return { models: [...CODEX_FALLBACK_MODELS], source: 'fallback', status: 'unavailable', error: '선택할 모델 목록을 받지 못했어요. 연결을 확인하고 목록을 새로고침하세요.' }
}

export async function probeCodexModels(
  options: CodexModelProbeOptions
): Promise<CliModel[]> {
  try {
    const { stdout } = await (options.exec ?? probeExec)(
      options.binaryPath,
      ['debug', 'models'],
      {
        timeoutMs: PROBE_TIMEOUT_MS,
        ...(options.env === undefined ? {} : { env: options.env })
      }
    )
    return parseCodexModelCatalog(
      stdout,
      configuredModel(options.configPath ?? join(homedir(), '.codex', 'config.toml'))
    )
  } catch {
    return [...CODEX_FALLBACK_MODELS]
  }
}
