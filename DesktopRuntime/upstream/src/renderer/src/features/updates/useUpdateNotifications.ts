/**
 * Surfaces auto-update state as toasts in the workspace window.
 *
 * Only two phases are worth interrupting a student for: a new version exists,
 * and a downloaded one is waiting to be applied. Everything else (checking,
 * download progress, "already up to date") belongs in Settings → About, where
 * it is asked for rather than pushed.
 *
 * Errors are shown once per distinct message, because the 6-hour background
 * check would otherwise re-toast the same failure indefinitely.
 */

import { useEffect, useRef } from 'react'
import { showToast, showToastWithAction } from '../../app/toast'
import { useUpdateStore } from '../../stores/updateStore'

/**
 * Whether a ready download may restart the app by itself.
 *
 * The whole point of the change is one gesture instead of two, but that must
 * not turn into a restart nobody asked for: a build downloaded in an earlier
 * session becomes `ready` again on the next launch, and applying that without
 * being asked would close the student's tabs mid-work.
 */
export function mayRestartUnprompted(
  readyVersion: string,
  versionAskedForThisSession: string | null
): boolean {
  return versionAskedForThisSession === readyVersion
}

export function useUpdateNotifications(): void {
  const status = useUpdateStore((state) => state.status)
  const actionError = useUpdateStore((state) => state.actionError)
  const init = useUpdateStore((state) => state.init)
  const download = useUpdateStore((state) => state.download)
  const install = useUpdateStore((state) => state.install)

  // Toasts are fire-and-forget side effects, so re-entering the same phase
  // must not re-fire them. Keyed by phase+version rather than a bare boolean
  // so a *second* update released later still announces itself.
  const announced = useRef<string | null>(null)
  const lastError = useRef<string | null>(null)
  /**
   * Version the student pressed 업데이트 on in THIS session. Only that one may
   * restart on its own — a download left over from a previous run must not
   * yank the app out from under them at some unrelated moment.
   */
  const askedThisSession = useRef<string | null>(null)

  useEffect(() => {
    init()
  }, [init])

  useEffect(() => {
    if (!actionError || lastError.current === actionError) return
    lastError.current = actionError
    showToast(actionError, 'danger')
  }, [actionError])

  useEffect(() => {
    if (status === null) return

    if (status.phase === 'available') {
      const key = `available:${status.version}`
      if (announced.current === key) return
      announced.current = key
      showToastWithAction(
        `새 버전 ${status.version} — 받은 뒤 자동으로 다시 시작해요`,
        {
          label: '업데이트',
          run: () => {
            // One gesture, not two. The restart is announced up front rather
            // than sprung as a second toast the student has to notice.
            askedThisSession.current = status.version
            void download()
          }
        }
      )
      return
    }

    if (status.phase === 'ready') {
      if (status.restartCancelled) { askedThisSession.current = null; return }
      const key = `ready:${status.version}`
      if (announced.current === key) return
      announced.current = key

      if (mayRestartUnprompted(status.version, askedThisSession.current)) {
        showToast(`${status.version} 적용 중 — 곧 다시 시작해요`)
        void install()
        return
      }

      // Downloaded in an earlier session and never applied. Restarting now
      // would be a restart nobody asked for, so this one still needs a click.
      showToastWithAction(`${status.version} 준비 완료 — 재시작하면 적용됩니다`, {
        label: '재시작',
        run: () => {
          void install()
        }
      })
      return
    }

    if (status.phase === 'error') {
      if (lastError.current === status.message) return
      lastError.current = status.message
      showToast(status.message, 'danger')
    }
  }, [status, download, install])
}
