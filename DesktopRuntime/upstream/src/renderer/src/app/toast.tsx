/**
 * [M5] Minimal app-level toast: a zustand queue plus a fixed host rendered
 * once in AppShell. Call `showToast(message)` from anywhere in the renderer.
 * Toasts auto-dismiss (danger toasts stay a bit longer) and can be clicked
 * away.
 */

import { create } from 'zustand'

const TOAST_DURATION_MS = 3200
const TOAST_DANGER_DURATION_MS = 6400

const TOAST_ACTION_DURATION_MS = 10_000

export type ToastTone = 'info' | 'danger'

/**
 * [P2-D] Optional action slot. The 1-step group creation flow (§5.1) has no
 * confirmation dialog by design, so its ONLY mistake guard is an undo offered
 * right here — which costs zero steps on the happy path, unlike a confirm.
 * Action toasts stay up for 10s so there is time to notice and reach for it.
 */
export interface ToastAction {
  label: string
  run: () => void
}

interface ToastItem {
  id: number
  message: string
  tone: ToastTone
  action?: ToastAction
}

interface ToastState {
  toasts: ToastItem[]
  show: (message: string, tone: ToastTone, action?: ToastAction) => void
  dismiss: (id: number) => void
}

function durationFor(tone: ToastTone, hasAction: boolean): number {
  if (hasAction) return TOAST_ACTION_DURATION_MS
  return tone === 'danger' ? TOAST_DANGER_DURATION_MS : TOAST_DURATION_MS
}

let toastSeq = 0

const useToastStore = create<ToastState>()((set) => ({
  toasts: [],
  show: (message, tone, action) => {
    toastSeq += 1
    const id = toastSeq
    const item: ToastItem =
      action === undefined ? { id, message, tone } : { id, message, tone, action }
    set((state) => ({ toasts: [...state.toasts, item] }))
    window.setTimeout(() => {
      set((state) => ({
        toasts: state.toasts.filter((toast) => toast.id !== id)
      }))
    }, durationFor(tone, action !== undefined))
  },
  dismiss: (id) => {
    set((state) => ({
      toasts: state.toasts.filter((toast) => toast.id !== id)
    }))
  }
}))

/** Imperative entry point for features (imports, background failures, …). */
export function showToast(message: string, tone: ToastTone = 'info'): void {
  useToastStore.getState().show(message, tone)
}

/** Toast carrying a single reversible action (e.g. 되돌리기). */
export function showToastWithAction(
  message: string,
  action: ToastAction,
  tone: ToastTone = 'info'
): void {
  useToastStore.getState().show(message, tone, action)
}

export function ToastHost(): JSX.Element | null {
  const toasts = useToastStore((state) => state.toasts)
  const dismiss = useToastStore((state) => state.dismiss)
  if (toasts.length === 0) return null

  return (
    <div className="toast-host" role="status" aria-live="polite">
      {toasts.map((toast) =>
        toast.action === undefined ? (
          <button
            key={toast.id}
            type="button"
            className="toast"
            data-tone={toast.tone}
            onClick={() => dismiss(toast.id)}
          >
            {toast.message}
          </button>
        ) : (
          // With an action the toast can no longer be one big button — a
          // nested button is invalid HTML and steals the click.
          <div key={toast.id} className="toast" data-tone={toast.tone}>
            <span className="toast__message">{toast.message}</span>
            <button
              type="button"
              className="toast__action"
              onClick={() => {
                dismiss(toast.id)
                toast.action?.run()
              }}
            >
              {toast.action.label}
            </button>
            <button
              type="button"
              className="toast__dismiss"
              aria-label="알림 닫기"
              onClick={() => dismiss(toast.id)}
            >
              ✕
            </button>
          </div>
        )
      )}
    </div>
  )
}
