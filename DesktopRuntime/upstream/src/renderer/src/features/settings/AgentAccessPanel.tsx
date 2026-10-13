import { useEffect, useSyncExternalStore } from 'react'
import { useLocale, useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import './agent-access.css'

export interface AgentBrowserGrant {
  id: string
  courseId: string
  origin: string
  capability: 'read' | 'interact' | 'download'
  createdAt: string
  expiresAt: string
  revokedAt: string | null
  lastUsedAt: string | null
}

export interface AgentAuditEntry {
  id: string
  action: string
  url: string
  detail: string
  createdAt: string
}

interface BrowserAccessSnapshot {
  grants: AgentBrowserGrant[] | null
  entries: AgentAuditEntry[] | null
  loading: boolean
  error: boolean
  busyId: string | null
}

interface ToolGrantRow {
  id: string
  courseId: string
  courseName: string
  rule: string
  createdAt: string
}

interface ToolGrantsSnapshot {
  grants: ToolGrantRow[] | null
  loading: boolean
  error: boolean
  busyId: string | null
}

const INITIAL_BROWSER_ACCESS: BrowserAccessSnapshot = {
  grants: null,
  entries: null,
  loading: false,
  error: false,
  busyId: null
}

const INITIAL_TOOL_GRANTS: ToolGrantsSnapshot = {
  grants: null,
  loading: false,
  error: false,
  busyId: null
}

let browserAccessSnapshot = INITIAL_BROWSER_ACCESS
let browserAccessLoadGeneration = 0
const browserAccessListeners = new Set<() => void>()
let toolGrantsSnapshot = INITIAL_TOOL_GRANTS
let toolGrantsLoadGeneration = 0
const toolGrantsListeners = new Set<() => void>()

function publishBrowserAccess(next: BrowserAccessSnapshot): void {
  browserAccessSnapshot = next
  for (const listener of browserAccessListeners) listener()
}

function publishToolGrants(next: ToolGrantsSnapshot): void {
  toolGrantsSnapshot = next
  for (const listener of toolGrantsListeners) listener()
}

function subscribeBrowserAccess(listener: () => void): () => void {
  browserAccessListeners.add(listener)
  return () => browserAccessListeners.delete(listener)
}

function subscribeToolGrants(listener: () => void): () => void {
  toolGrantsListeners.add(listener)
  return () => toolGrantsListeners.delete(listener)
}

export async function loadAgentBrowserAccess(): Promise<void> {
  const generation = ++browserAccessLoadGeneration
  publishBrowserAccess({ ...browserAccessSnapshot, loading: true, error: false })
  try {
    const [grantResult, auditResult] = await Promise.all([
      invoke('browserAgent:grants', {}),
      invoke('browserAgent:auditTail', { courseId: null, limit: 50 })
    ])
    if (generation !== browserAccessLoadGeneration) return
    publishBrowserAccess({
      grants: grantResult.grants,
      entries: auditResult.entries,
      loading: false,
      error: false,
      busyId: null
    })
  } catch {
    if (generation !== browserAccessLoadGeneration) return
    publishBrowserAccess({
      ...browserAccessSnapshot,
      loading: false,
      error: true,
      busyId: null
    })
  }
}

export async function loadAgentToolGrants(): Promise<void> {
  const generation = ++toolGrantsLoadGeneration
  publishToolGrants({ ...toolGrantsSnapshot, loading: true, error: false })
  try {
    const courses = await invoke('courses:list', { includeArchived: true })
    const grants = (
      await Promise.all(
        courses.map(async (course) => {
          const result = await invoke('chat:grants', { courseId: course.id })
          return result.grants.map((grant) => ({
            ...grant,
            courseId: course.id,
            courseName: course.name
          }))
        })
      )
    ).flat()
    if (generation !== toolGrantsLoadGeneration) return
    publishToolGrants({ grants, loading: false, error: false, busyId: null })
  } catch {
    if (generation !== toolGrantsLoadGeneration) return
    publishToolGrants({ grants: [], loading: false, error: true, busyId: null })
  }
}

async function revokeBrowserGrant(id: string): Promise<void> {
  publishBrowserAccess({ ...browserAccessSnapshot, busyId: id, error: false })
  try {
    await invoke('browserAgent:revokeGrant', { id })
    await loadAgentBrowserAccess()
  } catch {
    publishBrowserAccess({ ...browserAccessSnapshot, error: true, busyId: null })
  }
}

export async function revokeAgentToolGrant(id: string): Promise<void> {
  publishToolGrants({ ...toolGrantsSnapshot, busyId: id, error: false })
  try {
    await invoke('chat:revokeGrant', { id })
    await loadAgentToolGrants()
  } catch {
    publishToolGrants({ ...toolGrantsSnapshot, error: true, busyId: null })
  }
}

export function resetAgentAccessPanelForTests(): void {
  browserAccessLoadGeneration += 1
  toolGrantsLoadGeneration += 1
  publishBrowserAccess(INITIAL_BROWSER_ACCESS)
  publishToolGrants(INITIAL_TOOL_GRANTS)
}

/** Backwards-compatible test seam for the existing tool-grant tests. */
export function resetAgentToolGrantsForTests(): void {
  resetAgentAccessPanelForTests()
}

export function AgentToolGrantRevokeButton({
  grantId,
  disabled,
  label
}: {
  grantId: string
  disabled: boolean
  label: string
}): JSX.Element {
  return (
    <button
      type="button"
      className="settings-site-row__action"
      disabled={disabled}
      onClick={() => void revokeAgentToolGrant(grantId)}
    >
      {label}
    </button>
  )
}

function day(iso: string): string {
  return iso.slice(0, 10)
}

function urlParts(value: string): { host: string; path: string | null } {
  if (value === '') return { host: '', path: null }
  try {
    const url = new URL(value)
    return { host: url.host, path: url.pathname === '/' ? null : url.pathname }
  } catch {
    return { host: value, path: null }
  }
}

type EmptyStateIcon = 'shield' | 'checklist' | 'clock'

function EmptyState({
  label,
  icon
}: {
  label: string
  icon: EmptyStateIcon
}): JSX.Element {
  return (
    <div className="settings-agent-empty">
      <svg viewBox="0 0 24 24" aria-hidden="true" data-empty-icon={icon}>
        {icon === 'shield' ? (
          <path d="M12 3 19 6v5c0 4.5-2.8 7.7-7 9-4.2-1.3-7-4.5-7-9V6Z" />
        ) : icon === 'checklist' ? (
          <>
            <path d="m4 7 1.5 1.5L8 6M10 7h10M4 12l1.5 1.5L8 11M10 12h10M4 17l1.5 1.5L8 16M10 17h10" />
          </>
        ) : (
          <>
            <circle cx="12" cy="12" r="8" />
            <path d="M12 7v5l3 2" />
          </>
        )}
      </svg>
      <span>{label}</span>
    </div>
  )
}

function AuditIcon({ action }: { action: string }): JSX.Element {
  const path =
    action === 'read'
      ? 'M7 4h8l3 3v13H7z M15 4v4h4 M10 12h5 M10 16h5'
      : action === 'snapshot'
        ? 'M4 7h3l1.5-2h7L17 7h3v11H4z M9 12a3 3 0 1 0 6 0 3 3 0 0 0-6 0'
        : action === 'denied'
          ? 'M12 3 20 7v5c0 4.5-3.2 7.5-8 9-4.8-1.5-8-4.5-8-9V7z M9 9l6 6 M15 9l-6 6'
          : 'M5 12h12 M13 8l4 4-4 4'
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d={path} />
    </svg>
  )
}

function auditMessage(
  entry: AgentAuditEntry,
  locale: string,
  t: (key: string, vars?: Record<string, string | number>) => string
): string {
  const { host } = urlParts(entry.url)
  const body = /본문\s+(\d+)자/u.exec(entry.detail)
  if (entry.action === 'read' && body !== null) {
    return t('settings.agentAccess.audit.readBody', {
      host,
      count: new Intl.NumberFormat(locale).format(Number(body[1]))
    })
  }
  const tabs = /탭\s+(\d+)개/u.exec(entry.detail)
  if (entry.action === 'snapshot' && tabs !== null) {
    return t('settings.agentAccess.audit.tabs', { count: Number(tabs[1]) })
  }
  const clicked = /^click\s+([^\s]+)/u.exec(entry.detail)
  if (entry.action === 'navigate' && clicked !== null) {
    return t('settings.agentAccess.audit.clicked', {
      host,
      element: clicked[1] ?? ''
    })
  }
  return t('settings.agentAccess.audit.generic', {
    host,
    action: t(`settings.agentAccess.audit.action.${entry.action}`)
  })
}

export function AgentSiteGrantGroups({
  grants,
  busyId,
  onRevoke
}: {
  grants: AgentBrowserGrant[]
  busyId: string | null
  onRevoke: (id: string) => void
}): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const grouped = new Map<string, AgentBrowserGrant[]>()
  for (const grant of grants) {
    const host = urlParts(grant.origin).host
    grouped.set(host, [...(grouped.get(host) ?? []), grant])
  }

  return (
    <div className="settings-agent-hosts">
      {[...grouped.entries()].map(([host, hostGrants]) => (
        <article className="settings-agent-host" key={host}>
          <strong>{host}</strong>
          <div className="settings-agent-host__chips">
            {hostGrants.map((grant) => {
              const expires = new Intl.DateTimeFormat(locale, {
                month: 'long',
                day: 'numeric'
              }).format(new Date(grant.expiresAt))
              return (
                <span className="settings-agent-capability" key={grant.id}>
                  <span>{t(`settings.agentAccess.capability.${grant.capability}`)}</span>
                  <small>{t('settings.agentAccess.expires', { date: expires })}</small>
                  <button
                    type="button"
                    disabled={busyId !== null}
                    aria-label={t('settings.agentAccess.revokeGrant', {
                      host,
                      capability: t(
                        `settings.agentAccess.capability.${grant.capability}`
                      )
                    })}
                    onClick={() => onRevoke(grant.id)}
                  >
                    ×
                  </button>
                </span>
              )
            })}
          </div>
        </article>
      ))}
    </div>
  )
}

export function AgentAuditTimeline({
  entries
}: {
  entries: AgentAuditEntry[]
}): JSX.Element {
  const t = useT()
  const locale = useLocale()
  const groups = new Map<string, AgentAuditEntry[]>()
  for (const entry of entries) {
    groups.set(day(entry.createdAt), [
      ...(groups.get(day(entry.createdAt)) ?? []),
      entry
    ])
  }

  return (
    <div className="settings-agent-timeline">
      {[...groups.entries()].map(([date, dateEntries]) => (
        <section className="settings-agent-timeline__day" key={date}>
          <h3>
            {new Intl.DateTimeFormat(locale, {
              month: 'long',
              day: 'numeric',
              weekday: 'short'
            }).format(new Date(`${date}T00:00:00`))}
          </h3>
          <ol>
            {dateEntries.map((entry) => {
              const { path } = urlParts(entry.url)
              return (
                <li key={entry.id}>
                  <span className="settings-agent-timeline__icon">
                    <AuditIcon action={entry.action} />
                  </span>
                  <div>
                    <p>{auditMessage(entry, locale, t)}</p>
                    {path !== null && (
                      <span className="settings-agent-timeline__path">{path}</span>
                    )}
                  </div>
                  <time dateTime={entry.createdAt}>
                    {new Intl.DateTimeFormat(locale, {
                      timeStyle: 'short'
                    }).format(new Date(entry.createdAt))}
                  </time>
                </li>
              )
            })}
          </ol>
        </section>
      ))}
    </div>
  )
}

export function AgentAccessPanel(): JSX.Element {
  const t = useT()
  const browserState = useSyncExternalStore(
    subscribeBrowserAccess,
    () => browserAccessSnapshot,
    () => browserAccessSnapshot
  )
  const toolState = useSyncExternalStore(
    subscribeToolGrants,
    () => toolGrantsSnapshot,
    () => toolGrantsSnapshot
  )

  useEffect(() => {
    void loadAgentBrowserAccess()
    void loadAgentToolGrants()
  }, [])

  const now = new Date().toISOString()
  const live = (browserState.grants ?? []).filter(
    (grant) => grant.revokedAt === null && grant.expiresAt > now
  )
  const pastCount = (browserState.grants?.length ?? 0) - live.length

  return (
    <div className="settings-stack">
      <section className="settings-card settings-agent-card">
        <div className="settings-card__header">
          <h2>{t('settings.agentAccess.title')}</h2>
          <p>{t('settings.agentAccess.description')}</p>
        </div>
        {browserState.loading && browserState.grants === null ? (
          <p className="settings-feedback">{t('settings.agentAccess.loading')}</p>
        ) : browserState.error && browserState.grants === null ? (
          <p className="settings-feedback" role="alert">
            {t('settings.agentAccess.loadFailed')}
          </p>
        ) : live.length === 0 ? (
          <EmptyState label={t('settings.agentAccess.empty')} icon="shield" />
        ) : (
          <AgentSiteGrantGroups
            grants={live}
            busyId={browserState.busyId}
            onRevoke={(id) => void revokeBrowserGrant(id)}
          />
        )}
        {pastCount > 0 && (
          <p className="settings-agent-past">
            {t('settings.agentAccess.past', { count: pastCount })}
          </p>
        )}
      </section>

      <section className="settings-card settings-agent-card">
        <div className="settings-card__header">
          <h2>{t('settings.agentAccess.toolGrants.title')}</h2>
          <p>{t('settings.agentAccess.toolGrants.description')}</p>
        </div>
        {toolState.loading && toolState.grants === null ? (
          <p className="settings-feedback">
            {t('settings.agentAccess.toolGrants.loading')}
          </p>
        ) : toolState.error ? (
          <p className="settings-feedback" role="alert">
            {t('settings.agentAccess.toolGrants.loadFailed')}
          </p>
        ) : toolState.grants?.length === 0 ? (
          <EmptyState
            label={t('settings.agentAccess.toolGrants.empty')}
            icon="checklist"
          />
        ) : (
          <ul className="settings-agent-tool-list">
            {toolState.grants?.map((grant) => (
              <li key={grant.id}>
                <div>
                  <strong>{grant.courseName}</strong>
                  <span>{grant.rule}</span>
                  <small>
                    {t('settings.agentAccess.toolGrants.createdAt', {
                      date: day(grant.createdAt)
                    })}
                  </small>
                </div>
                <AgentToolGrantRevokeButton
                  grantId={grant.id}
                  disabled={toolState.busyId !== null}
                  label={t('settings.agentAccess.toolGrants.revoke')}
                />
              </li>
            ))}
          </ul>
        )}
      </section>

      <section className="settings-card settings-agent-card">
        <div className="settings-card__header">
          <h2>{t('settings.agentAccess.audit.title')}</h2>
          <p>{t('settings.agentAccess.audit.description')}</p>
        </div>
        {browserState.loading && browserState.entries === null ? (
          <p className="settings-feedback">{t('settings.agentAccess.loading')}</p>
        ) : browserState.error && browserState.entries === null ? (
          <p className="settings-feedback" role="alert">
            {t('settings.agentAccess.loadFailed')}
          </p>
        ) : browserState.entries?.length === 0 ? (
          <EmptyState
            label={t('settings.agentAccess.audit.empty')}
            icon="clock"
          />
        ) : browserState.entries !== null ? (
          <AgentAuditTimeline entries={browserState.entries} />
        ) : null}
      </section>
    </div>
  )
}
