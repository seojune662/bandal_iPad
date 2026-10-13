import { useEffect, useState } from 'react'
import { BandalMark } from '../../components/BandalMark'
import { ProviderMark } from '../../components/ProviderMark'
import { LOCALES, setLocale, useLocale, useT } from '../../i18n'
import type { Locale } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { isAgentConnectionBusy, isAgentConnectionReady, refreshAgentConnectionAfterMutation, seedAgentAvailability, startAgentLogin, useAgentConnectionStore } from '../chat/agentConnectionStore'
import { AgentConnectionControls } from '../chat/AgentConnectionControls'
import { useUpdateStore } from '../../stores/updateStore'
import {
  AGENT_PROVIDERS,
  type AgentAvailability,
  type AgentProvider
} from '../../../../shared/types/agent-events'
import type { Course } from '../../../../shared/types/course'
import type { Settings } from '../../../../shared/types/settings'
import { reopenedOnboarding } from '../onboarding/onboardingModel'
import { SettingsCard, ToggleRow } from './primitives'
import { Icon } from './SettingsIcon'
import { savePreference } from './savePreference'

export { AppearancePanel } from './AppearancePanel'

export function GeneralPanel({ settings }: { settings: Settings | null }): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const [onboardingReset, setOnboardingReset] = useState<
    'idle' | 'done' | 'failed'
  >('idle')
  const [tutorialReset, setTutorialReset] = useState<
    'idle' | 'done' | 'failed'
  >('idle')
  const handleReopenOnboarding = (): void => {
    void invoke('settings:set', { onboarding: reopenedOnboarding() })
      .then(() => setOnboardingReset('done'))
      .catch(() => setOnboardingReset('failed'))
  }

  const handleReplayTutorial = (): void => {
    // Fetch the current marker: an interrupted tour still needs guarded
    // cleanup before a replay can create another sample course.
    void invoke('settings:get', {})
      .then(current => invoke('settings:set', {
        tutorial: { ...current.tutorial, seenVersion: 0 }
      }))
      .then(() => setTutorialReset('done'))
      .catch(() => setTutorialReset('failed'))
  }

  return (
    <div className="settings-stack">
      <SettingsCard
        title={t('settings.general.language.title')}
        description={t('settings.general.language.description')}
      >
        <div className="setting-row">
          <div className="setting-row__copy">
            <span className="setting-row__label">
              {t('settings.general.language.label')}
            </span>
            <span className="setting-row__description">
              {t('settings.general.language.help')}
            </span>
            <span className="setting-row__description">
              {t('settings.general.locale.scope')}
            </span>
          </div>
          <select
            className="language-select"
            aria-label={t('settings.general.language.selectLabel')}
            value={locale}
            onChange={(event) => setLocale(event.target.value as Locale)}
          >
            {LOCALES.map((option) => (
              <option key={option} value={option}>
                {t(`settings.locale.${option}`)}
              </option>
            ))}
          </select>
        </div>
      </SettingsCard>

      <SettingsCard
        title={t('settings.general.tabs.title')}
        description={t('settings.general.tabs.description')}
      >
        <div className="settings-card__rows">
          <ToggleRow
            label={t('settings.general.tabs.openBeside')}
            description={t('settings.general.tabs.openBesideDescription')}
            checked={settings?.openAdjacentTab ?? false}
            disabled={settings === null}
            onChange={(openAdjacentTab) => {
              void savePreference({ openAdjacentTab })
            }}
          />
          <ToggleRow
            label={t('settings.general.tabs.restore')}
            description={t('settings.general.tabs.restoreDescription')}
            checked={settings?.restoreLastCourse ?? false}
            disabled={settings === null}
            onChange={(restoreLastCourse) => {
              void savePreference({ restoreLastCourse })
            }}
          />
        </div>
      </SettingsCard>

      <SettingsCard
        title={t('settings.general.onboarding.title')}
        description={t('settings.general.onboarding.description')}
      >
        <div className="settings-card__rows">
          <div className="setting-row">
            <div className="setting-row__copy">
              <div className="setting-row__label-line">
                <span className="setting-row__label">
                  {t('settings.general.onboarding.reopen')}
                </span>
              </div>
              <span className="setting-row__description">
                {t(`settings.general.onboarding.${onboardingReset}`)}
              </span>
            </div>
            <button
              type="button"
              className="secondary-button"
              onClick={handleReopenOnboarding}
            >
              {t('settings.general.onboarding.reopen')}
            </button>
          </div>
          <div className="setting-row">
            <div className="setting-row__copy">
              <div className="setting-row__label-line">
                <span className="setting-row__label">
                  {t('settings.general.tutorial.reopen')}
                </span>
              </div>
              <span className="setting-row__description">
                {t(`settings.general.tutorial.${tutorialReset}`)}
              </span>
            </div>
            <button
              type="button"
              className="secondary-button"
              onClick={handleReplayTutorial}
            >
              {t('settings.general.tutorial.reopen')}
            </button>
          </div>
        </div>
      </SettingsCard>
    </div>
  )
}


function AvailabilityRows({
  availability
}: {
  availability: AgentAvailability
}): JSX.Element {
  const t = useT()
  return (
    <dl className="detail-list">
      <div>
        <dt>{t('settings.ai.install')}</dt>
        <dd>
          {t(availability.installed ? 'settings.ai.installed' : 'settings.ai.notInstalled')}
        </dd>
      </div>
      <div>
        <dt>{t('settings.ai.version')}</dt>
        <dd>{availability.version ?? t('settings.ai.unknown')}</dd>
      </div>
      <div>
        <dt>{t('settings.ai.login')}</dt>
        <dd>
          {availability.installed
            ? t(availability.loggedIn ? 'settings.ai.connected' : 'settings.ai.loginRequired')
            : '—'}
        </dd>
      </div>
      <div>
        <dt>{t('settings.ai.subscription')}</dt>
        <dd>{availability.subscriptionType ?? t('settings.ai.unknown')}</dd>
      </div>
    </dl>
  )
}

function ProviderAccountRow({
  availability,
  providerName,
  busy,
  onReauthenticate
}: {
  availability: AgentAvailability
  providerName: string
  busy: boolean
  onReauthenticate: () => void
}): JSX.Element {
  const t = useT()

  return (
    <div className="settings-ai-account">
      <div className="settings-ai-account__copy">
        <strong>{t('settings.ai.account.systemDefault')}</strong>
        <span>
          {t('settings.ai.account.deviceLogin', { provider: providerName })}
        </span>
        {availability.accountEmail !== undefined &&
          availability.accountEmail !== '' && (
          <div className="settings-ai-account__identity">
            <span
              className="settings-ai-account__email"
              title={availability.accountEmail}
            >
              {availability.accountEmail}
            </span>
            <span className="settings-ai-account__badge">
              {t('settings.ai.account.thisDevice')}
            </span>
            <span className="status-pill status-pill--ready">
              <span className="status-pill__dot" />
              {t('settings.ai.account.signedIn')}
            </span>
          </div>
        )}
      </div>
      {availability.loggedIn && (
        <button
          type="button"
          className="secondary-button"
          disabled={busy}
          onClick={onReauthenticate}
        >
          {t('settings.ai.account.reauthenticate')}
        </button>
      )}
    </div>
  )
}

interface GeminiApiKeyStatus {
  configured: boolean
  hint: string | null
  storageAvailable: boolean
}

function GeminiApiKeyRow({ onRefresh }: { onRefresh: () => void }): JSX.Element {
  const t = useT()
  const [status, setStatus] = useState<GeminiApiKeyStatus | null>(null)
  const [key, setKey] = useState('')
  const [saving, setSaving] = useState(false)
  const [errorKey, setErrorKey] = useState<string | null>(null)

  useEffect(() => {
    let active = true
    void invoke('agent:geminiApiKey', {}).then(
      (result) => {
        if (active) setStatus(result)
      },
      () => {
        if (active) setErrorKey('settings.ai.apiKey.loadFailed')
      }
    )
    return () => {
      active = false
    }
  }, [])

  const persist = (nextKey: string | null): void => {
    if (saving || status?.storageAvailable !== true) return
    setSaving(true)
    setErrorKey(null)
    void invoke('agent:setGeminiApiKey', { key: nextKey }).then(
      (result) => {
        setStatus({ ...result, storageAvailable: true })
        setKey('')
        setSaving(false)
        void refreshAgentConnectionAfterMutation('gemini')
        onRefresh()
      },
      () => {
        setSaving(false)
        setErrorKey('settings.ai.apiKey.saveFailed')
      }
    )
  }

  const storageAvailable = status?.storageAvailable === true
  const configured = status?.configured === true
  const configuredLabel =
    status?.hint === null || status?.hint === undefined
      ? t('settings.ai.apiKey.configuredNoHint')
      : t('settings.ai.apiKey.configured', { hint: status.hint })

  return (
    <form
      className="settings-ai-api-key"
      aria-busy={saving}
      onSubmit={(event) => {
        event.preventDefault()
        const trimmed = key.trim()
        if (trimmed !== '') persist(trimmed)
      }}
    >
      <div className="setting-row">
        <div className="setting-row__copy">
          <span className="setting-row__label">{t('settings.ai.apiKey.label')}</span>
          <span className="setting-row__description">
            {t('settings.ai.apiKey.description')}{' '}
            <button
              type="button"
              className="settings-ai-api-key__link"
              onClick={() => {
                void invoke('shell:openExternal', {
                  url: 'https://aistudio.google.com/apikey'
                }).catch(() => setErrorKey('settings.ai.apiKey.openFailed'))
              }}
            >
              {t('settings.ai.apiKey.create')}
            </button>
          </span>
          {status?.storageAvailable === false && (
            <span className="setting-row__description">
              {t('settings.ai.apiKey.storageUnavailable')}
            </span>
          )}
        </div>
        <div className="settings-ai-api-key__actions">
          {configured ? (
            <>
              <span className="status-pill status-pill--ready">
                <span className="status-pill__dot" />
                {configuredLabel}
              </span>
              <button
                type="button"
                className="secondary-button"
                disabled={saving || !storageAvailable}
                onClick={() => persist(null)}
              >
                {t('settings.ai.apiKey.remove')}
              </button>
            </>
          ) : (
            <>
              <input
                type="password"
                className="language-select settings-ai-api-key__input"
                value={key}
                autoComplete="off"
                aria-label={t('settings.ai.apiKey.inputLabel')}
                placeholder={t('settings.ai.apiKey.placeholder')}
                disabled={!storageAvailable || saving}
                onChange={(event) => setKey(event.target.value)}
              />
              <button
                type="submit"
                className="secondary-button"
                disabled={!storageAvailable || saving || key.trim() === ''}
              >
                {t('settings.ai.apiKey.save')}
              </button>
            </>
          )}
        </div>
      </div>
      {errorKey !== null && (
        <p className="settings-ai-api-key__error" role="alert">
          {t(errorKey)}
        </p>
      )}
    </form>
  )
}

function AgentConnector({
  provider,
  availability,
  onRefresh
}: {
  provider: AgentProvider
  availability: AgentAvailability
  onRefresh: () => void
}): JSX.Element | null {
  const t = useT()
  const connection = useAgentConnectionStore(state => state.connections[provider])
  const current = connection.availability ?? availability
  const providerKey = provider === 'claude-code' ? 'claude' : provider
  const providerName = t(`settings.ai.${providerKey}.name`)
  useEffect(() => { seedAgentAvailability(provider, availability) }, [provider, availability])
  return <>
    {isAgentConnectionReady(current) && <ProviderAccountRow availability={current} providerName={providerName} busy={isAgentConnectionBusy(connection.stage)} onReauthenticate={() => { void startAgentLogin(provider) }} />}
    <AgentConnectionControls provider={provider} availability={availability} />
    {provider === 'gemini' && <GeminiApiKeyRow onRefresh={onRefresh} />}
  </>
}

function ProviderCard({
  provider,
  availability,
  loading,
  error,
  onRetry
}: {
  provider: AgentProvider
  availability: AgentAvailability | null
  loading: boolean
  error: string | null
  onRetry: () => void
}): JSX.Element {
  const t = useT()
  const providerKey = provider === 'claude-code' ? 'claude' : provider
  const installed = availability?.installed === true
  const connected = isAgentConnectionReady(availability)
  const providerName = t(`settings.ai.${providerKey}.name`)
  const statusLabel = loading
    ? t('settings.ai.checking')
    : error !== null
      ? t('settings.ai.checkFailed')
      : availability?.code === 'version-too-old'
        ? t('settings.ai.updateRequired')
        : connected
          ? t('settings.ai.available')
          : installed
            ? t('settings.ai.loginRequired')
            : t('settings.ai.notInstalled')

  return (
    <SettingsCard className="integration-card">
      <div
        id={`settings-ai-provider-${provider}`}
        className="integration-card__heading"
      >
        <ProviderMark provider={provider} size={32} />
        <div className="integration-card__title">
          <h2>{providerName}</h2>
          <p>{t(`settings.ai.${providerKey}.description`)}</p>
        </div>
        <span
          className={`status-pill status-pill--${
            loading
              ? 'loading'
              : error !== null
                ? 'muted'
                : connected
                  ? 'ready'
                  : 'muted'
          }`}
        >
          <span className="status-pill__dot" />
          {statusLabel}
        </span>
      </div>

      {loading && availability === null ? (
        <div
          className="availability-skeleton"
          aria-label={t(`settings.ai.${providerKey}.checkingLabel`)}
        >
          <span />
          <span />
          <span />
        </div>
      ) : error !== null ? (
        <div className="inline-notice">
          <div>
            <strong>{t('settings.ai.connectionFailed')}</strong>
            <span>{t('settings.ai.tryAgainLater')}</span>
          </div>
          <button type="button" className="secondary-button" onClick={onRetry}>
            {t('settings.ai.retry')}
          </button>
        </div>
      ) : availability !== null ? (
        <>
          <AgentConnector
            provider={provider}
            availability={availability}
            onRefresh={onRetry}
          />
          <details className="agent-connection__details"><summary>{t('settings.ai.connectionDetails')}</summary><AvailabilityRows availability={availability} /></details>
        </>
      ) : null}
    </SettingsCard>
  )
}


export function AiPanel({
  provider,
  providerReady,
  providerSaving,
  providerFeedback,
  providerFeedbackError,
  availability,
  loading,
  error,
  onProviderSelect,
  onRetry
}: {
  provider: AgentProvider
  providerReady: boolean
  providerSaving: boolean
  providerFeedback: string | null
  providerFeedbackError: boolean
  availability: Record<AgentProvider, AgentAvailability | null>
  loading: Record<AgentProvider, boolean>
  error: Record<AgentProvider, string | null>
  onProviderSelect: (provider: AgentProvider) => void
  onRetry: (provider: AgentProvider) => void
}): JSX.Element {
  const t = useT()

  return (
    <div className="settings-stack">
      <SettingsCard
        title={t('settings.ai.engine.title')}
        description={t('settings.ai.engine.description')}
      >
        <div className="settings-ai-engine">
          <div
            className="settings-ai-engine__segments"
            role="radiogroup"
            aria-label={t('settings.ai.engine.selectLabel')}
            aria-busy={providerSaving}
          >
            {AGENT_PROVIDERS.map((option) => {
              const optionKey = option === 'claude-code' ? 'claude' : option
              return (
                <button
                  key={option}
                  type="button"
                  role="radio"
                  aria-checked={provider === option}
                  disabled={!providerReady || providerSaving}
                  className={`settings-ai-engine__segment${
                    provider === option
                      ? ' settings-ai-engine__segment--selected'
                      : ''
                  }`}
                  onClick={() => onProviderSelect(option)}
                >
                  <ProviderMark provider={option} size={20} />
                  <span>{t(`settings.ai.${optionKey}.name`)}</span>
                </button>
              )
            })}
          </div>
          <p
            className={`settings-ai-engine__feedback${
              providerFeedbackError
                ? ' settings-ai-engine__feedback--error'
                : ''
            }`}
            aria-live="polite"
          >
            {providerFeedback ?? ''}
          </p>
        </div>
      </SettingsCard>

      {AGENT_PROVIDERS.map((option) => (
        <ProviderCard
          key={option}
          provider={option}
          availability={availability[option]}
          loading={loading[option]}
          error={error[option]}
          onRetry={() => onRetry(option)}
        />
      ))}
    </div>
  )
}

export function CoursesPanel({
  courses,
  loading,
  error,
  includeArchived,
  pendingCourseId,
  onIncludeArchivedChange,
  onRestore,
  onRetry
}: {
  courses: Course[]
  loading: boolean
  error: string | null
  includeArchived: boolean
  pendingCourseId: string | null
  onIncludeArchivedChange: (next: boolean) => void
  onRestore: (course: Course) => void
  onRetry: () => void
}): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const courseCount = new Intl.NumberFormat(locale).format(courses.length)
  const restoreLabel = locale === 'ko-KR' ? '복원' : 'Restore'
  const restoringLabel = locale === 'ko-KR' ? '복원 중…' : 'Restoring…'
  return (
    <div className="settings-stack">
      <SettingsCard>
        <div className="course-card-heading">
          <div>
            <h2>{t('settings.courses.title')}</h2>
            <p>{t('settings.courses.description')}</p>
          </div>
          {!loading && error === null && (
            <span className="count-badge">{courseCount}</span>
          )}
        </div>

        <div
          className="settings-course-list"
          aria-live="polite"
          aria-busy={pendingCourseId !== null}
        >
          {loading ? (
            <div className="course-loading" aria-label={t('settings.courses.loading')}>
              <span />
              <span />
              <span />
            </div>
          ) : error !== null ? (
            <div className="settings-empty-state">
              <div className="settings-empty-state__icon">
                <Icon name="courses" />
              </div>
              <strong>{t('settings.courses.loadFailed')}</strong>
              <span>{t('settings.courses.loadFailedHelp')}</span>
              <button type="button" className="secondary-button" onClick={onRetry}>
                {t('settings.courses.reload')}
              </button>
            </div>
          ) : courses.length === 0 ? (
            <div className="settings-empty-state">
              <div className="settings-empty-state__icon">
                <Icon name="courses" />
              </div>
              <strong>{t('settings.courses.empty')}</strong>
              <span>{t('settings.courses.emptyHelp')}</span>
            </div>
          ) : (
            courses.map((course) => (
              <div className="course-item" key={course.id}>
                <div className="course-item__icon">
                  <Icon name="courses" size={17} />
                </div>
                <div className="course-item__copy">
                  <strong>{course.name}</strong>
                  <span>{course.slug}</span>
                </div>
                {course.archived && (
                  <div className="course-item__actions">
                    <span className="badge">{t('settings.courses.archived')}</span>
                    <button
                      type="button"
                      className="secondary-button"
                      aria-label={`${course.name} ${restoreLabel}`}
                      disabled={pendingCourseId !== null}
                      onClick={() => onRestore(course)}
                    >
                      {pendingCourseId === course.id
                        ? restoringLabel
                        : restoreLabel}
                    </button>
                  </div>
                )}
              </div>
            ))
          )}
        </div>

        <div className="settings-card__footer-row">
          <ToggleRow
            label={t('settings.courses.showArchived')}
            description={t('settings.courses.showArchivedHelp')}
            checked={includeArchived}
            onChange={onIncludeArchivedChange}
          />
        </div>
      </SettingsCard>
    </div>
  )
}

function UpdateCard(): JSX.Element | null {
  const t = useT()
  const locale = useLocale()
  const status = useUpdateStore((state) => state.status)
  const init = useUpdateStore((state) => state.init)
  const check = useUpdateStore((state) => state.check)
  const download = useUpdateStore((state) => state.download)
  const install = useUpdateStore((state) => state.install)

  useEffect(() => {
    init()
  }, [init])

  if (status === null || status.phase === 'unsupported') return null

  const busy = status.phase === 'checking' || status.phase === 'downloading'
  const statusLabel =
    status.phase === 'checking'
      ? t('settings.update.checking')
      : status.phase === 'downloading'
        ? t('settings.update.downloading', { percent: status.percent })
        : status.phase === 'available'
          ? t('settings.update.available')
          : status.phase === 'ready'
            ? t('settings.update.ready')
            : status.phase === 'error'
              ? t('settings.update.failed')
              : t('settings.update.current')

  const pillTone =
    status.phase === 'checking' || status.phase === 'downloading'
      ? 'loading'
      : status.phase === 'available' || status.phase === 'ready'
        ? 'ready'
        : 'muted'

  return (
    <SettingsCard className="integration-card">
      <div className="integration-card__heading">
        <div className="integration-card__title">
          <h2>{t('settings.update.title')}</h2>
          <p>{t('settings.update.description')}</p>
        </div>
        <span className={`status-pill status-pill--${pillTone}`}>
          <span className="status-pill__dot" />
          {statusLabel}
        </span>
      </div>

      {status.phase === 'available' && (
        <div className="inline-notice">
          <div>
            <strong>{t('settings.update.availableTitle', { version: status.version })}</strong>
            <span>{t('settings.update.availableHelp')}</span>
          </div>
          <button
            type="button"
            className="secondary-button"
            onClick={() => void download()}
          >
            {t('settings.update.download')}
          </button>
        </div>
      )}

      {status.phase === 'ready' && (
        <div className="inline-notice">
          <div>
            <strong>{t('settings.update.readyTitle', { version: status.version })}</strong>
            <span>{t('settings.update.readyHelp')}</span>
          </div>
          <button
            type="button"
            className="secondary-button"
            onClick={() => void install()}
          >
            {t('settings.update.restart')}
          </button>
        </div>
      )}

      {status.phase === 'error' && (
        <div className="inline-notice">
          <div>
            <strong>{t('settings.update.errorTitle')}</strong>
            <span>{status.message}</span>
          </div>
        </div>
      )}

      {(status.phase === 'idle' || status.phase === 'checking') && (
        <div className="inline-notice">
          <div>
            <strong>
              {t('settings.update.currentVersion', { version: status.currentVersion })}
            </strong>
            <span>
              {status.phase === 'idle' && status.lastCheckedAt !== null
                ? t('settings.update.lastChecked', {
                    time: new Intl.DateTimeFormat(locale, {
                      timeStyle: 'short'
                    }).format(new Date(status.lastCheckedAt))
                  })
                : t('settings.update.automatic')}
            </span>
          </div>
          <button
            type="button"
            className="secondary-button"
            disabled={busy}
            onClick={() => void check()}
          >
            {t(busy ? 'settings.update.checkingButton' : 'settings.update.check')}
          </button>
        </div>
      )}
    </SettingsCard>
  )
}

export function AboutPanel(): JSX.Element {
  const t = useT()
  const status = useUpdateStore((state) => state.status)
  const init = useUpdateStore((state) => state.init)

  useEffect(() => {
    init()
  }, [init])

  return (
    <div className="settings-stack">
      <SettingsCard className="about-card">
        <div className="about-card__mark">
          <BandalMark size={62} title={t('settings.app.name')} />
        </div>
        <div className="about-card__copy">
          <h2>{t('settings.app.name')}</h2>
          <p>{t('settings.about.description')}</p>
          <span className="version-label">
            {t('settings.about.version', {
              version: status?.currentVersion ?? '—'
            })}
          </span>
        </div>
      </SettingsCard>
      <UpdateCard />
      <p className="about-footer">{t('settings.about.footer')}</p>
    </div>
  )
}
