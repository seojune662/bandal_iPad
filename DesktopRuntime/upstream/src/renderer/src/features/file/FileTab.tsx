import { readVisibleDocument } from '../../lib/documentWork'
import { useCourseActive } from '../workspace/courseActivity'
import { useCallback, useEffect, useState, useRef } from 'react'
import type { IDockviewPanelProps } from 'dockview'
import type { MaterialFileContent } from '../../../../shared/types/materials'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { isTabDescriptor } from '../workspace/tabIdentity'
import { useHasBeenShown } from '../workspace/useHasBeenShown'
import { viewerKindFor, type FileViewerKind } from './fileFormats'
import { DocxViewer } from './viewers/DocxViewer'
import { HwpViewer } from './viewers/HwpViewer'
import { PreviewFallback } from './viewers/PreviewFallback'
import { SheetViewer } from './viewers/SheetViewer'
import { SlidesViewer } from './viewers/SlidesViewer'
import { TextViewer } from './viewers/TextViewer'
import { VideoViewer } from './viewers/VideoViewer'
import './file-tab.css'
import { PresentationLoader } from './pptx/PresentationLoader'
import { PresentationContext } from './pptx/presentationContext'
import { isPdfPageNotePairContext } from '../../../../shared/pdfPageNote'

type FileLoadState =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; content: MaterialFileContent; viewerKind: FileViewerKind }

function fileName(relPath: string): string {
  return relPath.split('/').at(-1) ?? relPath
}

function base64ToUtf8(base64: string): string {
  const binary = window.atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return new TextDecoder('utf-8').decode(bytes)
}

function FileError({
  courseId,
  relPath,
  message
}: {
  courseId: string
  relPath: string
  message: string
}): JSX.Element {
  const [revealing, setRevealing] = useState(false)

  return (
    <div className="file-status file-status--error" role="alert">
      <h2>파일을 열 수 없어요</h2>
      <p>{message}</p>
      <button
        type="button"
        className="file-action"
        disabled={revealing}
        onClick={() => {
          setRevealing(true)
          void invoke('materials:reveal', { courseId, relPath })
            .catch(() => {
              showToast('파일을 Finder에서 열지 못했습니다.', 'danger')
            })
            .finally(() => setRevealing(false))
        }}
      >
        Finder에서 열기
      </button>
    </div>
  )
}

function LoadedFile({
  content,
  courseId,
  relPath,
  viewerKind
}: {
  content: MaterialFileContent
  courseId: string
  relPath: string
  viewerKind: FileViewerKind
}): JSX.Element {
  const [viewerFailed, setViewerFailed] = useState(false)
  const handleError = useCallback(() => setViewerFailed(true), [])
  const name = fileName(relPath)

  if (viewerFailed) {
    return (
      <FileError
        courseId={courseId}
        relPath={relPath}
        message="파일 형식이 손상됐거나 지원하지 않는 내용이 포함되어 있습니다."
      />
    )
  }

  switch (viewerKind) {
    case 'video':
      return <VideoViewer courseId={courseId} relPath={relPath} />
    case 'preview':
      return <PreviewFallback courseId={courseId} relPath={relPath} />
    case 'slides':
      if (content.encoding !== 'base64') {
        return (
          <FileError
            courseId={courseId}
            relPath={relPath}
            message="프레젠테이션 데이터를 읽을 수 없습니다."
          />
        )
      }
      return (
        <SlidesViewer
          courseId={courseId}
          relPath={relPath}
          base64={content.data}
          fileName={name}
          onError={handleError}
        />
      )
    case 'hwp':
      if (content.encoding !== 'base64') {
        return (
          <FileError
            courseId={courseId}
            relPath={relPath}
            message="한글 문서 데이터를 읽을 수 없습니다."
          />
        )
      }
      return (
        <HwpViewer
          base64={content.data}
          fileName={name}
          onError={handleError}
        />
      )
    case 'docx':
      if (content.encoding !== 'base64') {
        return (
          <FileError
            courseId={courseId}
            relPath={relPath}
            message="Word 문서 데이터를 읽을 수 없습니다."
          />
        )
      }
      return (
        <DocxViewer
          base64={content.data}
          fileName={name}
          onError={handleError}
        />
      )
    case 'sheet':
      return (
        <SheetViewer
          content={content}
          fileName={name}
          onError={handleError}
        />
      )
    case 'text': {
      try {
        const text =
          content.encoding === 'utf8' ? content.data : base64ToUtf8(content.data)
        return <TextViewer text={text} fileName={name} />
      } catch {
        return (
          <FileError
            courseId={courseId}
            relPath={relPath}
            message="텍스트 인코딩을 해석할 수 없습니다."
          />
        )
      }
    }
  }
}

function FileLoader({
  courseId,
  relPath
}: {
  courseId: string
  relPath: string
}): JSX.Element {
  const [state, setState] = useState<FileLoadState>({ status: 'loading' })
  const courseActive = useCourseActive()
  const loadedKey = useRef<string | null>(null)

  useEffect(() => {
    const key = `${courseId}\0${relPath}`
    if (!courseActive || loadedKey.current === key) return
    const controller = new AbortController()
    let cancelled = false
    const viewerKind = viewerKindFor(relPath)
    setState({ status: 'loading' })

    if (viewerKind === null) {
      setState({
        status: 'error',
        message: '앱에서 미리 볼 수 없는 파일 형식입니다.'
      })
      return () => {
        cancelled = true
      }
    }

    // 동영상은 bandal-media:// 스트리밍, preview 는 OS 로 넘기므로
    // 둘 다 IPC로 읽지 않는다.
    if (viewerKind === 'video' || viewerKind === 'preview' || viewerKind === 'slides') {
      return () => {
        cancelled = true
      }
    }

    void readVisibleDocument(() => invoke('materials:readFile', { courseId, relPath }), controller.signal)
      .then((content) => {
        if (!cancelled) { loadedKey.current = key; setState({ status: 'ready', content, viewerKind }) }
      })
      .catch(() => {
        if (!cancelled) {
          setState({
            status: 'error',
            message: '파일이 64MB보다 크거나, 파일을 읽을 수 없습니다.'
          })
        }
      })

    return () => {
      cancelled = true
      controller.abort()
    }
  }, [courseId, relPath, courseActive])

  if (viewerKindFor(relPath) === 'slides') return <PresentationLoader courseId={courseId} relPath={relPath} />
  if (viewerKindFor(relPath) === 'video') {
    return <VideoViewer courseId={courseId} relPath={relPath} />
  }
  if (viewerKindFor(relPath) === 'preview') {
    return <PreviewFallback courseId={courseId} relPath={relPath} />
  }
  if (state.status === 'loading') {
    return (
      <div className="file-status" role="status">
        파일을 불러오는 중…
      </div>
    )
  }
  if (state.status === 'error') {
    return (
      <FileError courseId={courseId} relPath={relPath} message={state.message} />
    )
  }
  return (
    <LoadedFile
      content={state.content}
      courseId={courseId}
      relPath={relPath}
      viewerKind={state.viewerKind}
    />
  )
}

export default function FileTab(props: IDockviewPanelProps): JSX.Element {
  useEffect(() => { props.api.setRenderer('always') }, [props.api])
  const courseActive = useCourseActive()
  const [interactive, setInteractive] = useState(props.api.isActive && props.api.isVisible)
  useEffect(() => {
    const update = (): void => setInteractive(props.api.isActive && props.api.isVisible)
    const active = props.api.onDidActiveChange(update), visible = props.api.onDidVisibilityChange(update)
    return () => { active.dispose(); visible.dispose() }
  }, [props.api])
  const hasBeenShown = useHasBeenShown(props.api)
  const candidate = props.params['descriptor']

  if (!isTabDescriptor(candidate) || candidate.kind !== 'file') {
    return <div className="workspace-panel file-panel" data-kind="file" />
  }
  if (!hasBeenShown) {
    return (
      <div className="workspace-panel file-panel" data-kind="file">
        <div className="file-status" role="status">
          파일을 불러오는 중…
        </div>
      </div>
    )
  }

  const { courseId, relPath } = candidate.payload
  const pair = isPdfPageNotePairContext(props.params['pageNotePair']) ? props.params['pageNotePair'] : null
  return (
    <PresentationContext.Provider value={{ panelId: props.api.id, interactive: interactive && courseActive, pair }}>
    <div className="workspace-panel file-panel" data-kind="file">
      <FileLoader
        key={`${courseId}:${relPath}`}
        courseId={courseId}
        relPath={relPath}
      />
    </div>
    </PresentationContext.Provider>
  )
}
