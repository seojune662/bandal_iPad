import { useCallback, useEffect, useRef, useState } from 'react'
import type { PointerEvent as ReactPointerEvent } from 'react'
import {
  RAIL_WIDTH_LIMITS,
  RAIL_WIDTH_VARIABLES,
  clampRailWidth,
  persistRailWidth,
  type RailSide
} from './railWidth'

interface RailResizerProps {
  side: RailSide
}

/**
 * 사이드바 안쪽 모서리의 드래그 핸들. move 중에는 리렌더 없이 documentElement
 * 의 CSS 변수를 직접 갱신하고(소비처 전부 실시간 추종), 놓을 때 저장한다.
 * 더블클릭 = 기본 폭 복원.
 */
export function RailResizer({ side }: RailResizerProps): JSX.Element {
  const dragRef = useRef<{ pointerId: number; startX: number; startWidth: number } | null>(null)
  const [width, setWidth] = useState(RAIL_WIDTH_LIMITS[side].default)
  useEffect(() => () => { delete document.documentElement.dataset.railResizing }, [])

  const applyWidth = useCallback((px: number): number => {
    const clamped = clampRailWidth(side, px)
    document.documentElement.style.setProperty(
      RAIL_WIDTH_VARIABLES[side],
      `${clamped}px`
    )
    setWidth(clamped)
    return clamped
  }, [side])

  const cancelDrag = useCallback((): void => {
    const drag = dragRef.current
    if (drag === null) return
    dragRef.current = null
    delete document.documentElement.dataset.railResizing
    applyWidth(drag.startWidth)
  }, [applyWidth])

  const currentWidth = useCallback((): number => {
    // 리사이저는 그리드 경계에 절대배치된 형제라, 실제 폭은 rail 요소를 잰다.
    const rail = document.querySelector(`.app-rail--${side}:not([hidden])`)
    return rail instanceof HTMLElement
      ? rail.getBoundingClientRect().width
      : RAIL_WIDTH_LIMITS[side].default
  }, [side])

  useEffect(() => { setWidth(currentWidth()) }, [currentWidth])

  const finishDrag = useCallback((event: ReactPointerEvent<HTMLDivElement>): void => {
    const drag = dragRef.current
    if (drag === null || drag.pointerId !== event.pointerId) return
    dragRef.current = null
    delete document.documentElement.dataset.railResizing
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    const delta = side === 'left'
      ? event.clientX - drag.startX
      : drag.startX - event.clientX
    persistRailWidth(side, applyWidth(drag.startWidth + delta))
  }, [applyWidth, side])

  return (
    <div
      className={`rail-resizer rail-resizer--${side}`}
      role="separator"
      aria-orientation="vertical"
      aria-label={side === 'left' ? '과목 사이드바 폭 조절' : '자료 사이드바 폭 조절'}
      aria-valuemin={RAIL_WIDTH_LIMITS[side].min}
      aria-valuemax={RAIL_WIDTH_LIMITS[side].max}
      aria-valuenow={width}
      tabIndex={0}
      title="드래그 또는 좌우 방향키로 폭 조절 · 더블클릭하면 기본 폭"
      onKeyDown={event => {
        if (event.altKey || event.ctrlKey || event.metaKey) return
        const delta = event.key === 'ArrowLeft' ? -16 : event.key === 'ArrowRight' ? 16 : null
        const next = event.key === 'Home' ? RAIL_WIDTH_LIMITS[side].min
          : event.key === 'End' ? RAIL_WIDTH_LIMITS[side].max
          : delta === null ? null : currentWidth() + (side === 'left' ? delta : -delta)
        if (next === null) return
        event.preventDefault()
        persistRailWidth(side, applyWidth(next))
      }}
      onPointerDown={(event) => {
        if (event.button !== 0) return
        event.preventDefault()
        document.documentElement.dataset.railResizing = 'true'
        event.currentTarget.setPointerCapture(event.pointerId)
        dragRef.current = {
          pointerId: event.pointerId,
          startX: event.clientX,
          startWidth: currentWidth()
        }
      }}
      onPointerMove={(event) => {
        const drag = dragRef.current
        if (drag === null || drag.pointerId !== event.pointerId) return
        const delta = side === 'left'
          ? event.clientX - drag.startX
          : drag.startX - event.clientX
        applyWidth(drag.startWidth + delta)
      }}
      onPointerUp={finishDrag}
      onPointerCancel={cancelDrag}
      onLostPointerCapture={cancelDrag}
      onDoubleClick={() => {
        persistRailWidth(side, applyWidth(RAIL_WIDTH_LIMITS[side].default))
      }}
    />
  )
}
