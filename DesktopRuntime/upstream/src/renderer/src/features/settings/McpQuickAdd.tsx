import { useMemo, useState } from 'react'
import type { McpServerSummary } from '../../../../shared/types/mcp'
import { useT } from '../../i18n'
import { invoke } from '../../lib/ipc'
import { parseMcpConfigText } from './mcpImport'

import { MCP_PRESETS, type McpPreset } from './mcpPresets'

type SaveState = 'idle' | 'saving' | 'saved' | 'error'

function PresetCard({
  preset,
  available,
  onSaved
}: {
  preset: McpPreset
  available: boolean
  onSaved: (server: McpServerSummary) => void
}): JSX.Element {
  const t = useT()
  const [values, setValues] = useState<Record<string, string>>({})
  const [state, setState] = useState<SaveState>('idle')
  const complete = preset.fields.every(
    (field) => (values[field.key] ?? '').trim() !== ''
  )

  const add = (): void => {
    if (!available || !complete || state === 'saving') return
    setState('saving')
    const input = preset.input(t(preset.descriptionKey), values)
    void invoke('mcp:save', input).then(
      ({ server }) => {
        onSaved(server)
        setState('saved')
      },
      () => setState('error')
    )
  }

  return (
    <article className="settings-mcp-preset">
      <div className="settings-mcp-preset__copy">
        <h3>{preset.name}</h3>
        <code>{preset.packageName}</code>
        <p>{t(preset.descriptionKey)}</p>
      </div>
      <div className="settings-mcp-preset__fields">
        {preset.fields.map((field) => (
          <label key={field.key}>
            <span>{t(field.labelKey)}</span>
            <input
              type={field.secret === true ? 'password' : 'text'}
              autoComplete="off"
              value={values[field.key] ?? ''}
              placeholder={field.placeholder}
              onChange={(event) => {
                const value = event.target.value
                setValues((current) => ({ ...current, [field.key]: value }))
                setState('idle')
              }}
            />
          </label>
        ))}
      </div>
      <div className="settings-mcp-preset__action">
        <button
          type="button"
          className="settings-mcp-button settings-mcp-button--primary"
          disabled={!available || !complete || state === 'saving'}
          onClick={add}
        >
          {t(
            state === 'saving'
              ? 'settings.mcp.action.saving'
              : state === 'saved'
                ? 'settings.mcp.quick.saved'
                : 'settings.mcp.quick.add'
          )}
        </button>
        {state === 'error' && (
          <span className="settings-mcp-feedback settings-feedback--error" role="alert">
            {t('settings.mcp.error.save')}
          </span>
        )}
      </div>
    </article>
  )
}

export function McpQuickAdd({
  available,
  onSaved
}: {
  available: boolean
  onSaved: (server: McpServerSummary) => void
}): JSX.Element {
  const t = useT()
  const [text, setText] = useState('')
  const [saving, setSaving] = useState(false)
  const [feedback, setFeedback] = useState<string | null>(null)
  const parsed = useMemo(() => parseMcpConfigText(text), [text])

  const addImported = (): void => {
    if (
      saving ||
      !available ||
      parsed.servers.length === 0 ||
      parsed.errors.length > 0
    ) {
      return
    }
    setSaving(true)
    setFeedback(null)
    void Promise.allSettled(
      parsed.servers.map((server) => invoke('mcp:save', server))
    ).then((results) => {
      let failures = 0
      results.forEach((result) => {
        if (result.status === 'fulfilled') onSaved(result.value.server)
        else failures += 1
      })
      if (failures > 0) {
        setFeedback(t('settings.mcp.import.saveFailed', { count: failures }))
      } else {
        setFeedback(
          t('settings.mcp.import.saved', { count: parsed.servers.length })
        )
        setText('')
      }
    }).finally(() => setSaving(false))
  }

  return (
    <>
      <section className="settings-mcp-card settings-mcp-import">
        <header className="settings-mcp-card-header">
          <div>
            <h2>{t('settings.mcp.import.title')}</h2>
            <p>{t('settings.mcp.import.description')}</p>
          </div>
        </header>
        <div className="settings-mcp-card-body">
          <label className="settings-mcp-field">
            <span>{t('settings.mcp.import.label')}</span>
            <textarea
              rows={7}
              spellCheck={false}
              value={text}
              placeholder={'{\n  "mcpServers": { ... }\n}'}
              onChange={(event) => {
                setText(event.target.value)
                setFeedback(null)
              }}
            />
          </label>

          {parsed.servers.length > 0 && (
            <div className="settings-mcp-import__preview">
              <strong>{t('settings.mcp.import.preview')}</strong>
              <ul>
                {parsed.servers.map((server) => (
                  <li key={server.name}>
                    <span>{server.name}</span>
                    <span className="settings-mcp-badge">{server.transport}</span>
                    <code>{server.command ?? server.url}</code>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {parsed.errors.length > 0 && (
            <ul className="settings-mcp-import__errors" role="alert">
              {parsed.errors.map((error) => <li key={error}>{error}</li>)}
            </ul>
          )}

          <div className="settings-mcp-import__actions">
            <button
              type="button"
              className="settings-mcp-button settings-mcp-button--primary"
              disabled={
                !available ||
                saving ||
                parsed.servers.length === 0 ||
                parsed.errors.length > 0
              }
              onClick={addImported}
            >
              {t(
                saving
                  ? 'settings.mcp.action.saving'
                  : 'settings.mcp.import.addAll',
                { count: parsed.servers.length }
              )}
            </button>
            {feedback !== null && (
              <span className="settings-mcp-feedback" role="status">
                {feedback}
              </span>
            )}
          </div>
        </div>
      </section>

      <section className="settings-mcp-card settings-mcp-gallery">
        <header className="settings-mcp-card-header">
          <div>
            <h2>{t('settings.mcp.gallery.title')}</h2>
            <p>{t('settings.mcp.gallery.description')}</p>
          </div>
        </header>
        <div className="settings-mcp-gallery__grid">
          {MCP_PRESETS.map((preset) => (
            <PresetCard
              key={preset.id}
              preset={preset}
              available={available}
              onSaved={onSaved}
            />
          ))}
        </div>
      </section>
    </>
  )
}
