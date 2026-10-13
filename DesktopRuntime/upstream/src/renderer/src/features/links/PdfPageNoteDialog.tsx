import { useEffect, useMemo, useRef, useState } from 'react'
import type { PDFDocumentProxy } from 'pdfjs-dist'
import type { MaterialLinkRecord } from '../../../../shared/types/link'
import {
  createPdfPageNoteMarkdown,
  type PdfPageSize
} from '../../../../shared/pdfPageNote'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { useFocusTrap } from '../../components/useFocusTrap'
import { invoke } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import {
  flattenMaterialFiles,
  type LinkPickerFile
} from './LinkPickerDialog'
import { requestMaterialConnectionsRefresh } from './useMaterialConnections'
import './links.css'

type CreationMode = 'new' | 'existing'

export interface PdfPageNoteDialogProps {
  courseId: string
  relPath: string
  pdf?: PDFDocumentProxy
  presentation?: { pageSizes: PdfPageSize[]; fingerprint: string }
  currentPage: number
  connections: MaterialLinkRecord[]
  onClose: () => void
}

function stem(relPath: string): string {
  const fileName = relPath.split('/').at(-1) ?? relPath
  return fileName.replace(/\.(pdf|pptx?)$/iu, '')
}

function parentPath(relPath: string): string {
  const parts = relPath.split('/')
  parts.pop()
  return parts.join('/')
}

function noteName(record: MaterialLinkRecord): string {
  if (record.target.kind !== 'note') return '페이지 필기'
  return record.target.payload.relPath.split('/').at(-1) ?? record.target.payload.relPath
}

export async function readPdfPageSizes(pdf: PDFDocumentProxy): Promise<PdfPageSize[]> {
  const sizes: PdfPageSize[] = []
  // Small batches avoid asking pdf.js to materialize hundreds of page proxies
  // in one microtask while still keeping setup quick for lecture decks.
  for (let start = 1; start <= pdf.numPages; start += 8) {
    const batch = Array.from(
      { length: Math.min(8, pdf.numPages - start + 1) },
      (_, index) => start + index
    )
    const pages = await Promise.all(batch.map((page) => pdf.getPage(page)))
    for (const page of pages) {
      const viewport = page.getViewport({ scale: 1 })
      sizes.push({ width: viewport.width, height: viewport.height })
    }
  }
  return sizes
}

export function PdfPageNoteDialog({
  courseId,
  relPath,
  pdf,
  presentation,
  currentPage,
  connections,
  onClose
}: PdfPageNoteDialogProps): JSX.Element {
  const numPages = presentation?.pageSizes.length ?? pdf?.numPages ?? 0
  const fingerprint = presentation?.fingerprint ?? pdf?.fingerprints[0] ?? ''
  const format = presentation ? 'PPT' : 'PDF'
  const [mode, setMode] = useState<CreationMode>('new')
  const [title, setTitle] = useState(`${stem(relPath)} 페이지 필기`)
  const [notes, setNotes] = useState<LinkPickerFile[]>([])
  const [selectedPath, setSelectedPath] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [busy, setBusy] = useState(false)
  const [progress, setProgress] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const dialogRef = useRef<HTMLDivElement>(null)

  useFocusTrap(dialogRef, { active: true, onEscape: busy ? undefined : onClose })

  useEffect(() => {
    const release = acquirePointerPassthrough()
    void invoke('materials:tree', { courseId })
      .then((tree) => {
        const connected = new Set(
          connections.flatMap((record) =>
            record.target.kind === 'note' ? [record.target.payload.relPath] : []
          )
        )
        setNotes(
          flattenMaterialFiles(tree).filter(
            (file) => file.kind === 'note' && !connected.has(file.relPath)
          )
        )
      })
      .catch(() => setNotes([]))
    return release
  }, [connections, courseId])

  const filteredNotes = useMemo(() => {
    const needle = query.trim().toLocaleLowerCase()
    if (needle.length === 0) return notes
    return notes.filter(
      (note) =>
        note.name.toLocaleLowerCase().includes(needle) ||
        note.relPath.toLocaleLowerCase().includes(needle)
    )
  }, [notes, query])

  const openConnection = (record: MaterialLinkRecord): void => {
    if ((record.source.kind !== 'pdf' && record.source.kind !== 'file') || record.target.kind !== 'note') return
    useWorkspaceStore.getState().openPdfNotePair(
      record.source,
      record.target,
      record.id,
      currentPage
    )
    onClose()
  }

  const create = async (): Promise<void> => {
    if (busy || (mode === 'existing' && selectedPath === null)) return
    setBusy(true)
    setError(null)
    let createdRelPath: string | null = null
    try {
      setProgress(`${format} ${numPages}쪽의 크기를 확인하는 중…`)
      const pageSizes = presentation?.pageSizes ?? (pdf ? await readPdfPageSizes(pdf) : [])
      const sourceMarkdown =
        mode === 'existing' && selectedPath !== null
          ? (await invoke('notes:read', { courseId, relPath: selectedPath })).markdown
          : ''
      setProgress('페이지 필기 파일을 만드는 중…')
      const created = await invoke('notes:create', {
        courseId,
        dirRelPath: parentPath(relPath),
        title
      })
      createdRelPath = created.relPath
      const seed = await invoke('notes:read', created)
      const markdown = createPdfPageNoteMarkdown(
        created.relPath.split('/').at(-1)?.replace(/\.md$/iu, '') ?? title,
        relPath,
        fingerprint,
        pageSizes,
        sourceMarkdown.length > 0 ? [sourceMarkdown] : []
      )
      await invoke('notes:write', {
        ...created,
        markdown,
        expectedMtime: seed.mtime
      })
      setProgress('자료와 필기를 연결하는 중…')
      const connection = await invoke('links:create', {
        courseId,
        source: descriptorFor(presentation ? 'file' : 'pdf', { courseId, relPath }),
        target: descriptorFor('note', {
          courseId,
          relPath: created.relPath
        }),
        kind: 'pdf-page-note',
        label: `${format} 페이지 필기`,
        metadata: {
          version: 1,
          syncScroll: true,
          fingerprint,
          pageSizes
        }
      })
      requestMaterialConnectionsRefresh(courseId)
      useWorkspaceStore.getState().openPdfNotePair(
        connection.source,
        connection.target,
        connection.id,
        currentPage
      )
      showToast(`${format} 페이지 필기를 만들었어요.`)
      onClose()
    } catch (caught) {
      console.error('[Bandal] PDF 페이지 필기를 만들지 못했습니다.', caught)
      setError(
        createdRelPath === null
          ? '페이지 필기를 만들지 못했어요.'
          : `필기 파일은 보존했지만 연결을 완료하지 못했어요: ${createdRelPath}`
      )
    } finally {
      setBusy(false)
      setProgress(null)
    }
  }

  return (
    <div
      className="link-picker-overlay"
      role="presentation"
      onMouseDown={(event) => {
        if (!busy && event.target === event.currentTarget) onClose()
      }}
    >
      <div
        ref={dialogRef}
        className="pdf-page-note-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="pdf-page-note-title"
      >
        <header className="link-picker__head">
          <div>
            <h2 id="pdf-page-note-title">{format} 페이지 필기</h2>
            <p>{numPages}쪽을 같은 비율의 빈 필기 페이지와 연결합니다.</p>
          </div>
          <button type="button" className="link-picker__close" disabled={busy} onClick={onClose} aria-label="닫기">
            <Icon name="x" />
          </button>
        </header>

        {connections.length > 0 && (
          <section className="pdf-page-note-dialog__connections">
            <h3>연결된 페이지 필기</h3>
            {connections.map((record) => (
              <button key={record.id} type="button" onClick={() => openConnection(record)}>
                <Icon name="fileText" />
                <span><strong>{noteName(record)}</strong><small>나란히 열기</small></span>
                <Icon name="chevronRight" />
              </button>
            ))}
          </section>
        )}

        <div className="pdf-page-note-dialog__mode" role="tablist" aria-label="만드는 방법">
          <button type="button" role="tab" aria-selected={mode === 'new'} onClick={() => setMode('new')}>
            새 빈 필기
          </button>
          <button type="button" role="tab" aria-selected={mode === 'existing'} onClick={() => setMode('existing')}>
            기존 필기 복제
          </button>
        </div>

        <div className="pdf-page-note-dialog__body">
          {mode === 'new' ? (
            <label className="pdf-page-note-dialog__field">
              <span>필기 이름</span>
              <input value={title} disabled={busy} onChange={(event) => setTitle(event.target.value)} />
              <small>{parentPath(relPath) || '과목 폴더'}에 저장됩니다.</small>
            </label>
          ) : (
            <>
              <div className="link-picker__field">
                <Icon name="search" />
                <input type="search" placeholder="복제할 마크다운 찾기" value={query} onChange={(event) => setQuery(event.target.value)} />
              </div>
              <div className="pdf-page-note-dialog__note-list">
                {filteredNotes.length === 0 ? (
                  <p>복제할 마크다운이 없어요.</p>
                ) : filteredNotes.map((note) => (
                  <button
                    key={note.relPath}
                    type="button"
                    aria-pressed={selectedPath === note.relPath}
                    onClick={() => {
                      setSelectedPath(note.relPath)
                      setTitle(`${note.name.replace(/\.md$/iu, '')} 페이지 필기`)
                    }}
                  >
                    <Icon name="fileText" />
                    <span><strong>{note.name}</strong><small>{note.relPath}</small></span>
                  </button>
                ))}
              </div>
              <p className="pdf-page-note-dialog__notice">
                원본은 그대로 두고 복제본을 만듭니다. 기존 내용은 첫 페이지에 배치됩니다.
              </p>
            </>
          )}

          <div className="pdf-page-note-dialog__summary">
            <span><strong>{numPages}</strong> 페이지</span>
            <span>페이지 비율 유지</span>
            <span>양방향 스크롤</span>
            <span>좌우 50:50</span>
          </div>
          {progress !== null && <p className="pdf-page-note-dialog__progress" role="status">{progress}</p>}
          {error !== null && <p className="link-picker__error" role="alert">{error}</p>}
        </div>

        <footer className="pdf-page-note-dialog__footer">
          <button type="button" disabled={busy} onClick={onClose}>취소</button>
          <button
            type="button"
            className="pdf-page-note-dialog__primary"
            disabled={busy || title.trim().length === 0 || (mode === 'existing' && selectedPath === null)}
            onClick={() => void create()}
          >
            {busy ? '만드는 중…' : mode === 'new' ? '만들고 나란히 열기' : '복제해 연결하기'}
          </button>
        </footer>
      </div>
    </div>
  )
}
