import { invoke } from '../../upstream/src/renderer/src/lib/ipc'
import type { BrowserLoadErrorOverlay } from '../../upstream/src/renderer/src/features/browser/loadError'

export type BrowserErrorKind = 'offline' | 'dns' | 'timeout' | 'connection' | 'certificate' | 'policy' | 'unsupported' | 'initialization' | 'crashed' | 'unknown'
export interface RecoveryNavState { navigationId?: number; estimatedProgress?: number }
export interface RecoveryMetadata extends RecoveryNavState {
  errorKind?: BrowserErrorKind
  errorDomain?: string
  retryable?: boolean
  requestMethod?: string
  canReturnToForm?: boolean
}
export type RecoveryOverlay = BrowserLoadErrorOverlay & RecoveryMetadata
export type RecoveryFailure = RecoveryMetadata & {
  errorCode: number; errorDescription: string; validatedURL: string; isMainFrame: boolean
}
export const recoveryRequest = <T = unknown>(channel: string, request: unknown): Promise<T> =>
  (invoke as (channel: string, request: unknown) => Promise<T>)(channel, request)

interface RecoveryHandle {
  reload: () => Promise<void>
  retry: (navigationId: number | undefined, url: string, initialization: boolean) => Promise<void>
  returnToForm: (navigationId: number) => Promise<void>
}
const handles = new Map<string, RecoveryHandle>()
export function registerRecoveryHandle(tabId: string, handle: RecoveryHandle): () => void {
  handles.set(tabId, handle)
  return () => { if (handles.get(tabId) === handle) handles.delete(tabId) }
}
export async function reloadBrowserPage(tabId: string): Promise<void> {
  const handle = handles.get(tabId)
  if (!handle) throw new Error('페이지가 준비되지 않았어요. 주소를 다시 입력해 주세요.')
  await handle.reload()
}
export async function retryBrowserPage(tabId: string, overlay: RecoveryOverlay): Promise<void> {
  const handle = handles.get(tabId)
  if (!handle) throw new Error('페이지가 준비되지 않았어요. 주소를 다시 입력해 주세요.')
  if (overlay.requestMethod && !['GET', 'HEAD'].includes(overlay.requestMethod.toUpperCase())) {
    throw new Error('입력한 내용은 자동으로 다시 보내지 않아요. 원래 페이지로 돌아가 다시 제출해 주세요.')
  }
  await handle.retry(overlay.navigationId, overlay.url, overlay.errorKind === 'initialization')
}
export async function returnToBrowserForm(tabId: string, navigationId: number): Promise<void> {
  const handle = handles.get(tabId)
  if (!handle) throw new Error('페이지를 찾을 수 없어요.')
  await handle.returnToForm(navigationId)
}

/** Native NSURLErrorDomain codes never pass through Chromium's error table. */
export function recoveryCopy(overlay: RecoveryOverlay): { title: string; detail: string } {
  switch (overlay.errorKind) {
    case 'offline': return { title: '인터넷에 연결되어 있지 않아요', detail: 'Wi-Fi 또는 셀룰러 연결을 확인한 뒤 다시 시도해 주세요.' }
    case 'dns': return { title: '주소를 찾지 못했어요', detail: '웹사이트 주소가 맞는지 확인해 주세요.' }
    case 'timeout': return { title: '응답 시간이 초과됐어요', detail: '웹사이트의 응답이 늦어지고 있어요. 잠시 후 다시 시도해 주세요.' }
    case 'connection': return { title: '서버에 연결하지 못했어요', detail: '네트워크 연결이나 웹사이트 서버에 문제가 있어요. 잠시 후 다시 시도해 주세요.' }
    case 'certificate': return { title: '안전한 연결을 확인할 수 없어요', detail: '웹사이트 인증서를 확인하지 못했어요. 기기의 날짜와 시간을 확인하거나 사이트 관리자에게 알려 주세요.' }
    case 'policy': return { title: '이 페이지를 열 수 없어요', detail: '웹사이트의 연결 또는 접근 정책으로 요청이 차단됐어요.' }
    case 'unsupported': return { title: '지원하지 않는 주소예요', detail: '주소가 올바른 웹사이트 주소인지 확인해 주세요.' }
    case 'crashed': return { title: '이 페이지가 멈췄어요', detail: '페이지를 표시하는 과정이 중단됐어요. 다시 시도하면 이 탭에서 계속할 수 있어요.' }
    case 'initialization': return { title: '브라우저를 준비하지 못했어요', detail: '다시 시도하면 이 탭에서 브라우저를 새로 준비해요.' }
    default: return { title: '페이지를 열지 못했어요', detail: '주소와 네트워크 연결을 확인한 뒤 다시 시도해 주세요.' }
  }
}

export function ignoredRecoveryFailure(event: RecoveryFailure, navigationId?: number): boolean {
  if (!event.isMainFrame) return true
  if (event.errorDomain === 'NSURLErrorDomain' && event.errorCode === -999) return true
  if (!event.errorDomain && !event.errorKind && event.errorCode === -3) return true
  // WebKit policy interruption covers handoffs to a download or external app.
  if (event.errorDomain === 'WebKitErrorDomain' && event.errorCode === 102) return true
  return event.navigationId !== undefined && navigationId !== undefined && event.navigationId < navigationId
}
