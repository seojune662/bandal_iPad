import { useState } from 'react'
import { showToast } from '../../../app/toast'
import { invoke } from '../../../lib/ipc'

interface PreviewFallbackProps {
  courseId: string
  relPath: string
}

/**
 * 앱이 렌더링하지 못하는 형식(.ppt 등)의 착지 화면 — 죽은 클릭 대신
 * macOS Quick Look(그 외 OS 는 기본 앱)과 Finder 로 이어준다.
 */
export function PreviewFallback({
  courseId,
  relPath
}: PreviewFallbackProps): JSX.Element {
  const [busy, setBusy] = useState(false)
  const name = relPath.split('/').at(-1) ?? relPath

  const run = (channel: 'materials:preview' | 'materials:reveal'): void => {
    setBusy(true)
    void invoke(channel, { courseId, relPath })
      .catch(() => {
        showToast('파일을 열지 못했습니다.', 'danger')
      })
      .finally(() => setBusy(false))
  }

  return (
    <div className="file-status file-preview" role="status">
      <h2>{name}</h2>
      <p>앱에서 열 수 없는 형식입니다. 시스템 미리보기로 확인하세요.</p>
      <div className="file-preview__actions">
        <button
          type="button"
          className="file-action"
          disabled={busy}
          onClick={() => run('materials:preview')}
        >
          미리보기
        </button>
        <button
          type="button"
          className="file-action"
          disabled={busy}
          onClick={() => run('materials:reveal')}
        >
          Finder에서 보기
        </button>
      </div>
    </div>
  )
}
