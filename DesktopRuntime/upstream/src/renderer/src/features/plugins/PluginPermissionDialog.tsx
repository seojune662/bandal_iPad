import { useRef } from 'react'
import { useFocusTrap } from '../../components/useFocusTrap'
import type { PluginSummary } from '../../../../shared/types/plugin'
import { describePermission } from '../../../../shared/plugins/permissions'
import { useLocale, useT } from '../../i18n'
import './plugins.css'

export interface PluginPermissionDialogProps {
  plugin: PluginSummary
  pending?: boolean
  notice?: string | undefined
  approveLabel?: string | undefined
  onApprove: () => void
  onCancel: () => void
}

export function PluginPermissionDialog({
  plugin,
  pending = false,
  notice,
  approveLabel,
  onApprove,
  onCancel
}: PluginPermissionDialogProps): JSX.Element {
  const dialogRef = useRef<HTMLElement>(null)
  useFocusTrap(dialogRef, { active: true, onEscape: pending ? undefined : onCancel })
  const locale = useLocale()
  const t = useT()

  return (
    <div
      className="plugin-permission-modal"
      role="presentation"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget && !pending) onCancel()
      }}
    >
      <section
        ref={dialogRef}
        className="plugin-permission-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="plugin-permission-title"
      >
        <header className="plugin-permission-dialog__header">
          <span className="plugin-permission-dialog__trust-mark" aria-hidden="true" />
          <div>
            <p>{t('settings.plugins.permission.eyebrow')}</p>
            <h2 id="plugin-permission-title">
              {t('settings.plugins.permission.title', {
                name: plugin.manifest.name
              })}
            </h2>
          </div>
        </header>
        <p className="plugin-permission-dialog__description">
          {t('settings.plugins.permission.description')}
        </p>
        {notice && <p className="plugin-permission-dialog__description">{notice}</p>}
        {plugin.manifest.permissions.length === 0 ? (
          <p className="plugin-permission-dialog__empty">
            {t('settings.plugins.permission.none')}
          </p>
        ) : (
          <ul className="plugin-permission-dialog__list">
            {plugin.manifest.permissions.map((permission) => (
              <li key={permission}>
                <code>{permission}</code>
                <span>{describePermission(permission, locale)}</span>
              </li>
            ))}
          </ul>
        )}
        <footer className="plugin-permission-dialog__actions">
          <button type="button" disabled={pending} onClick={onCancel}>
            {t('settings.plugins.action.cancel')}
          </button>
          <button
            type="button"
            className="plugin-permission-dialog__approve"
            disabled={pending}
            onClick={onApprove}
          >
            {(!pending && approveLabel) || t(
              pending
                ? 'settings.plugins.permission.approving'
                : 'settings.plugins.permission.approve'
            )}
          </button>
        </footer>
      </section>
    </div>
  )
}
