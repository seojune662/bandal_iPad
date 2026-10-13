import { useEffect, useId, useRef, useState } from 'react'
import type { MaterialNode } from '../../../../../shared/types/materials'
import type { MaterialHoverPreview } from '../../../../../shared/types/materialHoverPreview'
import { RECORDING_SAMPLE_RATE, recordingTime } from '../../../../../shared/recording'
import { invoke } from '../../../lib/ipc'
import { readOpenNoteSnapshots } from '../../notes/noteSessionRegistry'
import { noteFileKey, subscribeNoteDoc } from '../../notes/noteDocChannel'
import { markdownPreviewFragment } from './markdownPreview'
import { loadImageThumbnail, loadPdfThumbnail, loadVideoThumbnail, type MediaThumbnail } from './mediaThumbnails'
import './previewContent.css'

export { WhiteboardPreviewContent } from './WhiteboardPreviewContent'

function PreviewMessage({ children }: { children: string }): JSX.Element {
  return <p className="material-preview-content__message">{children}</p>
}

function MarkdownPreview({ text }: { text: string }): JSX.Element {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    let active = true
    const element = ref.current
    if (element !== null) element.textContent = text
    void markdownPreviewFragment(text).then((fragment) => {
      if (active) element?.replaceChildren(fragment)
    }).catch(() => undefined)
    return () => { active = false }
  }, [text])
  return text.trim().length === 0
    ? <PreviewMessage>아직 내용이 없어요</PreviewMessage>
    : <div ref={ref} className="material-preview-content__markdown" />
}

function MediaPreview({ courseId, preview }: { courseId: string; preview: MaterialHoverPreview }): JSX.Element {
  const [result, setResult] = useState<MediaThumbnail | 'error' | null>(null)
  const kind = preview.content.kind
  const version = `${preview.mtime}:${preview.size}`
  useEffect(() => {
    setResult(null)
    if (kind !== 'pdf' && kind !== 'video' && kind !== 'image') return
    const controller = new AbortController()
    const timeout = setTimeout(() => {
      setResult('error')
      controller.abort(new Error('Preview timeout'))
    }, 10000)
    const pending = preview.content.kind === 'image'
      ? loadImageThumbnail(courseId, preview.relPath, version, preview.content, controller.signal)
      : (kind === 'pdf' ? loadPdfThumbnail : loadVideoThumbnail)(courseId, preview.relPath, version, controller.signal)
    void pending.then((value) => {
      if (!controller.signal.aborted) setResult(value)
    }).catch(() => { if (!controller.signal.aborted) setResult('error') })
      .finally(() => clearTimeout(timeout))
    return () => {
      clearTimeout(timeout)
      controller.abort()
    }
  }, [courseId, preview.relPath, version, kind, preview.content])
  if (result === 'error') return <PreviewMessage>미리보기를 불러올 수 없어요</PreviewMessage>
  if (result === null) return <PreviewMessage>미리보기 불러오는 중…</PreviewMessage>
  return (
    <>
      <img className="material-preview-content__image" src={result.dataUrl} alt={kind === 'pdf' ? '첫 페이지' : kind === 'image' ? `${preview.name} 미리보기` : '영상 대표 장면'} draggable={false} />
      {kind !== 'image' && <span className="material-preview-content__caption">
        {kind === 'pdf' ? `1 / ${result.pageCount ?? 1}쪽` : recordingTime((result.durationSeconds ?? 0) * RECORDING_SAMPLE_RATE)}
      </span>}
    </>
  )
}

function RecordingPreview({ courseId, relPath }: { courseId: string; relPath: string }): JSX.Element {
  const [value, setValue] = useState<{ text: string; samples: number } | null | 'error'>(null)
  useEffect(() => {
    let active = true
    setValue(null)
    void invoke('recordings:resolve', { courseId, relPath }).then(async (session) => {
      if (!active) return
      if (session === null) { setValue({ text: '', samples: 0 }); return }
      const detail = await invoke('recordings:read', { id: session.id, afterId: 0 })
      if (active) setValue({ text: detail.segments.map((segment) => segment.text).join('\n').slice(0, 1200), samples: detail.session.samples })
    }).catch(() => { if (active) setValue('error') })
    return () => { active = false }
  }, [courseId, relPath])
  if (value === null) return <PreviewMessage>자막 불러오는 중…</PreviewMessage>
  if (value === 'error') return <PreviewMessage>자막을 불러올 수 없어요</PreviewMessage>
  return <>
    {value.text.trim().length === 0 ? <PreviewMessage>아직 자막이 없어요</PreviewMessage> : <p className="material-preview-content__text">{value.text}</p>}
    {value.samples > 0 && <span className="material-preview-content__caption">녹음 {recordingTime(value.samples)}</span>}
  </>
}

function PreviewBody({ courseId, preview }: { courseId: string; preview: MaterialHoverPreview }): JSX.Element {
  const content = preview.content
  switch (content.kind) {
    case 'markdown': return <MarkdownPreview text={content.text} />
    case 'text': return content.text.trim().length === 0
      ? <PreviewMessage>아직 내용이 없어요</PreviewMessage>
      : content.label === undefined
        ? <pre className="material-preview-content__text">{content.text}</pre>
        : <p className="material-preview-content__text">{content.text}</p>
    case 'table': return content.rows.length === 0
      ? <PreviewMessage>아직 내용이 없어요</PreviewMessage>
      : <>
        <div className="material-preview-content__table-wrap">
          <table className="material-preview-content__table"><tbody>{content.rows.slice(0, 8).map((row, index) => (
            <tr key={index}>{row.slice(0, 6).map((cell, column) => <td key={column}>{cell}</td>)}</tr>
          ))}</tbody></table>
        </div>
        <span className="material-preview-content__caption">{content.sheetName} · {content.sheetCount}개 시트{content.truncated ? ' · 일부 내용' : ''}</span>
      </>
    case 'slides': return <>
      {content.imageDataUrl !== undefined
        ? <img className="material-preview-content__image" src={content.imageDataUrl} alt="첫 슬라이드" draggable={false} />
        : content.text.trim().length === 0 ? <PreviewMessage>아직 내용이 없어요</PreviewMessage> : <p className="material-preview-content__text">{content.text}</p>}
      <span className="material-preview-content__caption">첫 슬라이드 · 총 {content.slideCount}장</span>
    </>
    case 'image': case 'pdf': case 'video': return <MediaPreview key={`${preview.relPath}:${preview.mtime}:${preview.size}`} courseId={courseId} preview={preview} />
    case 'recording': return <RecordingPreview courseId={courseId} relPath={preview.relPath} />
    case 'unsupported': return <PreviewMessage>{content.message}</PreviewMessage>
  }
}

export interface MaterialPreviewContentProps {
  courseId: string
  node: MaterialNode
  onMetadata?: (metadata: { size: number; mtime: number }) => void
}

export function MaterialPreviewContent({ courseId, node, onMetadata }: MaterialPreviewContentProps): JSX.Element {
  const key = JSON.stringify([courseId, node.relPath, node.mtime, node.size])
  const [loaded, setLoaded] = useState<{ key: string; value: MaterialHoverPreview | 'error' } | null>(null)
  const [live, setLive] = useState<{ key: string; text: string } | null>(null)
  const metadataRef = useRef(onMetadata)
  metadataRef.current = onMetadata
  const peerId = useId()
  useEffect(() => {
    let active = true
    const snapshot = readOpenNoteSnapshots().find((note) => note.courseId === courseId && note.relPath === node.relPath)
    setLive(snapshot === undefined ? null : { key, text: snapshot.markdown.slice(0, 1200) })
    const updateLive = (markdown: string): void => { if (active) setLive({ key, text: markdown.slice(0, 1200) }) }
    const unsubscribe = node.kind === 'note'
      ? subscribeNoteDoc(noteFileKey(courseId, node.relPath), `material-preview-${peerId}`, { onRemoteEdit: updateLive, onRemoteSave: updateLive })
      : undefined
    void invoke('materials:hoverPreview', { courseId, relPath: node.relPath }).then((value) => {
      if (!active) return
      setLoaded({ key, value })
      metadataRef.current?.({ size: value.size, mtime: value.mtime })
    }).catch(() => { if (active) setLoaded({ key, value: 'error' }) })
    return () => { active = false; unsubscribe?.() }
  }, [courseId, key, node.relPath, node.kind, peerId])
  const current = loaded?.key === key ? loaded.value : null
  return <div className="material-preview-content">
    {live?.key === key
      ? <MarkdownPreview text={live.text} />
      : current === null ? <PreviewMessage>미리보기 불러오는 중…</PreviewMessage>
        : current === 'error' ? <PreviewMessage>미리보기를 불러올 수 없어요</PreviewMessage>
          : <PreviewBody courseId={courseId} preview={current} />}
  </div>
}
