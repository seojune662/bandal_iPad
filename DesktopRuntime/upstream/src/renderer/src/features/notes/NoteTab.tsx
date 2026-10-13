import { firstNoteTitle as firstH1Title } from '../../../../shared/noteTitle'
import { usePanelAssistant } from '../assistantPanel/panelContext'
import { registerDocumentContext } from '../agent/documentContext'
import {
  Editor,
  EditorStatus,
  defaultValueCtx,
  editorViewCtx,
  nodeViewCtx,
  prosePluginsCtx,
  rootAttrsCtx,
  rootCtx,
  serializerCtx
} from '@milkdown/core'
import type { MilkdownPlugin } from '@milkdown/ctx'
import { DOMSerializer as ProseDOMSerializer } from '@milkdown/prose/model'
import { Plugin, TextSelection } from '@milkdown/prose/state'
import { Milkdown, MilkdownProvider, useEditor } from '@milkdown/react'
import type { IDockviewPanelProps } from 'dockview'
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type MouseEvent as ReactMouseEvent
} from 'react'
import type { NoteContent, NoteRef } from '../../../../shared/types/note'
import type { MaterialLinkRecord } from '../../../../shared/types/link'
import {
  hasPdfPageNoteHeader,
  isPdfPageNotePairContext,
  parsePdfPageNote,
  recoverPdfPageNoteAsMarkdown,
  serializePdfPageNote,
  sourceRelPath,
  type PdfPageNoteDocument,
  type PdfPageNotePairContext
} from '../../../../shared/pdfPageNote'
import { openHttpLink } from '../../app/openHttpLink'
import { showToast } from '../../app/toast'
import { createPluginEditorAccess } from '../plugins/pluginEditor'
import { useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor, isTabDescriptor } from '../workspace/tabIdentity'
import { requestMaterialConnectionsRefresh } from '../links/useMaterialConnections'
import { nativeHistoryGuard } from './nativeHistoryGuard'
import { canAutoFocusNote } from './noteAutoFocus'
import { createMentionMenuPlugin } from './mentionMenuPlugin'
import { openMaterialLink, resolveNoteLink } from './materialLinkNavigation'
import {
  createNoteConflictCopy,
  preserveNoteOnClose,
  registerNoteFlushTriggers,
  type NoteFlushResult
} from './noteSaveSafety'
import {
  EMPTY_NOTE_FORMAT_STATE,
  getNoteFormatState,
  type NoteFormatState
} from './noteFormatting'
import {
  loadNoteEditorPlugins,
  NOTE_EDITOR_PLUGINS
} from './noteEditorPlugins'
import { createMarkdownCodec, type MarkdownCodec } from './markdownCodec'
import {
  createNoteImagePlugin,
  createNoteImageView,
  noteImageSource
} from './noteImagePlugin'
import {
  broadcastNoteEdit,
  broadcastNoteSave,
  claimNoteWriter,
  currentNoteWriter,
  isNoteWriter,
  noteDocPeerCount,
  noteFileKey,
  subscribeNoteDoc
} from './noteDocChannel'
import {
  registerOpenNoteSession,
  retargetOpenNoteSession
} from './noteSessionRegistry'
import {
  synchronizeNoteRename,
  type NoteRenameSynchronization
} from './noteRenameSync'
import { NoteToolbar } from './NoteToolbar'
import { QuizPreview } from './QuizPreview'
import { splitQuizMarkdown } from './quizMarkdown'
import {
  createNoteZoomShortcutPlugin,
  NOTE_FONT_SCALE_STORAGE_KEY,
  parseNoteFontScale,
  stepNoteFontScale,
  type NoteFontScale
} from './noteZoom'
import { taskListItemView } from './taskListView'
import { createWikilinkPickerPlugin, wikilinkContextCtx } from './wikilink'
import './note-tab.css'
import {
  claimPageSyncInput,
  publishPageSyncAnchor,
  subscribePageSyncAnchor,
  usePageNoteSync
} from '../links/pdfPageNoteSync'
import { PageSyncScroll } from '../links/pageSyncScroll'
import { PageCenterCache } from '../pdf/useVisiblePages'

const SAVE_DELAY_MS = 800
/** Live-mirror latency between duplicate panels of the same file. */
const EDIT_BROADCAST_DELAY_MS = 300
/** Second, late scroll restore after the async editor plugins settle. */
const SCROLL_RESTORE_RETRY_MS = 120
/**
 * Caret visibility adjustments can scroll the page-note pane after an input
 * event. That is editor housekeeping, not a request to move the paired PDF.
 */
const PAGE_NOTE_INPUT_SCROLL_SUPPRESSION_MS = 300
let pageNotePreviewCodecPromise: Promise<MarkdownCodec> | null = null

type SaveStatus = 'saved' | 'dirty' | 'saving' | 'conflict' | 'error'
type NoteViewMode = 'edit' | 'quiz'

interface EditorSeed {
  markdown: string
  revision: number
}

interface NoteSessionProps extends NoteRef {
  panelApi: IDockviewPanelProps['api']
  pageNotePair: PdfPageNotePairContext | null
}

const STATUS_LABEL: Record<SaveStatus, string> = {
  saved: '저장됨',
  dirty: '저장 대기',
  saving: '저장 중',
  conflict: '충돌',
  error: '저장 실패'
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Mirrors the main-process title cleanup for a no-op rename comparison. */
function normalizedTitleStem(title: string): string {
  return title
    .replace(/\.md$/iu, '')
    .trim()
    .replace(/[/\\:*?"<>|]/g, '')
    .replace(/\s+/g, ' ')
    .replace(/^\.+/, '')
    .slice(0, 120)
    .trim()
}

function pageNotePreviewCodec(): Promise<MarkdownCodec> {
  pageNotePreviewCodecPromise ??= createMarkdownCodec()
  return pageNotePreviewCodecPromise
}

/**
 * Renders inactive pages with the editor's Markdown schema without mounting a
 * full ProseMirror editor for every page in a long PDF.
 */
function PageNotePreview({
  courseId,
  markdown
}: {
  courseId: string
  markdown: string
}): JSX.Element {
  const renderHostRef = useRef<HTMLDivElement>(null)
  const isEmpty = markdown.trim().length === 0

  useEffect(() => {
    const host = renderHostRef.current
    if (host === null || isEmpty) return
    let disposed = false
    host.setAttribute('aria-busy', 'true')

    void pageNotePreviewCodec()
      .then((codec) => {
        if (disposed) return
        const proseDocument = codec.parse(markdown)
        const milkdown = window.document.createElement('div')
        const editor = window.document.createElement('div')
        milkdown.className = 'milkdown'
        editor.className = 'editor'
        editor.appendChild(
          ProseDOMSerializer.fromSchema(proseDocument.type.schema)
            .serializeFragment(proseDocument.content)
        )
        for (const image of editor.querySelectorAll<HTMLImageElement>('img[src]')) {
          image.src = noteImageSource(courseId, image.getAttribute('src') ?? '')
        }
        milkdown.appendChild(editor)
        host.replaceChildren(milkdown)
        host.removeAttribute('data-render-error')
      })
      .catch((error: unknown) => {
        if (disposed) return
        console.error('[Bandal] 페이지 필기 미리보기를 렌더링하지 못했습니다.', error)
        const fallback = window.document.createElement('pre')
        fallback.className = 'page-note-paper__fallback'
        fallback.textContent = markdown
        host.replaceChildren(fallback)
        host.setAttribute('data-render-error', 'true')
      })
      .finally(() => {
        if (!disposed) host.removeAttribute('aria-busy')
      })

    return () => {
      disposed = true
    }
  }, [courseId, isEmpty, markdown])

  return (
    <div className="page-note-paper__preview">
      {!isEmpty && (
        <div ref={renderHostRef} className="page-note-paper__render" />
      )}
    </div>
  )
}

/** Put a newly opened note straight into its body, below the generated H1. */
function focusNoteBody(editor: Editor): void {
  editor.action((context) => {
    const view = context.get(editorViewCtx)
    let transaction = view.state.tr
    const first = transaction.doc.firstChild
    if (
      first?.type.name === 'heading' &&
      first.attrs['level'] === 1 &&
      transaction.doc.childCount === 1
    ) {
      const paragraph = view.state.schema.nodes.paragraph
      if (paragraph !== undefined) {
        transaction = transaction.insert(transaction.doc.content.size, paragraph.create())
      }
    }
    const bodyPosition = first?.type.name === 'heading'
      ? Math.min(transaction.doc.content.size, first.nodeSize + 1)
      : 1
    transaction = transaction.setSelection(
      TextSelection.near(transaction.doc.resolve(bodyPosition), 1)
    )
    view.dispatch(transaction.scrollIntoView())
    view.focus()
  })
}

function noteStem(relPath: string): string {
  const fileName = relPath.split('/').at(-1) ?? relPath
  return fileName.replace(/\.md$/iu, '')
}

function handleNoteLinkClick(
  event: ReactMouseEvent<HTMLDivElement>,
  courseId: string
): void {
  const target = event.target
  if (!(target instanceof Element)) return
  const anchor = target.closest<HTMLAnchorElement>('a[href]')
  const href = anchor?.getAttribute('href')
  if (href === null || href === undefined) return

  const resolution = resolveNoteLink(href)
  if (resolution.kind === 'pass-through') {
    let url: URL
    try {
      url = new URL(href)
    } catch {
      return
    }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return
    event.preventDefault()
    openHttpLink(url.toString(), {
      shift: event.shiftKey,
      mod: window.bandal?.platform === 'darwin' ? event.metaKey : event.ctrlKey
    })
    return
  }
  event.preventDefault()

  if (resolution.kind === 'invalid-bandal') {
    showToast('올바르지 않은 Bandal 자료 링크입니다.', 'danger')
    return
  }
  openMaterialLink(courseId, resolution.link)
}

export function isNoteConflict(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false
  const candidate = error as { name?: unknown; message?: unknown }
  return (
    candidate.name === 'ConflictError' ||
    (typeof candidate.message === 'string' && candidate.message.includes('[conflict]'))
  )
}

export function MilkdownNoteEditor({
  courseId,
  relPath,
  initialMarkdown,
  onMarkdownChange,
  onFormatStateChange,
  onZoomStep,
  autoFocus = true
}: {
  courseId: string
  relPath: string
  initialMarkdown: string
  onMarkdownChange: (markdown: string) => void
  onFormatStateChange: (state: NoteFormatState) => void
  onZoomStep: (direction: -1 | 1) => void
  autoFocus?: boolean
}): JSX.Element {
  const t = useT()
  const assistant = usePanelAssistant()
  // rename 이 에디터를 재생성하지 않도록 relPath 는 ref 로만 플러그인에 전달.
  const relPathRef = useRef(relPath)
  relPathRef.current = relPath
  const [editorPlugins, setEditorPlugins] = useState<
    readonly (MilkdownPlugin | MilkdownPlugin[])[] | null
  >(null)
  const [editorInitialization, setEditorInitialization] = useState<
    'idle' | 'initializing' | 'ready' | 'failed'
  >('idle')
  const editorAttemptRef = useRef(0)
  // `initialMarkdown` is a seed, not a controlled value. Page-note typing
  // serializes the whole document and feeds the current page back through
  // props on every transaction. Including that changing value in useEditor's
  // dependencies destroyed and recreated ProseMirror for every Korean IME
  // keystroke, which split composed syllables and reset the caret. Intentional
  // external replacements already remount this component via the revision key.
  const initialMarkdownRef = useRef(initialMarkdown)
  const onChangeRef = useRef(onMarkdownChange)
  const onFormatStateChangeRef = useRef(onFormatStateChange)
  const onZoomStepRef = useRef(onZoomStep)
  onChangeRef.current = onMarkdownChange
  onFormatStateChangeRef.current = onFormatStateChange
  onZoomStepRef.current = onZoomStep

  useEffect(() => {
    let active = true
    void loadNoteEditorPlugins()
      .then((plugins) => {
        if (active) setEditorPlugins(plugins)
      })
      .catch((error: unknown) => {
        console.error('[Bandal] 코드 하이라이터를 불러오지 못했습니다.', error)
        if (active) setEditorPlugins(NOTE_EDITOR_PLUGINS)
      })
    return () => {
      active = false
    }
  }, [])

  const { get: getEditor, loading } = useEditor(
    (root) => {
      if (editorPlugins === null) return undefined
      const attempt = editorAttemptRef.current + 1
      editorAttemptRef.current = attempt
      setEditorInitialization('initializing')
      const initialFocus = root.ownerDocument.activeElement

      const editor = Editor.make()
        .onStatusChange((status) => {
          if (
            editorAttemptRef.current === attempt &&
            status === EditorStatus.Created
          ) {
            setEditorInitialization('ready')
            if (autoFocus) requestAnimationFrame(() => {
              if (
                editorAttemptRef.current === attempt &&
                editor.status === EditorStatus.Created &&
                canAutoFocusNote(root, initialFocus)
              ) focusNoteBody(editor)
            })
          }
        })
        .config((context) => {
          context.set(rootCtx, root)
          context.set(defaultValueCtx, initialMarkdownRef.current)
          context.set(rootAttrsCtx, {
            'aria-label': '마크다운 필기 편집기',
            'aria-multiline': 'true'
          })
          context.set(wikilinkContextCtx.key, {
            courseId,
            getSelfRelPath: () => relPathRef.current
          })
          context.update(nodeViewCtx, (views) => [
            ...views.filter(
              ([name]) => name !== 'list_item' && name !== 'image'
            ),
            ['list_item', taskListItemView] as [string, typeof taskListItemView],
            ['image', createNoteImageView(courseId)] as [
              string,
              ReturnType<typeof createNoteImageView>
            ]
          ])
          context.update(prosePluginsCtx, (plugins) => [
            ...plugins,
            createNoteImagePlugin(courseId),
            createPluginEditorAccess(
              courseId,
              () => relPathRef.current,
              assistant?.panelId
            ),
            createMentionMenuPlugin({
              courseId,
              getSelfRelPath: () => relPathRef.current
            }),
            createWikilinkPickerPlugin({
              courseId,
              getSelfRelPath: () => relPathRef.current
            }),
            // Keeps the native Edit-menu ⌘Z from editing around ProseMirror.
            nativeHistoryGuard(),
            createNoteZoomShortcutPlugin((direction) =>
              onZoomStepRef.current(direction)
            ),
            new Plugin({
              view: (initialView) => {
                onFormatStateChangeRef.current(
                  getNoteFormatState(initialView.state)
                )
                return {
                  update: (view, previousState) => {
                    onFormatStateChangeRef.current(
                      getNoteFormatState(view.state)
                    )
                    if (previousState.doc.eq(view.state.doc)) return
                    const markdown = context.get(serializerCtx)(view.state.doc)
                    onChangeRef.current(markdown)
                  }
                }
              }
            })
          ])
        })

      return editorPlugins.reduce(
        (instance, plugin) => instance.use(plugin),
        editor
      )
    },
    [autoFocus, courseId, editorPlugins]
  )

  useEffect(() => {
    if (editorInitialization !== 'initializing' || loading) return
    const editor = getEditor()
    if (editor?.status === EditorStatus.Created) {
      setEditorInitialization('ready')
      return
    }
    console.error(
      '[Bandal] Note editor initialization finished without reaching Created.',
      { status: editor?.status ?? 'unavailable' }
    )
    setEditorInitialization('failed')
  }, [editorInitialization, getEditor, loading])

  return (
    <div className="note-editor-shell" aria-busy={loading}>
      {loading && <div className="note-editor-loading">편집기 준비 중…</div>}
      {editorInitialization === 'failed' && (
        <div className="note-editor-warning" role="alert">
          {t('notes.editor.initializationFailed')}
        </div>
      )}
      <Milkdown />
    </div>
  )
}

function NoteEditorWorkspace({
  courseId,
  relPath,
  initialMarkdown,
  onMarkdownChange,
  fontScale,
  onFontScaleChange,
  onZoomStep
}: {
  courseId: string
  relPath: string
  initialMarkdown: string
  onMarkdownChange: (markdown: string) => void
  fontScale: NoteFontScale
  onFontScaleChange: (scale: NoteFontScale) => void
  onZoomStep: (direction: -1 | 1) => void
}): JSX.Element {
  const [formatState, setFormatState] = useState<NoteFormatState>(
    EMPTY_NOTE_FORMAT_STATE
  )

  return (
    <div className="note-editor-scroll">
      <NoteToolbar
        courseId={courseId}
        relPath={relPath}
        formatState={formatState}
        fontScale={fontScale}
        onFontScaleChange={onFontScaleChange}
      />
      <MilkdownNoteEditor
        courseId={courseId}
        relPath={relPath}
        initialMarkdown={initialMarkdown}
        onMarkdownChange={onMarkdownChange}
        onFormatStateChange={setFormatState}
        onZoomStep={onZoomStep}
      />
    </div>
  )
}

export function PageNoteWorkspace({
  courseId,
  relPath,
  document,
  onMarkdownChange,
  fontScale,
  onFontScaleChange,
  onZoomStep,
  pageNotePair,
  panelId,
  syncEnabled,
  onCurrentPageChange
}: {
  courseId: string
  relPath: string
  document: PdfPageNoteDocument
  onMarkdownChange: (markdown: string) => void
  fontScale: NoteFontScale
  onFontScaleChange: (scale: NoteFontScale) => void
  onZoomStep: (direction: -1 | 1) => void
  pageNotePair: PdfPageNotePairContext | null
  panelId: string
  syncEnabled: boolean
  onCurrentPageChange: (page: number) => void
}): JSX.Element {
  const [pages, setPages] = useState(document.pages)
  const [activePage, setActivePage] = useState(
    Math.min(pageNotePair?.initialPage ?? 1, document.pages.length)
  )
  const [viewportPage, setViewportPage] = useState(
    Math.min(pageNotePair?.initialPage ?? 1, document.pages.length)
  )
  const [formatState, setFormatState] = useState<NoteFormatState>(
    EMPTY_NOTE_FORMAT_STATE
  )
  const pagesRef = useRef(document.pages)
  const scrollerRef = useRef<HTMLDivElement>(null)
  const listRef = useRef<HTMLDivElement>(null)
  const pageRefs = useRef(new Map<number, HTMLElement>())
  const pageRefCallbacks = useRef(
    new Map<number, (element: HTMLElement | null) => void>()
  )
  const pageCenterCacheRef = useRef(new PageCenterCache())
  const reportedPageRef = useRef(0)
  const viewportAnchorRef = useRef<{ page: number; pageOffset: number } | null>(null)
  const pageSyncScroll = useRef(new PageSyncScroll())
  const scrollFrameRef = useRef<number | null>(null)
  const composingRef = useRef(false)
  const suppressSyncUntilRef = useRef(0)

  const suppressInputDrivenSync = (): void => {
    suppressSyncUntilRef.current =
      performance.now() + PAGE_NOTE_INPUT_SCROLL_SUPPRESSION_MS
  }

  const registerPage = useCallback((page: number) => {
    const cached = pageRefCallbacks.current.get(page)
    if (cached !== undefined) return cached
    const callback = (element: HTMLElement | null): void => {
      const previous = pageRefs.current.get(page)
      if (element === null) pageRefs.current.delete(page)
      else pageRefs.current.set(page, element)
      if (previous !== element) pageCenterCacheRef.current.invalidate()
    }
    pageRefCallbacks.current.set(page, callback)
    return callback
  }, [])

  useEffect(() => {
    const list = listRef.current
    if (list === null) return
    let previousWidth = list.clientWidth
    const observer = new ResizeObserver(() => {
      pageCenterCacheRef.current.invalidate()
      const width = list.clientWidth
      const scroller = scrollerRef.current
      if (width <= 0 || !scroller || scroller.clientHeight <= 0) return
      if (width !== previousWidth && viewportAnchorRef.current) {
        pageSyncScroll.current.apply(scroller, () => {
          pageCenterCacheRef.current.restoreViewportAnchor(scroller, pageRefs.current, viewportAnchorRef.current!)
        })
      }
      previousWidth = width
    })
    observer.observe(list)
    return () => observer.disconnect()
  }, [])

  const reportCurrentPage = useCallback(
    (page: number): void => {
      setViewportPage((current) => (current === page ? current : page))
      if (reportedPageRef.current === page) return
      reportedPageRef.current = page
      onCurrentPageChange(page)
    },
    [onCurrentPageChange]
  )

  const captureAnchor = useCallback((): { page: number; pageOffset: number } | null => {
    const scroller = scrollerRef.current
    if (scroller === null) return null
    const anchor = pageCenterCacheRef.current.captureViewportAnchor(scroller, pageRefs.current)
    if (anchor) viewportAnchorRef.current = anchor
    return anchor
  }, [])

  const restoreAnchor = useCallback(
    (page: number, pageOffset: number): boolean => {
      const scroller = scrollerRef.current
      if (scroller === null || scroller.clientHeight <= 0) return false
      viewportAnchorRef.current = { page, pageOffset }
      return pageCenterCacheRef.current.restoreViewportAnchor(
        scroller,
        pageRefs.current,
        {
          page: Math.min(Math.max(1, page), document.pages.length),
          pageOffset
        }
      )
    },
    [document.pages.length]
  )

  const initialRestoreKey = useRef<string | null>(null)
  useLayoutEffect(() => {
    const initialPage = Math.min(pageNotePair?.initialPage ?? 1, document.pages.length)
    const key = `${pageNotePair?.pairId ?? ''}:${initialPage}`
    if (initialRestoreKey.current === key) return
    const frame = requestAnimationFrame(() => {
      initialRestoreKey.current = key
      // A user jump / peer scroll may already have arrived while the editor
      // mounted. Never overwrite it with the initial page or echo page 1 back.
      if (viewportAnchorRef.current !== null) return
      const scroller = scrollerRef.current
      if (!scroller) return
      pageSyncScroll.current.apply(scroller, () => restoreAnchor(initialPage, 0))
      reportCurrentPage(initialPage)
    })
    return () => cancelAnimationFrame(frame)
  }, [document.pages.length, pageNotePair?.pairId, pageNotePair?.initialPage, reportCurrentPage, restoreAnchor])

  useEffect(() => {
    if (pageNotePair === null || !syncEnabled) return
    return subscribePageSyncAnchor(pageNotePair.pairId, (anchor) => {
      if (
        anchor.connectionId !== pageNotePair.connectionId ||
        anchor.originPanelId === panelId
      ) return
      const scroller = scrollerRef.current
      if (!scroller || scroller.clientHeight <= 0 || !pageSyncScroll.current.accept(anchor.sequence)) return
      pageSyncScroll.current.apply(scroller, () => restoreAnchor(anchor.page, anchor.pageOffset))
      reportCurrentPage(Math.min(Math.max(1, anchor.page), document.pages.length))
    })
  }, [document.pages.length, pageNotePair, panelId, reportCurrentPage, restoreAnchor, syncEnabled])

  useEffect(() => () => {
    if (scrollFrameRef.current !== null) cancelAnimationFrame(scrollFrameRef.current)
  }, [])

  const handleScroll = (): void => {
    if (scrollFrameRef.current !== null) return
    scrollFrameRef.current = requestAnimationFrame(() => {
      scrollFrameRef.current = null
      const anchor = captureAnchor()
      if (anchor === null) return
      reportCurrentPage(anchor.page)
      const scroller = scrollerRef.current
      const applyingSync = scroller !== null && pageSyncScroll.current.isEcho(scroller)
      const inputDrivenScroll =
        composingRef.current || performance.now() < suppressSyncUntilRef.current
      if (
        pageNotePair !== null &&
        syncEnabled &&
        !applyingSync &&
        !inputDrivenScroll
      ) {
        publishPageSyncAnchor({
          connectionId: pageNotePair.connectionId,
          pairId: pageNotePair.pairId,
          page: anchor.page,
          pageOffset: anchor.pageOffset,
          originPanelId: panelId
        })
      }
    })
  }

  const changePage = (page: number, markdown: string): void => {
    if (pagesRef.current[page - 1] === markdown) return
    const next = [...pagesRef.current]
    next[page - 1] = markdown
    pagesRef.current = next
    setPages(next)
    onMarkdownChange(serializePdfPageNote({ ...document, pages: next }))
  }

  const changeAppendix = (appendix: string): void => {
    onMarkdownChange(
      serializePdfPageNote({ ...document, pages: pagesRef.current, appendix })
    )
  }

  // The page-note toolbar calls Milkdown's useInstance(). Keep the toolbar and
  // whichever page is currently editable inside one provider. Previously each
  // page wrapped only MilkdownNoteEditor, leaving the toolbar outside the
  // context and crashing the whole renderer whenever a page-note tab was
  // restored at startup.
  return (
    <MilkdownProvider>
      <div
        ref={scrollerRef}
        className="note-editor-scroll page-note-scroll"
        onWheelCapture={() => {
          suppressSyncUntilRef.current = 0
          if (pageNotePair) claimPageSyncInput(pageNotePair.pairId, panelId)
        }}
        onPointerDownCapture={() => { if (pageNotePair) claimPageSyncInput(pageNotePair.pairId, panelId) }}
        onScroll={handleScroll}
        onBeforeInputCapture={suppressInputDrivenSync}
        onCompositionStartCapture={() => {
          composingRef.current = true
          suppressInputDrivenSync()
        }}
        onCompositionEndCapture={() => {
          composingRef.current = false
          suppressInputDrivenSync()
        }}
      >
        <NoteToolbar
          courseId={courseId}
          relPath={relPath}
          formatState={formatState}
          fontScale={fontScale}
          onFontScaleChange={onFontScaleChange}
        />
        <div ref={listRef} className="page-note-list">
          {pages.map((markdown, index) => {
            const page = index + 1
            const size = document.manifest.pages[index] ?? {
              width: 1,
              height: Math.SQRT2
            }
            const isActive = activePage === page
            return (
              <section
                key={page}
                ref={registerPage(page)}
                className="page-note-paper"
                data-active={isActive || undefined}
                style={{ aspectRatio: `${size.width} / ${size.height}` }}
                aria-label={`${page} 페이지 필기`}
                onMouseDown={(event) => {
                  const target = event.target
                  if (
                    target instanceof Element &&
                    target.closest('a[href]') !== null
                  ) {
                    return
                  }
                  setActivePage(page)
                }}
              >
                <span className="page-note-paper__number">{page}</span>
                <div className="page-note-paper__body">
                  {isActive ? (
                    <MilkdownNoteEditor
                      key={page}
                      courseId={courseId}
                      relPath={relPath}
                      initialMarkdown={markdown}
                      onMarkdownChange={(next) => changePage(page, next)}
                      onFormatStateChange={setFormatState}
                      onZoomStep={onZoomStep}
                    />
                  ) : Math.abs(page - viewportPage) <= 2 ? (
                    <PageNotePreview courseId={courseId} markdown={markdown} />
                  ) : (
                    <div
                      className="page-note-paper__preview"
                      aria-hidden="true"
                    />
                  )}
                </div>
              </section>
            )
          })}
          {document.appendix.length > 0 && (
            <section
              className="page-note-appendix"
              data-active={activePage === 0 || undefined}
              onMouseDown={(event) => {
                const target = event.target
                if (
                  target instanceof Element &&
                  target.closest('a[href]') !== null
                ) {
                  return
                }
                setActivePage(0)
              }}
            >
              <header>
                <strong>연결 제외된 페이지</strong>
                <span>PDF에서 사라진 페이지의 필기를 보존했습니다.</span>
              </header>
              {activePage === 0 ? (
                <MilkdownNoteEditor
                  key="appendix"
                  courseId={courseId}
                  relPath={relPath}
                  initialMarkdown={document.appendix}
                  onMarkdownChange={changeAppendix}
                  onFormatStateChange={setFormatState}
                  onZoomStep={onZoomStep}
                />
              ) : (
                <PageNotePreview
                  courseId={courseId}
                  markdown={document.appendix}
                />
              )}
            </section>
          )}
        </div>
      </div>
    </MilkdownProvider>
  )
}

function NoteSession({
  courseId,
  relPath,
  panelApi,
  pageNotePair
}: NoteSessionProps): JSX.Element {
  const [editorSeed, setEditorSeed] = useState<EditorSeed | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [status, setStatus] = useState<SaveStatus>('saved')
  const [statusDetail, setStatusDetail] = useState<string | null>(null)
  const [conflictBusy, setConflictBusy] = useState(false)
  const [recoveryBusy, setRecoveryBusy] = useState(false)
  const assistant = usePanelAssistant()
  const [presentedMarkdown, setPresentedMarkdown] = useState('')
  const [viewMode, setViewMode] = useState<NoteViewMode>('edit')
  const [currentRelPath, setCurrentRelPath] = useState(relPath)
  const [fontScale, setFontScale] = useState<NoteFontScale>(() => {
    try {
      return parseNoteFontScale(localStorage.getItem(NOTE_FONT_SCALE_STORAGE_KEY))
    } catch {
      return 1
    }
  })
  const pageNoteDocument = useMemo(
    () => parsePdfPageNote(presentedMarkdown),
    [presentedMarkdown]
  )
  const damagedPageNote =
    pageNoteDocument === null && hasPdfPageNoteHeader(presentedMarkdown)
  const [pageNoteConnection, setPageNoteConnection] =
    useState<MaterialLinkRecord | null>(null)
  const [pageNoteCurrentPage, setPageNoteCurrentPage] = useState(
    pageNotePair?.initialPage ?? 1
  )
  const [pageNoteSync, setPageNoteSync] = usePageNoteSync(
    pageNotePair?.pairId ?? null,
    pageNoteConnection?.metadata?.syncScroll ?? true
  )

  const aliveRef = useRef(true)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const currentMarkdownRef = useRef('')
  const persistedMarkdownRef = useRef('')
  const mtimeRef = useRef<number | null>(null)
  const syncedTitleRef = useRef<string | null>(null)
  const conflictRef = useRef(false)
  const writeInFlightRef = useRef<Promise<NoteFlushResult> | null>(null)
  const revisionRef = useRef(0)
  const flushRef = useRef<(overwrite?: boolean) => Promise<NoteFlushResult>>(
    async () => ({ status: 'unavailable' })
  )
  const scheduleRef = useRef<() => void>(() => undefined)
  const closeTaskRef = useRef<Promise<unknown> | null>(null)
  const noteRef = useRef<NoteRef>({ courseId, relPath })
  const containerRef = useRef<HTMLDivElement | null>(null)
  const broadcastTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  /** Remote markdown waiting for focus to leave before it can remount the editor. */
  const pendingEditorMarkdownRef = useRef<string | null>(null)
  const pendingScrollTopRef = useRef<number | null>(null)
  useEffect(() => registerDocumentContext(assistant?.panelId ?? `note:${courseId}:${currentRelPath}`, () => ({ courseId, kind: 'note', title: currentRelPath.split('/').pop() ?? currentRelPath, relPath: currentRelPath, text: currentMarkdownRef.current.slice(0, 12000), unsaved: currentMarkdownRef.current !== persistedMarkdownRef.current })), [courseId, currentRelPath, assistant?.panelId])


  useEffect(() => {
    if (pageNoteDocument === null) {
      setPageNoteConnection(null)
      return
    }
    let disposed = false
    void invoke('links:listFor', { courseId, relPath: currentRelPath })
      .then(({ outgoing, incoming }) => {
        if (disposed) return
        const records = [...outgoing, ...incoming]
        setPageNoteConnection(
          records.find(
            (record) =>
              record.kind === 'pdf-page-note' &&
              (pageNotePair === null || record.id === pageNotePair.connectionId)
          ) ?? null
        )
      })
      .catch(() => {
        if (!disposed) setPageNoteConnection(null)
      })
    return () => {
      disposed = true
    }
  }, [courseId, currentRelPath, pageNoteDocument !== null, pageNotePair])

  useEffect(() => {
    if (pageNotePair !== null && pageNoteConnection?.metadata !== null && pageNoteConnection !== null) {
      setPageNoteSync(pageNoteConnection.metadata.syncScroll)
    }
  }, [pageNoteConnection, pageNotePair, setPageNoteSync])

  const noteFileKeyNow = useCallback(
    (): string => noteFileKey(noteRef.current.courseId, noteRef.current.relPath),
    []
  )

  const clearTimer = useCallback((): void => {
    if (timerRef.current === null) return
    clearTimeout(timerRef.current)
    timerRef.current = null
  }, [])

  const cancelEditBroadcast = useCallback((): void => {
    if (broadcastTimerRef.current === null) return
    clearTimeout(broadcastTimerRef.current)
    broadcastTimerRef.current = null
  }, [])

  const setStatusIfMounted = useCallback(
    (nextStatus: SaveStatus, detail: string | null = null): void => {
      if (!aliveRef.current) return
      setStatus(nextStatus)
      setStatusDetail(detail)
    },
    []
  )

  const retargetNote = useCallback(
    (
      nextRelPath: string,
      mtime?: number,
      rename?: NoteRenameSynchronization
    ): void => {
      const previousRelPath = noteRef.current.relPath
      noteRef.current = { ...noteRef.current, relPath: nextRelPath }
      if (mtime !== undefined) mtimeRef.current = mtime
      if (rename !== undefined) {
        clearTimer()
        cancelEditBroadcast()
        const synchronized = synchronizeNoteRename(
          currentMarkdownRef.current,
          rename.sourceMarkdown,
          {
            relPath: nextRelPath,
            mtime: mtime ?? mtimeRef.current ?? 0,
            title: rename.title,
            markdown: rename.markdown
          }
        )
        currentMarkdownRef.current = synchronized.currentMarkdown
        persistedMarkdownRef.current = synchronized.persistedMarkdown
        syncedTitleRef.current = synchronized.syncedTitle
        conflictRef.current = false
        pendingEditorMarkdownRef.current = null
        if (aliveRef.current) {
          revisionRef.current += 1
          setEditorSeed({
            markdown: synchronized.currentMarkdown,
            revision: revisionRef.current
          })
          setPresentedMarkdown(synchronized.currentMarkdown)
          setViewMode(
            splitQuizMarkdown(synchronized.currentMarkdown) === null
              ? 'edit'
              : 'quiz'
          )
          setStatusIfMounted(synchronized.dirty ? 'dirty' : 'saved')
          if (synchronized.dirty) scheduleRef.current()
        }
      }
      if (!aliveRef.current || previousRelPath === nextRelPath) return
      setCurrentRelPath(nextRelPath)
      // Every session on the file is retargeted (H1 rename included), so each
      // panel keeps its own dockview identity in sync here.
      panelApi.updateParameters({
        descriptor: descriptorFor('note', {
          courseId: noteRef.current.courseId,
          relPath: nextRelPath
        })
      })
      panelApi.setTitle(noteStem(nextRelPath))
    },
    [cancelEditBroadcast, clearTimer, panelApi, setStatusIfMounted]
  )

  const syncTitleToFileName = useCallback(
    async (markdown: string): Promise<void> => {
      const title = firstH1Title(markdown)
      if (title === syncedTitleRef.current) return
      if (title === null) {
        syncedTitleRef.current = null
        return
      }

      const ref = noteRef.current
      if (noteStem(ref.relPath) === normalizedTitleStem(title)) {
        syncedTitleRef.current = title
        return
      }

      const renamed = await invoke('notes:rename', {
        ...ref,
        newName: title
      })
      const rename = {
        sourceMarkdown: markdown,
        title: renamed.title,
        markdown: renamed.markdown
      }
      // Retargets EVERY session on the file — each panel (this one included)
      // refreshes its own dockview descriptor and title via retargetNote.
      if (!retargetOpenNoteSession(ref, renamed.relPath, renamed.mtime, rename)) {
        retargetNote(renamed.relPath, renamed.mtime, rename)
      }
    },
    [retargetNote]
  )

  /** Debounced live mirror of local typing into the file's other panels. */
  const scheduleEditBroadcast = useCallback((): void => {
    if (noteDocPeerCount(noteFileKeyNow()) < 2) return
    cancelEditBroadcast()
    broadcastTimerRef.current = setTimeout(() => {
      broadcastTimerRef.current = null
      broadcastNoteEdit(
        noteFileKeyNow(),
        panelApi.id,
        currentMarkdownRef.current
      )
    }, EDIT_BROADCAST_DELAY_MS)
  }, [cancelEditBroadcast, noteFileKeyNow, panelApi])

  const flush = useCallback(
    async (overwrite = false): Promise<NoteFlushResult> => {
      clearTimer()

      const inFlight = writeInFlightRef.current
      if (inFlight !== null) {
        const result = await inFlight
        if (
          currentMarkdownRef.current !== persistedMarkdownRef.current &&
          (!conflictRef.current || overwrite)
        ) {
          return flushRef.current(overwrite)
        }
        return result
      }

      if (mtimeRef.current === null) return { status: 'unavailable' }

      // Single-writer rule: only the panel that last received a local edit
      // persists the file. Mirroring panels report saved — their content is
      // the writer's, and the writer's own flush covers it.
      if (overwrite) {
        claimNoteWriter(noteFileKeyNow(), panelApi.id)
      } else if (!isNoteWriter(noteFileKeyNow(), panelApi.id)) {
        setStatusIfMounted('saved')
        return { status: 'saved' }
      }

      if (conflictRef.current && !overwrite) {
        return {
          status: 'conflict',
          detail: '디스크의 파일이 편집 중 변경되었습니다.'
        }
      }
      const markdown = currentMarkdownRef.current
      if (markdown === persistedMarkdownRef.current && !overwrite) {
        setStatusIfMounted('saved')
        return { status: 'saved' }
      }

      setStatusIfMounted('saving')
      const ref = noteRef.current
      const expectedMtime = mtimeRef.current
      const request = (async () => {
        try {
          const result = await invoke('notes:write', {
            ...ref,
            markdown,
            ...(overwrite ? {} : { expectedMtime })
          })
          mtimeRef.current = result.mtime
          persistedMarkdownRef.current = markdown
          conflictRef.current = false
          // The saved content supersedes any pending live broadcast; peers
          // get both the markdown and the fresh mtime so whichever panel
          // edits next saves without an expectedMtime conflict.
          cancelEditBroadcast()
          broadcastNoteSave(
            noteFileKey(ref.courseId, ref.relPath),
            panelApi.id,
            markdown,
            result.mtime
          )
          requestMaterialConnectionsRefresh(ref.courseId)
          try {
            await syncTitleToFileName(markdown)
          } catch (error) {
            const detail = errorMessage(error)
            setStatusIfMounted('error', detail)
            return { status: 'error', detail } as const
          }

          if (currentMarkdownRef.current === persistedMarkdownRef.current) {
            setStatusIfMounted('saved')
          } else {
            setStatusIfMounted('dirty')
            scheduleRef.current()
          }
          return { status: 'saved' } as const
        } catch (error) {
          if (isNoteConflict(error)) {
            const detail = '디스크의 파일이 편집 중 변경되었습니다.'
            if (
              !overwrite &&
              mtimeRef.current !== null &&
              mtimeRef.current !== expectedMtime
            ) {
              // Another panel of this app saved while our write was in
              // flight — its broadcast already refreshed our mtime. This is
              // an in-app race, not an external change: leave conflictRef
              // false so the outer flush retries instead of raising the
              // conflict banner.
              return { status: 'conflict', detail } as const
            }
            conflictRef.current = true
            setStatusIfMounted('conflict', detail)
            return { status: 'conflict', detail } as const
          } else if (overwrite) {
            const detail = errorMessage(error)
            conflictRef.current = true
            setStatusIfMounted('conflict', detail)
            return { status: 'error', detail } as const
          } else {
            const detail = errorMessage(error)
            setStatusIfMounted('error', detail)
            return { status: 'error', detail } as const
          }
        } finally {
          writeInFlightRef.current = null
        }
      })()
      writeInFlightRef.current = request
      const result = await request

      // In-app race (see the conflict handler above): retry against the
      // propagated mtime instead of surfacing a conflict banner.
      if (result.status === 'conflict' && !conflictRef.current && !overwrite) {
        return flushRef.current()
      }
      if (
        overwrite &&
        !conflictRef.current &&
        currentMarkdownRef.current !== persistedMarkdownRef.current
      ) {
        return flushRef.current()
      }
      return result
    },
    [
      cancelEditBroadcast,
      clearTimer,
      noteFileKeyNow,
      panelApi,
      setStatusIfMounted,
      syncTitleToFileName
    ]
  )
  flushRef.current = flush

  const preserveOnClose = useCallback((): Promise<unknown> => {
    const existing = closeTaskRef.current
    if (existing !== null) return existing

    const task = preserveNoteOnClose({
      flush: () => flushRef.current(),
      snapshot: () => ({
        ref: noteRef.current,
        markdown: currentMarkdownRef.current,
        persistedMarkdown: persistedMarkdownRef.current,
        conflict: conflictRef.current
      }),
      createConflictCopy: createNoteConflictCopy,
      notify: showToast
    })
    closeTaskRef.current = task
    return task
  }, [noteRef])

  const scheduleSave = useCallback((): void => {
    if (!aliveRef.current || conflictRef.current) return
    clearTimer()
    timerRef.current = setTimeout(() => {
      timerRef.current = null
      void flushRef.current()
    }, SAVE_DELAY_MS)
  }, [clearTimer])
  scheduleRef.current = scheduleSave

  const applyLoadedNote = useCallback(
    (note: NoteContent): void => {
      clearTimer()
      pendingEditorMarkdownRef.current = null
      currentMarkdownRef.current = note.markdown
      persistedMarkdownRef.current = note.markdown
      mtimeRef.current = note.mtime
      syncedTitleRef.current = firstH1Title(note.markdown)
      conflictRef.current = false
      revisionRef.current += 1
      setEditorSeed({ markdown: note.markdown, revision: revisionRef.current })
      setPresentedMarkdown(note.markdown)
      setViewMode(splitQuizMarkdown(note.markdown) === null ? 'edit' : 'quiz')
      setLoadError(null)
      setStatusIfMounted('saved')
    },
    [clearTimer, setStatusIfMounted]
  )

  /**
   * Reflects remote (same-app, other-panel) markdown into this panel's
   * editor by reseeding it — the same remount path the "다시 불러오기"
   * button uses. While this panel holds focus the swap is deferred so the
   * caret and IME state survive; the scroll position is captured and
   * restored around the remount.
   */
  const applyMarkdownToEditor = useCallback((markdown: string): void => {
    const root = containerRef.current
    const active = document.activeElement
    if (root !== null && active !== null && root.contains(active)) {
      pendingEditorMarkdownRef.current = markdown
      return
    }
    pendingEditorMarkdownRef.current = null
    const scroller = root?.querySelector('.note-editor-scroll')
    pendingScrollTopRef.current =
      scroller instanceof HTMLElement ? scroller.scrollTop : null
    revisionRef.current += 1
    setEditorSeed({ markdown, revision: revisionRef.current })
  }, [])

  /** Applies markdown that arrived while this panel was focused. */
  const flushPendingEditorMarkdown = useCallback((): void => {
    const pending = pendingEditorMarkdownRef.current
    if (pending === null) return
    pendingEditorMarkdownRef.current = null
    applyMarkdownToEditor(pending)
  }, [applyMarkdownToEditor])

  const handleRemoteEdit = useCallback(
    (markdown: string): void => {
      // The sender is now the writer — drop our stale save/broadcast timers.
      clearTimer()
      cancelEditBroadcast()
      if (markdown === currentMarkdownRef.current) return
      currentMarkdownRef.current = markdown
      // The writer panel owns persistence of this content: mirroring panels
      // must not treat it as their own dirty state (no save attempts, no
      // conflict-copy toast when they close). Any conflict is likewise the
      // writer's to detect and surface.
      persistedMarkdownRef.current = markdown
      conflictRef.current = false
      syncedTitleRef.current = firstH1Title(markdown)
      if (!aliveRef.current) return
      setPresentedMarkdown(markdown)
      setStatusIfMounted('saved')
      applyMarkdownToEditor(markdown)
    },
    [applyMarkdownToEditor, cancelEditBroadcast, clearTimer, setStatusIfMounted]
  )

  const handleRemoteSave = useCallback(
    (markdown: string, mtime: number): void => {
      // The propagated mtime is what lets this panel save next without an
      // expectedMtime conflict, writer or not.
      mtimeRef.current = mtime
      persistedMarkdownRef.current = markdown
      if (currentNoteWriter(noteFileKeyNow()) === panelApi.id) {
        // We already took over as writer with newer local edits; keep them.
        return
      }
      conflictRef.current = false
      if (markdown !== currentMarkdownRef.current) {
        currentMarkdownRef.current = markdown
        syncedTitleRef.current = firstH1Title(markdown)
        if (aliveRef.current) {
          setPresentedMarkdown(markdown)
          applyMarkdownToEditor(markdown)
        }
      }
      setStatusIfMounted('saved')
    },
    [applyMarkdownToEditor, noteFileKeyNow, panelApi, setStatusIfMounted]
  )

  const remoteEditRef = useRef(handleRemoteEdit)
  const remoteSaveRef = useRef(handleRemoteSave)
  remoteEditRef.current = handleRemoteEdit
  remoteSaveRef.current = handleRemoteSave

  const loadNote = useCallback(async (): Promise<void> => {
    setLoadError(null)
    try {
      const note = await invoke('notes:read', noteRef.current)
      if (aliveRef.current) applyLoadedNote(note)
    } catch (error) {
      if (aliveRef.current) setLoadError(errorMessage(error))
    }
  }, [applyLoadedNote, noteRef])

  useEffect(() => {
    void loadNote()
  }, [loadNote])

  useEffect(() => {
    if (
      noteRef.current.courseId === courseId &&
      noteRef.current.relPath === relPath
    ) {
      return
    }
    noteRef.current = { courseId, relPath }
    setCurrentRelPath(relPath)
  }, [courseId, relPath])

  useEffect(
    () =>
      registerOpenNoteSession({
        panelId: panelApi.id,
        flush: () => { flushPendingEditorMarkdown(); return flushRef.current() },
        snapshot: () => mtimeRef.current === null ? null : currentMarkdownRef.current,
        ref: () => noteRef.current,
        retarget: retargetNote
      }),
    [panelApi, retargetNote, flushPendingEditorMarkdown]
  )

  // Live sync channel with other panels showing the same file. Re-subscribes
  // under the new file key whenever a rename/move retargets this session.
  useEffect(() => {
    return subscribeNoteDoc(
      noteFileKey(courseId, currentRelPath),
      panelApi.id,
      {
        onRemoteEdit: (markdown) => remoteEditRef.current(markdown),
        onRemoteSave: (markdown, mtime) =>
          remoteSaveRef.current(markdown, mtime)
      }
    )
  }, [courseId, currentRelPath, panelApi])

  // Best-effort scroll restore around a remote-apply remount. The second,
  // delayed pass covers the async editor-plugin load reflowing the document.
  useEffect(() => {
    if (editorSeed === null) return
    const scrollTop = pendingScrollTopRef.current
    if (scrollTop === null) return
    pendingScrollTopRef.current = null
    const restore = (): void => {
      const scroller = containerRef.current?.querySelector('.note-editor-scroll')
      if (scroller instanceof HTMLElement) scroller.scrollTop = scrollTop
    }
    const frame = requestAnimationFrame(restore)
    const timeout = setTimeout(restore, SCROLL_RESTORE_RETRY_MS)
    return () => {
      cancelAnimationFrame(frame)
      clearTimeout(timeout)
    }
  }, [editorSeed])

  useEffect(() => {
    const disposable = panelApi.onDidActiveChange(({ isActive }) => {
      if (isActive) return
      flushPendingEditorMarkdown()
      void flushRef.current()
    })
    return () => disposable.dispose()
  }, [flushPendingEditorMarkdown, panelApi])

  useEffect(() => {
    return registerNoteFlushTriggers({
      windowTarget: window,
      documentTarget: document,
      visibilityState: () => document.visibilityState,
      flush: () => void flushRef.current(),
      close: () => void preserveOnClose()
    })
  }, [preserveOnClose])

  useEffect(() => {
    // Revive on (re)mount. StrictMode mounts → unmounts → remounts the SAME
    // instance, so refs survive the cycle: without this line the cleanup's
    // `false` sticks, every `if (aliveRef.current)` guard fails, and the
    // resolved notes:read is dropped on the floor — the tab then sits on
    // "필기를 불러오는 중…" forever.
    aliveRef.current = true
    closeTaskRef.current = null
    return () => {
      clearTimer()
      cancelEditBroadcast()
      aliveRef.current = false
      void preserveOnClose()
    }
  }, [cancelEditBroadcast, clearTimer, preserveOnClose])

  useEffect(() => {
    const syncFontScale = (event: Event): void => {
      if (!(event instanceof CustomEvent)) return
      const scale = parseNoteFontScale(String(event.detail))
      setFontScale(scale)
    }
    window.addEventListener('bandal:note-font-scale', syncFontScale)
    return () =>
      window.removeEventListener('bandal:note-font-scale', syncFontScale)
  }, [])

  const changeFontScale = useCallback((scale: NoteFontScale): void => {
    setFontScale(scale)
    try {
      localStorage.setItem(NOTE_FONT_SCALE_STORAGE_KEY, String(scale))
    } catch {
      // Storage may be unavailable in a locked-down renderer; keep the session value.
    }
    window.dispatchEvent(
      new CustomEvent('bandal:note-font-scale', { detail: scale })
    )
  }, [])

  const stepFontScale = useCallback(
    (direction: -1 | 1): void => {
      changeFontScale(stepNoteFontScale(fontScale, direction))
    },
    [changeFontScale, fontScale]
  )

  const openPageNotePair = useCallback((): void => {
    if (
      pageNoteConnection === null ||
      !(pageNoteConnection.source.kind === 'pdf' || pageNoteConnection.source.kind === 'file') ||
      pageNoteConnection.target.kind !== 'note'
    ) return
    useWorkspaceStore.getState().openPdfNotePair(
      pageNoteConnection.source,
      pageNoteConnection.target,
      pageNoteConnection.id,
      pageNoteCurrentPage
    )
  }, [pageNoteConnection, pageNoteCurrentPage])

  const togglePageNoteSync = useCallback((): void => {
    const next = !pageNoteSync
    setPageNoteSync(next)
    if (pageNoteConnection?.metadata === null || pageNoteConnection === null) return
    void invoke('links:updatePageNote', {
      courseId,
      id: pageNoteConnection.id,
      metadata: { ...pageNoteConnection.metadata, syncScroll: next }
    }).then((updated) => {
      if (aliveRef.current) setPageNoteConnection(updated)
    }).catch((error: unknown) => {
      console.error('[Bandal] 페이지 필기 동기화 설정을 저장하지 못했습니다.', error)
    })
  }, [courseId, pageNoteConnection, pageNoteSync, setPageNoteSync])

  const handleMarkdownChange = useCallback(
    (markdown: string): void => {
      if (markdown === currentMarkdownRef.current) return
      currentMarkdownRef.current = markdown
      // Typing here makes this panel's doc authoritative for the file: any
      // deferred remote content is stale, and this panel becomes the writer.
      pendingEditorMarkdownRef.current = null
      claimNoteWriter(noteFileKeyNow(), panelApi.id)
      scheduleEditBroadcast()
      setPresentedMarkdown(markdown)

      if (conflictRef.current) return
      if (markdown === persistedMarkdownRef.current) {
        clearTimer()
        setStatusIfMounted('saved')
        return
      }
      setStatusIfMounted('dirty')
      scheduleSave()
    },
    [
      clearTimer,
      noteFileKeyNow,
      panelApi,
      scheduleEditBroadcast,
      scheduleSave,
      setStatusIfMounted
    ]
  )

  const reloadFromDisk = useCallback(async (): Promise<void> => {
    setConflictBusy(true)
    try {
      const note = await invoke('notes:read', noteRef.current)
      if (aliveRef.current) applyLoadedNote(note)
    } catch (error) {
      setStatusIfMounted('conflict', errorMessage(error))
    } finally {
      if (aliveRef.current) setConflictBusy(false)
    }
  }, [applyLoadedNote, noteRef, setStatusIfMounted])

  const keepMine = useCallback(async (): Promise<void> => {
    setConflictBusy(true)
    try {
      await flushRef.current(true)
    } finally {
      if (aliveRef.current) setConflictBusy(false)
    }
  }, [])

  const createRecoveryCopy = useCallback(async (): Promise<void> => {
    if (recoveryBusy) return
    setRecoveryBusy(true)
    try {
      const separator = currentRelPath.lastIndexOf('/')
      const dirRelPath = separator < 0 ? '' : currentRelPath.slice(0, separator)
      const title = `${noteStem(currentRelPath)} (복구 사본)`
      const copy = await invoke('notes:create', { courseId, dirRelPath, title })
      await invoke('notes:write', {
        ...copy,
        markdown: recoverPdfPageNoteAsMarkdown(currentMarkdownRef.current)
      })
      useWorkspaceStore.getState().openTab(
        descriptorFor('note', { courseId, relPath: copy.relPath })
      )
      showToast(`원본을 유지하고 “${copy.relPath}”에 복구했어요.`)
    } catch (error) {
      showToast(`복구 사본을 만들지 못했어요: ${errorMessage(error)}`, 'danger')
    } finally {
      if (aliveRef.current) setRecoveryBusy(false)
    }
  }, [courseId, currentRelPath, recoveryBusy])

  const quizSections = useMemo(
    () => splitQuizMarkdown(presentedMarkdown),
    [presentedMarkdown]
  )

  const enterEditMode = useCallback((): void => {
    revisionRef.current += 1
    setEditorSeed({
      markdown: currentMarkdownRef.current,
      revision: revisionRef.current
    })
    setViewMode('edit')
  }, [])

  const enterQuizMode = useCallback((): void => {
    setViewMode('quiz')
  }, [])

  const fileName = currentRelPath.split('/').at(-1) ?? currentRelPath

  if (loadError !== null && editorSeed === null) {
    return (
      <div className="note-tab note-tab--message">
        <p>필기를 불러오지 못했습니다.</p>
        <p className="note-tab__error-detail">{loadError}</p>
        <button type="button" className="note-action" onClick={() => void loadNote()}>
          다시 시도
        </button>
      </div>
    )
  }

  return (
    <div
      className="note-tab"
      ref={containerRef}
      onBlurCapture={(event) => {
        const next = event.relatedTarget
        if (next instanceof Node && event.currentTarget.contains(next)) return
        flushPendingEditorMarkdown()
      }}
    >
      <header className="note-toolbar">
        <div className="note-toolbar__identity">
          <span className="note-toolbar__path" title={currentRelPath}>
            {fileName}
          </span>
          {pageNoteDocument !== null && (
            <span className="note-toolbar__page-source" title={sourceRelPath(pageNoteDocument.manifest)}>
              {sourceRelPath(pageNoteDocument.manifest).split('/').at(-1)}
              <span>{pageNoteCurrentPage} / {pageNoteDocument.pages.length}</span>
            </span>
          )}
        </div>
        <div className="note-toolbar__actions">
          {pageNoteDocument !== null && pageNoteConnection !== null && pageNotePair === null && (
            <button type="button" className="note-action" onClick={openPageNotePair}>
              나란히 열기
            </button>
          )}
          {pageNoteDocument !== null && pageNotePair !== null && (
            <button
              type="button"
              className="note-action note-toolbar__sync"
              aria-pressed={pageNoteSync}
              onClick={togglePageNoteSync}
            >
              {pageNoteSync ? '스크롤 연결됨' : '스크롤 독립'}
            </button>
          )}
          {quizSections !== null && (
            <button
              type="button"
              className="note-action note-toolbar__mode"
              onClick={viewMode === 'quiz' ? enterEditMode : enterQuizMode}
            >
              {viewMode === 'quiz' ? '편집 모드' : '풀이 모드'}
            </button>
          )}
          <span
            className="note-save-status"
            data-status={status}
            title={statusDetail ?? STATUS_LABEL[status]}
            role="status"
            aria-live="polite"
          >
            <span className="note-save-status__dot" aria-hidden="true" />
            {STATUS_LABEL[status]}
          </span>
        </div>
      </header>

      {status === 'conflict' && (
        <div className="note-conflict" role="alert">
          <div>
            <strong>디스크에서 변경됨</strong>
            <span>{statusDetail}</span>
          </div>
          <div className="note-conflict__actions">
            <button
              type="button"
              className="note-action"
              disabled={conflictBusy}
              onClick={() => void reloadFromDisk()}
            >
              다시 불러오기
            </button>
            <button
              type="button"
              className="note-action note-action--primary"
              disabled={conflictBusy}
              onClick={() => void keepMine()}
            >
              내 버전 유지
            </button>
          </div>
        </div>
      )}

      {editorSeed === null ? (
        <div className="note-tab__loading" role="status">
          필기를 불러오는 중…
        </div>
      ) : (
        <div
          className="note-editor"
          style={{ '--note-font-scale': fontScale } as CSSProperties}
          onClickCapture={(event) => handleNoteLinkClick(event, courseId)}
        >
          {damagedPageNote ? (
            <div className="page-note-recovery" role="alert">
              <strong>페이지 필기 형식을 읽을 수 없어요</strong>
              <p>
                페이지 구분 정보가 손상되어 원본 편집을 잠갔습니다. 원본은 그대로 두고
                일반 마크다운 복구 사본을 만든 뒤 내용을 확인할 수 있어요.
              </p>
              <div className="page-note-recovery__actions">
                <button
                  type="button"
                  className="note-action note-action--primary"
                  disabled={recoveryBusy}
                  onClick={() => void createRecoveryCopy()}
                >
                  {recoveryBusy ? '복구 중…' : '복구 사본 만들기'}
                </button>
                <button type="button" className="note-action" onClick={() => void loadNote()}>
                  다시 불러오기
                </button>
              </div>
              <details>
                <summary>보존된 원문 보기</summary>
                <pre>{presentedMarkdown}</pre>
              </details>
            </div>
          ) : pageNoteDocument !== null ? (
            <PageNoteWorkspace
              key={editorSeed.revision}
              courseId={courseId}
              relPath={currentRelPath}
              document={pageNoteDocument}
              onMarkdownChange={handleMarkdownChange}
              fontScale={fontScale}
              onFontScaleChange={changeFontScale}
              onZoomStep={stepFontScale}
              pageNotePair={pageNotePair}
              panelId={panelApi.id}
              syncEnabled={pageNoteSync}
              onCurrentPageChange={setPageNoteCurrentPage}
            />
          ) : viewMode === 'quiz' && quizSections !== null ? (
            <QuizPreview courseId={courseId} sections={quizSections} />
          ) : (
            <MilkdownProvider key={editorSeed.revision}>
              <NoteEditorWorkspace
                courseId={courseId}
                relPath={currentRelPath}
                initialMarkdown={editorSeed.markdown}
                onMarkdownChange={handleMarkdownChange}
                fontScale={fontScale}
                onFontScaleChange={changeFontScale}
                onZoomStep={stepFontScale}
              />
            </MilkdownProvider>
          )}
        </div>
      )}
    </div>
  )
}

export default function NoteTab(props: IDockviewPanelProps): JSX.Element {
  const sessionIdRef = useRef<string | null>(null)
  const candidate = props.params['descriptor']
  if (!isTabDescriptor(candidate) || candidate.kind !== 'note') {
    return (
      <div className="note-tab note-tab--message" role="alert">
        올바르지 않은 필기 탭입니다.
      </div>
    )
  }

  const { courseId, relPath } = candidate.payload
  const pageNotePair = isPdfPageNotePairContext(props.params['pageNotePair']) &&
    props.params['pageNotePair'].role === 'note'
    ? props.params['pageNotePair']
    : null
  sessionIdRef.current ??= relPath
  return (
    <NoteSession
      key={`${courseId}:${sessionIdRef.current}`}
      courseId={courseId}
      relPath={relPath}
      panelApi={props.api}
      pageNotePair={pageNotePair}
    />
  )
}
