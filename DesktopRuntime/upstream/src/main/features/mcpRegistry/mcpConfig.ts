import { Buffer } from 'node:buffer'
import type { McpServerConfig } from '../../../shared/types/mcp'

const BANDAL_SERVER_NAME = 'bandal'
const MAX_TOOLS_PER_SERVER = 12
const MAX_PROMPT_BYTES = 2 * 1024

function enabledExternalServers(
  servers: McpServerConfig[]
): McpServerConfig[] {
  return servers.filter(
    (server) => server.enabled && server.name !== BANDAL_SERVER_NAME
  )
}

export function buildClaudeMcpConfig(
  bandal: { url: string; token: string },
  servers: McpServerConfig[]
): { mcpServers: Record<string, unknown> } {
  const mcpServers: Record<string, unknown> = {
    bandal: {
      type: 'http',
      url: bandal.url,
      headers: { Authorization: `Bearer ${bandal.token}` }
    }
  }
  for (const server of enabledExternalServers(servers)) {
    if (server.transport === 'stdio' && server.command !== undefined) {
      mcpServers[server.name] = {
        type: 'stdio',
        command: server.command,
        ...(server.args === undefined ? {} : { args: [...server.args] }),
        ...(server.env === undefined ? {} : { env: { ...server.env } })
      }
    } else if (server.transport === 'http' && server.url !== undefined) {
      mcpServers[server.name] = {
        type: 'http',
        url: server.url,
        ...(server.headers === undefined
          ? {}
          : { headers: { ...server.headers } })
      }
    }
  }
  return { mcpServers }
}

export function claudeAllowRulesFor(servers: McpServerConfig[]): string[] {
  return enabledExternalServers(servers).map(
    (server) => `mcp__${server.name}`
  )
}

function tomlString(value: string): string {
  // JSON basic-string escaping is also valid TOML. DEL is the one control
  // character JSON leaves raw but TOML forbids in a basic string.
  return JSON.stringify(value).replace(/\u007f/gu, '\\u007F')
}

function tomlKey(value: string): string {
  return /^[A-Za-z0-9_-]+$/u.test(value) ? value : tomlString(value)
}

function tomlArray(values: string[]): string {
  return `[${values.map(tomlString).join(',')}]`
}

function tomlInlineTable(values: Record<string, string>): string {
  return `{${Object.keys(values)
    .sort()
    .map((key) => `${tomlKey(key)}=${tomlString(values[key] as string)}`)
    .join(',')}}`
}

function bearerEnvName(serverName: string): string {
  const normalized = serverName.toUpperCase().replace(/[^A-Z0-9_]/gu, '_')
  return `BANDAL_MCP_${normalized}_TOKEN`
}

function pushOverride(target: string[], value: string): void {
  target.push('-c', value)
}

export function buildCodexMcpOverrides(
  servers: McpServerConfig[],
  envSink: Record<string, string>
): string[] {
  const overrides: string[] = []
  for (const server of enabledExternalServers(servers)) {
    const prefix = `mcp_servers.${server.name}`
    if (server.transport === 'stdio' && server.command !== undefined) {
      pushOverride(overrides, `${prefix}.command=${tomlString(server.command)}`)
      if (server.args !== undefined) {
        pushOverride(overrides, `${prefix}.args=${tomlArray(server.args)}`)
      }
      if (server.env !== undefined) {
        pushOverride(overrides, `${prefix}.env=${tomlInlineTable(server.env)}`)
      }
      continue
    }
    if (server.transport !== 'http' || server.url === undefined) continue

    pushOverride(overrides, `${prefix}.url=${tomlString(server.url)}`)
    const otherHeaders: Record<string, string> = {}
    let bearerToken: string | undefined
    for (const [key, value] of Object.entries(server.headers ?? {})) {
      const match = /^Bearer\s+(.+?)\s*$/iu.exec(value)
      if (key.toLowerCase() === 'authorization' && match?.[1] !== undefined) {
        bearerToken ??= match[1]
      } else {
        otherHeaders[key] = value
      }
    }
    if (bearerToken !== undefined) {
      const envName = bearerEnvName(server.name)
      envSink[envName] = bearerToken
      pushOverride(
        overrides,
        `${prefix}.bearer_token_env_var=${tomlString(envName)}`
      )
    }
    if (Object.keys(otherHeaders).length > 0) {
      pushOverride(
        overrides,
        `${prefix}.http_headers=${tomlInlineTable(otherHeaders)}`
      )
    }
  }
  return overrides
}

function truncateUtf8(value: string, maxBytes: number): string {
  if (Buffer.byteLength(value, 'utf8') <= maxBytes) return value
  const ellipsis = '…'
  const ellipsisBytes = Buffer.byteLength(ellipsis, 'utf8')
  let result = ''
  let used = 0
  for (const character of value) {
    const size = Buffer.byteLength(character, 'utf8')
    if (used + size + ellipsisBytes > maxBytes) break
    result += character
    used += size
  }
  return `${result}${ellipsis}`
}

export function promptHintFor(servers: McpServerConfig[]): string {
  const lines = enabledExternalServers(servers).map((server) => {
    const tools = server.lastTest?.tools ?? []
    const shownTools = tools.slice(0, MAX_TOOLS_PER_SERVER)
    const toolText = shownTools.length === 0
      ? '확인되지 않음'
      : `${shownTools.join(', ')}${
          tools.length > MAX_TOOLS_PER_SERVER ? ', …' : ''
        }`
    return `등록된 외부 도구 서버: ${server.name} — ${server.description} (도구: ${toolText})`
  })
  return truncateUtf8(lines.join('\n'), MAX_PROMPT_BYTES)
}
