import { isAgentReady, providerPreferenceOrder } from '../../../shared/agentProviderSelection'
import type { AgentAvailability, AgentProvider } from '../../../shared/types/agent-events'

/** Only a conversation with no existing provider may choose an automatic fallback. */
export async function resolveConversationProvider(options: {
  storedProvider?: AgentProvider | null
  warmProvider?: AgentProvider | null
  preferredProvider: AgentProvider
  check: (provider: AgentProvider) => Promise<AgentAvailability>
}): Promise<AgentProvider> {
  if (options.storedProvider) return options.storedProvider
  if (options.warmProvider) return options.warmProvider
  for (const provider of providerPreferenceOrder(options.preferredProvider, options.preferredProvider)) {
    try { if (isAgentReady(await options.check(provider))) return provider } catch {
      // A failed probe must not block a brand-new conversation's other choices.
    }
  }
  return options.preferredProvider
}
