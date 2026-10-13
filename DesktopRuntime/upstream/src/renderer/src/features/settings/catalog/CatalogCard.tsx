import type { CatalogEntry } from '../../../../../shared/types/pluginCatalog'
import { useState } from 'react'
import { useLocale, useT } from '../../../i18n'
import { Icon } from '../SettingsIcon'
import { installState } from './catalogModel'
import { MarketplaceReleaseDetails } from './MarketplaceReleaseDetails'

function initials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean)
  if (words.length > 1) return `${words[0]?.[0] ?? ''}${words[1]?.[0] ?? ''}`.toLocaleUpperCase()
  return (words[0] ?? '?').slice(0, 2).toLocaleUpperCase()
}

export function CatalogCard({
  entry,
  installedVersion,
  installing,
  error,
  runtimeEnabled,
  onInstall,
  onOpenExperimental
}: {
  entry: CatalogEntry
  installedVersion: string | null
  installing: boolean
  error: string | null
  runtimeEnabled: boolean
  onInstall: () => void
  onOpenExperimental: () => void
}): JSX.Element {
  const t = useT()
  const ko = useLocale() === 'ko-KR'
  const [detailsOpen, setDetailsOpen] = useState(false)
  const state = installState(entry, installedVersion)
  const runtimeBlocked = entry.kind === 'extension' && !runtimeEnabled

  return (
    <article className="settings-catalog-card">
      {runtimeBlocked && (
        <button
          type="button"
          className="secondary-button settings-catalog-card__runtime-badge"
          onClick={onOpenExperimental}
        >
          {t('settings.catalog.card.enableInExperimental')}
        </button>
      )}
      <div className="settings-catalog-card__heading">
        <span className="settings-catalog-card__avatar" aria-hidden="true">
          {initials(entry.name)}
        </span>
        <div className="settings-catalog-card__identity">
          <div className="settings-catalog-card__title">
            <h3>{entry.name}</h3>
            {entry.verified && (
              <span
                className="settings-catalog-card__verified"
                title={t('settings.catalog.card.official')}
              >
                <Icon name="check" />
              </span>
            )}
          </div>
          <span className="settings-catalog-card__publisher">{entry.publisher}</span>
        </div>
      </div>

      <p className="settings-catalog-card__description">{entry.description}</p>
      {entry.marketplaceReleaseId && <details onToggle={(event) => setDetailsOpen(event.currentTarget.open)}>
        <summary>{ko ? '심사 완료 · 버전 정보' : 'Reviewed · Release details'}</summary>
        {detailsOpen && <MarketplaceReleaseDetails id={entry.marketplaceReleaseId} />}
      </details>}

      <div className="settings-catalog-card__footer">
        <div className="settings-catalog-card__tags" aria-label={t('settings.catalog.card.tags')}>
          {entry.tags.map((tag) => (
            <span key={tag}>{tag}</span>
          ))}
        </div>
        {state === 'installed' ? (
          <span className="settings-catalog-card__installed">
            <Icon name="check" />
            {t('settings.catalog.card.installed')}
          </span>
        ) : (
          <button
            type="button"
            className="secondary-button settings-catalog-card__action"
            disabled={installing || runtimeBlocked}
            onClick={onInstall}
          >
            {installing && <span className="settings-catalog-spinner" aria-hidden="true" />}
            {t(
              installing
                ? 'settings.catalog.card.installing'
                : state === 'update'
                  ? 'settings.catalog.card.update'
                  : 'settings.catalog.card.install'
            )}
          </button>
        )}
      </div>
      {error !== null && (
        <p className="settings-catalog-card__error" role="alert">{error}</p>
      )}
    </article>
  )
}
