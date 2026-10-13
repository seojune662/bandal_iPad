import { useViewportBounds } from '../../lib/useViewportBounds'
/**
 * 모든 워크스페이스 탭을 감싸는 자료 연결 레이어.
 *
 * 세 가지를 얹는다:
 * 1. 자료 파일 드래그(materialFileDrag) 중 좌/우 가장자리 드롭존 — 평소엔
 *    투명한 센서만 있다가, 포인터가 가장자리에 들어올 때만 반투명 드롭
 *    박스가 나타난다. 오른쪽 = "이 탭의 다음", 왼쪽 = "이전".
 * 2. 탭 상단의 ← 이전 · 다음 → 내비게이션.
 * 3. 연결 칩([🔗 N]) — 클릭하면 이 자료의 연결·인용 목록 패널이 열린다.
 *    노트/PDF 에만 있던 연결 UI 를 모든 탭 종류로 통일한 자리다.
 *
 * 드롭존/패널은 document.body 포탈 + position:fixed 다: 브라우저 탭의
 * webview 게스트가 window 레벨 고정 레이어(z-index 10)에 살아서 패널 DOM
 * 내부 요소로는 위를 덮을 수 없다. 드래그 중 pointer passthrough 는 일부러
 * 잡지 않는다 — 잡으면 웹뷰 안 업로드 폼(메일 첨부, LMS 제출)으로의 파일
 * 드롭이 죽는다. 연결 패널이 열려 있는 동안만 잡는다(클릭이 먹히도록).
 */

import {
  useCallback,
  useEffect,
  useState,
  useRef,
  useSyncExternalStore,
  type FunctionComponent
} from 'react'
import { createPortal } from 'react-dom'
import type { IDockviewPanelProps } from 'dockview'
import { isTabDescriptor, type TabDescriptor } from '../../../../shared/tabs'
import type { MaterialLinkRecord } from '../../../../shared/types/link'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { invoke, onPush, pathForFile } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { tabTitle } from '../workspace/tabIdentity'
import { TabKindIcon } from '../workspace/workspaceIcons'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import { relPathInsideCourse } from '../materials/importDrop'
import {
  clearMaterialFileDrag,
  getMaterialFileDrag,
  subscribeMaterialFileDrag,
  type MaterialFileDragState
} from '../materials/materialFileDrag'
import {
  MaterialConnectionsSection,
  connectionFileName
} from './MaterialConnectionsSection'
import { materialLinkDescriptor } from './LinkPickerDialog'
import {
  SEQUENCE_LABEL,
  edgeDropPlan,
  pickSequence,
  type SequenceEdge,
  type SequenceNeighbors
} from './sequenceLinks'
import {
  requestMaterialConnectionsRefresh,
  subscribeMaterialConnectionsRefresh
} from './useMaterialConnections'
import './links.css'

const EDGE_SENSOR_WIDTH_PX = 96

interface SequenceLinksState {
  neighbors: SequenceNeighbors
  outgoing: MaterialLinkRecord[]
  incoming: MaterialLinkRecord[]
  backlinkCount: number
}

const EMPTY_STATE: SequenceLinksState = {
  neighbors: { prev: null, next: null },
  outgoing: [],
  incoming: [],
  backlinkCount: 0
}

function descriptorCourseId(descriptor: TabDescriptor): string | null {
  const payload = descriptor.payload as Record<string, unknown>
  const courseId = payload['courseId']
  return typeof courseId === 'string' && courseId.length > 0 ? courseId : null
}

function descriptorRelPath(descriptor: TabDescriptor): string | null {
  const payload = descriptor.payload as Record<string, unknown>
  const relPath = payload['relPath']
  return typeof relPath === 'string' && relPath.length > 0 ? relPath : null
}

function useSequenceLinks(
  courseId: string | null,
  descriptorJson: string | null
): SequenceLinksState {
  const [state, setState] = useState<SequenceLinksState>(EMPTY_STATE)

  useEffect(() => {
    if (courseId === null || descriptorJson === null) {
      setState(EMPTY_STATE)
      return
    }
    const descriptor = JSON.parse(descriptorJson) as TabDescriptor
    const relPath = descriptorRelPath(descriptor)
    let disposed = false
    let sequence = 0

    const loadLinks = async (): Promise<void> => {
      const current = ++sequence
      try {
        const result = await invoke('links:listForDescriptor', {
          courseId,
          descriptor
        })
        if (!disposed && current === sequence) {
          setState((previous) => ({
            ...previous,
            neighbors: pickSequence(result.outgoing, result.incoming),
            outgoing: result.outgoing,
            incoming: result.incoming
          }))
        }
      } catch (caught) {
        if (!disposed && current === sequence) {
          console.error('[Bandal] 자료 연결을 불러오지 못했습니다.', caught)
          setState(EMPTY_STATE)
        }
      }
    }

    // 백링크는 과목 전체 재스캔이라 비싸다 — 마운트와 명시적 연결 갱신에서만.
    const loadBacklinks = async (): Promise<void> => {
      if (relPath === null) return
      try {
        const backlinks = await invoke('links:forMaterial', {
          courseId,
          relPath
        })
        if (!disposed) {
          setState((previous) => ({
            ...previous,
            backlinkCount: backlinks.notes.length + backlinks.boards.length
          }))
        }
      } catch {
        // 백링크 수는 장식 — 실패해도 링크 UI 는 그대로 동작한다.
      }
    }

    void loadLinks()
    void loadBacklinks()
    // links:create/remove 가 materials:changed 를 broadcast 하므로 이거면 된다.
    const stopMaterials = onPush('materials:changed', (payload) => {
      if (payload.courseId === courseId) void loadLinks()
    })
    const stopRefresh = subscribeMaterialConnectionsRefresh(courseId, () => {
      void loadLinks()
      void loadBacklinks()
    })
    return () => {
      disposed = true
      sequence += 1
      stopMaterials()
      stopRefresh()
    }
  }, [courseId, descriptorJson])

  return state
}

/**
 * 드롭된 Files 가 기록된 드래그와 같은 파일인지 대조한다. 파일이 비어 있으면
 * (e2e 합성 이벤트) 모듈 상태를 신뢰하고, 경로가 어긋나면 스테일 상태다.
 */
function dropMatchesDrag(
  event: React.DragEvent,
  drag: MaterialFileDragState,
  courseFolder: string | undefined
): boolean {
  const files = event.dataTransfer?.files
  if (files === undefined || files.length === 0) return true
  if (courseFolder === undefined) return false
  const first = files[0]
  if (first === undefined) return false
  const absPath = pathForFile(first)
  return relPathInsideCourse(absPath, courseFolder) === drag.relPath.normalize('NFC')
}

function EdgeDropStrips({
  hostRef,
  tabDescriptor,
  tabCourseId
}: {
  hostRef: React.RefObject<HTMLDivElement>
  tabDescriptor: TabDescriptor
  tabCourseId: string | null
}): JSX.Element | null {
  const drag = useSyncExternalStore(
    subscribeMaterialFileDrag,
    getMaterialFileDrag
  )
  const [rect, setRect] = useState<DOMRect | null>(null)
  const [hoverEdge, setHoverEdge] = useState<SequenceEdge | null>(null)
  const courses = useCoursesStore((state) => state.courses)

  useEffect(() => {
    if (drag === null) {
      setRect(null)
      setHoverEdge(null)
      return
    }
    const host = hostRef.current
    if (host === null) return
    const next = host.getBoundingClientRect()
    // 숨겨진(비활성) 패널은 폭이 0 — 스트립을 만들지 않는다.
    setRect(next.width > 0 && next.height > 0 ? next : null)
  }, [drag, hostRef])

  if (drag === null || rect === null) return null
  // 링크는 자료의 과목 아래 저장된다. 과목이 있는 탭이면 같은 과목만 허용.
  if (tabCourseId !== null && tabCourseId !== drag.courseId) return null

  const material = materialLinkDescriptor(drag.courseId, drag.relPath)

  const handleDrop = (edge: SequenceEdge) => (event: React.DragEvent) => {
    event.preventDefault()
    setHoverEdge(null)
    const courseFolder = courses.find(
      (course) => course.id === drag.courseId
    )?.folderPath
    if (!dropMatchesDrag(event, drag, courseFolder)) {
      clearMaterialFileDrag()
      return
    }
    clearMaterialFileDrag()

    const plan = edgeDropPlan(edge, tabDescriptor, material)
    void invoke('links:create', {
      courseId: drag.courseId,
      source: plan.source,
      target: plan.target,
      kind: 'sequence',
      label: SEQUENCE_LABEL
    })
      .then(() => {
        requestMaterialConnectionsRefresh(drag.courseId)
        showToast(
          edge === 'next' ? '다음 자료로 연결했어요' : '이전 자료로 연결했어요'
        )
      })
      .catch((caught: unknown) => {
        console.error('[Bandal] 자료를 연결하지 못했습니다.', caught)
        showToast(
          caught instanceof Error && caught.message.includes('different')
            ? '같은 자료끼리는 연결할 수 없어요'
            : '자료를 연결하지 못했어요',
          'danger'
        )
      })
  }

  const stripProps = (edge: SequenceEdge): React.HTMLAttributes<HTMLDivElement> => ({
    onDragOver: (event) => {
      event.preventDefault()
      if (event.dataTransfer !== null) event.dataTransfer.dropEffect = 'link'
    },
    onDragEnter: () => setHoverEdge(edge),
    onDragLeave: (event) => {
      // 자식(라벨)으로의 이동은 leave 가 아니다.
      const next = event.relatedTarget
      if (next instanceof Node && event.currentTarget.contains(next)) return
      setHoverEdge((current) => (current === edge ? null : current))
    },
    onDrop: handleDrop(edge)
  })

  // 센서는 상시 투명 — data-active 일 때만 반투명 드롭 박스로 나타난다.
  return createPortal(
    <>
      <div
        className="sequence-drop-strip sequence-drop-strip--prev"
        data-active={hoverEdge === 'prev' || undefined}
        style={{
          top: rect.top,
          left: rect.left,
          height: rect.height,
          width: EDGE_SENSOR_WIDTH_PX
        }}
        {...stripProps('prev')}
      >
        <span className="sequence-drop-strip__hint">← 이전 자료로 연결</span>
      </div>
      <div
        className="sequence-drop-strip sequence-drop-strip--next"
        data-active={hoverEdge === 'next' || undefined}
        style={{
          top: rect.top,
          left: rect.right - EDGE_SENSOR_WIDTH_PX,
          height: rect.height,
          width: EDGE_SENSOR_WIDTH_PX
        }}
        {...stripProps('next')}
      >
        <span className="sequence-drop-strip__hint">다음 자료로 연결 →</span>
      </div>
    </>,
    document.body
  )
}

/** 브라우저처럼 relPath 가 없는 탭의 수동 연결 목록 (열기/해제만). */
function DescriptorConnectionsList({
  courseId,
  outgoing,
  incoming
}: {
  courseId: string
  outgoing: MaterialLinkRecord[]
  incoming: MaterialLinkRecord[]
}): JSX.Element {
  const openTab = useWorkspaceStore((state) => state.openTab)
  const [pendingId, setPendingId] = useState<string | null>(null)
  const rows = [
    ...outgoing.map((record) => ({ record, other: record.target })),
    ...incoming.map((record) => ({ record, other: record.source }))
  ]

  const unlink = async (record: MaterialLinkRecord): Promise<void> => {
    setPendingId(record.id)
    try {
      await invoke('links:remove', { courseId, id: record.id })
      requestMaterialConnectionsRefresh(courseId)
    } catch (caught) {
      console.error('[Bandal] 자료 연결을 해제하지 못했습니다.', caught)
      showToast('연결을 해제하지 못했어요', 'danger')
    } finally {
      setPendingId(null)
    }
  }

  if (rows.length === 0) {
    return <p className="material-connections__empty">연결한 자료가 없어요.</p>
  }
  return (
    <ul className="material-connections__list">
      {rows.map(({ record, other }) => (
        <li key={record.id} className="material-connections__row">
          <TabKindIcon
            kind={other.kind}
            className="material-connections__kind-icon"
            aria-hidden="true"
          />
          <span className="material-connections__body">
            <span className="material-connections__file">
              {connectionFileName(other)}
            </span>
          </span>
          <span className="material-connections__actions">
            <button type="button" onClick={() => openTab(other)}>
              열기
            </button>
            <button
              type="button"
              disabled={pendingId === record.id}
              onClick={() => void unlink(record)}
            >
              {pendingId === record.id ? '해제 중…' : '해제'}
            </button>
          </span>
        </li>
      ))}
    </ul>
  )
}

/** 칩 아래에 뜨는 연결 패널 — body 포탈이라 웹뷰 위에서도 보인다. */
function ConnectionsPanel({
  anchor,
  courseId,
  relPath,
  outgoing,
  incoming,
  onClose
}: {
  anchor: DOMRect
  courseId: string
  relPath: string | null
  outgoing: MaterialLinkRecord[]
  incoming: MaterialLinkRecord[]
  onClose: () => void
}): JSX.Element {
  const panelRef = useRef<HTMLDivElement>(null)
  useViewportBounds(panelRef)

  // 웹뷰 게스트가 포인터를 삼키지 않게 — LinkPickerDialog 와 같은 이유.
  useEffect(() => acquirePointerPassthrough(), [])

  useEffect(() => {
    const closeOnPointerDown = (event: PointerEvent): void => {
      if (!panelRef.current?.contains(event.target as Node)) onClose()
    }
    const closeOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') onClose()
    }
    // 칩 클릭 자체로 바로 닫히지 않게 다음 틱에 설치한다.
    const timer = window.setTimeout(() => {
      document.addEventListener('pointerdown', closeOnPointerDown)
      document.addEventListener('keydown', closeOnEscape)
    }, 0)
    return () => {
      window.clearTimeout(timer)
      document.removeEventListener('pointerdown', closeOnPointerDown)
      document.removeEventListener('keydown', closeOnEscape)
    }
  }, [onClose])

  const left = Math.max(
    8,
    Math.min(anchor.left, window.innerWidth - 380)
  )

  return createPortal(
    <div
      ref={panelRef}
      className="sequence-connections-panel"
      role="dialog"
      aria-label="자료 연결"
      style={{ top: anchor.bottom + 4, left }}
    >
      {relPath !== null ? (
        <MaterialConnectionsSection courseId={courseId} relPath={relPath} />
      ) : (
        <DescriptorConnectionsList
          courseId={courseId}
          outgoing={outgoing}
          incoming={incoming}
        />
      )}
    </div>,
    document.body
  )
}

function SequenceNavBar({
  descriptor,
  courseId,
  links
}: {
  descriptor: TabDescriptor
  courseId: string
  links: SequenceLinksState
}): JSX.Element | null {
  const openTab = useWorkspaceStore((state) => state.openTab)
  const chipRef = useRef<HTMLButtonElement>(null)
  const [panelAnchor, setPanelAnchor] = useState<DOMRect | null>(null)
  const { neighbors } = links
  const relPath = descriptorRelPath(descriptor)
  const connectionCount =
    links.outgoing.length + links.incoming.length + links.backlinkCount

  const closePanel = useCallback(() => setPanelAnchor(null), [])

  if (
    neighbors.prev === null &&
    neighbors.next === null &&
    connectionCount === 0
  ) {
    return null
  }

  return (
    <nav className="sequence-nav" aria-label="연결된 자료 이동">
      {neighbors.prev !== null && (
        <button
          type="button"
          className="sequence-nav__link sequence-nav__link--prev"
          title={tabTitle(neighbors.prev.source)}
          onClick={() => {
            if (neighbors.prev !== null) openTab(neighbors.prev.source)
          }}
        >
          <Icon name="chevronLeft" />
          <span>{tabTitle(neighbors.prev.source)}</span>
        </button>
      )}
      <span className="sequence-nav__spacer" aria-hidden="true" />
      <button
        ref={chipRef}
        type="button"
        className="sequence-nav__chip"
        aria-haspopup="dialog"
        aria-expanded={panelAnchor !== null}
        onClick={() => {
          if (panelAnchor !== null) {
            closePanel()
            return
          }
          const rect = chipRef.current?.getBoundingClientRect()
          if (rect !== undefined) setPanelAnchor(rect)
        }}
      >
        <Icon name="link" />
        <span>연결 {connectionCount}</span>
      </button>
      <span className="sequence-nav__spacer" aria-hidden="true" />
      {neighbors.next !== null && (
        <button
          type="button"
          className="sequence-nav__link sequence-nav__link--next"
          title={tabTitle(neighbors.next.target)}
          onClick={() => {
            if (neighbors.next !== null) openTab(neighbors.next.target)
          }}
        >
          <span>{tabTitle(neighbors.next.target)}</span>
          <Icon name="chevronRight" />
        </button>
      )}
      {panelAnchor !== null && (
        <ConnectionsPanel
          anchor={panelAnchor}
          courseId={courseId}
          relPath={relPath}
          outgoing={links.outgoing}
          incoming={links.incoming}
          onClose={closePanel}
        />
      )}
    </nav>
  )
}

/** dockviewComponents 생성 시 모든 TabKind 를 이걸로 감싼다. */
export function withMaterialSequence(
  Component: FunctionComponent<IDockviewPanelProps>
): FunctionComponent<IDockviewPanelProps> {
  function MaterialSequenceHost(props: IDockviewPanelProps): JSX.Element {
    const hostRef = useRef<HTMLDivElement>(null)
    const rawDescriptor = (props.params as Record<string, unknown>)['descriptor']
    const descriptor = isTabDescriptor(rawDescriptor) ? rawDescriptor : null
    const selectedCourseId = useCoursesStore((state) => state.selectedCourseId)
    const tabCourseId = descriptor === null ? null : descriptorCourseId(descriptor)
    const queryCourseId = tabCourseId ?? selectedCourseId
    // params 객체는 참조가 흔들릴 수 있어 JSON 문자열로 정체성을 고정한다.
    const descriptorJson =
      descriptor === null ? null : JSON.stringify(descriptor)
    const links = useSequenceLinks(queryCourseId, descriptorJson)

    if (descriptor === null) return <Component {...props} />

    return (
      <div ref={hostRef} className="material-sequence-host">
        {queryCourseId !== null && (
          <SequenceNavBar
            descriptor={descriptor}
            courseId={queryCourseId}
            links={links}
          />
        )}
        <div className="material-sequence-host__content">
          <Component {...props} />
        </div>
        <EdgeDropStrips
          hostRef={hostRef}
          tabDescriptor={descriptor}
          tabCourseId={tabCourseId}
        />
      </div>
    )
  }
  MaterialSequenceHost.displayName = `withMaterialSequence(${
    Component.displayName ?? Component.name ?? 'Panel'
  })`
  return MaterialSequenceHost
}
