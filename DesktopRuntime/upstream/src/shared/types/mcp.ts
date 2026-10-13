export type McpTransport = 'stdio' | 'http'

export const MCP_SERVER_NAME_PATTERN = /^[a-z0-9_-]{1,32}$/

export const MCP_RESERVED_NAMES = ['bandal'] as const

export interface McpServerConfig {
  id: string
  name: string
  description: string
  transport: McpTransport
  command?: string
  args?: string[]
  env?: Record<string, string>
  url?: string
  headers?: Record<string, string>
  enabled: boolean
  createdAt: string
  updatedAt: string
  lastTest?: { at: string; ok: boolean; tools: string[]; error?: string }
}

/** 렌더러용: 비밀값은 IPC를 넘지 않는다. */
export interface McpServerSummary
  extends Omit<McpServerConfig, 'env' | 'headers'> {
  envKeys: string[]
  headerKeys: string[]
}

/** env/headers 를 생략하면 "기존 값 유지". */
export interface McpServerInput
  extends Omit<
    McpServerConfig,
    'id' | 'createdAt' | 'updatedAt' | 'lastTest'
  > {
  id?: string
}

export interface McpTestResult {
  ok: boolean
  tools: string[]
  error?: string
  durationMs: number
}

export interface McpAvailability {
  available: boolean
  reason: string | null
}
