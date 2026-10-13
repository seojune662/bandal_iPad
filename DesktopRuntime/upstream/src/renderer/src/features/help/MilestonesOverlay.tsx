import { useEffect, useRef } from 'react'
import { useFocusTrap } from '../../components/useFocusTrap'
import { useT } from '../../i18n'
import { Icon } from '../../app/icons'
import { ProgressRing } from './ProgressRing'
import {
  useMilestones,
  type MilestoneId
} from './milestonesStore'

interface MilestonesOverlayProps {
  open: boolean
  selectedCourseId: string | null
  onClose: () => void
  onTry: (id: MilestoneId) => void
}

export function MilestonesOverlay({
  open,
  selectedCourseId,
  onClose,
  onTry
}: MilestonesOverlayProps): JSX.Element | null {
  const t = useT()
  const dialogRef = useRef<HTMLElement>(null)
  const items = useMilestones((state) => state.items)
  const progress = useMilestones((state) => state.progress)
  const loading = useMilestones((state) => state.loading)
  const error = useMilestones((state) => state.error)
  const refresh = useMilestones((state) => state.refresh)

  useFocusTrap(dialogRef, { active: open, onEscape: onClose })

  useEffect(() => {
    if (open) void refresh(selectedCourseId)
  }, [open, refresh, selectedCourseId])

  if (!open) return null
  const completed = items.filter((item) => item.completed).length

  return (
    <div
      className="settings-overlay help-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <section
        ref={dialogRef}
        className="help-panel help-milestones"
        role="dialog"
        aria-modal="true"
        aria-labelledby="help-milestones-title"
      >
        <header className="help-panel__header">
          <div>
            <p className="help-panel__eyebrow">MILESTONES</p>
            <h2 id="help-milestones-title">{t('help.milestones.title')}</h2>
          </div>
          <button
            type="button"
            className="help-panel__close"
            aria-label={t('help.close')}
            onClick={onClose}
          >
            <Icon name="x" />
          </button>
        </header>

        <div className="help-milestones__summary">
          <ProgressRing
            progress={progress}
            label={t('help.milestones.progress')}
          />
          <strong>
            {t('help.milestones.count', {
              completed,
              total: items.length
            })}
          </strong>
        </div>

        {error !== null && (
          <div className="help-panel__error" role="alert">
            <span>{t(error)}</span>
            <button type="button" onClick={() => void refresh(selectedCourseId)}>
              {t('help.retry')}
            </button>
          </div>
        )}

        <ul className="help-milestone-list" aria-busy={loading}>
          {items.map((item) => (
            <li key={item.id} data-completed={item.completed || undefined}>
              <span className="help-milestone-list__status" aria-hidden="true">
                {item.completed ? '✓' : '○'}
              </span>
              <span className="help-milestone-list__label">
                {t(`help.milestones.item.${item.id}`)}
              </span>
              {!item.completed && (
                <button
                  type="button"
                  className="help-milestone-list__try"
                  onClick={() => onTry(item.id)}
                >
                  {t('help.milestones.try')}
                </button>
              )}
            </li>
          ))}
        </ul>
      </section>
    </div>
  )
}
