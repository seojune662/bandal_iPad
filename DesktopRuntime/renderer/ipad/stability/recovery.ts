import { isOperationError, reportOperationError, type OperationNotice } from './operations'

let reloading: Promise<void> | undefined
type CloseResult = { status: 'saved' | 'copied' | 'failed' }
type Closing = { operation: () => Promise<CloseResult>; flight?: Promise<CloseResult>; failed: boolean }
const closingDocuments = new Set<Closing>()
function runClose(entry: Closing): Promise<CloseResult> {
  if (entry.flight) return entry.flight
  let operation: Promise<CloseResult>
  try { operation = entry.operation() } catch (error) { operation = Promise.reject(error) }
  entry.flight = operation.then(result => {
    entry.failed = result.status === 'failed'
    if (!entry.failed) closingDocuments.delete(entry)
    return result
  }, error => { entry.failed = true; throw error }).finally(() => { delete entry.flight })
  return entry.flight
}
/** Preserve the original writer after React removes its registered session.
 * Failed closures retain that writer for an explicit recovery retry. */
export function trackDocumentClose<T extends CloseResult>(operation: () => Promise<T>): Promise<T> {
  const entry: Closing = { operation, failed: false }
  closingDocuments.add(entry)
  return runClose(entry) as Promise<T>
}
export async function prepareDocumentRecovery(): Promise<void> {
  // Yield through the current commit so React's passive close cleanup is visible.
  await new Promise<void>(resolve => window.setTimeout(resolve, 0))
  for (let attempt = 0; attempt < 8; attempt++) {
    const entries = [...closingDocuments]
    if (!entries.length) break
    await Promise.all(entries.map(runClose))
    if (entries.some(entry => entry.failed)) throw new Error('닫힌 문서의 편집 내용을 아직 저장하지 못했습니다. 저장 공간이나 충돌을 확인한 뒤 다시 시도해 주세요.')
    if (attempt === 7 && closingDocuments.size) throw new Error('문서 저장이 진행 중입니다. 잠시 뒤 다시 시도해 주세요.')
  }
  if (window.bandal) await (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)('runtime:prepareReload', {})
}
/** Never reload an editable workspace until the original writers report saved. */
export function recoverRenderer(): Promise<void> {
  if (reloading) return reloading
  reloading = (async () => {
    await prepareDocumentRecovery()
    window.location.reload()
  })().catch(reason => { reportOperationError(reason, { operation: '화면 복구' }); throw reason }).finally(() => { reloading = undefined })
  return reloading
}

const message = (reason: unknown) => reason instanceof Error ? reason.message : String(reason ?? '작업을 완료하지 못했습니다.')
const button = (text: string, action: () => void) => {
  const element = document.createElement('button')
  element.type = 'button'; element.textContent = text
  Object.assign(element.style, { minHeight: '44px', padding: '8px 14px', borderRadius: '9px', border: '1px solid currentColor', color: 'inherit', background: 'transparent', font: 'inherit' })
  element.addEventListener('click', action)
  return element
}
let activeNotice: { panel: HTMLElement; signature: string; retry: OperationNotice['retry'] } | undefined

/** A dismissible operation notice. It leaves documents and navigation usable. */
export function showOperationNotice({ reason, operation, retry }: OperationNotice): void {
  const signature = [operation ?? '', message(reason), isOperationError(reason) ? reason.code + ':' + reason.channel + ':' + reason.category : ''].join('\0')
  // A surface-mask failure itself produces a notice. Avoid turning its DOM
  // mutation observer into a repeated failure → notice → layout cycle.
  if (activeNotice?.panel.isConnected && activeNotice.signature === signature && activeNotice.retry === retry) return
  document.getElementById('bandal-operation-notice')?.remove()
  const panel = document.createElement('section')
  panel.id = 'bandal-operation-notice'; panel.setAttribute('role', 'alert')
  panel.setAttribute('aria-label', '작업 오류'); panel.setAttribute('data-bandal-native-overlay', '')
  Object.assign(panel.style, { position: 'fixed', right: 'max(12px, env(safe-area-inset-right))', bottom: 'max(12px, env(safe-area-inset-bottom))', zIndex: '2147483646', width: 'min(380px, calc(100vw - 24px))', boxSizing: 'border-box', padding: '16px', borderRadius: '14px', background: '#fff8f2', color: '#592b19', border: '1px solid #deb99c', boxShadow: '0 8px 30px #0002', font: '15px/1.5 system-ui', maxHeight: '45vh', overflow: 'auto' })
  const title = document.createElement('strong')
  title.textContent = operation ?? (isOperationError(reason) && reason.category === 'unsupported' ? 'iPad에서 사용할 수 없는 작업' : '작업을 완료하지 못했어요')
  const body = document.createElement('p'); body.textContent = message(reason)
  body.style.overflowWrap = 'anywhere'
  const actions = document.createElement('div'); Object.assign(actions.style, { display: 'flex', gap: '8px', justifyContent: 'flex-end' })
  if (retry) {
    const retryButton = button('다시 시도', () => {
      retryButton.disabled = true
      void Promise.resolve().then(retry).then(() => panel.remove()).catch(next => {
        body.textContent = message(next)
        // A retry may dispatch a second notice; keep the failed result visible.
        if (!panel.isConnected) showOperationNotice({ reason: next, ...(operation ? { operation } : {}), retry })
      }).finally(() => { retryButton.disabled = false })
    })
    actions.append(retryButton)
  }
  actions.append(button('닫기', () => panel.remove()))
  panel.append(title, body, actions); document.body.append(panel)
  activeNotice = { panel, signature, retry }
}

export function installOperationNotices(): void {
  window.addEventListener('bandal:operation-error', event => showOperationNotice((event as CustomEvent<OperationNotice>).detail))
}

export function showStartupFailure(reason: unknown): void {
  document.getElementById('bandal-native-diagnostic')?.remove()
  const panel = document.createElement('section')
  panel.id = 'bandal-native-diagnostic'; panel.setAttribute('role', 'alert')
  panel.setAttribute('aria-label', '시작 오류'); panel.setAttribute('data-bandal-native-overlay', '')
  Object.assign(panel.style, { position: 'fixed', inset: 'max(16px, env(safe-area-inset-top)) 16px auto', zIndex: '2147483647', padding: '20px', background: '#fff5f4', color: '#541815', border: '1px solid #d49690', borderRadius: '12px', font: '15px/1.5 system-ui', maxHeight: '60vh', overflow: 'auto' })
  const title = document.createElement('h2'); title.textContent = '반달 화면을 열지 못했어요'; title.style.fontSize = '18px'
  const body = document.createElement('p'); body.textContent = message(reason)
  const retry = button('다시 불러오기', () => {
    retry.disabled = true
    void recoverRenderer().catch(next => { body.textContent = message(next) }).finally(() => { retry.disabled = false })
  })
  panel.append(title, body, retry, button('오류 닫기', () => panel.remove())); document.body.append(panel)
}
