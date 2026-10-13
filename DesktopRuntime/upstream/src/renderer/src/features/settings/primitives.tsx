/**
 * Shared settings-surface primitives. SettingsPanels.tsx grew private copies
 * of these; new panels (v0.37) import from here instead so the card and the
 * toggle row look the same everywhere.
 */
import type { ReactNode } from 'react'

export function SettingsCard({
  title,
  description,
  children,
  className = ''
}: {
  title?: string
  description?: string
  children: ReactNode
  className?: string
}): JSX.Element {
  return (
    <section className={`settings-card ${className}`.trim()}>
      {(title !== undefined || description !== undefined) && (
        <div className="settings-card__header">
          {title !== undefined && <h2>{title}</h2>}
          {description !== undefined && <p>{description}</p>}
        </div>
      )}
      {children}
    </section>
  )
}

export function ToggleRow({
  label,
  description,
  checked,
  disabled = false,
  onChange,
  badge
}: {
  label: string
  description: string
  checked: boolean
  disabled?: boolean
  onChange?: (next: boolean) => void
  badge?: string
}): JSX.Element {
  return (
    <div className={`setting-row${disabled ? ' setting-row--disabled' : ''}`}>
      <div className="setting-row__copy">
        <div className="setting-row__label-line">
          <span className="setting-row__label">{label}</span>
          {badge !== undefined && <span className="badge">{badge}</span>}
        </div>
        <span className="setting-row__description">{description}</span>
      </div>
      <button
        type="button"
        role="switch"
        aria-label={label}
        aria-checked={checked}
        disabled={disabled}
        className={`toggle${checked ? ' toggle--checked' : ''}`}
        onClick={() => onChange?.(!checked)}
      >
        <span className="toggle__thumb" />
      </button>
    </div>
  )
}
