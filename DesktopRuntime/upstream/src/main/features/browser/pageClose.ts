import { BrowserWindow, dialog, type WebContents, type Event } from 'electron'

type CloseReason = 'tab' | 'profile'
interface PendingClose {
  reason: CloseReason
  promise: Promise<boolean>
  finish(allowed: boolean): void
}
const pending = new WeakMap<WebContents, PendingClose>()

/** The sole beforeunload decision for navigation, tab close and profile change. */
export function confirmPageUnload(contents: WebContents, event: Event, host: WebContents): void {
  const request = pending.get(contents)
  const owner = BrowserWindow.fromWebContents(host)
  const options: Electron.MessageBoxSyncOptions = {
    type: 'question', noLink: true, buttons: ['머무르기', '나가기'], defaultId: 0, cancelId: 0,
    message: request?.reason === 'profile' ? '작성 중인 내용을 두고 프로필을 바꿀까요?' : '이 페이지에서 나가시겠습니까?',
    detail: '작성 중인 내용이 저장되지 않을 수 있습니다.'
  }
  const choice = owner ? dialog.showMessageBoxSync(owner, options) : dialog.showMessageBoxSync(options)
  if (choice === 1) event.preventDefault()
  else request?.finish(false)
}

/** Resolves only when Chromium closes the page or the user cancels beforeunload. */
export function closePage(contents: WebContents, reason: CloseReason): Promise<boolean> {
  if (contents.isDestroyed()) return Promise.resolve(true)
  const existing = pending.get(contents)
  if (existing) return existing.promise
  let finish!: (allowed: boolean) => void
  const promise = new Promise<boolean>(resolve => { finish = resolve })
  const closed = (): void => request.finish(true)
  const request: PendingClose = {
    reason, promise,
    finish(allowed) {
      if (pending.get(contents) !== request) return
      pending.delete(contents)
      contents.removeListener('destroyed', closed)
      finish(allowed)
    }
  }
  pending.set(contents, request)
  contents.once('destroyed', closed)
  try { contents.close({ waitForBeforeUnload: true }) }
  catch { request.finish(contents.isDestroyed()) }
  return promise
}
