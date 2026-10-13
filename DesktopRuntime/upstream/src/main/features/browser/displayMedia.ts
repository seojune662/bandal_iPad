/**
 * Screen sharing, so the 화면 공유 prompt is not a lie.
 *
 * Granting the `display-capture` permission is necessary but not sufficient:
 * without `setDisplayMediaRequestHandler`, `getDisplayMedia()` still rejects.
 * A student who presses 허용 and watches nothing happen learns that the
 * dialog means nothing — the worst failure shape a permission can have.
 *
 * Chrome shows a picker of screens and windows. So do we, rather than
 * silently handing over the whole primary display: 화상 수업 is usually
 * "share the slide deck", and a handler that shares everything would put the
 * student's KakaoTalk on the projector.
 */

import { desktopCapturer, dialog, BrowserWindow, session } from 'electron'

/** Big enough to recognise a window, small enough to build quickly. */
const THUMBNAIL = { width: 320, height: 180 }

export interface CaptureSource {
  id: string
  name: string
  kind: 'screen' | 'window'
}

export async function listCaptureSources(): Promise<CaptureSource[]> {
  const sources = await desktopCapturer.getSources({
    types: ['screen', 'window'],
    thumbnailSize: THUMBNAIL,
    fetchWindowIcons: false
  })
  return sources.map((source) => ({
    id: source.id,
    name: source.name,
    kind: source.id.startsWith('screen:') ? 'screen' : 'window'
  }))
}

/**
 * Asks which screen or window to share.
 *
 * A native list rather than an in-app one for the same reason the permission
 * prompt is native: the page requesting capture can draw a convincing copy of
 * any in-app surface, and "which of your windows shall I record" is precisely
 * the question worth spoofing.
 */
async function chooseSource(
  sources: CaptureSource[]
): Promise<CaptureSource | null> {
  if (sources.length === 0) return null
  const owner = BrowserWindow.getFocusedWindow()
  const labels = sources.map(
    (source) => `${source.kind === 'screen' ? '화면' : '창'} · ${source.name}`
  )
  const options: Electron.MessageBoxOptions = {
    type: 'question',
    noLink: true,
    // The cancel button must be first so the default is not "share something".
    buttons: ['취소', ...labels],
    defaultId: 0,
    cancelId: 0,
    message: '무엇을 공유할까요?',
    detail: '공유하는 동안 상대에게 이 화면이 그대로 보입니다.'
  }
  const { response } =
    owner === null
      ? await dialog.showMessageBox(options)
      : await dialog.showMessageBox(owner, options)
  if (response === 0) return null
  return sources[response - 1] ?? null
}

const installed = new Set<string>()

/** Installs the handler on the browsing session. Idempotent. */
export function installDisplayMediaHandler(partition: string): void {
  if (installed.has(partition)) return
  installed.add(partition)
  session
    .fromPartition(partition)
    .setDisplayMediaRequestHandler(
      (_request, callback) => {
        void (async () => {
          try {
            const sources = await listCaptureSources()
            const chosen = await chooseSource(sources)
            if (chosen === null) {
              // Electron's documented way to say "the student declined".
              callback({})
              return
            }
            const raw = await desktopCapturer.getSources({
              types: ['screen', 'window'],
              thumbnailSize: { width: 0, height: 0 }
            })
            const match = raw.find((source) => source.id === chosen.id)
            if (match === undefined) {
              callback({})
              return
            }
            // Audio is deliberately not offered: macOS has no loopback capture
            // without a kernel extension, so promising it would be another lie.
            callback({ video: match })
          } catch {
            callback({})
          }
        })()
      },
      // We never hand over system audio, so this stays false.
      { useSystemPicker: false }
    )
}
