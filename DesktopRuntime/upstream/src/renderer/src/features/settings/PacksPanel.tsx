import { useEffect, useMemo, useState, useSyncExternalStore } from 'react'
import type { WorkflowPack, WorkflowPackSummary } from '../../../../shared/types/workflowPack'
import { useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { parsePackImportText } from './packImport'
import './settings-packs.css'
import { resetWorkflowPacksStoreForTests, useWorkflowPacksStore } from '../../stores/workflowPacksStore'

export async function loadPacks(): Promise<void> {
  await useWorkflowPacksStore.getState().refresh()
}

export function resetPacksPanelForTests(): void {
  resetWorkflowPacksStoreForTests()
}

function PackBadges({ pack }: { pack: WorkflowPack }): JSX.Element {
  const t = useT()
  return (
    <div className="settings-pack-badges">
      {pack.allowedTools.map((tool) => (
        <span className="settings-pack-chip" key={tool}>{tool}</span>
      ))}
      {pack.usesWeb && (
        <span className="settings-pack-badge settings-pack-badge--web">
          {t('settings.packs.web')}
        </span>
      )}
    </div>
  )
}

function PackCard({
  summary,
  expanded,
  pending,
  onExpand,
  onToggle,
  onRemove,
  onExport
}: {
  summary: WorkflowPackSummary
  expanded: boolean
  pending: boolean
  onExpand: () => void
  onToggle: (enabled: boolean) => void
  onRemove: () => void
  onExport: () => void
}): JSX.Element {
  const t = useT()
  const { pack } = summary
  const userPack = summary.source === 'user'

  return (
    <article className="settings-pack-card">
      <div className="settings-pack-card__top">
        <button
          type="button"
          className="settings-pack-card__summary"
          aria-expanded={expanded}
          aria-controls={`pack-details-${pack.id}`}
          onClick={onExpand}
        >
          <span className="settings-pack-card__copy">
            <strong>{pack.name}</strong>
            <span>{pack.description}</span>
            <small>{`v${pack.version} · ${pack.author}`}</small>
          </span>
          <span className="settings-pack-card__chevron" aria-hidden="true">⌄</span>
        </button>
        <div className="settings-pack-card__controls">
          {userPack && (
            <>
              <button type="button" className="settings-pack-button" disabled={pending} onClick={onExport}>
                {t('settings.packs.export')}
              </button>
              <button type="button" className="settings-pack-button" disabled={pending} onClick={onRemove}>
                {t('settings.packs.remove')}
              </button>
            </>
          )}
          <button
            type="button"
            role="switch"
            aria-label={t('settings.packs.enabledLabel', { name: pack.name })}
            aria-checked={summary.enabled}
            className={`settings-pack-switch${summary.enabled ? ' settings-pack-switch--checked' : ''}`}
            disabled={pending}
            onClick={() => onToggle(!summary.enabled)}
          >
            <span />
          </button>
        </div>
      </div>

      {expanded && (
        <div className="settings-pack-card__details" id={`pack-details-${pack.id}`}>
          <div>
            <span className="settings-pack-detail-label">{t('settings.packs.tools')}</span>
            <PackBadges pack={pack} />
          </div>
          <dl className="settings-pack-metadata">
            <div>
              <dt>{t('settings.packs.outputDir')}</dt>
              <dd><code>{pack.outputs.dir}</code></dd>
            </div>
            {pack.followUp !== undefined && (
              <div>
                <dt>{t('settings.packs.followUp')}</dt>
                <dd>{pack.followUp.label}</dd>
              </div>
            )}
          </dl>
          <div>
            <span className="settings-pack-detail-label">{t('settings.packs.recipe')}</span>
            <pre>{pack.recipe}</pre>
          </div>
        </div>
      )}
    </article>
  )
}

function PackSection({
  title,
  packs,
  empty,
  expandedIds,
  pendingId,
  onExpand,
  onToggle,
  onRemove,
  onExport
}: {
  title: string
  packs: WorkflowPackSummary[]
  empty: string
  expandedIds: ReadonlySet<string>
  pendingId: string | null
  onExpand: (id: string) => void
  onToggle: (summary: WorkflowPackSummary, enabled: boolean) => void
  onRemove: (summary: WorkflowPackSummary) => void
  onExport: (summary: WorkflowPackSummary) => void
}): JSX.Element {
  return (
    <section className="settings-packs-section">
      <h2>{title}</h2>
      {packs.length === 0 ? (
        <p className="settings-packs-empty">{empty}</p>
      ) : (
        <div className="settings-packs-list">
          {packs.map((summary) => (
            <PackCard
              key={summary.pack.id}
              summary={summary}
              expanded={expandedIds.has(summary.pack.id)}
              pending={pendingId === summary.pack.id}
              onExpand={() => onExpand(summary.pack.id)}
              onToggle={(enabled) => onToggle(summary, enabled)}
              onRemove={() => onRemove(summary)}
              onExport={() => onExport(summary)}
            />
          ))}
        </div>
      )}
    </section>
  )
}

export function ImportDialog({ onClose }: { onClose: () => void }): JSX.Element {
  const t = useT()
  const [text, setText] = useState('')
  const [saving, setSaving] = useState(false)
  const [feedback, setFeedback] = useState<string | null>(null)
  const parsed = useMemo(() => parsePackImportText(text), [text])

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent): void => {
      if (event.key === 'Escape' && !saving) onClose()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [onClose, saving])

  const importPack = (): void => {
    if (saving || parsed.pack === undefined) return
    setSaving(true)
    setFeedback(null)
    void invoke('packs:importText', { json: text })
      .then(() => loadPacks())
      .then(onClose)
      .catch(() => setFeedback(t('settings.packs.error.import')))
      .finally(() => setSaving(false))
  }

  return (
    <div className="settings-pack-modal" role="presentation" onPointerDown={(event) => {
      if (event.target === event.currentTarget && !saving) onClose()
    }}>
      <section className="settings-pack-dialog" role="dialog" aria-modal="true" aria-labelledby="pack-import-title">
        <header>
          <div>
            <h2 id="pack-import-title">{t('settings.packs.import.title')}</h2>
            <p>{t('settings.packs.import.description')}</p>
          </div>
          <button type="button" className="settings-pack-button" disabled={saving} onClick={onClose}>
            {t('settings.packs.cancel')}
          </button>
        </header>
        <label className="settings-pack-import-field">
          <span>{t('settings.packs.import.label')}</span>
          <textarea
            rows={10}
            spellCheck={false}
            value={text}
            placeholder={'{\n  "schemaVersion": 1,\n  ...\n}'}
            onChange={(event) => {
              setText(event.target.value)
              setFeedback(null)
            }}
          />
        </label>
        {parsed.pack !== undefined && (
          <div className="settings-pack-import-preview">
            <strong>{parsed.pack.name}</strong>
            <PackBadges pack={parsed.pack} />
          </div>
        )}
        {parsed.errors.length > 0 && (
          <ul className="settings-pack-errors" role="alert">
            {parsed.errors.map((error) => <li key={error}>{error}</li>)}
          </ul>
        )}
        {feedback !== null && <p className="settings-pack-feedback" role="alert">{feedback}</p>}
        <footer>
          <button
            type="button"
            className="settings-pack-button settings-pack-button--primary"
            disabled={saving || parsed.pack === undefined}
            onClick={importPack}
          >
            {t(saving ? 'settings.packs.import.importing' : 'settings.packs.import.confirm')}
          </button>
        </footer>
      </section>
    </div>
  )
}

export function PacksPanel({
  initialExpandedIds = []
}: {
  initialExpandedIds?: readonly string[]
} = {}): JSX.Element {
  const t = useT()
  const registry = useSyncExternalStore(useWorkflowPacksStore.subscribe, useWorkflowPacksStore.getState, useWorkflowPacksStore.getState)
  const [expandedIds, setExpandedIds] = useState<ReadonlySet<string>>(
    () => new Set(initialExpandedIds)
  )
  const [pendingId, setPendingId] = useState<string | null>(null)
  const [importOpen, setImportOpen] = useState(false)
  const [feedback, setFeedback] = useState<string | null>(null)

  useEffect(() => {
    void loadPacks()
  }, [])

  const builtin = registry.packs.filter((summary) => summary.source === 'builtin')
  const installed = registry.packs.filter((summary) => summary.source === 'user')

  const toggle = (summary: WorkflowPackSummary, enabled: boolean): void => {
    if (pendingId !== null) return
    setPendingId(summary.pack.id)
    setFeedback(null)
    void registry.setEnabled(summary.pack.id, enabled)
      .catch(() => setFeedback(t('settings.packs.error.toggle')))
      .finally(() => setPendingId(null))
  }

  const remove = (summary: WorkflowPackSummary): void => {
    if (pendingId !== null) return
    setPendingId(summary.pack.id)
    setFeedback(null)
    void registry.remove(summary.pack.id)
      .catch(() => setFeedback(t('settings.packs.error.remove')))
      .finally(() => setPendingId(null))
  }

  const exportPack = (summary: WorkflowPackSummary): void => {
    setFeedback(null)
    if (navigator.clipboard === undefined) {
      setFeedback(t('settings.packs.error.export'))
      return
    }
    void navigator.clipboard.writeText(JSON.stringify(summary.pack, null, 2))
      .then(() => setFeedback(t('settings.packs.exported')))
      .catch(() => setFeedback(t('settings.packs.error.export')))
  }

  const sectionProps = {
    expandedIds,
    pendingId,
    onExpand: (id: string) => setExpandedIds((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    }),
    onToggle: toggle,
    onRemove: remove,
    onExport: exportPack
  }

  return (
    <div className="settings-packs-stack">
      <div className="settings-packs-toolbar">
        <p>{t('settings.packs.notice')}</p>
        <button type="button" className="settings-pack-button settings-pack-button--primary" onClick={() => setImportOpen(true)}>
          {t('settings.packs.import.button')}
        </button>
      </div>

      {registry.loading && registry.packs.length === 0 ? (
        <p className="settings-packs-state">{t('settings.packs.loading')}</p>
      ) : registry.error && registry.packs.length === 0 ? (
        <div className="settings-packs-state">
          <span>{t('settings.packs.error.load')}</span>
          <button type="button" className="settings-pack-button" onClick={() => void loadPacks()}>{t('settings.packs.retry')}</button>
        </div>
      ) : (
        <>
          <PackSection title={t('settings.packs.builtin')} packs={builtin} empty={t('settings.packs.builtin.empty')} {...sectionProps} />
          <PackSection title={t('settings.packs.installed')} packs={installed} empty={t('settings.packs.installed.empty')} {...sectionProps} />
        </>
      )}

      {feedback !== null && <p className="settings-pack-feedback" role="status">{feedback}</p>}
      {registry.error && registry.packs.length > 0 && (
        <p className="settings-pack-feedback" role="alert">
          {t('settings.packs.error.load')}
        </p>
      )}
      {importOpen && <ImportDialog onClose={() => setImportOpen(false)} />}
    </div>
  )
}
