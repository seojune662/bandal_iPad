import { isAgentReady } from '../../../shared/agentProviderSelection'
import type { AgentAvailability, AgentProvider } from '../../../shared/types/agent-events'
import { AgentUnavailableError, type BinaryLocator, unavailableSummary } from './binaryLocator'
import { requireProtocolVersion } from './protocolAvailability'

export interface AgentAvailabilityOptions { refresh?: boolean | undefined }
interface ProbeState { generation: number; pending?: Promise<AgentAvailability> | undefined; newest?: Promise<AgentAvailability> | undefined }
const probes = new WeakMap<BinaryLocator, Map<AgentProvider, ProbeState>>()

function normalizeAvailability(provider: AgentProvider, value: AgentAvailability): AgentAvailability {
  const availability = provider === 'claude-code' ? value : requireProtocolVersion(value, provider)
  if (availability.installed && !availability.loggedIn && !availability.code) {
    return { ...availability, code: 'not-logged-in', reason: 'AI에 로그인이 필요해요. 설정 → AI에서 연결을 확인해 주세요.' }
  }
  return availability
}

/** Concurrent setup, routing and adapter callers share the same live probe. */
export function checkAgentAvailability(provider: AgentProvider, locator: BinaryLocator, options: AgentAvailabilityOptions = {}): Promise<AgentAvailability> {
  let providerProbes = probes.get(locator)
  if (!providerProbes) { providerProbes = new Map(); probes.set(locator, providerProbes) }
  let state = providerProbes.get(provider)
  if (!state) { state = { generation: 0 }; providerProbes.set(provider, state) }
  if (options.refresh) { state.generation++; state.pending = undefined; locator.reset() }
  if (state.pending) return state.pending
  const generation = state.generation
  const current = state
  const probe = Promise.resolve().then(() => generation === current.generation ? locator.availability() : current.newest!).then(value => normalizeAvailability(provider, value), unavailableSummary)
  const pending: Promise<AgentAvailability> = probe.then(result => {
    // A reset invalidates every older waiter, not only the next caller.
    return generation === current.generation ? result : current.newest!
  }).finally(() => { if (current.pending === pending) current.pending = undefined })
  state.pending = pending; state.newest = pending
  return pending
}

function requireReady(availability: AgentAvailability): void {
  if (!isAgentReady(availability)) throw new AgentUnavailableError(
    availability.code ?? (availability.installed ? 'not-logged-in' : 'not-installed'),
    availability.reason ?? 'AI 연결을 확인해 주세요.', availability.version
  )
}
export async function assertAgentReady(provider: AgentProvider, locator: BinaryLocator, options?: AgentAvailabilityOptions): Promise<void> {
  requireReady(await checkAgentAvailability(provider, locator, options))
}
export function createAgentAvailabilityService(deps: { locators: Record<AgentProvider, BinaryLocator> }) {
  return {
    check: (provider: AgentProvider, options?: AgentAvailabilityOptions) => checkAgentAvailability(provider, deps.locators[provider], options),
    async assertReady(provider: AgentProvider, options?: AgentAvailabilityOptions): Promise<void> {
      requireReady(await checkAgentAvailability(provider, deps.locators[provider], options))
    }
  }
}
