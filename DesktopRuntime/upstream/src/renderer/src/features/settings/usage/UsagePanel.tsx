import { useEffect, useState } from 'react'
import {
  AGENT_PROVIDERS,
  type AgentProvider
} from '../../../../../shared/types/agent-events'
import {
  USAGE_WINDOWS,
  type UsageByProvider,
  type UsageSummary,
  type UsageWindowDays
} from '../../../../../shared/types/usage'
import { ProviderMark } from '../../../components/ProviderMark'
import { useLocale, useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { SettingsCard } from '../primitives'
import { formatDuration, formatRelative, formatTokens } from './formatUsage'
import './usage-panel.css'

function providerNameKey(provider: AgentProvider): string {
  if (provider === 'claude-code') return 'settings.ai.claude.name'
  if (provider === 'codex') return 'settings.ai.codex.name'
  return 'settings.ai.gemini.name'
}

function UsageLoading(): JSX.Element {
  const t = useT()
  return (
    <div
      className="availability-skeleton settings-usage-loading"
      aria-label={t('settings.usage.loading')}
    >
      <span />
      <span />
      <span />
    </div>
  )
}

function WindowSelect({
  value,
  onChange
}: {
  value: UsageWindowDays
  onChange: (value: UsageWindowDays) => void
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard>
      <div className="setting-row">
        <div className="setting-row__copy">
          <span className="setting-row__label">
            {t('settings.usage.window.label')}
          </span>
        </div>
        <select
          className="language-select"
          aria-label={t('settings.usage.window.selectLabel')}
          value={value}
          onChange={(event) =>
            onChange(Number(event.target.value) as UsageWindowDays)
          }
        >
          {USAGE_WINDOWS.map((days) => (
            <option key={days} value={days}>
              {t(`settings.usage.window.${days}`)}
            </option>
          ))}
        </select>
      </div>
    </SettingsCard>
  )
}

function SummaryTiles({ summary }: { summary: UsageSummary }): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const since = summary.since === null ? null : new Date(summary.since)
  const sinceLabel =
    since !== null && Number.isFinite(since.getTime())
      ? t('settings.usage.summary.since', {
          date: new Intl.DateTimeFormat(locale, {
            dateStyle: 'long'
          }).format(since)
        })
      : null

  return (
    <div>
      <div className="settings-usage-tiles">
        <UsageTile
          label={t('settings.usage.summary.sessions')}
          value={formatTokens(summary.totals.sessions)}
        />
        <UsageTile
          label={t('settings.usage.summary.agentTime')}
          value={formatDuration(summary.totals.agentMs)}
        />
        <UsageTile
          label={t('settings.usage.summary.tokens')}
          value={formatTokens(
            summary.totals.inputTokens + summary.totals.outputTokens
          )}
        />
      </div>
      {sinceLabel !== null && (
        <p className="settings-usage-since">{sinceLabel}</p>
      )}
    </div>
  )
}

function UsageTile({
  label,
  value
}: {
  label: string
  value: string
}): JSX.Element {
  return (
    <SettingsCard className="settings-usage-tile">
      <span>{label}</span>
      <strong>{value}</strong>
    </SettingsCard>
  )
}

function TokenRows({ usage }: { usage: UsageByProvider }): JSX.Element {
  const t = useT()
  return (
    <dl className="settings-usage-token-rows">
      <div>
        <dt>{t('settings.usage.tokens.input')}</dt>
        <dd>{formatTokens(usage.inputTokens)}</dd>
      </div>
      <div>
        <dt>{t('settings.usage.tokens.output')}</dt>
        <dd>{formatTokens(usage.outputTokens)}</dd>
      </div>
      <div>
        <dt>{t('settings.usage.tokens.cacheRead')}</dt>
        <dd>{formatTokens(usage.cacheReadTokens)}</dd>
      </div>
    </dl>
  )
}

function ProviderUsageCard({
  provider,
  usage
}: {
  provider: AgentProvider
  usage: UsageByProvider | undefined
}): JSX.Element {
  const t = useT()
  const hasUsage = usage !== undefined && usage.turns > 0
  return (
    <SettingsCard className="settings-usage-provider-card">
      <div className="settings-usage-provider-heading">
        <ProviderMark provider={provider} size={32} />
        <div>
          <h2>{t(providerNameKey(provider))}</h2>
          <span>{usage?.model ?? t('settings.usage.model.none')}</span>
        </div>
      </div>
      {!hasUsage ? (
        <span className="status-pill settings-usage-empty">
          {t('settings.usage.provider.empty')}
        </span>
      ) : (
        <>
          <TokenRows usage={usage} />
          <div className="settings-usage-provider-footer">
            <span>
              {t('settings.usage.provider.activity', {
                sessions: usage.sessions,
                turns: usage.turns
              })}
            </span>
            {usage.lastUsedAt !== null && (
              <time dateTime={usage.lastUsedAt}>
                {t('settings.usage.provider.lastUsed', {
                  time: formatRelative(usage.lastUsedAt, Date.now())
                })}
              </time>
            )}
          </div>
        </>
      )}
    </SettingsCard>
  )
}

function UsageContent({ summary }: { summary: UsageSummary }): JSX.Element {
  const t = useT()
  return (
    <>
      <SummaryTiles summary={summary} />
      <section aria-labelledby="settings-usage-providers-title">
        <h2
          id="settings-usage-providers-title"
          className="settings-usage-section-title"
        >
          {t('settings.usage.providers.title')}
        </h2>
        <div className="settings-usage-provider-grid">
          {AGENT_PROVIDERS.map((provider) => (
            <ProviderUsageCard
              key={provider}
              provider={provider}
              usage={summary.byProvider.find(
                (item) => item.provider === provider
              )}
            />
          ))}
        </div>
      </section>
    </>
  )
}

export function UsagePanel(): JSX.Element {
  const t = useT()
  const [windowDays, setWindowDays] = useState<UsageWindowDays>(30)
  const [summary, setSummary] = useState<UsageSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [retryKey, setRetryKey] = useState(0)

  useEffect(() => {
    let active = true
    setLoading(true)
    setFailed(false)
    void invoke('usage:summary', { windowDays })
      .then((result) => {
        if (active) setSummary(result)
      })
      .catch(() => {
        if (active) setFailed(true)
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => {
      active = false
    }
  }, [retryKey, windowDays])

  return (
    <div className="settings-stack">
      <WindowSelect value={windowDays} onChange={setWindowDays} />
      {loading ? (
        <UsageLoading />
      ) : failed || summary === null ? (
        <div className="inline-notice settings-usage-error" role="alert">
          <div>
            <strong>{t('settings.usage.loadFailed')}</strong>
          </div>
          <button
            type="button"
            className="secondary-button"
            onClick={() => setRetryKey((current) => current + 1)}
          >
            {t('settings.usage.retry')}
          </button>
        </div>
      ) : (
        <UsageContent summary={summary} />
      )}
    </div>
  )
}
