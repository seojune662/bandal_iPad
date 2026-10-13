import { useEffect, useState } from 'react'
import type { ConversionRuntimeState } from '../../../../../shared/types/presentation'
import { invoke } from '../../../lib/ipc'
import { SlidesViewer } from '../viewers/SlidesViewer'
import './presentation.css'

export function PresentationLoader({ courseId, relPath }: { courseId: string; relPath: string }): JSX.Element {
  const [runtime, setRuntime] = useState<ConversionRuntimeState | null>(null)
  const [base64, setBase64] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [installing, setInstalling] = useState(false)
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    let alive = true
    const requestId = crypto.randomUUID()
    setLoading(true); setError(null)
    void (async () => {
      if (/\.ppt$/i.test(relPath)) {
        const status = await invoke('presentation:runtime', {})
        if (!alive) return
        setRuntime(status)
        if (status.status !== 'ready') return
      }
      const content = await invoke('presentation:prepare', { courseId, relPath, requestId })
      if (alive && content.encoding === 'base64') setBase64(content.data)
    })().catch((cause) => { if (alive) setError(cause instanceof Error ? cause.message : '프레젠테이션을 열지 못했어요.') }).finally(() => { if (alive) setLoading(false) })
    return () => { alive = false; void invoke('presentation:cancelPrepare', { requestId }).catch(() => {}) }
  }, [courseId, relPath, attempt])
  useEffect(() => {
    if (!installing) return
    const interval = window.setInterval(() => void invoke('presentation:runtime', {}).then(setRuntime).catch(() => {}), 500)
    return () => window.clearInterval(interval)
  }, [installing])
  if (base64) return <SlidesViewer key={attempt} courseId={courseId} relPath={relPath} base64={base64} fileName={relPath.split('/').at(-1) ?? relPath} onError={() => { setBase64(null); setError('파일 내용을 읽지 못했어요. 손상되거나 암호화된 파일인지 확인해 주세요.') }} />
  if (loading) return <div className="file-status" role="status">{runtime?.status === 'ready' ? '구형 PPT를 준비하는 중…' : '프레젠테이션을 여는 중…'}</div>
  return <div className="presentation-runtime">
    <h2>{runtime && runtime.status !== 'ready' ? '구형 PPT도 바로 열어보세요' : '프레젠테이션을 열지 못했어요'}</h2>
    {runtime && runtime.status !== 'ready' && <><p>처음 한 번 변환기를 내려받으면 PPT를 읽고 필기할 수 있어요. 이후에는 인터넷 없이 사용할 수 있습니다.</p><p>약 300~450MB 다운로드 · 자료는 기기 안에서만 처리</p></>}
    {(error || runtime?.message) && <p role="alert">{error ?? runtime?.message}</p>}
    {installing ? <><progress value={runtime?.receivedBytes ?? 0} max={runtime?.totalBytes || 450 * 1024 * 1024} /><p role="status">{runtime?.status === 'installing' ? '변환기를 설치하는 중…' : `내려받는 중 · ${Math.round((runtime?.receivedBytes ?? 0) / 1024 / 1024)}MB`}</p><button type="button" onClick={() => void invoke('presentation:cancelRuntime', {})}>취소</button></> : <button type="button" disabled={runtime?.status === 'unsupported'} onClick={() => {
      if (!runtime || runtime.status === 'ready') { setAttempt((v) => v + 1); return }
      setInstalling(true); setError(null)
      void invoke('presentation:installRuntime', {}).then((status) => { setRuntime(status); setAttempt((v) => v + 1) }).catch((cause) => setError(cause instanceof Error ? cause.message : '설치하지 못했어요.')).finally(() => setInstalling(false))
    }}>{runtime && runtime.status !== 'ready' ? '변환기 설치하고 열기' : '다시 시도'}</button>}
    <button type="button" onClick={() => void invoke('materials:reveal', { courseId, relPath })}>파일 위치 보기</button>
  </div>
}
