import { useEffect, useState } from 'react'
import type {
  ExternalReason,
  ServiceKind,
  University,
  UniversityService,
  VerificationLevel
} from '../../../../shared/types/university'
import { useLocale, useT } from '../../i18n'
import { useUniversityStore } from '../../stores/universityStore'
import { SettingsUniversityPicker } from './SettingsUniversityPicker'
import { SavedLoginsSettings } from './SavedLoginsSettings'
import '../university/university.css'

type Translator = ReturnType<typeof useT>
type CurrentLocale = ReturnType<typeof useLocale>

function universityName(university: University, locale: CurrentLocale): string {
  return locale === 'en-US' && university.nameEn.length > 0
    ? university.nameEn
    : university.nameKo
}

function serviceName(service: UniversityService, locale: CurrentLocale): string {
  return locale === 'en-US' && service.labelEn !== undefined
    ? service.labelEn
    : service.label
}

function verifiedAtLabel(t: Translator, verifiedAt: string): string {
  return verifiedAt.length === 0
    ? t('settings.university.noVerifiedAt')
    : t('settings.university.verifiedAt', { date: verifiedAt })
}

function verificationBadge(t: Translator, level: VerificationLevel): string | null {
  switch (level) {
    case 'verified':
      return null
    case 'partial':
      return t('settings.university.verification.partial')
    case 'unverified':
      return t('settings.university.verification.unverified')
  }
}

function serviceKindLabel(t: Translator, kind: ServiceKind): string {
  return t(`settings.university.kind.${kind}`)
}

function externalReasonMessage(
  t: Translator,
  reason: ExternalReason | undefined
): string {
  switch (reason) {
    case 'federated-login':
      return t('settings.university.external.federated-login')
    case 'ua-sniffing':
      return t('settings.university.external.ua-sniffing')
    case 'native-plugin':
      return t('settings.university.external.native-plugin')
    default:
      return t('settings.university.external.default')
  }
}

export function UniversitySettingsPanel(): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const loaded = useUniversityStore((state) => state.loaded)
  const settings = useUniversityStore((state) => state.settings)
  const university = useUniversityStore((state) => state.university)
  const services = useUniversityStore((state) => state.services)
  const error = useUniversityStore((state) => state.error)
  const init = useUniversityStore((state) => state.init)
  const selectPreset = useUniversityStore((state) => state.selectPreset)
  const addCustom = useUniversityStore((state) => state.addCustom)
  const clearSelection = useUniversityStore((state) => state.clearSelection)
  const setServiceHidden = useUniversityStore((state) => state.setServiceHidden)
  const setOpenExternally = useUniversityStore((state) => state.setOpenExternally)
  const moveService = useUniversityStore((state) => state.moveService)
  const setServiceSecondary = useUniversityStore(
    (state) => state.setServiceSecondary
  )
  const resetServiceLayout = useUniversityStore(
    (state) => state.resetServiceLayout
  )
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    void init()
  }, [init])

  const run = async (work: () => Promise<void>): Promise<boolean> => {
    setBusy(true)
    try {
      await work()
      return useUniversityStore.getState().error === null
    } finally { setBusy(false) }
  }

  const hiddenIds = settings.hiddenServiceIds
  const hiddenPresets = (university?.services ?? []).filter((service) =>
    hiddenIds.includes(service.id)
  )
  const serviceGroups = [
    {
      id: 'primary',
      label: t('settings.university.group.primary'),
      services: services.filter((service) => !service.secondary)
    },
    {
      id: 'secondary',
      label: t('settings.university.group.secondary'),
      services: services.filter((service) => service.secondary)
    }
  ] as const

  return (
    <div className="settings-stack">
      <section className="settings-card">
        <div className="settings-card__header">
          <h2>{t('settings.university.mine.title')}</h2>
          <p>
            {university === null
              ? t('settings.university.mine.emptyHelp')
              : t('settings.university.mine.selected', {
                  name: universityName(university, locale),
                  verifiedAt: verifiedAtLabel(t, university.verifiedAt)
                })}
          </p>
        </div>
        <div className="settings-card__body">
          {!loaded ? (
            <p className="settings-feedback settings-feedback--inline">
              {t('settings.university.loading')}
            </p>
          ) : (
            <SettingsUniversityPicker
              selectedId={settings.universityId}
              customName={settings.customUniversity?.nameKo}
              busy={busy}
              onSelectPreset={(id) => run(() => selectPreset(id))}
              onAddCustom={(input) => run(() => addCustom(input))}
            />
          )}
          <p
            className={`settings-feedback settings-feedback--inline${error !== null ? ' settings-feedback--error' : ''}`}
            aria-live="polite"
          >
            {error !== null
              ? t('settings.university.saveError')
              : t('settings.university.catalogHelp')}
          </p>
        </div>
        {university !== null && (
          <div className="settings-card__footer-row settings-card__footer-row--compact">
            <button
              type="button"
              className="secondary-button"
              disabled={busy}
              onClick={() => run(() => clearSelection())}
            >
              {t('settings.university.clear')}
            </button>
          </div>
        )}
      </section>

      {university !== null && (
        <section className="settings-card">
          <div className="settings-card__header">
            <h2>{t('settings.university.shortcuts.title')}</h2>
            <p>{t('settings.university.shortcuts.description')}</p>
          </div>

          <div className="university-service-table">
            {serviceGroups.map((group) => (
              <section
                className="university-service-group"
                aria-labelledby={`university-service-group-${group.id}`}
                key={group.id}
              >
                <h3
                  className="university-service-group__heading"
                  id={`university-service-group-${group.id}`}
                >
                  <span>{group.label}</span>
                  <span className="count-badge">
                    {new Intl.NumberFormat(locale).format(group.services.length)}
                  </span>
                </h3>

                {group.services.map((service, index) => {
                  const badge = verificationBadge(t, service.verification)
                  const label = serviceName(service, locale)
                  const moveUpLabel = t('settings.university.moveUp', {
                    name: label
                  })
                  const moveDownLabel = t('settings.university.moveDown', {
                    name: label
                  })
                  return (
                    <div className="setting-row" key={service.id}>
                      <div className="setting-row__copy">
                        <div className="setting-row__label-line">
                          <span className="setting-row__label">{label}</span>
                          <span className="badge">
                            {serviceKindLabel(t, service.kind)}
                          </span>
                          {badge !== null && (
                            <span className="badge">{badge}</span>
                          )}
                        </div>
                        <span className="setting-row__description">
                          {service.opensExternally
                            ? externalReasonMessage(t, service.externalReason)
                            : locale === 'ko-KR'
                              ? (service.note ?? service.url)
                              : service.url}
                        </span>
                      </div>
                      <div className="university-service-table__actions">
                        <div
                          className="university-service-table__move"
                          role="group"
                          aria-label={t('settings.university.reorder', {
                            name: label
                          })}
                        >
                          <button
                            type="button"
                            className="secondary-button university-service-table__move-button"
                            aria-label={moveUpLabel}
                            title={moveUpLabel}
                            disabled={busy || index === 0}
                            onClick={() =>
                              run(() => moveService(service.id, -1))
                            }
                          >
                            ↑
                          </button>
                          <button
                            type="button"
                            className="secondary-button university-service-table__move-button"
                            aria-label={moveDownLabel}
                            title={moveDownLabel}
                            disabled={
                              busy || index === group.services.length - 1
                            }
                            onClick={() =>
                              run(() => moveService(service.id, 1))
                            }
                          >
                            ↓
                          </button>
                        </div>
                        <div className="university-service-table__toggle-control">
                          <span>
                            {t('settings.university.openExternalLabel')}
                          </span>
                          <button
                            type="button"
                            role="switch"
                            aria-checked={service.opensExternally}
                            aria-label={t(
                              'settings.university.openExternal',
                              { name: label }
                            )}
                            className={`toggle${service.opensExternally ? ' toggle--checked' : ''}`}
                            disabled={busy}
                            onClick={() =>
                              run(() =>
                                setOpenExternally(
                                  service.id,
                                  !service.opensExternally
                                )
                              )
                            }
                          >
                            <span className="toggle__thumb" />
                          </button>
                        </div>
                        <div className="university-service-table__toggle-control">
                          <span>{t('settings.university.moreLabel')}</span>
                          <button
                            type="button"
                            role="switch"
                            aria-checked={service.secondary}
                            aria-label={t(
                              'settings.university.secondaryToggle',
                              { name: label }
                            )}
                            className={`toggle${service.secondary ? ' toggle--checked' : ''}`}
                            disabled={busy}
                            onClick={() =>
                              run(() =>
                                setServiceSecondary(
                                  service.id,
                                  !service.secondary
                                )
                              )
                            }
                          >
                            <span className="toggle__thumb" />
                          </button>
                        </div>
                        <button
                          type="button"
                          className="secondary-button"
                          disabled={busy}
                          onClick={() =>
                            run(() => setServiceHidden(service.id, true))
                          }
                        >
                          {t('settings.university.hide')}
                        </button>
                      </div>
                    </div>
                  )
                })}
              </section>
            ))}
          </div>

          {hiddenPresets.length > 0 && (
            <div className="settings-card__footer-row">
              <div className="setting-row">
                <div className="setting-row__copy">
                  <div className="setting-row__label-line">
                    <span className="setting-row__label">
                      {t('settings.university.hidden')}
                    </span>
                    <span className="count-badge">
                      {new Intl.NumberFormat(locale).format(hiddenPresets.length)}
                    </span>
                  </div>
                  <span className="setting-row__description">
                    {hiddenPresets
                      .map((service) => serviceName(service, locale))
                      .join(', ')}
                  </span>
                </div>
                <button
                  type="button"
                  className="secondary-button"
                  disabled={busy}
                  onClick={() =>
                    run(async () => {
                      for (const service of hiddenPresets) {
                        await setServiceHidden(service.id, false)
                      }
                    })
                  }
                >
                  {t('settings.university.restoreAll')}
                </button>
              </div>
            </div>
          )}

          <div className="settings-card__footer-row">
            <div className="setting-row">
              <div className="setting-row__copy">
                <span className="setting-row__label">
                  {t('settings.university.resetLayout')}
                </span>
                <span className="setting-row__description">
                  {t('settings.university.resetLayoutHelp')}
                </span>
              </div>
              <button
                type="button"
                className="secondary-button"
                disabled={busy}
                onClick={() => run(() => resetServiceLayout())}
              >
                {t('settings.university.resetLayout')}
              </button>
            </div>
          </div>
        </section>
      )}

      <SavedLoginsSettings />
    </div>
  )
}
