import { useRef, useState, type PointerEvent } from 'react'
import { invoke } from '../../lib/ipc'

export function PipToolbarApp(): JSX.Element {
  const [active, setActive] = useState(false)
  const dragRef = useRef<{
    pointerId: number
    screenX: number
    screenY: number
  } | null>(null)

  const beginDrag = (event: PointerEvent<HTMLElement>): void => {
    if (event.button !== 0) return
    const target = event.target
    if (target instanceof Element && target.closest('button') !== null) return
    dragRef.current = {
      pointerId: event.pointerId,
      screenX: event.screenX,
      screenY: event.screenY
    }
    event.currentTarget.setPointerCapture(event.pointerId)
    event.preventDefault()
  }

  const drag = (event: PointerEvent<HTMLElement>): void => {
    const previous = dragRef.current
    if (previous === null || previous.pointerId !== event.pointerId) return
    const dx = event.screenX - previous.screenX
    const dy = event.screenY - previous.screenY
    if (dx === 0 && dy === 0) return
    dragRef.current = {
      pointerId: event.pointerId,
      screenX: event.screenX,
      screenY: event.screenY
    }
    void invoke('pip:moveBy', { dx, dy }).catch(() => undefined)
  }

  const finishDrag = (event: PointerEvent<HTMLElement>): void => {
    const previous = dragRef.current
    if (previous === null || previous.pointerId !== event.pointerId) return
    if (event.currentTarget.hasPointerCapture(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }
    dragRef.current = null
  }

  return (
    <nav
      className={`pip-toolbar${active ? ' pip-toolbar--active' : ''}`}
      aria-label="웹 미니 플레이어 컨트롤"
      onMouseEnter={() => setActive(true)}
      onMouseMove={() => setActive(true)}
      onMouseLeave={() => setActive(false)}
      onPointerDown={beginDrag}
      onPointerMove={drag}
      onPointerUp={finishDrag}
      onPointerCancel={finishDrag}
    >
      <span className="pip-toolbar__grab" aria-hidden="true" />
      <button
        type="button"
        className="pip-toolbar__button"
        aria-label="원래 화면으로 돌아가기"
        title="돌아가기"
        onClick={() => {
          void invoke('pip:restore', {}).catch(() => undefined)
        }}
      >
        <span aria-hidden="true">↩</span>
      </button>
      <button
        type="button"
        className="pip-toolbar__button pip-toolbar__button--close"
        aria-label="미니 플레이어 닫기"
        title="닫기"
        onClick={() => {
          void invoke('pip:close', {}).catch(() => undefined)
        }}
      >
        <span aria-hidden="true">×</span>
      </button>
    </nav>
  )
}
