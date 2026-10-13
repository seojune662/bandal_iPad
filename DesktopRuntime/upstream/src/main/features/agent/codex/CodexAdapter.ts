import { assertAgentReady, checkAgentAvailability } from '../availability'
import type { AgentAdapter, AgentCapabilities, AgentStartSessionOptions } from '../../../../shared/types/agent-events'
import type { BinaryLocator } from '../binaryLocator'
import { augmentedPathEnv, killProcessTree, spawnClaude } from '../platform'
import { createCodexBinaryLocator } from './binaryLocator'
import { createRpcSession } from '../rpcSession'
export const CODEX_CAPABILITIES: AgentCapabilities = { interactivePermissions: true, streamingInput: false, partialText: true, cancel: true, imageInput: true, resume: true }
const processes = new Set<number>()
export function killAllCodexProcessesSync(): void { for (const pid of processes) killProcessTree(pid, 'SIGKILL'); processes.clear() }
export interface CodexAdapterDeps { locator?: BinaryLocator; spawnImpl?: typeof spawnClaude }
export const CODEX_MCP_TOKEN_ENV_VAR = 'BANDAL_MCP_TOKEN'
export function buildCodexArgs(opts: { mcpUrl?: string; mcpExtraArgs?: readonly string[]; webSearch?: AgentStartSessionOptions['webSearch'] }): string[] {
  const args = ['app-server', '--listen', 'stdio://']
  if (opts.mcpUrl) args.push('-c', `mcp_servers.bandal.url=${JSON.stringify(opts.mcpUrl)}`, '-c', `mcp_servers.bandal.bearer_token_env_var=${JSON.stringify(CODEX_MCP_TOKEN_ENV_VAR)}`, '-c', 'mcp_servers.bandal.tool_timeout_sec=300')
  return [...args, ...(opts.mcpExtraArgs ?? []), ...(opts.webSearch ? ['-c', `web_search=${JSON.stringify(opts.webSearch)}`] : [])]
}
export function createCodexAdapter(deps: CodexAdapterDeps = {}): AgentAdapter {
  const locator = deps.locator ?? createCodexBinaryLocator()
  return { provider: 'codex', capabilities: CODEX_CAPABILITIES, checkAvailability: () => checkAgentAvailability('codex', locator),
    async startSession(options: AgentStartSessionOptions) {
      await assertAgentReady('codex', locator, { refresh: true })
      const binary = await locator.locate(), loginPath = await locator.loginShellPath()
      const env = { ...augmentedPathEnv(binary.path, loginPath), ...options.mcpExtraEnv }
      delete env['CODEX_THREAD_ID']; delete env['CODEX_CI']
      if (options.mcpHttp) env[CODEX_MCP_TOKEN_ENV_VAR] = options.mcpHttp.token
      return createRpcSession(options, 'codex', () => {
        const child = (deps.spawnImpl ?? spawnClaude)(binary.path, buildCodexArgs({ ...(options.mcpHttp ? { mcpUrl: options.mcpHttp.url } : {}), ...(options.mcpExtraArgs ? { mcpExtraArgs: options.mcpExtraArgs } : {}), ...(options.webSearch ? { webSearch: options.webSearch } : {}) }), { cwd: options.cwd, env, stdio: ['pipe', 'pipe', 'pipe'] })
        if (child.pid) { const pid = child.pid; processes.add(pid); child.once('close', () => processes.delete(pid)) }
        return child
      })
    }
  }
}
