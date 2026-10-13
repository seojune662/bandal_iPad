/**
 * [M8] 학교 바로가기 — the compact section at the top of the left rail.
 *
 * The resolved service list already contains the persisted order and tier
 * overrides. This surface only splits it for display and hands user gestures
 * back to the university store's layout mutators.
 */

import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent,
  type MouseEvent,
  type RefObject,
  type SVGProps
} from 'react'
import {
  moveServiceBefore,
  moveServiceToEnd,
  serviceTierIds,
  type ResolvedService
} from '../../../../shared/universities'
import { Icon } from '../../app/icons'
import { useT } from '../../i18n'
import { useUiStore } from '../../stores/uiStore'
import { useUniversityStore } from '../../stores/universityStore'
import { openShortcut } from './openService'
import { externalReasonMessage } from './serviceCopy'
import {
  persistUniversitySectionCollapsed,
  persistUniversitySectionShowAll,
  readUniversitySectionCollapsed,
  readUniversitySectionShowAll
} from './universityCollapse'
import { ExternalIcon, ServiceKindIcon } from './universityIcons'
import './university.css'

export const UNIVERSITY_SERVICE_MIME =
  'application/x-bandal-university-service-id'

type ServiceTier = 'primary' | 'secondary'

type DropTarget =
  | { kind: 'before'; serviceId: string }
  | { kind: 'end'; tier: ServiceTier }

interface ContextMenuState {
  service: ResolvedService
  x: number
  y: number
  placement: 'top' | 'bottom'
}

interface ShortcutRowProps {
  service: ResolvedService
  dragging: boolean
  dropBefore: boolean
  onContextMenu: (event: MouseEvent<HTMLButtonElement>) => void
  onDragEnd: () => void
  onDragLeave: (event: DragEvent<HTMLButtonElement>) => void
  onDragOver: (event: DragEvent<HTMLButtonElement>) => void
  onDragStart: (event: DragEvent<HTMLButtonElement>) => void
  onDrop: (event: DragEvent<HTMLButtonElement>) => void
  onMove: (delta: -1 | 1) => void
}

interface TierDropZoneProps {
  active: boolean
  compact: boolean
  label: string
  over: boolean
  onDragLeave: (event: DragEvent<HTMLDivElement>) => void
  onDragOver: (event: DragEvent<HTMLDivElement>) => void
  onDrop: (event: DragEvent<HTMLDivElement>) => void
}

function DragHandleIcon(props: SVGProps<SVGSVGElement>): JSX.Element {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" {...props}>
      <g fill="currentColor">
        <circle cx="8" cy="7" r="1.5" />
        <circle cx="16" cy="7" r="1.5" />
        <circle cx="8" cy="12" r="1.5" />
        <circle cx="16" cy="12" r="1.5" />
        <circle cx="8" cy="17" r="1.5" />
        <circle cx="16" cy="17" r="1.5" />
      </g>
    </svg>
  )
}

/** Closes the row menu on outside pointerdown, Escape or window blur. */
function useDismissableMenu(
  active: boolean,
  ref: RefObject<HTMLElement>,
  dismiss: () => void
): void {
  useEffect(() => {
    if (!active) return
    const frame = window.requestAnimationFrame(() => {
      ref.current?.querySelector<HTMLElement>('button')?.focus()
    })
    const closeOnPointerDown = (event: PointerEvent): void => {
      if (!ref.current?.contains(event.target as Node)) dismiss()
    }
    const closeOnEscape = (event: globalThis.KeyboardEvent): void => {
      if (event.key === 'Escape') dismiss()
    }
    window.addEventListener('pointerdown', closeOnPointerDown)
    window.addEventListener('keydown', closeOnEscape)
    window.addEventListener('blur', dismiss)
    return () => {
      window.cancelAnimationFrame(frame)
      window.removeEventListener('pointerdown', closeOnPointerDown)
      window.removeEventListener('keydown', closeOnEscape)
      window.removeEventListener('blur', dismiss)
    }
  }, [active, dismiss, ref])
}

function ShortcutRow({
  service,
  dragging,
  dropBefore,
  onContextMenu,
  onDragEnd,
  onDragLeave,
  onDragOver,
  onDragStart,
  onDrop,
  onMove
}: ShortcutRowProps): JSX.Element {
  const title = service.opensExternally
    ? `${service.label} — ${externalReasonMessage(service.externalReason)}`
    : (service.note ?? service.label)

  const handleKeyDown = (event: KeyboardEvent<HTMLButtonElement>): void => {
    if (
      !event.altKey ||
      (event.key !== 'ArrowUp' && event.key !== 'ArrowDown')
    ) {
      return
    }
    event.preventDefault()
    event.stopPropagation()
    onMove(event.key === 'ArrowUp' ? -1 : 1)
  }

  return (
    <li>
      <button
        type="button"
        className="university-shortcut"
        data-dragging={dragging || undefined}
        data-drop-before={dropBefore || undefined}
        data-external={service.opensExternally || undefined}
        draggable
        title={title}
        onClick={() =>
          openShortcut({
            url: service.url,
            opensExternally: service.opensExternally
          })
        }
        onContextMenu={onContextMenu}
        onDragEnd={onDragEnd}
        onDragLeave={onDragLeave}
        onDragOver={onDragOver}
        onDragStart={onDragStart}
        onDrop={onDrop}
        onKeyDown={handleKeyDown}
      >
        <DragHandleIcon className="university-shortcut__handle" />
        <ServiceKindIcon kind={service.kind} className="university-shortcut__icon" />
        <span className="university-shortcut__label">{service.label}</span>
        {service.opensExternally && (
          <ExternalIcon className="university-shortcut__external" />
        )}
      </button>
    </li>
  )
}

function TierDropZone({
  active,
  compact,
  label,
  over,
  onDragLeave,
  onDragOver,
  onDrop
}: TierDropZoneProps): JSX.Element {
  return (
    <div
      className="university-tier-drop-zone"
      aria-label={label}
      data-compact={compact || undefined}
      data-drag-active={active || undefined}
      data-drop-tier={over || undefined}
      onDragLeave={onDragLeave}
      onDragOver={onDragOver}
      onDrop={onDrop}
    >
      <span>{label}</span>
    </div>
  )
}

export function UniversityShortcuts(): JSX.Element | null {
  const t = useT()
  const loaded = useUniversityStore((state) => state.loaded)
  const university = useUniversityStore((state) => state.university)
  const services = useUniversityStore((state) => state.services)
  const reorderServices = useUniversityStore((state) => state.reorderServices)
  const moveService = useUniversityStore((state) => state.moveService)
  const setServiceSecondary = useUniversityStore(
    (state) => state.setServiceSecondary
  )
  const setServiceHidden = useUniversityStore((state) => state.setServiceHidden)
  const resetServiceLayout = useUniversityStore(
    (state) => state.resetServiceLayout
  )
  const openSettings = useUiStore((state) => state.openSettings)
  const [collapsed, setCollapsed] = useState(readUniversitySectionCollapsed)
  const [showAll, setShowAll] = useState(readUniversitySectionShowAll)
  const [draggingServiceId, setDraggingServiceId] = useState<string | null>(null)
  const [dropTarget, setDropTarget] = useState<DropTarget | null>(null)
  const [contextMenu, setContextMenu] = useState<ContextMenuState | null>(null)
  const contextMenuRef = useRef<HTMLDivElement>(null)

  const { primary, secondary, primaryIds, secondaryIds, visibleIds } =
    useMemo(() => {
      const primaryServices = services.filter((service) => !service.secondary)
      const secondaryServices = services.filter((service) => service.secondary)
      const tierIds = serviceTierIds(services)
      return {
        primary: primaryServices,
        secondary: secondaryServices,
        primaryIds: tierIds.primary,
        secondaryIds: tierIds.secondary,
        visibleIds: [...tierIds.primary, ...tierIds.secondary]
      }
    }, [services])

  const closeContextMenu = useCallback(() => setContextMenu(null), [])
  useDismissableMenu(contextMenu !== null, contextMenuRef, closeContextMenu)

  if (!loaded) return null

  if (university === null) {
    return (
      <section className="university-section" aria-label="학교 바로가기">
        <button
          type="button"
          className="university-section__pick"
          onClick={() => openSettings("university")}
        >
          학교 고르기
        </button>
      </section>
    )
  }

  const toggleCollapsed = (): void => {
    setCollapsed((current) => {
      const next = !current
      persistUniversitySectionCollapsed(next)
      return next
    })
  }

  const toggleShowAll = (): void => {
    setShowAll((current) => {
      const next = !current
      persistUniversitySectionShowAll(next)
      return next
    })
  }

  const acceptsServiceDrag = (event: DragEvent<HTMLElement>): boolean =>
    [...event.dataTransfer.types].includes(UNIVERSITY_SERVICE_MIME)

  const finishDrag = (): void => {
    setDraggingServiceId(null)
    setDropTarget(null)
  }

  const sourceIdFromDrop = (event: DragEvent<HTMLElement>): string | null => {
    if (!acceptsServiceDrag(event)) return null
    const sourceId = event.dataTransfer.getData(UNIVERSITY_SERVICE_MIME)
    return sourceId.length > 0 && visibleIds.includes(sourceId) ? sourceId : null
  }

  const moveBefore = async (
    sourceId: string,
    target: ResolvedService
  ): Promise<void> => {
    const source = services.find((service) => service.id === sourceId)
    if (source === undefined || source.id === target.id) return
    await reorderServices(moveServiceBefore(visibleIds, source.id, target.id))
    if (source.secondary !== target.secondary) {
      await setServiceSecondary(source.id, target.secondary)
    }
  }

  const moveToTierEnd = async (
    sourceId: string,
    tier: ServiceTier
  ): Promise<void> => {
    const source = services.find((service) => service.id === sourceId)
    if (source === undefined) return
    const nextPrimary = primaryIds.filter((id) => id !== sourceId)
    const nextSecondary = secondaryIds.filter((id) => id !== sourceId)
    const nextIds =
      tier === 'primary'
        ? [
            ...moveServiceToEnd([...nextPrimary, sourceId], sourceId),
            ...nextSecondary
          ]
        : [
            ...nextPrimary,
            ...moveServiceToEnd([...nextSecondary, sourceId], sourceId)
          ]
    await reorderServices(nextIds)
    const secondaryTier = tier === 'secondary'
    if (source.secondary !== secondaryTier) {
      await setServiceSecondary(source.id, secondaryTier)
    }
  }

  const renderRow = (service: ResolvedService): JSX.Element => (
    <ShortcutRow
      key={service.id}
      service={service}
      dragging={draggingServiceId === service.id}
      dropBefore={
        dropTarget?.kind === 'before' && dropTarget.serviceId === service.id
      }
      onContextMenu={(event) => {
        event.preventDefault()
        setContextMenu({
          service,
          x: event.clientX,
          y: event.clientY,
          placement: event.clientY > window.innerHeight / 2 ? 'top' : 'bottom'
        })
      }}
      onDragStart={(event) => {
        event.dataTransfer.effectAllowed = 'move'
        event.dataTransfer.setData(UNIVERSITY_SERVICE_MIME, service.id)
        setContextMenu(null)
        setDraggingServiceId(service.id)
        setDropTarget(null)
      }}
      onDragEnd={finishDrag}
      onDragOver={(event) => {
        if (
          !acceptsServiceDrag(event) ||
          draggingServiceId === service.id
        ) {
          return
        }
        event.preventDefault()
        event.stopPropagation()
        event.dataTransfer.dropEffect = 'move'
        setDropTarget({ kind: 'before', serviceId: service.id })
      }}
      onDragLeave={(event) => {
        if (
          event.relatedTarget instanceof Node &&
          event.currentTarget.contains(event.relatedTarget)
        ) {
          return
        }
        setDropTarget((target) =>
          target?.kind === 'before' && target.serviceId === service.id
            ? null
            : target
        )
      }}
      onDrop={(event) => {
        const sourceId = sourceIdFromDrop(event)
        if (sourceId === null || sourceId === service.id) return
        event.preventDefault()
        event.stopPropagation()
        finishDrag()
        void moveBefore(sourceId, service)
      }}
      onMove={(delta) => void moveService(service.id, delta)}
    />
  )

  const renderDropZone = (
    tier: ServiceTier,
    label: string,
    compact = false
  ): JSX.Element => (
    <TierDropZone
      active={draggingServiceId !== null}
      compact={compact}
      label={label}
      over={dropTarget?.kind === 'end' && dropTarget.tier === tier}
      onDragOver={(event) => {
        if (!acceptsServiceDrag(event)) return
        event.preventDefault()
        event.stopPropagation()
        event.dataTransfer.dropEffect = 'move'
        setDropTarget({ kind: 'end', tier })
      }}
      onDragLeave={(event) => {
        if (
          event.relatedTarget instanceof Node &&
          event.currentTarget.contains(event.relatedTarget)
        ) {
          return
        }
        setDropTarget((target) =>
          target?.kind === 'end' && target.tier === tier ? null : target
        )
      }}
      onDrop={(event) => {
        const sourceId = sourceIdFromDrop(event)
        if (sourceId === null) return
        event.preventDefault()
        event.stopPropagation()
        finishDrag()
        void moveToTierEnd(sourceId, tier)
      }}
    />
  )

  const secondaryExpanded = showAll && secondary.length > 0

  return (
    <section className="university-section" aria-label="학교 바로가기">
      <button
        type="button"
        className="university-section__heading"
        aria-label={`${university.nameKo} 바로가기 ${collapsed ? '펼치기' : '접기'}`}
        aria-expanded={!collapsed}
        onClick={toggleCollapsed}
      >
        <Icon name="chevronRight" className="university-section__chevron" />
        <span className="university-section__name">{university.nameKo}</span>
      </button>

      {!collapsed && (
        <>
          {primary.length === 0 && secondary.length === 0 ? (
            <ServiceKindIcon
              kind="homepage"
              className="university-section__empty-icon"
            />
          ) : (
            <ul className="university-shortcuts" data-tier="primary">
              {primary.map(renderRow)}
            </ul>
          )}

          {renderDropZone('primary', t('university.drop.primaryEnd'))}

          {secondaryExpanded && (
            <>
              <ul className="university-shortcuts" data-tier="secondary">
                {secondary.map(renderRow)}
              </ul>
              {renderDropZone(
                'secondary',
                t('university.drop.secondaryEnd')
              )}
            </>
          )}

          {!secondaryExpanded &&
            renderDropZone(
              'secondary',
              t('university.drop.sendToMore'),
              true
            )}

          {secondary.length > 0 && (
            <button
              type="button"
              className="university-section__more"
              aria-expanded={showAll}
              onClick={toggleShowAll}
            >
              {showAll ? '접기' : `더보기 ${secondary.length}`}
            </button>
          )}
        </>
      )}

      {contextMenu !== null && (
        <div
          ref={contextMenuRef}
          className="context-menu university-shortcut-menu"
          role="menu"
          aria-label={t('university.contextMenuLabel', {
            name: contextMenu.service.label
          })}
          data-placement={contextMenu.placement}
          style={{ left: contextMenu.x, top: contextMenu.y }}
        >
          <p className="context-menu__label">{contextMenu.service.label}</p>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              void moveService(contextMenu.service.id, -1)
              setContextMenu(null)
            }}
          >
            <Icon
              name="chevronRight"
              className="university-shortcut-menu__icon--up"
            />
            {t('university.moveUp')}
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              void moveService(contextMenu.service.id, 1)
              setContextMenu(null)
            }}
          >
            <Icon
              name="chevronRight"
              className="university-shortcut-menu__icon--down"
            />
            {t('university.moveDown')}
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              void setServiceSecondary(
                contextMenu.service.id,
                !contextMenu.service.secondary
              )
              setContextMenu(null)
            }}
          >
            <Icon
              name={
                contextMenu.service.secondary
                  ? 'chevronLeft'
                  : 'chevronRight'
              }
            />
            {contextMenu.service.secondary
              ? t('university.alwaysShow')
              : t('university.sendToMore')}
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              void setServiceHidden(contextMenu.service.id, true)
              setContextMenu(null)
            }}
          >
            <Icon name="trash" />
            {t('university.hide')}
          </button>
          <span className="context-menu__separator" role="separator" />
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              void resetServiceLayout()
              setContextMenu(null)
            }}
          >
            <Icon name="refresh" />
            {t('university.resetLayout')}
          </button>
        </div>
      )}
    </section>
  )
}
