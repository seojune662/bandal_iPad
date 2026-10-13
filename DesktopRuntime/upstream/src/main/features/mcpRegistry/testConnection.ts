import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js'
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js'
import type { McpServerConfig, McpTestResult } from '../../../shared/types/mcp'
import { redactText } from '../browserAgent/redact'

const DEFAULT_TIMEOUT_MS = 10_000
const MASK = '██████'

function maskSecrets(message: string, secrets: string[]): string {
  let masked = message
  for (const secret of [...new Set(secrets)].sort(
    (left, right) => right.length - left.length
  )) {
    if (secret !== '') masked = masked.split(secret).join(MASK)
  }
  return masked
}

function safeError(error: unknown, secrets: string[]): string {
  const message = error instanceof Error ? error.message : String(error)
  const redacted = redactText(maskSecrets(message, secrets)).trim()
  return redacted === '' ? 'MCP 서버 연결에 실패했습니다.' : redacted
}

function killStdioChild(transport: StdioClientTransport | undefined): void {
  const pid = transport?.pid
  if (pid === null || pid === undefined) return
  try {
    process.kill(pid, 'SIGKILL')
  } catch {
    // It may already have exited between reading pid and sending the signal.
  }
}

function definedEnv(env: NodeJS.ProcessEnv): Record<string, string> {
  return Object.fromEntries(
    Object.entries(env).filter(
      (entry): entry is [string, string] => typeof entry[1] === 'string'
    )
  )
}

export async function testMcpServer(
  config: McpServerConfig,
  opts: { timeoutMs?: number; env?: NodeJS.ProcessEnv } = {}
): Promise<McpTestResult> {
  const startedAt = Date.now()
  const timeoutMs = Number.isFinite(opts.timeoutMs) && (opts.timeoutMs ?? 0) > 0
    ? Math.floor(opts.timeoutMs as number)
    : DEFAULT_TIMEOUT_MS
  const secrets = [
    ...Object.values(config.env ?? {}),
    ...Object.values(config.headers ?? {}),
    ...Object.values(config.headers ?? {}).flatMap((value) => {
      const token = /^Bearer\s+(.+?)\s*$/iu.exec(value)?.[1]
      return token === undefined ? [] : [token]
    }),
    ...Object.values(opts.env ?? {}).filter(
      (value): value is string => typeof value === 'string'
    )
  ]
  let stdioTransport: StdioClientTransport | undefined
  const client = new Client(
    { name: 'bandal-mcp-connection-test', version: '1.0.0' },
    { capabilities: {} }
  )
  const controller = new AbortController()
  let timeout: NodeJS.Timeout | undefined
  let result: Omit<McpTestResult, 'durationMs'>

  try {
    const transport = config.transport === 'stdio'
      ? (stdioTransport = new StdioClientTransport({
          command: config.command ?? '',
          ...(config.args === undefined ? {} : { args: [...config.args] }),
          env: {
            ...definedEnv(opts.env ?? process.env),
            ...(config.env ?? {})
          },
          stderr: 'pipe'
        }))
      : new StreamableHTTPClientTransport(new URL(config.url ?? ''), {
          requestInit: {
            headers: { ...(config.headers ?? {}) }
          }
        })
    const operation = (async (): Promise<string[]> => {
      // SDK 1.30's concrete HTTP transport declares `sessionId` as
      // `string | undefined`, while its Transport interface uses an optional
      // `string`. They are runtime-compatible; exactOptionalPropertyTypes is
      // the only reason a narrow cast is needed here.
      await client.connect(transport as unknown as Transport, {
        signal: controller.signal,
        timeout: timeoutMs
      })
      const response = await client.listTools({}, {
        signal: controller.signal,
        timeout: timeoutMs
      })
      return response.tools.map((tool) => tool.name)
    })()
    const deadline = new Promise<never>((_resolve, reject) => {
      timeout = setTimeout(() => {
        controller.abort()
        killStdioChild(stdioTransport)
        reject(new Error('MCP 서버 연결 시간이 초과되었습니다.'))
      }, timeoutMs)
    })
    const tools = await Promise.race([operation, deadline])
    result = { ok: true, tools }
  } catch (error) {
    result = { ok: false, tools: [], error: safeError(error, secrets) }
  } finally {
    if (timeout !== undefined) clearTimeout(timeout)
    controller.abort()
    try {
      await client.close()
    } catch {
      // The connection result is more useful than a cleanup error.
    }
    killStdioChild(stdioTransport)
  }

  return { ...result, durationMs: Date.now() - startedAt }
}
