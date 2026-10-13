import { useEffect, useState } from 'react'
import type { AgentAvailability, AgentProvider } from '../../../../shared/types/agent-events'
import { useLocale } from '../../i18n'
import { agentConnectionCopy } from './agentConnectionCopy'
import {
  cancelAgentLogin, hasCompatibleAgentBinary, isAgentConnectionBusy, isAgentConnectionReady,
  prepareAgentConnection, reopenAgentLogin, startAgentConnection, startAgentInstall, submitAgentLoginCode, useAgentConnectionStore
} from './agentConnectionStore'
import './agent-connection.css'

/** The same connection flow remains visible when moving between chat and settings. */
export function AgentConnectionControls({ provider, availability }: { provider: AgentProvider; availability: AgentAvailability }): JSX.Element {
  const connection = useAgentConnectionStore(state => state.connections[provider])
  const copy = agentConnectionCopy(useLocale(), provider)
  const [copied, setCopied] = useState(false)
  const [code, setCode] = useState('')
  const [submittingCode, setSubmittingCode] = useState(false)
  const current = connection.availability ?? availability
  const installed = hasCompatibleAgentBinary(current)
  const { stage } = connection
  const busy = isAgentConnectionBusy(stage)
  const loginActive = ['opening-login', 'waiting-login', 'verifying-login'].includes(stage)
  const ready = isAgentConnectionReady(current) && !busy
  const step = ready ? 3 : stage === 'installing' || stage === 'checking-install' ? 0 : installed ? stage === 'verifying-login' ? 2 : 1 : 0
  const actionLabel = stage === 'error' ? copy.retry : stage === 'installing' ? copy.installing
    : stage === 'checking-install' ? copy.checking : stage === 'opening-login' ? copy.opening
      : stage === 'waiting-login' ? copy.waiting : stage === 'verifying-login' ? copy.verifying : copy.connect
  useEffect(() => { if (!installed) void prepareAgentConnection(provider).catch(() => undefined) }, [installed, provider])
  return <section className="agent-connection" aria-label={copy.title}>
    <p className="agent-connection__intro">{ready ? copy.readyMessage : copy.description}</p>
    {!ready && <p className="agent-connection__plan">{copy.subscription}</p>}
    <ol className="agent-connection__steps" aria-label={copy.progress}>
      {[copy.preparation, copy.account, copy.ready].map((label, index) => <li key={label} data-state={index < step ? 'complete' : index === step ? 'current' : 'pending'} aria-current={index === step ? 'step' : undefined}>
        <span aria-hidden="true">{index < step ? '✓' : index + 1}</span><span>{label}</span>
      </li>)}
    </ol>
    {!ready && <>
      <p className="agent-connection__help">{loginActive ? provider === 'gemini' && connection.loginUrl === null ? copy.terminalHelp : copy.help : current.code === 'version-too-old' ? copy.update : copy.automatic}</p>
      <div className="agent-connection__actions">
        {stage === 'waiting-login' && connection.loginUrl !== null ? <button type="button" className="agent-connection__primary" data-settings-connect-action="true" onClick={() => { void reopenAgentLogin(provider) }}>{copy.reopen}</button>
          : <button type="button" className="agent-connection__primary" data-settings-connect-action="true" disabled={busy} onClick={() => { void startAgentConnection(provider) }}>{actionLabel}</button>}
        {loginActive && <button type="button" className="agent-connection__secondary" onClick={() => { void cancelAgentLogin(provider) }}>{copy.cancel}</button>}
      </div>
      {busy && <p className="agent-connection__status" role="status">{actionLabel}</p>}
    </>}
    {connection.error && <p className="agent-connection__error" role="alert">{connection.error}</p>}
    {connection.availabilityError && <p className="agent-connection__error" role="alert">{connection.availabilityError}</p>}
    {connection.loginFailure && <p className="agent-connection__error" role="alert">{connection.loginFailure}</p>}
    {stage === 'waiting-login' && connection.requiresCode && <details className="agent-connection__details">
      <summary>{copy.codeQuestion}</summary><p>{copy.codeHelp}</p>
      <form className="agent-connection__code" onSubmit={event => { event.preventDefault(); if (!code.trim() || submittingCode) return; setSubmittingCode(true); void submitAgentLoginCode(provider, code.trim()).then(ok => { if (ok) setCode('') }).finally(() => setSubmittingCode(false)) }}>
        <input type="password" autoComplete="off" aria-label={copy.codeLabel} placeholder={copy.codeLabel} value={code} onChange={event => setCode(event.currentTarget.value)} />
        <button type="submit" className="agent-connection__secondary" disabled={submittingCode || !code.trim()}>{copy.codeSubmit}</button>
      </form>
    </details>}
    <p className="agent-connection__limits">{copy.sharedLimits}</p>
    {!ready && <details className="agent-connection__details">
      <summary>{copy.details}</summary>
      {installed && <button type="button" className="agent-connection__secondary" disabled={busy} onClick={() => { void startAgentInstall(provider) }}>{copy.repair}</button>}
      {stage === 'waiting-login' && connection.loginUrl !== null && <div className="agent-connection__fallback"><p>{copy.externalHelp}</p><button type="button" className="agent-connection__secondary" onClick={() => { void reopenAgentLogin(provider, true) }}>{copy.external}</button></div>}
      {connection.command !== '' && <><p>{copy.command}</p><code>{connection.command}</code><button type="button" className="agent-connection__secondary" onClick={() => { void navigator.clipboard.writeText(connection.command).then(() => setCopied(true), () => setCopied(false)) }}>{copied ? copy.copied : copy.copy}</button></>}
      {connection.logs.length > 0 && <pre aria-label={copy.logs}>{connection.logs.join('\n')}</pre>}
      {current.reason && <p>{current.reason}</p>}
    </details>}
  </section>
}
