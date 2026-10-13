// Public main-process entry points used by IPC registration.
export { createBinaryLocator } from './binaryLocator'
export { createClaudeCodeAdapter, killAllClaudeProcessesSync } from './claude/ClaudeCodeAdapter'
export { createCodexAdapter, killAllCodexProcessesSync } from './codex/CodexAdapter'
export { createCodexBinaryLocator } from './codex/binaryLocator'
export { createGeminiAdapter, killAllGeminiProcessesSync } from './gemini/GeminiAdapter'
export { createGeminiBinaryLocator } from './gemini/binaryLocator'
export { createAgentInstaller } from './installer'
export { createLoginLauncher } from './loginLauncher'
export { getAgentModels } from './agentModels'
export { createEventBatcher } from './eventBatcher'
export { createChatRepo } from './chatRepo'
export {
  serializeTranscript,
  CARRYOVER_HISTORY_LIMIT
} from './transcriptCarryover'
export { createSessionManager } from './SessionManager'
