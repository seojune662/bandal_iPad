/**
 * Model discovery via the CLI's `list_models` control_request (Orca pattern,
 * MIT — stablyai/orca `src/shared/claude-model-list-probe.ts`; reimplemented
 * here against the verified 2.1.222 wire). One-shot process: spawn, ask,
 * parse, kill. Older CLIs answer with an error → static fallback.
 */

import { createInterface, type Interface } from 'node:readline'
import { tmpdir } from 'node:os'
import { killProcessTree, spawnClaude } from '../platform'

const PROBE_TIMEOUT_MS = 10_000
const PROBE_REQUEST_ID = 'bandal-list-models'

export interface CliModel {
  value: string
  displayName: string
  description?: string
  resolvedModel?: string
  supportedEfforts?: string[]
  defaultEffort?: string
}

export const FALLBACK_MODELS: CliModel[] = [
  { value: 'default', displayName: 'Default (recommended)' },
  { value: 'opus', displayName: 'Opus' },
  { value: 'sonnet', displayName: 'Sonnet' },
  { value: 'haiku', displayName: 'Haiku' }
]

function parseModels(value: unknown): CliModel[] | null {
  if (typeof value !== 'object' || value === null) {
    return null
  }
  const outer = value as Record<string, unknown>
  if (outer['type'] !== 'control_response') {
    return null
  }
  const response = outer['response'] as Record<string, unknown> | undefined
  if (
    response === undefined ||
    response['request_id'] !== PROBE_REQUEST_ID ||
    response['subtype'] !== 'success'
  ) {
    return null
  }
  const inner = response['response'] as Record<string, unknown> | undefined
  const models = inner?.['models']
  if (!Array.isArray(models)) {
    return null
  }
  const parsed: CliModel[] = []
  for (const entry of models) {
    const record = entry as Record<string, unknown>
    if (typeof record['value'] !== 'string') {
      continue
    }
    const model: CliModel = {
      value: record['value'],
      displayName:
        typeof record['displayName'] === 'string'
          ? record['displayName']
          : record['value']
    }
    if (typeof record['description'] === 'string') {
      model.description = record['description']
    }
    if (typeof record['resolvedModel'] === 'string') model.resolvedModel = record['resolvedModel']
    if (record['supportsEffort'] === true && Array.isArray(record['supportedEffortLevels'])) {
      model.supportedEfforts = record['supportedEffortLevels'].filter((level): level is string => typeof level === 'string' && /^[a-z]+$/.test(level))
    }
    parsed.push(model)
  }
  return parsed.length > 0 ? parsed : null
}

export interface ModelProbeOptions {
  binaryPath: string
  cwd?: string
  timeoutMs?: number
  spawnImpl?: typeof spawnClaude
  env?: NodeJS.ProcessEnv
}

/** Lists the models the user's CLI offers; falls back to a static list. */
export async function probeModels(opts: ModelProbeOptions): Promise<CliModel[]> {
  const spawnImpl = opts.spawnImpl ?? spawnClaude
  const env = { ...(opts.env ?? process.env) }
  delete env['CLAUDECODE']
  delete env['CLAUDE_CODE_ENTRYPOINT']

  return new Promise<CliModel[]>((resolve) => {
    let settled = false
    let reader: Interface | null = null
    let timer: ReturnType<typeof setTimeout> | undefined
    const finish = (models: CliModel[]): void => {
      if (!settled) {
        settled = true
        clearTimeout(timer)
        reader?.close()
        child.stdin?.end()
        // Tree kill, not `child.kill()`: on Windows the direct child is the
        // `cmd.exe` shim, and killing it would orphan the real CLI process.
        if (child.pid !== undefined) {
          killProcessTree(child.pid, 'SIGKILL')
        }
        resolve(models)
      }
    }

    let child: ReturnType<typeof spawnClaude>
    try {
      child = spawnImpl(
        opts.binaryPath,
        [
          '-p',
          '--input-format',
          'stream-json',
          '--output-format',
          'stream-json',
          '--setting-sources',
          'user',
          '--disable-slash-commands',
          '--verbose'
        ],
        {
          cwd: opts.cwd ?? tmpdir(),
          env,
          stdio: ['pipe', 'pipe', 'ignore'],
          // Teardown signals the entire group, including native/npm helpers.
          detached: true
        }
      )
    } catch {
      resolve(FALLBACK_MODELS)
      return
    }

    timer = setTimeout(
      () => finish(FALLBACK_MODELS),
      opts.timeoutMs ?? PROBE_TIMEOUT_MS
    )
    timer.unref()

    child.on('error', () => finish(FALLBACK_MODELS))
    child.on('exit', () => finish(FALLBACK_MODELS))
    child.stdin?.on('error', () => finish(FALLBACK_MODELS))

    if (child.stdout !== null) {
      reader = createInterface({ input: child.stdout })
      reader.on('line', (line) => {
        try {
          const models = parseModels(JSON.parse(line))
          if (models !== null) {
            finish(models)
          }
        } catch {
          // ignore non-JSON noise
        }
      })
    }

    child.stdin?.write(
      `${JSON.stringify({
        type: 'control_request',
        request_id: PROBE_REQUEST_ID,
        request: { subtype: 'list_models' }
      })}\n`
    )
  })
}
