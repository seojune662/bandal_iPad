import { randomBytes, randomUUID } from 'node:crypto'
import {
  chmodSync,
  mkdirSync,
  unlinkSync,
  writeFileSync
} from 'node:fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import type { Transport } from '@modelcontextprotocol/sdk/shared/transport.js'
import {
  CallToolRequestSchema,
  isInitializeRequest,
  ListToolsRequestSchema
} from '@modelcontextprotocol/sdk/types.js'
import type { McpServerConfig } from '../../../shared/types/mcp'
import { resolveInside } from '../../db/validate'
import type { GeminiMcpServerSettings } from '../agent/gemini/settingsFile'
import {
  buildClaudeMcpConfig,
  buildCodexMcpOverrides,
  claudeAllowRulesFor,
  promptHintFor
} from '../mcpRegistry'
import { createAgentTools, type AgentTools, type AgentToolsDeps } from './tools'

const HOST = '127.0.0.1'
const MCP_PATH = '/mcp'
const MAX_REQUEST_BYTES = 1024 * 1024

export interface StartAgentToolsServerOptions {
  sessionId: string
  userDataPath: string
  deps: AgentToolsDeps
  userMcpServers?: McpServerConfig[]
}

export interface AgentToolsServerHandle {
  /** Path passed to CLI `--mcp-config`. */
  mcpConfigPath: string
  /** Exact values passed to CLI `--allowedTools`. */
  extraAllowedTools: readonly string[]
  /** Secret environment values for user MCP transports. */
  extraEnv: Record<string, string>
  /** Codex `-c` overrides for user MCP transports. */
  codexOverrides: string[]
  /** Gemini system-settings entries for the same user MCP transports. */
  geminiMcpServers: Record<string, GeminiMcpServerSettings>
  /** Concise, bounded tool summary for the session system prompt. */
  mcpHint: string
  /** Raw endpoint for CLIs that take MCP config as flags (codex `-c`). */
  url: string
  /** Bearer token for `url` — hand to the child via env, never argv. */
  token: string
  close: () => Promise<void>
}

interface SessionConnection {
  transport: StreamableHTTPServerTransport
  server: McpServer
}

function buildGeminiMcpServers(
  servers: McpServerConfig[]
): Record<string, GeminiMcpServerSettings> {
  const result: Record<string, GeminiMcpServerSettings> = {}
  for (const server of servers) {
    if (!server.enabled || server.name === 'bandal') continue
    if (server.transport === 'stdio' && server.command !== undefined) {
      result[server.name] = {
        command: server.command,
        ...(server.args === undefined ? {} : { args: [...server.args] }),
        ...(server.env === undefined ? {} : { env: { ...server.env } }),
        trust: true,
        timeout: 300_000
      }
    } else if (server.transport === 'http' && server.url !== undefined) {
      result[server.name] = {
        httpUrl: server.url,
        ...(server.headers === undefined
          ? {}
          : { headers: { ...server.headers } }),
        trust: true,
        timeout: 300_000
      }
    }
  }
  return result
}

function makeMcpServer(agentTools: AgentTools): McpServer {
  const server = new McpServer(
    { name: 'bandal', version: '1.0.0' },
    { capabilities: { tools: {} } }
  )
  // App Server supports interactive approval; keep the real tool annotations.
  // Bandal's own gate still checks the conversation policy before executing.
  server.server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: agentTools.definitions }))
  const calls = new Map<string, ReturnType<AgentTools['call']>>()
  server.server.setRequestHandler(CallToolRequestSchema, (request, extra) => {
    const key = `${typeof extra.requestId}:${extra.requestId}`
    const previous = calls.get(key)
    if (previous) return previous
    const result = agentTools.call(request.params.name, request.params.arguments)
    calls.set(key, result)
    if (calls.size > 1000) calls.delete(calls.keys().next().value!)
    return result
  })
  return server
}

function jsonRpcError(
  response: ServerResponse,
  status: number,
  code: number,
  message: string
): void {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(JSON.stringify({
    jsonrpc: '2.0',
    error: { code, message },
    id: null
  }))
}

async function readJson(request: IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)
    size += bytes.byteLength
    if (size > MAX_REQUEST_BYTES) {
      throw new Error(`request body exceeds ${MAX_REQUEST_BYTES} bytes`)
    }
    chunks.push(bytes)
  }
  if (chunks.length === 0) return undefined
  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
}

function sessionHeader(request: IncomingMessage): string | undefined {
  const value = request.headers['mcp-session-id']
  return Array.isArray(value) ? undefined : value
}

function listen(httpServer: ReturnType<typeof createServer>): Promise<number> {
  return new Promise((resolve, reject) => {
    const onError = (error: Error): void => reject(error)
    httpServer.once('error', onError)
    httpServer.listen(0, HOST, () => {
      httpServer.off('error', onError)
      const address = httpServer.address() as AddressInfo | null
      if (address === null) {
        reject(new Error('MCP server did not expose a listening address'))
        return
      }
      resolve(address.port)
    })
  })
}

function closeHttp(httpServer: ReturnType<typeof createServer>): Promise<void> {
  return new Promise((resolve, reject) => {
    if (!httpServer.listening) {
      resolve()
      return
    }
    httpServer.close((error) => {
      if (error === undefined) resolve()
      else reject(error)
    })
    httpServer.closeAllConnections()
  })
}

function requireSafeSessionId(sessionId: string): string {
  if (!/^[A-Za-z0-9._-]+$/.test(sessionId)) {
    throw new Error('sessionId may contain only letters, digits, dot, underscore and dash')
  }
  return sessionId
}

/**
 * Starts the exact stateful Streamable HTTP shape verified by the spike.
 * Every MCP protocol session owns a separate McpServer and transport.
 */
export async function startAgentToolsServer(
  options: StartAgentToolsServerOptions
): Promise<AgentToolsServerHandle> {
  const sessionId = requireSafeSessionId(options.sessionId)
  const token = randomBytes(32).toString('base64url')
  const agentTools = createAgentTools(options.deps)
  const connections = new Map<string, SessionConnection>()
  let closing = false

  const httpServer = createServer(async (request, response) => {
    try {
      if (request.headers.authorization !== `Bearer ${token}`) {
        response.writeHead(401).end()
        return
      }
      const pathname = new URL(request.url ?? '/', `http://${HOST}`).pathname
      if (pathname !== MCP_PATH) {
        response.writeHead(404).end()
        return
      }
      if (!['GET', 'POST', 'DELETE'].includes(request.method ?? '')) {
        response.writeHead(405, { allow: 'GET, POST, DELETE' }).end()
        return
      }

      const body = request.method === 'POST' ? await readJson(request) : undefined
      const requestedSessionId = sessionHeader(request)
      let connection = requestedSessionId === undefined
        ? undefined
        : connections.get(requestedSessionId)

      if (connection === undefined && isInitializeRequest(body)) {
        let initializedConnection: SessionConnection
        const transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (id) => {
            connections.set(id, initializedConnection)
          }
        })
        const server = makeMcpServer(agentTools)
        initializedConnection = { transport, server }
        transport.onclose = () => {
          const id = transport.sessionId
          if (id !== undefined && connections.get(id) === initializedConnection) {
            connections.delete(id)
          }
        }
        // SDK 1.30's Node wrapper and base Transport declarations disagree
        // under exactOptionalPropertyTypes even though this is its documented
        // transport pairing.
        await server.connect(transport as unknown as Transport)
        connection = initializedConnection
      }

      if (connection === undefined) {
        jsonRpcError(response, 400, -32000, 'no valid MCP session')
        return
      }
      await connection.transport.handleRequest(request, response, body)
    } catch (error) {
      console.error('[agentTools] MCP request failed', error)
      if (!response.headersSent) {
        jsonRpcError(response, 400, -32600, 'invalid MCP request')
      } else if (!response.writableEnded) {
        response.end()
      }
    }
  })

  let port: number
  try {
    port = await listen(httpServer)
  } catch (error) {
    await closeHttp(httpServer).catch(() => {})
    throw error
  }

  const url = `http://${HOST}:${port}${MCP_PATH}`
  const userMcpServers = options.userMcpServers ?? []
  const extraEnv: Record<string, string> = {}
  const codexOverrides = buildCodexMcpOverrides(userMcpServers, extraEnv)
  const geminiMcpServers = buildGeminiMcpServers(userMcpServers)
  const mcpDirectory = resolveInside(options.userDataPath, 'mcp')
  const mcpConfigPath = resolveInside(mcpDirectory, `${sessionId}.json`)
  const config = buildClaudeMcpConfig(
    { url, token },
    userMcpServers
  )

  try {
    mkdirSync(mcpDirectory, { recursive: true, mode: 0o700 })
    chmodSync(mcpDirectory, 0o700)
    writeFileSync(mcpConfigPath, JSON.stringify(config), {
      encoding: 'utf8',
      mode: 0o600
    })
    chmodSync(mcpConfigPath, 0o600)
  } catch (error) {
    await closeHttp(httpServer).catch(() => {})
    throw error
  }

  const removeConfig = (): void => {
    try {
      unlinkSync(mcpConfigPath)
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'ENOENT') console.error('[agentTools] config cleanup failed', error)
    }
  }
  process.once('exit', removeConfig)

  return {
    mcpConfigPath,
    extraAllowedTools: [
      ...agentTools.names.map((name) => `mcp__bandal__${name}`),
      ...claudeAllowRulesFor(userMcpServers)
    ],
    extraEnv,
    codexOverrides,
    geminiMcpServers,
    mcpHint: promptHintFor(userMcpServers),
    url,
    token,
    async close() {
      if (closing) return
      closing = true
      process.off('exit', removeConfig)
      removeConfig()
      const servers = [...new Set(
        [...connections.values()].map((connection) => connection.server)
      )]
      connections.clear()
      await Promise.all(servers.map(async (server) => {
        await server.close().catch(() => {})
      }))
      await closeHttp(httpServer)
    }
  }
}
