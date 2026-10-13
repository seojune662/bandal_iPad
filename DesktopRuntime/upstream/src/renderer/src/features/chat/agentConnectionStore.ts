import { create } from 'zustand'
import { useUiStore } from '../../stores/uiStore'
import { isAgentReady } from '../../../../shared/agentProviderSelection'
import { AGENT_PROVIDERS, isAgentProvider, type AgentAvailability, type AgentProvider } from '../../../../shared/types/agent-events'
import { invoke, onPush, type Unsubscribe } from '../../lib/ipc'

export const INSTALL_CHECK_TIMEOUT_MS = 60_000
export const CONNECTION_POLL_MS = 3_000

export type ConnectionStage = 'idle' | 'installing' | 'checking-install' | 'opening-login' | 'waiting-login' | 'verifying-login' | 'error'
export interface AgentConnectionSnapshot {
  availability: AgentAvailability | null
  loading: boolean
  stage: ConnectionStage
  command: string
  supported: boolean | null
  logs: string[]
  message: string
  error: string | null
  availabilityError: string | null
  loginFailure: string
  loginUrl: string | null
  requiresCode: boolean
  modelsRevision: number
  modelsInvalidationRevision: number
  availabilityRevision: number
}
const emptyConnection = (): AgentConnectionSnapshot => ({ availability: null, loading: false, stage: 'idle', command: '', supported: null, logs: [], message: '', error: null, availabilityError: null, loginFailure: '', loginUrl: null, requiresCode: false, modelsRevision: 0, modelsInvalidationRevision: 0, availabilityRevision: 0 })
const initialConnections = () => Object.fromEntries(AGENT_PROVIDERS.map(provider => [provider, emptyConnection()])) as Record<AgentProvider, AgentConnectionSnapshot>
export const useAgentConnectionStore = create<{ connections: Record<AgentProvider, AgentConnectionSnapshot> }>(() => ({ connections: initialConnections() }))

interface ConnectionRuntime {
  refs: number
  generation: number
  operation: number
  probe: { promise: Promise<void>; refresh: boolean } | null
  command: Promise<void> | null
  commandGeneration: number
  modelsDirty: boolean
  poll: ReturnType<typeof setTimeout> | null
  deadline: ReturnType<typeof setTimeout> | null
  autoLogin: boolean
  loginRequestId: string | null
  loginCompleted: boolean
  repairedLogin: boolean
}
const runtimes = new Map<AgentProvider, ConnectionRuntime>()
let unsubscribeProgress: Unsubscribe | null = null
let unsubscribeLoginProgress: Unsubscribe | null = null
let stopFocusListeners: (() => void) | null = null

function runtimeFor(provider: AgentProvider): ConnectionRuntime {
  let runtime = runtimes.get(provider)
  if (!runtime) {
    runtime = { refs: 0, generation: 0, operation: 0, probe: null, command: null, commandGeneration: 0, modelsDirty: false, poll: null, deadline: null, autoLogin: false, loginRequestId: null, loginCompleted: false, repairedLogin: false }
    runtimes.set(provider, runtime)
  }
  return runtime
}
function snapshot(provider: AgentProvider): AgentConnectionSnapshot { return useAgentConnectionStore.getState().connections[provider] }
function update(provider: AgentProvider, change: Partial<AgentConnectionSnapshot>): void {
  useAgentConnectionStore.setState(state => ({ connections: { ...state.connections, [provider]: { ...state.connections[provider], ...change } } }))
}
export function hasCompatibleAgentBinary(availability: AgentAvailability | null): boolean {
  return availability?.installed === true && (availability.code === undefined || availability.code === 'not-logged-in')
}
export function isAgentConnectionReady(availability: AgentAvailability | null): boolean {
  return isAgentReady(availability ?? undefined)
}
export function isAgentConnectionBusy(stage: ConnectionStage): boolean {
  return stage === 'installing' || stage === 'checking-install' || stage === 'opening-login' || stage === 'waiting-login' || stage === 'verifying-login'
}
function clearTimers(runtime: ConnectionRuntime): void {
  if (runtime.poll !== null) clearTimeout(runtime.poll)
  if (runtime.deadline !== null) clearTimeout(runtime.deadline)
  runtime.poll = null
  runtime.deadline = null
}
function finishReady(provider: AgentProvider): void {
  const runtime = runtimeFor(provider)
  clearTimers(runtime)
  runtime.autoLogin = false
  runtime.loginRequestId = null
  runtime.loginCompleted = false
  update(provider, { stage: 'idle', error: null, loginFailure: '', loginUrl: null, requiresCode: false, message: '' })
}
function schedulePoll(provider: AgentProvider): void {
  const runtime = runtimeFor(provider)
  const stage = snapshot(provider).stage
  if (runtime.poll !== null || (stage !== 'checking-install' && stage !== 'waiting-login' && stage !== 'verifying-login')) return
  runtime.poll = setTimeout(() => {
    runtime.poll = null
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') { schedulePoll(provider); return }
    void refreshAgentConnection(provider, true)
  }, CONNECTION_POLL_MS)
}
function startDeadline(provider: AgentProvider, timeout: number, message: string): void {
  const runtime = runtimeFor(provider)
  if (runtime.deadline !== null) clearTimeout(runtime.deadline)
  const operation = runtime.operation
  runtime.deadline = setTimeout(() => {
    if (runtime.operation !== operation) return
    runtime.operation += 1
    runtime.autoLogin = false
    clearTimers(runtime)
    update(provider, { stage: 'error', error: message, message: '' })
  }, timeout)
}
function settleAvailability(provider: AgentProvider): void {
  const runtime = runtimeFor(provider)
  const current = snapshot(provider)
  if (current.stage === 'checking-install' && hasCompatibleAgentBinary(current.availability)) {
    clearTimers(runtime)
    if (runtime.autoLogin && (runtime.repairedLogin || !isAgentConnectionReady(current.availability))) {
      runtime.autoLogin = false
      void startAgentLogin(provider, true)
    } else if (isAgentConnectionReady(current.availability)) finishReady(provider)
  } else if ((current.stage === 'verifying-login' && runtime.loginCompleted || current.stage === 'error') && isAgentConnectionReady(current.availability)) finishReady(provider)
  schedulePoll(provider)
}
function installListeners(): void {
  if (unsubscribeProgress !== null) return
  unsubscribeProgress = onPush('agent:install-progress', progress => {
    if (!isAgentProvider(progress.provider)) return
    const provider = progress.provider
    if (snapshot(provider).stage === 'installing' && progress.line !== '') update(provider, { logs: [...snapshot(provider).logs.slice(-119), progress.line] })
    // The invoking surface owns continuation. A broadcast from another install
    // must never open a second login terminal or finish an unrelated operation.
    if (progress.done) {
      if (snapshot(provider).stage === 'installing') void refreshAgentConnection(provider, true)
      else void refreshAgentConnectionAfterMutation(provider)
    }
  })
  unsubscribeLoginProgress = onPush('agent:login-progress', progress => {
    if (!isAgentProvider(progress.provider)) return
    const provider = progress.provider
    const current = snapshot(provider)
    if (runtimeFor(provider).loginRequestId !== progress.requestId) return
    if (!['opening-login', 'waiting-login', 'verifying-login'].includes(current.stage)) return
    if (progress.stage === 'waiting-browser') {
      update(provider, { stage: 'waiting-login', message: progress.message, loginUrl: progress.url ?? current.loginUrl, requiresCode: progress.requiresCode ?? current.requiresCode })
      if (current.stage === 'opening-login') useUiStore.getState().closeSettings()
    } else if (progress.stage === 'verifying' || progress.stage === 'done') {
      update(provider, { stage: 'verifying-login', message: progress.message })
    } else if (progress.stage === 'error') {
      clearTimers(runtimeFor(provider))
      update(provider, { stage: 'error', error: progress.message, loginUrl: null, requiresCode: false })
    } else if (progress.stage === 'cancelled') {
      clearTimers(runtimeFor(provider))
      update(provider, { stage: 'idle', message: '', loginUrl: null })
    } else update(provider, { message: progress.message })
  })
  if (typeof window === 'undefined') return
  const refreshVisible = (): void => {
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
    for (const [provider, runtime] of runtimes) if (runtime.refs > 0 || snapshot(provider).stage === 'waiting-login') void refreshAgentConnection(provider, true)
  }
  window.addEventListener('focus', refreshVisible)
  document.addEventListener('visibilitychange', refreshVisible)
  stopFocusListeners = () => { window.removeEventListener('focus', refreshVisible); document.removeEventListener('visibilitychange', refreshVisible) }
}

/** Renderer-wide single flight. Forced refresh supersedes an older cached probe. */
export function refreshAgentConnection(provider: AgentProvider, refresh = false): Promise<void> {
  const runtime = runtimeFor(provider)
  if (runtime.probe !== null && (!refresh || runtime.probe.refresh)) return runtime.probe.promise
  const generation = ++runtime.generation
  update(provider, { loading: true, availabilityError: null })
  const probe = { refresh, promise: Promise.resolve() }
  runtime.probe = probe
  probe.promise = invoke('agent:availability', { provider, ...(refresh ? { refresh: true } : {}) }).then(
    availability => {
      if (runtime.generation !== generation) return
      const previous = snapshot(provider)
      const accountChanged = previous.availability?.accountEmail !== availability.accountEmail || previous.availability?.subscriptionType !== availability.subscriptionType || previous.availability?.version !== availability.version
      const refreshModels = isAgentConnectionReady(availability) && (runtime.modelsDirty || !isAgentConnectionReady(previous.availability) || accountChanged)
      if (refreshModels) runtime.modelsDirty = false
      update(provider, { availability, availabilityRevision: previous.availabilityRevision + 1, modelsRevision: previous.modelsRevision + (refreshModels ? 1 : 0), loading: false, ...(previous.stage === 'idle' ? { error: null } : {}) })
      settleAvailability(provider)
    },
    () => {
      if (runtime.generation !== generation) return
      update(provider, { loading: false, availabilityError: 'AI 연결 상태를 확인하지 못했어요. 다시 확인해 주세요.' })
      schedulePoll(provider)
    }
  ).finally(() => { if (runtime.probe === probe) runtime.probe = null })
  return probe.promise
}
export function seedAgentAvailability(provider: AgentProvider, availability: AgentAvailability): void {
  if (snapshot(provider).availability === null && !snapshot(provider).loading) update(provider, { availability })
}
export function acquireAgentConnection(provider: AgentProvider, refresh = false): () => void {
  const runtime = runtimeFor(provider)
  runtime.refs += 1
  installListeners()
  void refreshAgentConnection(provider, refresh)
  let released = false
  return () => { if (!released) { released = true; runtime.refs = Math.max(0, runtime.refs - 1) } }
}
export function prepareAgentConnection(provider: AgentProvider, refresh = false): Promise<void> {
  const runtime = runtimeFor(provider)
  if (!refresh && runtime.command !== null) return runtime.command
  if (!refresh && snapshot(provider).command !== '') return Promise.resolve()
  const generation = ++runtime.commandGeneration
  runtime.command = invoke('agent:installCommand', { provider }).then(result => { if (runtime.commandGeneration === generation) update(provider, { command: result.command, supported: result.supported }) }).finally(() => { if (runtime.commandGeneration === generation) runtime.command = null })
  return runtime.command
}
export async function startAgentInstall(provider: AgentProvider, repairingLogin = false): Promise<void> {
  const runtime = runtimeFor(provider)
  if (isAgentConnectionBusy(snapshot(provider).stage)) return
  if (!repairingLogin) runtime.repairedLogin = false
  installListeners()
  clearTimers(runtime)
  const operation = ++runtime.operation
  runtime.autoLogin = false
  update(provider, { stage: 'installing', logs: [], error: null, message: '', loginFailure: '' })
  try {
    await prepareAgentConnection(provider, true)
    if (runtime.operation !== operation) return
    if (snapshot(provider).supported === false) throw new Error('이 기기에서는 자동 설치를 지원하지 않아요. 연결 상세 정보를 확인해 주세요.')
    const result = await invoke('agent:install', { provider })
    if (runtime.operation !== operation) return
    if (!result.ok) throw new Error(result.message)
    runtime.autoLogin = true
    update(provider, { stage: 'checking-install', message: result.message })
    startDeadline(provider, INSTALL_CHECK_TIMEOUT_MS, '설치 후 연결을 확인하지 못했어요. 설치 경로와 버전을 확인한 뒤 다시 시도해 주세요.')
    await refreshAgentConnectionAfterMutation(provider)
  } catch (error) {
    if (runtime.operation !== operation) return
    clearTimers(runtime)
    update(provider, { stage: 'error', error: error instanceof Error ? error.message : '설치 요청을 완료하지 못했어요.' })
  }
}
/** Continue from the last verified step, including after a failed or cancelled attempt. */
export async function startAgentConnection(provider: AgentProvider): Promise<void> {
  if (isAgentConnectionBusy(snapshot(provider).stage)) return
  const availability = snapshot(provider).availability
  if (availability?.installed !== true || availability.code === 'version-too-old') await startAgentInstall(provider)
  else await startAgentLogin(provider)
}
export async function startAgentLogin(provider: AgentProvider, continuingInstallation = false): Promise<void> {
  const runtime = runtimeFor(provider)
  if (isAgentConnectionBusy(snapshot(provider).stage) && snapshot(provider).stage !== 'checking-install') return
  if (!continuingInstallation) runtime.repairedLogin = false
  installListeners()
  clearTimers(runtime)
  const operation = ++runtime.operation
  const requestId = crypto.randomUUID()
  runtime.loginRequestId = requestId
  runtime.loginCompleted = false
  update(provider, { stage: 'opening-login', error: null, loginFailure: '', loginUrl: null, requiresCode: false, message: '' })
  try {
    // The managed login stays pending while the user signs in inside Bandal.
    const result = await invoke('agent:login', { provider, requestId })
    if (runtime.operation !== operation) return
    if (result.requiresUpdate && !runtime.repairedLogin) {
      runtime.repairedLogin = true
      update(provider, { stage: 'idle', message: '' })
      await startAgentInstall(provider, true)
      return
    }
    if (!result.ok) { clearTimers(runtime); update(provider, { stage: 'error', error: result.message }); return }
    runtime.loginCompleted = true
    update(provider, { stage: 'verifying-login', message: '로그인을 마쳤어요. 연결을 확인하고 있어요.' })
    startDeadline(provider, INSTALL_CHECK_TIMEOUT_MS, '로그인은 끝났지만 연결을 확인하지 못했어요. 다시 확인해 주세요.')
    await refreshAgentConnectionAfterMutation(provider)
  } catch {
    if (runtime.operation !== operation) return
    clearTimers(runtime)
    update(provider, { stage: 'error', error: '로그인을 완료하지 못했어요. 다시 연결해 주세요.' })
  }
}
export async function cancelAgentLogin(provider: AgentProvider): Promise<void> {
  const runtime = runtimeFor(provider)
  if (!['opening-login', 'waiting-login', 'verifying-login'].includes(snapshot(provider).stage)) return
  const operation = ++runtime.operation
  const requestId = runtime.loginRequestId ?? undefined
  runtime.loginRequestId = null
  runtime.loginCompleted = false
  clearTimers(runtime)
  update(provider, { stage: 'idle', message: '', error: null, loginUrl: null })
  try { await invoke('agent:cancelLogin', { provider, ...(requestId ? { requestId } : {}) }) }
  catch { if (runtime.operation === operation) update(provider, { stage: 'error', error: '로그인을 중단하지 못했어요. 다시 시도해 주세요.' }) }
}
export async function reopenAgentLogin(provider: AgentProvider, external = false): Promise<void> {
  const runtime = runtimeFor(provider)
  const operation = runtime.operation
  try {
    const result = await invoke('agent:reopenLogin', { provider, external, ...(runtimeFor(provider).loginRequestId ? { requestId: runtimeFor(provider).loginRequestId! } : {}) })
    if (runtime.operation !== operation) return
    if (!result.ok) update(provider, { error: result.message })
    else if (!external) useUiStore.getState().closeSettings()
  } catch { if (runtime.operation === operation) update(provider, { error: '로그인 페이지를 다시 열지 못했어요. 잠시 후 다시 시도해 주세요.' }) }
}
export async function submitAgentLoginCode(provider: AgentProvider, code: string): Promise<boolean> {
  const runtime = runtimeFor(provider)
  const operation = runtime.operation
  try {
    const result = await invoke('agent:submitLoginCode', { provider, code, ...(runtimeFor(provider).loginRequestId ? { requestId: runtimeFor(provider).loginRequestId! } : {}) })
    if (runtime.operation !== operation) return false
    if (!result.ok) update(provider, { error: result.message })
    return result.ok
  } catch {
    if (runtime.operation === operation) update(provider, { error: '로그인 코드를 보내지 못했어요. 다시 시도해 주세요.' })
    return false
  }
}
/** A mutation must not reuse a probe begun before credentials/installation changed. */
export function refreshAgentConnectionAfterMutation(provider: AgentProvider): Promise<void> {
  const runtime = runtimeFor(provider)
  runtime.generation += 1
  runtime.probe = null
  runtime.modelsDirty = true
  update(provider, { modelsInvalidationRevision: snapshot(provider).modelsInvalidationRevision + 1 })
  return refreshAgentConnection(provider, true)
}
export function resetAgentConnectionsForTests(): void {
  for (const runtime of runtimes.values()) { runtime.generation += 1; runtime.operation += 1; runtime.commandGeneration += 1; clearTimers(runtime) }
  runtimes.clear()
  unsubscribeProgress?.()
  unsubscribeProgress = null
  unsubscribeLoginProgress?.()
  unsubscribeLoginProgress = null
  stopFocusListeners?.()
  stopFocusListeners = null
  useAgentConnectionStore.setState({ connections: initialConnections() })
}
