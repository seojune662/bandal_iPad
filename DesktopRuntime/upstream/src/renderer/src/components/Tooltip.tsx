import {
  cloneElement,
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type FocusEventHandler,
  type KeyboardEventHandler,
  type PointerEventHandler,
  type ReactElement
} from 'react'
import { createPortal } from 'react-dom'
import './tooltip.css'

type TooltipPlacement = 'top' | 'bottom' | 'left' | 'right'

interface TooltipProps {
  label: string
  placement?: TooltipPlacement
  children: ReactElement
}

interface TooltipPosition {
  left: number
  top: number
  placement: TooltipPlacement
}

interface TooltipChildHandlers {
  onPointerEnter?: PointerEventHandler<HTMLElement>
  onPointerLeave?: PointerEventHandler<HTMLElement>
  onPointerDown?: PointerEventHandler<HTMLElement>
  onFocus?: FocusEventHandler<HTMLElement>
  onBlur?: FocusEventHandler<HTMLElement>
  onKeyDown?: KeyboardEventHandler<HTMLElement>
}

const SHOW_DELAY_MS = 300
const FALLBACK_VIEWPORT_MARGIN_PX = 8

function viewportMargin(): number {
  const value = getComputedStyle(document.documentElement)
    .getPropertyValue('--space-2')
    .trim()
  const parsed = Number.parseFloat(value)
  if (!Number.isFinite(parsed)) return FALLBACK_VIEWPORT_MARGIN_PX
  if (value.endsWith('rem')) {
    const rootFontSize = Number.parseFloat(
      getComputedStyle(document.documentElement).fontSize
    )
    return Number.isFinite(rootFontSize)
      ? parsed * rootFontSize
      : FALLBACK_VIEWPORT_MARGIN_PX
  }
  if (value.endsWith('px') || value === '0') return parsed
  return FALLBACK_VIEWPORT_MARGIN_PX
}

function flippedPlacement(
  preferred: TooltipPlacement,
  anchor: DOMRect,
  tooltip: DOMRect,
  margin: number
): TooltipPlacement {
  if (preferred === 'top' || preferred === 'bottom') {
    const preferredRoom =
      preferred === 'top'
        ? anchor.top - margin
        : window.innerHeight - anchor.bottom - margin
    const oppositeRoom =
      preferred === 'top'
        ? window.innerHeight - anchor.bottom - margin
        : anchor.top - margin
    if (tooltip.height > preferredRoom && oppositeRoom > preferredRoom) {
      return preferred === 'top' ? 'bottom' : 'top'
    }
    return preferred
  }

  const preferredRoom =
    preferred === 'left'
      ? anchor.left - margin
      : window.innerWidth - anchor.right - margin
  const oppositeRoom =
    preferred === 'left'
      ? window.innerWidth - anchor.right - margin
      : anchor.left - margin
  if (tooltip.width > preferredRoom && oppositeRoom > preferredRoom) {
    return preferred === 'left' ? 'right' : 'left'
  }
  return preferred
}

function positionTooltip(
  anchor: DOMRect,
  tooltip: DOMRect,
  preferred: TooltipPlacement
): TooltipPosition {
  const margin = viewportMargin()
  const placement = flippedPlacement(preferred, anchor, tooltip, margin)
  let left = anchor.left + (anchor.width - tooltip.width) / 2
  let top = anchor.top + (anchor.height - tooltip.height) / 2

  if (placement === 'top') top = anchor.top - tooltip.height - margin
  if (placement === 'bottom') top = anchor.bottom + margin
  if (placement === 'left') left = anchor.left - tooltip.width - margin
  if (placement === 'right') left = anchor.right + margin

  const maxLeft = Math.max(margin, window.innerWidth - tooltip.width - margin)
  const maxTop = Math.max(margin, window.innerHeight - tooltip.height - margin)

  return {
    left: Math.round(Math.min(Math.max(left, margin), maxLeft)),
    top: Math.round(Math.min(Math.max(top, margin), maxTop)),
    placement
  }
}

export function Tooltip({
  label,
  placement = 'top',
  children
}: TooltipProps): JSX.Element {
  const [visible, setVisible] = useState(false)
  const [pending, setPending] = useState(false)
  const [position, setPosition] = useState<TooltipPosition | null>(null)
  const anchorRef = useRef<HTMLElement | null>(null)
  const tooltipRef = useRef<HTMLDivElement>(null)
  const showTimerRef = useRef<number | null>(null)
  const focusResetTimerRef = useRef<number | null>(null)
  const ignoreNextFocusRef = useRef(false)

  const clearShowTimer = useCallback((): void => {
    if (showTimerRef.current === null) return
    window.clearTimeout(showTimerRef.current)
    showTimerRef.current = null
  }, [])

  const hideImmediately = useCallback((): void => {
    clearShowTimer()
    setPending(false)
    setVisible(false)
    setPosition(null)
  }, [clearShowTimer])

  const ignorePointerFocus = useCallback((): void => {
    ignoreNextFocusRef.current = true
    if (focusResetTimerRef.current !== null) {
      window.clearTimeout(focusResetTimerRef.current)
    }
    focusResetTimerRef.current = window.setTimeout(() => {
      ignoreNextFocusRef.current = false
      focusResetTimerRef.current = null
    }, 0)
  }, [])

  const showAfterDelay = useCallback(
    (anchor: HTMLElement): void => {
      clearShowTimer()
      anchorRef.current = anchor
      setPending(true)
      showTimerRef.current = window.setTimeout(() => {
        showTimerRef.current = null
        setPending(false)
        if (anchor.isConnected) setVisible(true)
      }, SHOW_DELAY_MS)
    },
    [clearShowTimer]
  )

  useLayoutEffect(() => {
    if (!visible) return

    const updatePosition = (): void => {
      const anchor = anchorRef.current
      const tooltip = tooltipRef.current
      if (anchor === null || tooltip === null || !anchor.isConnected) {
        hideImmediately()
        return
      }
      setPosition(
        positionTooltip(
          anchor.getBoundingClientRect(),
          tooltip.getBoundingClientRect(),
          placement
        )
      )
    }

    updatePosition()
    window.addEventListener('resize', updatePosition)
    window.addEventListener('scroll', updatePosition, true)
    return () => {
      window.removeEventListener('resize', updatePosition)
      window.removeEventListener('scroll', updatePosition, true)
    }
  }, [hideImmediately, label, placement, visible])

  useEffect(() => {
    if (!visible && !pending) return
    const hideOnEscape = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') hideImmediately()
    }
    window.addEventListener('keydown', hideOnEscape)
    return () => window.removeEventListener('keydown', hideOnEscape)
  }, [hideImmediately, pending, visible])

  useEffect(
    () => () => {
      clearShowTimer()
      if (focusResetTimerRef.current !== null) {
        window.clearTimeout(focusResetTimerRef.current)
      }
    },
    [clearShowTimer]
  )

  const child = children as ReactElement<TooltipChildHandlers>
  const trigger = cloneElement(child, {
    onPointerEnter: (event) => {
      child.props.onPointerEnter?.(event)
      showAfterDelay(event.currentTarget)
    },
    onPointerLeave: (event) => {
      child.props.onPointerLeave?.(event)
      hideImmediately()
    },
    onPointerDown: (event) => {
      child.props.onPointerDown?.(event)
      hideImmediately()
      ignorePointerFocus()
    },
    onFocus: (event) => {
      child.props.onFocus?.(event)
      if (event.currentTarget !== event.target) return
      if (ignoreNextFocusRef.current) {
        ignoreNextFocusRef.current = false
        return
      }
      showAfterDelay(event.currentTarget)
    },
    onBlur: (event) => {
      child.props.onBlur?.(event)
      if (event.currentTarget !== event.target) return
      hideImmediately()
    },
    onKeyDown: (event) => {
      child.props.onKeyDown?.(event)
      if (event.key === 'Escape') hideImmediately()
    }
  })

  return (
    <>
      {trigger}
      {visible &&
        createPortal(
          <div
            ref={tooltipRef}
            className="tooltip"
            role="tooltip"
            aria-hidden="true"
            data-placement={position?.placement ?? placement}
            data-positioned={position === null ? undefined : 'true'}
            style={
              position === null
                ? undefined
                : { left: position.left, top: position.top }
            }
          >
            {label}
          </div>,
          document.body
        )}
    </>
  )
}
