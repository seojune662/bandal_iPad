/**
 * Right-hand annotation rail: page-grouped list of highlights with quote +
 * comment previews. Clicking an entry scrolls the viewer to the highlight
 * and flashes it. Stale entries (anchor no longer found in the page text)
 * get a subtle badge with an explanatory tooltip.
 */

import { useMemo } from 'react'
import { Icon } from '../../app/icons'
import { TabKindIcon } from '../workspace/workspaceIcons'
import type { Annotation } from '../../../../shared/types/annotation'

export {
  backlinkPageLabel,
  MaterialBacklinksSection
} from '../links/MaterialConnectionsSection'

// 연결/인용 목록은 탭 상단 공통 연결 칩(MaterialSequenceWrapper)으로
// 이동했다 — 레일은 하이라이트만 담당한다.
export interface AnnotationRailProps {
  annotations: Annotation[]
  staleIds: Set<string>
  activeId: string | null
  error: string | null
  onJump: (annotation: Annotation) => void
  /** [M5] "AI에게 물어보기" — prefill the course chat with this highlight. */
  onAskAi: (annotation: Annotation) => void
  onClose: () => void
}

interface PageGroup {
  page: number
  items: Annotation[]
}

function groupByPage(annotations: Annotation[]): PageGroup[] {
  const map = new Map<number, Annotation[]>()
  for (const annotation of annotations) {
    const list = map.get(annotation.page)
    if (list === undefined) {
      map.set(annotation.page, [annotation])
    } else {
      list.push(annotation)
    }
  }
  return [...map.entries()]
    .sort(([a], [b]) => a - b)
    .map(([page, items]) => ({
      page,
      items: [...items].sort(
        (a, b) => (a.rects[0]?.y ?? 0) - (b.rects[0]?.y ?? 0)
      )
    }))
}

function RailItem({
  annotation,
  isStale,
  isActive,
  onJump,
  onAskAi
}: {
  annotation: Annotation
  isStale: boolean
  isActive: boolean
  onJump: (annotation: Annotation) => void
  onAskAi: (annotation: Annotation) => void
}): JSX.Element {
  return (
    <li className="pdf-rail__row">
      <button
        type="button"
        className="pdf-rail__item"
        data-active={isActive}
        onClick={() => onJump(annotation)}
      >
        <span
          className="pdf-rail__chip"
          data-color={annotation.color}
          aria-hidden="true"
        />
        <span className="pdf-rail__body">
          <span className="pdf-rail__quote">{annotation.anchor.quote}</span>
          {annotation.comment !== null && annotation.comment.length > 0 && (
            <span className="pdf-rail__comment">{annotation.comment}</span>
          )}
          {isStale && (
            <span
              className="pdf-rail__stale"
              title="문서가 바뀌어 이 인용을 원래 위치에서 찾지 못했어요. 표시 위치가 실제와 다를 수 있어요."
            >
              위치 불확실
            </span>
          )}
        </span>
      </button>
      <button
        type="button"
        className="pdf-rail__ask"
        aria-label="AI에게 물어보기"
        title="AI에게 물어보기"
        onClick={() => onAskAi(annotation)}
      >
        <TabKindIcon kind="chat" />
      </button>
    </li>
  )
}

export function AnnotationRail({
  annotations,
  staleIds,
  activeId,
  error,
  onJump,
  onAskAi,
  onClose
}: AnnotationRailProps): JSX.Element {
  const groups = useMemo(() => groupByPage(annotations), [annotations])

  return (
    <aside className="pdf-rail" aria-label="하이라이트 목록">
      <header className="pdf-rail__head">
        <h2 className="pdf-rail__title">
          하이라이트
          <span className="pdf-rail__count">{annotations.length}</span>
        </h2>
        <button
          type="button"
          className="pdf-rail__close"
          aria-label="하이라이트 목록 닫기"
          onClick={onClose}
        >
          <Icon name="x" />
        </button>
      </header>

      {error !== null && <p className="pdf-rail__error">{error}</p>}

      <div className="pdf-rail__scroll">
        {groups.length === 0 ? (
          <div className="pdf-rail__empty">
            <span className="pdf-rail__empty-mark" aria-hidden="true">
              <Icon name="pencil" />
            </span>
          </div>
        ) : (
          groups.map((group) => (
            <section key={group.page} className="pdf-rail__group">
              <h3 className="pdf-rail__page">p. {group.page}</h3>
              <ul className="pdf-rail__list">
                {group.items.map((annotation) => (
                  <RailItem
                    key={annotation.id}
                    annotation={annotation}
                    isStale={staleIds.has(annotation.id)}
                    isActive={annotation.id === activeId}
                    onJump={onJump}
                    onAskAi={onAskAi}
                  />
                ))}
              </ul>
            </section>
          ))
        )}
      </div>
    </aside>
  )
}
