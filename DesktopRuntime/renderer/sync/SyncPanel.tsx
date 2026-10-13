import { useCallback, useEffect, useState } from 'react'
import { useLocale } from '../../upstream/src/renderer/src/i18n'
import './sync.css'

type Status = { phase: string; conflicts: number; pending?: number; error?: string; lastSyncedAt?: string }
type RecordVersion = { id: string; kind: string; deleted: boolean; payload: Record<string, unknown> }
type Conflict = { id: string; recordID: string; label?: string; createdAt: string; local: RecordVersion | null; remote: RecordVersion }
type Selection = { id: string; variant: 'local' | 'remote' }
type SyncTransport = {
  invoke(channel: string, request: Record<string, unknown>): Promise<unknown>
  on(channel: string, action: (value: Status) => void): () => void
}
export const syncTransport = () => window.bandal as unknown as SyncTransport
export const syncRequest = <T,>(channel: string, request: Record<string, unknown> = {}) => syncTransport().invoke(channel, request) as Promise<T>

function title(item: Conflict): string {
  if (item.label) return item.label
  const payload = item.local?.payload ?? item.remote.payload
  return String(payload.title ?? payload.fileName ?? payload.relPath ?? payload.name ?? item.recordID)
}
function preview(value: RecordVersion | null, ko: boolean): string {
  if (!value) return ko ? '이 기기에 저장된 사본이 없습니다.' : 'No copy on this device.'
  if (value.deleted) return ko ? '삭제된 버전' : 'Deleted version'
  const text = value.payload.markdown ?? value.payload.text ?? value.payload.content
  const result = typeof text === 'string' ? text : JSON.stringify(value.payload, null, 2)
  return result.length > 3000 ? result.slice(0, 3000) + '\n…' : result
}

/** Uses the existing Account settings cards, buttons and confirmation pattern.
 * Conflicts remain available after a toast expires or the app is restarted. */
export function SyncPanel(): JSX.Element {
  const ko = useLocale() === 'ko-KR'
  const [state, setState] = useState<Status | null>(null)
  const [items, setItems] = useState<Conflict[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [selection, setSelection] = useState<Selection | null>(null)
  const load = useCallback(async () => {
    const [next, conflicts] = await Promise.all([
      syncRequest<Status>('runtime:syncState'), syncRequest<Conflict[]>('runtime:syncConflicts')
    ])
    setState(next); setItems(conflicts)
  }, [])
  useEffect(() => {
    let alive = true
    const refresh = () => { void load().catch(reason => { if (alive) setError(String(reason instanceof Error ? reason.message : reason)) }) }
    const stop = syncTransport().on('runtime:syncChanged', () => refresh())
    refresh()
    return () => { alive = false; stop() }
  }, [load])
  const run = async (work: () => Promise<unknown>) => {
    if (busy) return
    setBusy(true); setError(null)
    try { await work(); setSelection(null); await load() }
    catch (reason) { setError(reason instanceof Error ? reason.message : String(reason)) }
    finally { setBusy(false) }
  }
  return <section className="settings-card">
    <div className="settings-card__header">
      <h2>{ko ? '기기 간 동기화' : 'Sync across devices'}</h2>
      <p>{ko ? '자료와 학습 기록을 같은 반달 계정의 기기에서 이어 사용합니다.' : 'Continue your materials and study history on devices using the same Bandal account.'}</p>
    </div>
    <div className="account-nickname-form">
      <div className="account-nickname-form__row">
        <p className="account-field-help" role="status">{state?.phase === 'syncing' ? (ko ? '동기화 중…' : 'Syncing…') : state?.phase === 'waiting' ? (ko ? '동기화 대기 중' : 'Waiting to sync') : state?.lastSyncedAt ? (ko ? '마지막 동기화: ' : 'Last synced: ') + new Date(state.lastSyncedAt).toLocaleString() : (ko ? '변경 내용을 기기에 먼저 저장합니다.' : 'Changes are saved on this device first.')}</p>
        <button className="secondary-button" type="button" disabled={busy || state?.phase === 'syncing'} onClick={() => void run(() => syncRequest('runtime:syncNow'))}>{ko ? '지금 동기화' : 'Sync now'}</button>
      </div>
      {(error || state?.error) && <p className="account-panel__feedback" data-tone="error" role="alert">{error ?? state?.error}</p>}
      {items.length > 0 && <p>{ko ? `${items.length}개의 충돌 사본을 보관하고 있습니다. 내용을 비교한 뒤 사용할 버전을 선택해 주세요.` : `${items.length} conflict copies are preserved. Compare them and choose which version to use.`}</p>}
      {items.map(item => <details key={item.id} className="sync-conflict">
        <summary>{title(item)} <span className="account-field-help">{new Date(item.createdAt).toLocaleString()}</span></summary>
        <div className="sync-conflict__versions">
          {(['local', 'remote'] as const).map(variant => <section key={variant}>
            <h3>{variant === 'local' ? (ko ? '이 기기의 사본' : 'Copy on this device') : (ko ? '다른 기기의 사본' : 'Copy from another device')}</h3>
            <pre>{preview(item[variant], ko)}</pre>
            <button type="button" className="secondary-button" disabled={busy || item[variant] === null} onClick={() => setSelection({ id: item.id, variant })}>{ko ? '이 버전 사용' : 'Use this version'}</button>
          </section>)}
        </div>
        <button type="button" className="secondary-button" disabled={busy} onClick={() => void run(() => syncRequest('runtime:syncExport', { id: item.id }))}>{ko ? '두 사본 내보내기' : 'Export both copies'}</button>
        {selection?.id === item.id && <div className="account-nickname-confirm" role="alertdialog" aria-label={ko ? '충돌 사본 적용' : 'Apply conflict copy'}>
          <p>{ko ? '선택한 버전을 현재 자료에 적용합니다. 기존 사본과 검토 중 수정한 내용은 복구 기록에 보관합니다.' : 'Apply the selected version to the current material. Existing copies and edits made during review stay in recovery history.'}</p>
          <div className="account-nickname-confirm__actions">
            <button type="button" className="secondary-button" disabled={busy} onClick={() => setSelection(null)}>{ko ? '취소' : 'Cancel'}</button>
            <button type="button" className="secondary-button account-nickname-confirm__accept" disabled={busy} onClick={() => void run(() => syncRequest('runtime:syncRestore', selection))}>{ko ? '선택한 버전 적용' : 'Apply selected version'}</button>
          </div>
        </div>}
      </details>)}
    </div>
  </section>
}
