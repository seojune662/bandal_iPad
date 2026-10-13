/** Main owns update status; all renderer controls share the same pending actions. */
import { create } from 'zustand'
import type { UpdateStatus } from '../../../shared/types/update'
import { invoke, onPush } from '../lib/ipc'
import { prepareUpdateInstall } from '../features/updates/prepareUpdateInstall'

export type UpdateAction = 'check' | 'download' | 'install'
interface UpdateState {
  status: UpdateStatus | null
  /** Retained through a download error so the rail can offer recovery. */
  knownVersion: string | null
  pendingAction: UpdateAction | null
  actionError: string | null
  init: () => void
  check: () => Promise<void>
  download: () => Promise<void>
  install: () => Promise<void>
}
let unsubscribe: (() => void) | null = null
let generation = 0
let resetGeneration = 0
let installAcceptedVersion: string | null = null
let installAttempt = 0
const flights = new Map<UpdateAction, Promise<void>>()

function actionError(action: UpdateAction): string {
  return action === 'check' ? '업데이트를 확인하지 못했어요. 다시 시도해 주세요.'
    : action === 'download' ? '업데이트를 다운로드하지 못했어요. 연결을 확인한 뒤 다시 시도해 주세요.'
      : '업데이트를 적용하지 못했어요. 다시 시도하거나 설정에서 업데이트 상태를 확인해 주세요.'
}
function currentPending(): UpdateAction | null {
  if (installAcceptedVersion !== null || flights.has('install')) return 'install'
  if (flights.has('download')) return 'download'
  return flights.has('check') ? 'check' : null
}
function applyStatus(status: UpdateStatus): void {
  const restartCancelled = status.phase === 'ready' && status.restartCancelled === true
  const previous = useUpdateStore.getState().status
  const alreadyCancelled = previous?.phase === 'ready' && previous.restartCancelled === true &&
    status.phase === 'ready' && previous.version === status.version
  if (restartCancelled && !alreadyCancelled) {
    installAttempt++
    installAcceptedVersion = null
    flights.delete('install')
  }
  if (status.phase === 'error' || status.phase === 'idle' || status.phase === 'unsupported' ||
    ('version' in status && status.version !== installAcceptedVersion)) installAcceptedVersion = null
  useUpdateStore.setState(state => ({
    status, actionError: restartCancelled && !flights.has('install') ? '다시 시작을 취소했어요. 준비된 업데이트는 다시 시작할 때 적용할 수 있어요.' : null, pendingAction: currentPending(),
    knownVersion: 'version' in status ? status.version
      : status.phase === 'idle' || status.phase === 'unsupported' ? null : state.knownVersion
  }))
}
function run(action: UpdateAction, operation: (requestGeneration: number, epoch: number) => Promise<void>): Promise<void> {
  const existing = flights.get(action)
  if (existing) return existing
  const epoch = resetGeneration
  const current = ++generation
  const startingStatus = useUpdateStore.getState().status
  const version = startingStatus && 'version' in startingStatus ? startingStatus.version : useUpdateStore.getState().knownVersion
  const request = Promise.resolve().then(() => operation(current, epoch)).catch(error => {
    const latest = useUpdateStore.getState().status
    const sameOperationStillRunning = action === 'check' && latest?.phase === 'checking'
      || action === 'download' && latest?.phase === 'downloading' && latest.version === version
    // Save/install failures are local to the explicit restart, not stale status
    // replies. Intermediate check/progress pushes also do not settle a request.
    if (epoch === resetGeneration && flights.get(action) === request && (action === 'install' || current === generation || sameOperationStillRunning)) {
      useUpdateStore.setState({ actionError: error instanceof Error ? error.message : actionError(action) })
    }
  }).finally(() => {
    if (flights.get(action) === request) {
      flights.delete(action)
      useUpdateStore.setState({ pendingAction: currentPending() })
    }
  })
  flights.set(action, request)
  useUpdateStore.setState({ pendingAction: currentPending(), actionError: null })
  return request
}
function requestStatus(action: 'check' | 'download'): Promise<void> {
  return run(action, async current => {
    try {
      const status = await invoke(action === 'check' ? 'update:check' : 'update:download', {})
      if (current === generation) applyStatus(status)
    } catch {
      throw new Error(actionError(action))
    }
  })
}

export const useUpdateStore = create<UpdateState>()(() => ({
  status: null, knownVersion: null, pendingAction: null, actionError: null,
  init: () => {
    if (unsubscribe !== null) return
    unsubscribe = onPush('update:changed', status => { generation += 1; applyStatus(status) })
    const current = generation
    void invoke('update:status', {}).then(status => { if (current === generation) applyStatus(status) }).catch(() => {})
  },
  check: () => requestStatus('check'),
  download: () => requestStatus('download'),
  install: () => {
    if (installAcceptedVersion !== null) return Promise.resolve()
    return run('install', async (_current, epoch) => {
      const attempt = ++installAttempt
      const before = useUpdateStore.getState().status
      if (before?.phase !== 'ready') return
      await prepareUpdateInstall()
      const prepared = useUpdateStore.getState().status
      if (epoch !== resetGeneration || attempt !== installAttempt || prepared?.phase !== 'ready' || prepared.version !== before.version) return
      const result = await invoke('update:install', {})
      if (epoch !== resetGeneration || attempt !== installAttempt) return
      if (!result.ok) throw new Error(actionError('install'))
      // Main is about to quit. Keep every restart control disabled until then.
      const latest = useUpdateStore.getState().status
      if (latest?.phase === 'ready' && !latest.restartCancelled && latest.version === before.version) installAcceptedVersion = before.version
    })
  }
}))

export function resetUpdateStoreForTests(): void {
  unsubscribe?.(); unsubscribe = null
  generation += 1; resetGeneration += 1
  flights.clear(); installAcceptedVersion = null; installAttempt++
  useUpdateStore.setState({ status: null, knownVersion: null, pendingAction: null, actionError: null })
}
