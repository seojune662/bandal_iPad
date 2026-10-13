import {
  useEffect,
  useId,
  useRef,
  useState,
  type FormEvent
} from 'react'
import type {
  IpcRequest,
  IpcResponse
} from '../../../../shared/ipc/contract'
import * as appLinks from '../../../../shared/appLinks'
import { showToast, showToastWithAction } from '../../app/toast'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import './feedback.css'

export const OPEN_FEEDBACK_EVENT = 'bandal:open-feedback'

type FeedbackKind = IpcRequest<'feedback:send'>['kind']
type FeedbackResult = IpcResponse<'feedback:send'>

const KIND_OPTIONS: ReadonlyArray<{
  value: FeedbackKind
  labelKey: string
}> = [
  { value: 'bug', labelKey: 'feedback.kind.bug' },
  { value: 'friction', labelKey: 'feedback.kind.friction' },
  { value: 'feature', labelKey: 'feedback.kind.feature' }
]

export interface FeedbackDialogProps {
  /** Supports deterministic previews and server-rendered regression tests. */
  initiallyOpen?: boolean
  initialKind?: FeedbackKind
}

export function feedbackResultState(
  result: FeedbackResult
): 'success' | 'rate-limited' | 'unavailable' {
  if (result.ok) return 'success'
  return result.reason
}

export function FeedbackDialog({
  initiallyOpen = false,
  initialKind = 'bug'
}: FeedbackDialogProps = {}): JSX.Element | null {
  const t = useT()
  const titleId = useId()
  const bodyId = useId()
  const dialogRef = useRef<HTMLElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const [open, setOpen] = useState(initiallyOpen)
  const [kind, setKind] = useState<FeedbackKind>(initialKind)
  const [body, setBody] = useState('')
  const [includeAppInfo, setIncludeAppInfo] = useState(true)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const resetForm = (): void => {
    setKind('bug')
    setBody('')
    setIncludeAppInfo(true)
    setError(null)
  }

  const close = (): void => {
    if (pending) return
    setOpen(false)
    resetForm()
  }

  useFocusTrap(dialogRef, {
    active: open,
    initialFocus: textareaRef,
    onEscape: pending ? undefined : close
  })

  useEffect(() => {
    const handleOpen = (): void => {
      setOpen(true)
    }
    window.addEventListener(OPEN_FEEDBACK_EVENT, handleOpen)
    return () => window.removeEventListener(OPEN_FEEDBACK_EVENT, handleOpen)
  }, [])

  const githubAction = {
    label: t('feedback.githubOpen'),
    run: (): void => {
      void invoke('shell:openExternal', {
        url: appLinks.GITHUB_ISSUES_URL
      }).catch(() => {
        console.error('[feedback] GitHub issues page unavailable')
        showToast(t('feedback.githubOpenFailed'), 'danger')
      })
    }
  }

  const handleUnavailable = async (): Promise<void> => {
    let copied = false
    try {
      await navigator.clipboard.writeText(body)
      copied = true
    } catch {
      // Never pass the Clipboard error object: a platform implementation may
      // include the rejected content in its message.
      console.error('[feedback] clipboard copy failed')
    }
    const message = t(copied ? 'feedback.unavailable' : 'feedback.unavailableCopyFailed')
    setError(message)
    showToastWithAction(message, githubAction)
  }

  const submit = async (event: FormEvent<HTMLFormElement>): Promise<void> => {
    event.preventDefault()
    if (pending || body.trim() === '') return

    setPending(true)
    setError(null)
    try {
      let result: FeedbackResult
      try {
        result = await invoke('feedback:send', {
          kind,
          body,
          includeAppInfo
        })
      } catch {
        // Treat a broken IPC path like any other unavailable backend, while
        // keeping user-authored feedback out of diagnostic output.
        console.error('[feedback] feedback:send unavailable')
        result = { ok: false, reason: 'unavailable' }
      }

      const state = feedbackResultState(result)
      if (state === 'success') {
        showToast(t('feedback.success'))
        setOpen(false)
        resetForm()
      } else if (state === 'rate-limited') {
        setError(t('feedback.rateLimited'))
      } else {
        await handleUnavailable()
      }
    } finally {
      setPending(false)
    }
  }

  if (!open) return null

  return (
    <div
      className="help-feedback-backdrop"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) close()
      }}
    >
      <section
        ref={dialogRef}
        className="help-feedback"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
      >
        <header className="help-feedback__header">
          <h2 id={titleId}>{t('feedback.title')}</h2>
        </header>

        <form onSubmit={(event) => void submit(event)}>
          <fieldset className="help-feedback__fields" disabled={pending}>
            <legend>{t('feedback.kind.label')}</legend>
            <div
              className="help-feedback__segments"
              role="radiogroup"
              aria-label={t('feedback.kind.label')}
            >
              {KIND_OPTIONS.map((option) => (
                <button
                  key={option.value}
                  type="button"
                  className="help-feedback__segment"
                  data-selected={kind === option.value ? 'true' : undefined}
                  role="radio"
                  aria-checked={kind === option.value}
                  onClick={() => setKind(option.value)}
                >
                  {t(option.labelKey)}
                </button>
              ))}
            </div>

            <label className="help-feedback__body-label" htmlFor={bodyId}>
              {t('feedback.body.label')}
            </label>
            <textarea
              ref={textareaRef}
              id={bodyId}
              className="help-feedback__textarea"
              value={body}
              maxLength={4_000}
              required
              placeholder={t('feedback.body.placeholder')}
              onChange={(event) => setBody(event.target.value)}
            />

            <label className="help-feedback__app-info">
              <input
                type="checkbox"
                checked={includeAppInfo}
                onChange={(event) => setIncludeAppInfo(event.target.checked)}
              />
              <span>{t('feedback.includeAppInfo')}</span>
            </label>
          </fieldset>

          {error !== null && <p className="form-error" role="alert">{error}</p>}

          <footer className="help-feedback__actions">
            <button
              type="button"
              className="button button--secondary"
              disabled={pending}
              onClick={close}
            >
              {t('feedback.cancel')}
            </button>
            <button
              type="submit"
              className="button button--primary"
              disabled={pending || body.trim() === ''}
            >
              {pending ? t('feedback.sending') : t('feedback.send')}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}
