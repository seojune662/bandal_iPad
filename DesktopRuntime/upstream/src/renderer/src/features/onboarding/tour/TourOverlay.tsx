import {
  useEffect,
  useId,
  useMemo,
  useRef,
  useState
} from 'react'
import type { CSSProperties, RefObject } from 'react'
import { useFocusTrap } from '../../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../../browser/webviewPassthrough'
import { TOUR_STEP_COUNT, TOUR_STEPS } from './tourScript'
import { useTourAnchor } from './useTourAnchor'
import { useTourStore, type TourStatus } from './tourStore'
import type {
  TourAnchorRect,
  TourPlacement,
  TourStep
} from './tourTypes'
import { useLocale } from '../../../i18n'
import { onboardingCopy } from '../onboardingCopy'
import './tour.css'

interface CardSize {
  width: number
  height: number
}

interface CardPosition {
  top: number
  left: number
  placement: TourPlacement
}

interface TourLayout {
  width: number
  height: number
  holePadding: number
  cardGap: number
  viewportMargin: number
}

function tokenPixels(token: string): number {
  const styles = window.getComputedStyle(document.documentElement)
  const value = styles.getPropertyValue(token).trim()
  const numeric = Number.parseFloat(value)
  const rootFontSize = Number.parseFloat(styles.fontSize)
  if (!Number.isFinite(numeric)) return rootFontSize
  if (value.endsWith('rem')) return numeric * rootFontSize
  return numeric
}

function currentLayout(): TourLayout {
  return {
    width: window.innerWidth,
    height: window.innerHeight,
    holePadding: tokenPixels('--space-2'),
    cardGap: tokenPixels('--space-3'),
    viewportMargin: tokenPixels('--space-4')
  }
}

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(Math.max(value, minimum), Math.max(minimum, maximum))
}

function paddedRect(rect: TourAnchorRect, layout: TourLayout): TourAnchorRect {
  const left = clamp(rect.left - layout.holePadding, 0, layout.width)
  const top = clamp(rect.top - layout.holePadding, 0, layout.height)
  const right = clamp(rect.right + layout.holePadding, left, layout.width)
  const bottom = clamp(rect.bottom + layout.holePadding, top, layout.height)
  return {
    top,
    right,
    bottom,
    left,
    width: right - left,
    height: bottom - top
  }
}

function opposite(placement: TourPlacement): TourPlacement {
  switch (placement) {
    case 'top':
      return 'bottom'
    case 'right':
      return 'left'
    case 'bottom':
      return 'top'
    case 'left':
      return 'right'
  }
}

function cardPosition(
  hole: TourAnchorRect,
  size: CardSize,
  preferred: TourPlacement,
  layout: TourLayout
): CardPosition {
  const space: Record<TourPlacement, number> = {
    top: hole.top - layout.viewportMargin,
    right: layout.width - hole.right - layout.viewportMargin,
    bottom: layout.height - hole.bottom - layout.viewportMargin,
    left: hole.left - layout.viewportMargin
  }
  const needed = (placement: TourPlacement): number =>
    placement === 'top' || placement === 'bottom'
      ? size.height + layout.cardGap
      : size.width + layout.cardGap
  const remaining = (['top', 'right', 'bottom', 'left'] as const).filter(
    (placement) => placement !== preferred && placement !== opposite(preferred)
  )
  const candidates = [preferred, opposite(preferred), ...remaining]
  const placement =
    candidates.find((candidate) => space[candidate] >= needed(candidate)) ??
    candidates.reduce((best, candidate) =>
      space[candidate] > space[best] ? candidate : best
    )

  let top = hole.bottom + layout.cardGap
  let left = hole.left + (hole.width - size.width) / 2
  if (placement === 'top') {
    top = hole.top - size.height - layout.cardGap
  }
  if (placement === 'right') {
    top = hole.top + (hole.height - size.height) / 2
    left = hole.right + layout.cardGap
  }
  if (placement === 'left') {
    top = hole.top + (hole.height - size.height) / 2
    left = hole.left - size.width - layout.cardGap
  }

  return {
    top: clamp(
      top,
      layout.viewportMargin,
      layout.height - size.height - layout.viewportMargin
    ),
    left: clamp(
      left,
      layout.viewportMargin,
      layout.width - size.width - layout.viewportMargin
    ),
    placement
  }
}

function dimStyles(hole: TourAnchorRect): readonly CSSProperties[] {
  return [
    { top: 0, right: 0, left: 0, height: hole.top },
    { top: hole.top, left: 0, width: hole.left, height: hole.height },
    {
      top: hole.top,
      left: hole.right,
      right: 0,
      height: hole.height
    },
    { top: hole.bottom, right: 0, bottom: 0, left: 0 }
  ]
}

function BusyCard({ status }: { status: 'starting' | 'cleaning' }): JSX.Element {
  const copy = onboardingCopy(useLocale())
  return (
    <div className="tour-overlay" role="presentation">
      <div className="tour-dim tour-dim--full" />
      <div className="tour-card tour-card--centered" role="status">
        <span className="tour-spinner" aria-hidden="true" />
        <p className="tour-busy-copy">
          {status === 'starting'
            ? copy.preparing
            : copy.cleaning}
        </p>
      </div>
    </div>
  )
}

function TourOffer(): JSX.Element {
  const start = useTourStore((state) => state.start)
  const later = useTourStore((state) => state.later)
  const titleId = useId()
  const copy = onboardingCopy(useLocale())

  return (
    <aside className="tour-offer" role="dialog" aria-labelledby={titleId}>
      <h2 id={titleId} className="tour-offer__title">
        {copy.offer}
      </h2>
      <p className="tour-offer__body">
        {copy.tourDescription}
      </p>
      <div className="tour-offer__actions">
        <button
          type="button"
          className="button button--secondary"
          onClick={() => void later()}
        >
          {copy.later}
        </button>
        <button
          type="button"
          className="button button--primary"
          onClick={() => void start()}
        >
          {copy.tour}
        </button>
      </div>
    </aside>
  )
}

function StepCard({
  step,
  stepIndex,
  anchorMissing,
  position,
  cardRef
}: {
  step: TourStep
  stepIndex: number
  anchorMissing: boolean
  position: CardPosition | null
  cardRef: RefObject<HTMLDivElement>
}): JSX.Element {
  const transitioning = useTourStore((state) => state.transitioning)
  const next = useTourStore((state) => state.next)
  const back = useTourStore((state) => state.back)
  const skip = useTourStore((state) => state.skip)
  const finish = useTourStore((state) => state.finish)
  const titleId = useId()
  const copy = onboardingCopy(useLocale())
  const isLast = stepIndex === TOUR_STEP_COUNT - 1
  const style: CSSProperties | undefined =
    position === null ? undefined : { top: position.top, left: position.left }

  useFocusTrap(cardRef, { active: true, onEscape: skip })

  return (
    <div
      ref={cardRef}
      className={`tour-card${position === null ? ' tour-card--centered' : ''}`}
      style={style}
      data-placement={position?.placement}
      role="dialog"
      aria-modal="true"
      aria-labelledby={titleId}
    >
      <div className="tour-card__progress" aria-label={copy.progress}>
        {TOUR_STEPS.map((tourStep, index) => (
          <span
            key={tourStep.id}
            className="tour-card__dot"
            data-active={index === stepIndex || undefined}
            data-done={index < stepIndex || undefined}
            aria-label={`${index + 1}${index === stepIndex ? `, ${copy.current}` : ''}`}
          />
        ))}
      </div>
      <p className="tour-eyebrow">
        {stepIndex + 1} / {TOUR_STEP_COUNT}
      </p>
      <h2 id={titleId} className="tour-card__title">
        {copy[step.titleKey]}
      </h2>
      <div className="tour-card__body"><p>{copy[step.bodyKey]}</p></div>
      {anchorMissing && (
        <p className="tour-card__anchor-status" role="status">
          {copy.missing}
        </p>
      )}
      <div className="tour-card__footer">
        <button type="button" className="tour-skip" onClick={skip}>
          {copy.skip}
        </button>
        <div className="tour-card__nav">
          <button
            type="button"
            className="button button--secondary"
            disabled={stepIndex === 0 || transitioning}
            onClick={back}
          >
            {copy.previous}
          </button>
          <button
            type="button"
            className="button button--primary"
            disabled={transitioning}
            onClick={isLast ? finish : next}
          >
            {transitioning ? copy.moving : isLast ? copy.finish : copy.next}
          </button>
        </div>
      </div>
    </div>
  )
}

function ActiveTourOverlay({
  status
}: {
  status: Exclude<TourStatus, 'idle' | 'acknowledging'>
}): JSX.Element {
  const stepIndex = useTourStore((state) => state.stepIndex)
  const step = TOUR_STEPS[stepIndex] ?? TOUR_STEPS[0]
  const cardRef = useRef<HTMLDivElement>(null)
  const [cardSize, setCardSize] = useState<CardSize>({ width: 352, height: 240 })
  const [layout, setLayout] = useState<TourLayout>(currentLayout)
  const anchorRect = useTourAnchor(step.target)
  const hole = useMemo(
    () => (anchorRect === null ? null : paddedRect(anchorRect, layout)),
    [anchorRect, layout]
  )
  const position = useMemo(
    () =>
      hole === null
        ? null
        : cardPosition(hole, cardSize, step.placement, layout),
    [cardSize, hole, layout, step.placement]
  )

  useEffect(() => acquirePointerPassthrough(), [])

  useEffect(() => {
    const updateLayout = (): void => setLayout(currentLayout())
    window.addEventListener('resize', updateLayout)
    return () => window.removeEventListener('resize', updateLayout)
  }, [])

  useEffect(() => {
    if (status !== 'running' || cardRef.current === null) return
    const card = cardRef.current
    const measure = (): void => {
      const rect = card.getBoundingClientRect()
      setCardSize((current) =>
        current.width === rect.width && current.height === rect.height
          ? current
          : { width: rect.width, height: rect.height }
      )
    }
    measure()
    if (typeof ResizeObserver === 'undefined') return
    const observer = new ResizeObserver(measure)
    observer.observe(card)
    return () => observer.disconnect()
  }, [status, stepIndex])

  if (status === 'offer') return <TourOffer />
  if (status === 'starting' || status === 'cleaning') {
    return <BusyCard status={status} />
  }

  const anchorMissing = step.target !== null && hole === null
  return (
    <div className="tour-overlay" role="presentation">
      {hole === null ? (
        <div className="tour-dim tour-dim--full" />
      ) : (
        <>
          {dimStyles(hole).map((style, index) => (
            <div
              key={index}
              className="tour-dim"
              style={style}
              aria-hidden="true"
            />
          ))}
          <div
            className="tour-hole"
            style={{
              top: hole.top,
              left: hole.left,
              width: hole.width,
              height: hole.height
            }}
            aria-hidden="true"
          />
        </>
      )}
      <StepCard key={step.id}
        step={step}
        stepIndex={stepIndex}
        anchorMissing={anchorMissing}
        position={position}
        cardRef={cardRef}
      />
    </div>
  )
}

export function TourOverlay(): JSX.Element | null {
  const [status, setStatus] = useState(
    () => useTourStore.getState().status
  )

  useEffect(
    () => useTourStore.subscribe((state) => setStatus(state.status)),
    []
  )

  if (status === 'idle' || status === 'acknowledging') return null
  return <ActiveTourOverlay status={status} />
}
