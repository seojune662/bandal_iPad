import { assertAgentReady, checkAgentAvailability } from '../availability'
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import type { AgentAdapter, AgentCapabilities, AgentStartSessionOptions } from '../../../../shared/types/agent-events'
import type { BinaryLocator } from '../binaryLocator'
import { augmentedPathEnv, killProcessTree, spawnClaude } from '../platform'
import { createGeminiApiKeyStore } from '../geminiApiKeyStore'
import { createGeminiBinaryLocator } from './binaryLocator'
import { createRpcSession } from '../rpcSession'
import { writeGeminiSettings, GEMINI_SYSTEM_SETTINGS_ENV_VAR, GEMINI_MCP_TOKEN_ENV_VAR, type GeminiMcpServerSettings } from './settingsFile'
const capabilities: AgentCapabilities = { interactivePermissions: true, streamingInput: false, partialText: true, cancel: true, imageInput: true, resume: true }
const processes = new Set<number>()
export interface GeminiAdapterDeps { userDataPath: string; locator?: BinaryLocator; spawnImpl?: typeof spawnClaude; apiKey?: () => string | null }
export function buildGeminiArgs(options: { model?: string }): string[] { return ['--acp', ...(options.model && options.model !== 'default' ? ['-m', options.model] : [])] }
export function killAllGeminiProcessesSync(): void { for (const pid of processes) killProcessTree(pid, 'SIGKILL'); processes.clear() }
export function createGeminiAdapter(deps: GeminiAdapterDeps): AgentAdapter {
  const key = deps.apiKey ?? (() => createGeminiApiKeyStore(deps.userDataPath).readKey())
  const locator = deps.locator ?? createGeminiBinaryLocator({ hasApiKey: () => key() !== null })
  return { provider: 'gemini', capabilities, checkAvailability: () => checkAgentAvailability('gemini', locator),
    async startSession(base: AgentStartSessionOptions) {
      const options = base as AgentStartSessionOptions & { geminiMcpServers?: Record<string, GeminiMcpServerSettings> }
      await assertAgentReady('gemini', locator, { refresh: true })
      const binary = await locator.locate(), loginPath = await locator.loginShellPath(), apiKey = key()
      const root = join(deps.userDataPath, 'gemini-sessions'); mkdirSync(root, { recursive: true, mode: 0o700 })
      const directory = mkdtempSync(join(root, 'session-'))
      const settings = writeGeminiSettings({ userDataPath: directory, useApiKey: !!apiKey, ...(options.accessPolicy ? { accessPolicy: options.accessPolicy } : {}), ...(options.mcpHttp ? { mcpHttp: options.mcpHttp } : {}), ...(options.geminiMcpServers ? { externalServers: options.geminiMcpServers } : {}) })
      const env: NodeJS.ProcessEnv = { ...augmentedPathEnv(binary.path, loginPath), ...options.mcpExtraEnv, [GEMINI_SYSTEM_SETTINGS_ENV_VAR]: settings }
      if (apiKey) env['GEMINI_API_KEY'] = apiKey
      else delete env['GEMINI_API_KEY']
      if (options.mcpHttp) env[GEMINI_MCP_TOKEN_ENV_VAR] = options.mcpHttp.token
      return createRpcSession(options, 'gemini', () => {
        const child = (deps.spawnImpl ?? spawnClaude)(binary.path, buildGeminiArgs(options), { cwd: options.cwd, env, stdio: ['pipe', 'pipe', 'pipe'] })
        if (child.pid) { const pid = child.pid; processes.add(pid); child.once('close', () => { processes.delete(pid); rmSync(directory, { recursive: true, force: true }) }) }
        else child.once('close', () => rmSync(directory, { recursive: true, force: true }))
        return child
      }, () => rmSync(directory, { recursive: true, force: true }))
    }
  }
}
