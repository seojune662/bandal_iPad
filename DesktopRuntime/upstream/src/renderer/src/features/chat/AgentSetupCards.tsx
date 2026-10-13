import {
  useEffect,
  useRef,
  type ReactNode
} from 'react'
import {
  AGENT_PROVIDERS,
  isAgentProvider,
  type AgentAvailability,
  type AgentProvider
} from '../../../../shared/types/agent-events'
import { BandalMark } from '../../components/BandalMark'
import { Icon } from '../../app/icons'
import {
  acquireAgentConnection, isAgentConnectionBusy, isAgentConnectionReady,
  refreshAgentConnection, seedAgentAvailability, useAgentConnectionStore
} from './agentConnectionStore'
import { AgentConnectionControls } from './AgentConnectionControls'
import { agentConnectionCopy, connectionProviderName } from './agentConnectionCopy'
import { useLocale } from '../../i18n'

const PROVIDER_LABELS: Record<AgentProvider, string> = {
  'claude-code': 'Claude',
  codex: 'ChatGPT',
  gemini: 'Gemini'
}

export function providerLabel(provider: AgentProvider): string {
  return PROVIDER_LABELS[provider]
}

export function ProviderSelector({
  provider,
  onChange,
  disabled = false,
  compact = false
}: {
  provider: AgentProvider
  onChange: (provider: AgentProvider) => void
  disabled?: boolean
  compact?: boolean
}): JSX.Element {
  if (compact) {
    return (
      <label className="chat-provider-select">
        <span>AI 제공자</span>
        <select
          aria-label="AI 제공자 선택"
          value={provider}
          disabled={disabled}
          onChange={(event) => {
            const nextProvider = event.currentTarget.value
            if (isAgentProvider(nextProvider)) onChange(nextProvider)
          }}
        >
          {AGENT_PROVIDERS.map((option) => (
            <option key={option} value={option}>
              {PROVIDER_LABELS[option]}
            </option>
          ))}
        </select>
      </label>
    )
  }
  return (
    <fieldset className="chat-provider" disabled={disabled}>
      <legend>AI 제공자 선택</legend>
      <div className="chat-provider__options">
        {AGENT_PROVIDERS.map((option) => (
          <label
            key={option}
            className="chat-provider__option"
            data-selected={provider === option}
          >
            <input
              type="radio"
              name="chat-agent-provider"
              value={option}
              checked={provider === option}
              onChange={() => onChange(option)}
            />
            <span>{PROVIDER_LABELS[option]}</span>
          </label>
        ))}
      </div>
    </fieldset>
  )
}

export function GateCard({
  eyebrow,
  title,
  children,
  onRefresh
}: {
  eyebrow: string
  title: string
  children: ReactNode
  onRefresh?: () => void
}): JSX.Element {
  return (
    <div className="chat-gate">
      <div className="chat-gate__card">
        <BandalMark size={36} className="chat-gate__moon" />
        <p className="chat-gate__eyebrow">{eyebrow}</p>
        <h2 className="chat-gate__title">{title}</h2>
        {children}
        {onRefresh !== undefined && (
          <button
            type="button"
            className="chat-gate__refresh"
            onClick={onRefresh}
          >
            <Icon name="refresh" />
            재확인
          </button>
        )}
      </div>
    </div>
  )
}

export function AgentSetupCard({
  provider,
  availability,
  onProviderChange,
  onRefresh
}: {
  provider: AgentProvider
  availability: AgentAvailability
  onProviderChange: (provider: AgentProvider) => void
  onRefresh: () => void
}): JSX.Element {
  const connection = useAgentConnectionStore(state => state.connections[provider])
  const copy = agentConnectionCopy(useLocale(), provider)
  const refreshRef = useRef(onRefresh)
  refreshRef.current = onRefresh
  const confirmedReadyRef = useRef(false)
  useEffect(() => { seedAgentAvailability(provider, availability) }, [provider, availability])
  useEffect(() => {
    confirmedReadyRef.current = false
    return acquireAgentConnection(provider)
  }, [provider])
  useEffect(() => {
    if (!isAgentConnectionReady(useAgentConnectionStore.getState().connections[provider].availability) || confirmedReadyRef.current) return
    confirmedReadyRef.current = true
    refreshRef.current()
  }, [connection.availability, provider])
  return <GateCard eyebrow={connectionProviderName(provider)} title={copy.title} onRefresh={() => { void refreshAgentConnection(provider, true) }}>
    <ProviderSelector provider={provider} onChange={onProviderChange} disabled={isAgentConnectionBusy(connection.stage)} />
    <AgentConnectionControls provider={provider} availability={availability} />
  </GateCard>
}

export function LoginCard({
  provider,
  onProviderChange,
  onRefresh,
  availability = { installed: true, loggedIn: false }
}: {
  provider: AgentProvider
  onProviderChange: (provider: AgentProvider) => void
  onRefresh: () => void
  availability?: AgentAvailability
}): JSX.Element {
  return (
    <AgentSetupCard
      provider={provider}
      availability={availability}
      onProviderChange={onProviderChange}
      onRefresh={onRefresh}
    />
  )
}
