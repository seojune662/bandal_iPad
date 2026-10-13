import type { McpServerInput } from '../../../../shared/types/mcp'
import { MCP_SERVER_NAME_PATTERN } from '../../../../shared/types/mcp'

export interface McpImportResult {
  servers: McpServerInput[]
  errors: string[]
}

type JsonRecord = Record<string, unknown>

function isRecord(value: unknown): value is JsonRecord {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function stringRecord(
  value: unknown,
  field: string
): { value?: Record<string, string>; error?: string } {
  if (value === undefined) return {}
  if (!isRecord(value)) return { error: `${field} must be an object.` }

  const entries = Object.entries(value)
  if (!entries.every(([, item]) => typeof item === 'string')) {
    return { error: `${field} values must all be strings.` }
  }
  return { value: Object.fromEntries(entries) as Record<string, string> }
}

function uniqueName(rawName: string, usedNames: Set<string>, index: number): string {
  const normalized = rawName
    .normalize('NFKD')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')

  const base = (normalized || `mcp-server-${index + 1}`).slice(0, 32)
  let candidate = base
  let suffix = 2
  while (usedNames.has(candidate)) {
    const ending = `-${suffix}`
    candidate = `${base.slice(0, 32 - ending.length)}${ending}`
    suffix += 1
  }
  return candidate
}

function parseServer(
  rawName: string,
  rawConfig: unknown,
  usedNames: Set<string>,
  index: number
): { server?: McpServerInput; error?: string } {
  if (!isRecord(rawConfig)) {
    return { error: `${rawName}: server configuration must be an object.` }
  }

  const name = uniqueName(rawName, usedNames, index)
  if (!MCP_SERVER_NAME_PATTERN.test(name)) {
    return { error: `${rawName}: server name could not be normalized.` }
  }

  const description =
    typeof rawConfig['description'] === 'string'
      ? rawConfig['description'].trim()
      : ''
  const command = rawConfig['command']
  const url = rawConfig['url']

  if (typeof command === 'string' && command.trim() !== '') {
    if (url !== undefined) {
      return { error: `${rawName}: choose either command or url, not both.` }
    }
    const rawArgs = rawConfig['args']
    if (
      rawArgs !== undefined &&
      (!Array.isArray(rawArgs) || !rawArgs.every((arg) => typeof arg === 'string'))
    ) {
      return { error: `${rawName}: args must be an array of strings.` }
    }
    const env = stringRecord(rawConfig['env'], `${rawName}.env`)
    if (env.error !== undefined) return { error: env.error }
    usedNames.add(name)

    return {
      server: {
        name,
        description,
        transport: 'stdio',
        command: command.trim(),
        args: (rawArgs as string[] | undefined) ?? [],
        ...(env.value === undefined ? {} : { env: env.value }),
        enabled: true
      }
    }
  }

  if (typeof url === 'string') {
    let parsedUrl: URL
    try {
      parsedUrl = new URL(url)
    } catch {
      return { error: `${rawName}: url must be a valid HTTP or HTTPS URL.` }
    }
    if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
      return { error: `${rawName}: url must use HTTP or HTTPS.` }
    }
    const headers = stringRecord(rawConfig['headers'], `${rawName}.headers`)
    if (headers.error !== undefined) return { error: headers.error }
    usedNames.add(name)

    return {
      server: {
        name,
        description,
        transport: 'http',
        url: url.trim(),
        ...(headers.value === undefined ? {} : { headers: headers.value }),
        enabled: true
      }
    }
  }

  return { error: `${rawName}: provide a command or an HTTP URL.` }
}

/** Parses Claude Desktop and Cursor's shared `{ mcpServers: ... }` format. */
export function parseMcpConfigText(text: string): McpImportResult {
  if (text.trim() === '') {
    return { servers: [], errors: [] }
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error)
    return { servers: [], errors: [`Invalid JSON: ${detail}`] }
  }

  if (!isRecord(parsed) || !isRecord(parsed['mcpServers'])) {
    return {
      servers: [],
      errors: ['The configuration must contain an mcpServers object.']
    }
  }

  const entries = Object.entries(parsed['mcpServers'])
  if (entries.length === 0) {
    return { servers: [], errors: ['The mcpServers object is empty.'] }
  }

  const servers: McpServerInput[] = []
  const errors: string[] = []
  const usedNames = new Set<string>()
  entries.forEach(([name, config], index) => {
    const result = parseServer(name, config, usedNames, index)
    if (result.server !== undefined) servers.push(result.server)
    if (result.error !== undefined) errors.push(result.error)
  })
  return { servers, errors }
}
