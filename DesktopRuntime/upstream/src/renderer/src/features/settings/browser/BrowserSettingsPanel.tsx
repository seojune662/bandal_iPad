import { BrowserProfileSelect } from '../../browser/BrowserProfileSelect'
import { useEffect, useState, type FormEvent } from 'react'
import { ZOOM_LEVELS, zoomPercent } from '../../../../../shared/browserZoom'
import {
  SEARCH_ENGINE_NAMES,
  SEARCH_ENGINES,
  type SearchEngineId
} from '../../../../../shared/search'
import type {
  BrowserSettings,
  LinkRouting,
  PopupBehavior,
  Settings
} from '../../../../../shared/types/settings'
import type { BrowserExtensionSummary } from '../../../../../shared/types/browserExtension'
import { useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { BrowserImportDialog } from '../../browser/BrowserImportDialog'
import { savePreference } from '../savePreference'
import { AgentAccessPanel } from '../AgentAccessPanel'
import { BrowsingDataPanel } from '../BrowsingDataPanel'
import { SettingsCard, ToggleRow } from '../primitives'
import './browser-settings.css'

const LINK_ROUTINGS: readonly LinkRouting[] = ['in-app', 'system']
const POPUP_BEHAVIORS: readonly PopupBehavior[] = ['balanced', 'strict']
const TRACKING_PROTECTIONS = ['balanced', 'strict', 'off'] as const

function saveBrowserSettings(
  settings: Settings | null,
  patch: Partial<BrowserSettings>
): void {
  if (settings === null) return
  void savePreference({
    browser: patch
  })
}

function AgentUseSection({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  const enabled = settings?.browser.agentUse ?? false
  return (
    <SettingsCard>
      <ToggleRow
        label={t('settings.browser.agentUse.label')}
        description={t('settings.browser.agentUse.description')}
        checked={enabled}
        disabled={settings === null}
        onChange={(agentUse) => saveBrowserSettings(settings, { agentUse })}
      />
    </SettingsCard>
  )
}

/** The grant/audit cards are long; everyday knobs come first, these after. */
function AgentAccessSection({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const enabled = settings?.browser.agentUse ?? false
  return (
    <div className={!enabled ? 'settings-browser__dimmed' : ''}>
      <AgentAccessPanel />
    </div>
  )
}

function HomePageCard({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  const [homePage, setHomePage] = useState('')
  const [savingHomePage, setSavingHomePage] = useState(false)
  useEffect(() => {
    setHomePage(settings?.browser.homePage ?? '')
  }, [settings?.browser.homePage])
  const saveHomePage = (event: FormEvent<HTMLFormElement>): void => {
    event.preventDefault()
    if (settings === null || savingHomePage) return
    setSavingHomePage(true)
    void savePreference({
      browser: { homePage }
    })
      .then((nextSettings) => {
        if (nextSettings === null) return
        setHomePage(nextSettings.browser.homePage)
      })
      .finally(() => setSavingHomePage(false))
  }
  return (
    <SettingsCard
      title={t('settings.browser.homePage.title')}
      description={t('settings.browser.homePage.description')}
    >
      <form className="directory-field" noValidate onSubmit={saveHomePage}>
        <input
          type="url"
          aria-label={t('settings.browser.homePage.label')}
          placeholder="https://"
          value={homePage}
          disabled={settings === null || savingHomePage}
          onChange={(event) => setHomePage(event.currentTarget.value)}
        />
        <button
          type="submit"
          className="secondary-button"
          disabled={settings === null || savingHomePage}
        >
          {savingHomePage
            ? t('settings.browser.homePage.saving')
            : t('settings.browser.homePage.save')}
        </button>
      </form>
    </SettingsCard>
  )
}

function SearchEngineCard({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard
      title={t('settings.browser.search.title')}
      description={t('settings.browser.search.description')}
    >
      <div className="settings-card__rows">
        <div className="setting-row">
          <div className="setting-row__copy">
            <span className="setting-row__label">
              {t('settings.browser.search.label')}
            </span>
          </div>
          <select
            className="language-select"
            aria-label={t('settings.browser.search.label')}
            value={settings?.browserSearchEngine ?? 'google'}
            disabled={settings === null}
            onChange={(event) => {
              void savePreference({
                browserSearchEngine: event.currentTarget.value as SearchEngineId
              })
            }}
          >
            {(Object.keys(SEARCH_ENGINES) as SearchEngineId[]).map((id) => (
              <option key={id} value={id}>
                {SEARCH_ENGINE_NAMES[id]}
              </option>
            ))}
          </select>
        </div>
      </div>
    </SettingsCard>
  )
}

function DefaultZoomCard({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard title={t('settings.browser.zoom.title')}>
      <div className="settings-card__rows">
        <div className="setting-row">
          <div className="setting-row__copy">
            <span className="setting-row__label">
              {t('settings.browser.zoom.label')}
            </span>
            <span className="setting-row__description">
              {t('settings.browser.zoom.description')}
            </span>
          </div>
          <select
            className="language-select"
            aria-label={t('settings.browser.zoom.label')}
            value={settings?.browser.defaultZoomLevel ?? 0}
            disabled={settings === null}
            onChange={(event) =>
              saveBrowserSettings(settings, {
                defaultZoomLevel: Number(event.currentTarget.value)
              })
            }
          >
            {ZOOM_LEVELS.map((level) => (
              <option key={level} value={level}>
                {zoomPercent(level)}%
              </option>
            ))}
          </select>
        </div>
      </div>
    </SettingsCard>
  )
}

function LinkRoutingCard({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  const selected = settings?.browser.linkRouting
  const modifierHint =
    typeof window !== 'undefined' && window.bandal?.platform === 'darwin'
      ? t('settings.browser.linkRouting.modifier.mac')
      : t('settings.browser.linkRouting.modifier.other')
  return (
    <SettingsCard title={t('settings.browser.linkRouting.title')}>
      <div className="settings-card__rows">
        <div className="setting-row">
          <div className="setting-row__copy">
            <span className="setting-row__label">
              {t('settings.browser.linkRouting.label')}
            </span>
            <span className="setting-row__description">{modifierHint}</span>
          </div>
          <div className="segmented settings-browser__segmented">
            {LINK_ROUTINGS.map((routing) => (
              <button
                key={routing}
                type="button"
                className={`segmented__option${
                  selected === routing ? ' segmented__option--selected' : ''
                }`}
                aria-pressed={selected === routing}
                disabled={settings === null}
                onClick={() =>
                  saveBrowserSettings(settings, { linkRouting: routing })
                }
              >
                <span className="segmented__label">
                  {t(`settings.browser.linkRouting.${routing}`)}
                </span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </SettingsCard>
  )
}

function PrivacyProtectionCard({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const t = useT()
  const browser = settings?.browser
  return (
    <SettingsCard
      title={t('settings.browser.protection.title')}
      description={t('settings.browser.protection.description')}
    >
      <div className="settings-card__rows">
        <div className="setting-row">
          <div className="setting-row__copy">
            <span className="setting-row__label">
              {t('settings.browser.tracking.label')}
            </span>
            <span className="setting-row__description">
              {t('settings.browser.tracking.description')}
            </span>
          </div>
          <select
            className="language-select"
            aria-label={t('settings.browser.tracking.label')}
            value={browser?.trackingProtection ?? 'balanced'}
            disabled={settings === null}
            onChange={(event) => saveBrowserSettings(settings, {
              trackingProtection: event.currentTarget.value as BrowserSettings['trackingProtection']
            })}
          >
            {TRACKING_PROTECTIONS.map((protection) => (
              <option key={protection} value={protection}>
                {t(`settings.browser.tracking.${protection}`)}
              </option>
            ))}
          </select>
        </div>
        <ToggleRow
          label={t('settings.browser.dnt.label')}
          description={t('settings.browser.dnt.description')}
          checked={browser?.doNotTrack ?? true}
          disabled={settings === null}
          onChange={(doNotTrack) => saveBrowserSettings(settings, { doNotTrack })}
        />
      </div>
    </SettingsCard>
  )
}

function PopupCard({ settings }: { settings: Settings | null }): JSX.Element {
  const t = useT()
  const selected = settings?.browser.popupBehavior ?? 'balanced'
  return (
    <SettingsCard
      title={t('settings.browser.popups.title')}
      description={t('settings.browser.popups.description')}
    >
      <div className="segmented settings-browser__segmented">
        {POPUP_BEHAVIORS.map((behavior) => (
          <button
            key={behavior}
            type="button"
            className={`segmented__option${
              selected === behavior ? ' segmented__option--selected' : ''
            }`}
            aria-pressed={selected === behavior}
            disabled={settings === null}
            onClick={() => saveBrowserSettings(settings, { popupBehavior: behavior })}
          >
            <span className="segmented__label">
              {t(`settings.browser.popups.${behavior}`)}
            </span>
          </button>
        ))}
      </div>
    </SettingsCard>
  )
}

function BrowserImportCard({ profileId }: { profileId: string }): JSX.Element {
  const t = useT()
  const [open, setOpen] = useState(false)
  return <SettingsCard title={t('settings.browser.import.title')} description="Chrome · Edge · Firefox · Safari">
    <button type="button" className="secondary-button" onClick={() => setOpen(true)}>{t('settings.browser.import.title')}</button>
    {open && <BrowserImportDialog profileId={profileId} onClose={() => setOpen(false)} />}
  </SettingsCard>
}

function WebExtensionsCard({ profileId }: { profileId: string }): JSX.Element {
  const t = useT()
  const [extensions, setExtensions] = useState<BrowserExtensionSummary[] | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [feedback, setFeedback] = useState('')

  const refresh = (): void => {
    void invoke('browser:extensions', { profileId })
      .then((result) => setExtensions(result.extensions))
      .catch(() => {
        setExtensions([])
        setFeedback(t('settings.browser.extensions.error'))
      })
  }

  useEffect(refresh, [])

  const install = (): void => {
    setBusy('install')
    setFeedback('')
    void invoke('browser:installExtension', { profileId })
      .then(({ extension }) => {
        if (extension === null) return
        refresh()
        setFeedback(extension.status === 'loaded'
          ? t('settings.browser.extensions.installed')
          : extension.error ?? t('settings.browser.extensions.error'))
      })
      .catch((error: unknown) => setFeedback(
        error instanceof Error ? error.message : t('settings.browser.extensions.error')
      ))
      .finally(() => setBusy(null))
  }

  const toggle = (extension: BrowserExtensionSummary): void => {
    setBusy(extension.path)
    void invoke('browser:setExtensionEnabled', { profileId,
      path: extension.path,
      enabled: !extension.enabled
    }).then((result) => setExtensions(result.extensions))
      .catch(() => setFeedback(t('settings.browser.extensions.error')))
      .finally(() => setBusy(null))
  }

  const remove = (extension: BrowserExtensionSummary): void => {
    setBusy(extension.path)
    void invoke('browser:removeExtension', { profileId, path: extension.path })
      .then((result) => setExtensions(result.extensions))
      .catch(() => setFeedback(t('settings.browser.extensions.error')))
      .finally(() => setBusy(null))
  }

  return (
    <SettingsCard
      title={t('settings.browser.extensions.title')}
      description={t('settings.browser.extensions.description')}
    >
      <button
        type="button"
        className="secondary-button settings-browser__extension-add"
        disabled={busy !== null}
        onClick={install}
      >
        {busy === 'install'
          ? t('settings.browser.extensions.loading')
          : t('settings.browser.extensions.add')}
      </button>
      {extensions === null ? (
        <p className="settings-feedback">{t('settings.browser.extensions.loading')}</p>
      ) : extensions.length === 0 ? (
        <p className="settings-feedback">{t('settings.browser.extensions.empty')}</p>
      ) : (
        <ul className="settings-browser__extension-list">
          {extensions.map((extension) => (
            <li key={extension.path} className="settings-browser__extension-row">
              <span className="settings-browser__extension-copy">
                <strong>{extension.name}</strong>
                <small>
                  {extension.version !== '' ? `v${extension.version} · ` : ''}
                  {extension.status === 'loaded'
                    ? t('settings.browser.extensions.active')
                    : extension.status === 'disabled'
                      ? t('settings.browser.extensions.disabled')
                      : extension.error ?? t('settings.browser.extensions.error')}
                </small>
              </span>
              <button
                type="button"
                className="settings-site-row__action"
                disabled={busy !== null}
                onClick={() => toggle(extension)}
              >
                {extension.enabled
                  ? t('settings.browser.extensions.disable')
                  : t('settings.browser.extensions.enable')}
              </button>
              <button
                type="button"
                className="settings-site-row__action"
                disabled={busy !== null}
                onClick={() => remove(extension)}
              >
                {t('settings.browser.extensions.remove')}
              </button>
            </li>
          ))}
        </ul>
      )}
      <p className="settings-feedback" aria-live="polite">{feedback}</p>
    </SettingsCard>
  )
}

export function BrowserSettingsPanel({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const [profileId, setProfileId] = useState('default')
  return (
    <div className="settings-stack">
      <BrowserProfileSelect value={profileId} onChange={setProfileId} />
      <SettingsCard><ToggleRow label="두 손가락으로 앞뒤 이동" description="페이지 가장자리에서 가로로 쓸어 탐색합니다." checked={settings?.browser.swipeNavigation ?? true} onChange={swipeNavigation => saveBrowserSettings(settings, { swipeNavigation })} /></SettingsCard>
      <AgentUseSection settings={settings} />
      <HomePageCard settings={settings} />
      <SearchEngineCard settings={settings} />
      <DefaultZoomCard settings={settings} />
      <LinkRoutingCard settings={settings} />
      <PrivacyProtectionCard settings={settings} />
      <PopupCard settings={settings} />
      <WebExtensionsCard key={`extensions-${profileId}`} profileId={profileId} />
      <BrowserImportCard profileId={profileId} />
      <AgentAccessSection settings={settings} />
      <BrowsingDataPanel key={profileId} settings={settings} profileId={profileId} />
    </div>
  )
}
