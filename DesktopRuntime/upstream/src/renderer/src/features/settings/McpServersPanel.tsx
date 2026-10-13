import { useEffect, useState, useSyncExternalStore } from 'react'
import type { FormEvent } from 'react'
import type { McpAvailability, McpServerInput, McpServerSummary, McpTestResult, McpTransport } from '../../../../shared/types/mcp'
import { MCP_SERVER_NAME_PATTERN } from '../../../../shared/types/mcp'
import { useT } from '../../i18n'
import { invoke, onPush } from '../../lib/ipc'
import { McpQuickAdd } from './McpQuickAdd'
import './settings-mcp.css'
interface RegistrySnapshot {
  servers: McpServerSummary[]
  availability: McpAvailability | null
  loading: boolean
  error: boolean
}

const INITIAL_REGISTRY_SNAPSHOT: RegistrySnapshot = {
  servers: [],
  availability: null,
  loading: true,
  error: false
}

let registrySnapshot = INITIAL_REGISTRY_SNAPSHOT
let loadGeneration = 0
const registryListeners = new Set<() => void>()
function publishRegistry(next: RegistrySnapshot): void {
  registrySnapshot = next
  for (const listener of registryListeners) listener()
}

function subscribeRegistry(listener: () => void): () => void {
  registryListeners.add(listener)
  return () => registryListeners.delete(listener)
}

function getRegistrySnapshot(): RegistrySnapshot {
  return registrySnapshot
}

function updateServer(server: McpServerSummary): void {
  const exists = registrySnapshot.servers.some((item) => item.id === server.id)
  publishRegistry({
    ...registrySnapshot,
    servers: exists
      ? registrySnapshot.servers.map((item) =>
          item.id === server.id ? server : item
        )
      : [...registrySnapshot.servers, server]
  })
}

function removeServer(id: string): void {
  publishRegistry({
    ...registrySnapshot,
    servers: registrySnapshot.servers.filter((server) => server.id !== id)
  })
}

function updateTestResult(id: string, result: McpTestResult): void {
  const at = new Date().toISOString()
  const lastTest =
    result.error === undefined
      ? { at, ok: result.ok, tools: result.tools }
      : { at, ok: result.ok, tools: result.tools, error: result.error }

  publishRegistry({
    ...registrySnapshot,
    servers: registrySnapshot.servers.map((server) =>
      server.id === id ? { ...server, lastTest } : server
    )
  })
}

export async function loadMcpServers(): Promise<void> {
  const generation = ++loadGeneration
  publishRegistry({ ...registrySnapshot, loading: true, error: false })
  try {
    const result = await invoke('mcp:list', {})
    if (generation !== loadGeneration) return
    publishRegistry({
      servers: result.servers,
      availability: result.availability,
      loading: false,
      error: false
    })
  } catch {
    if (generation !== loadGeneration) return
    publishRegistry({ ...registrySnapshot, loading: false, error: true })
  }
}

export function resetMcpServersPanelForTests(): void {
  loadGeneration += 1
  publishRegistry(INITIAL_REGISTRY_SNAPSHOT)
}

export function summaryInput(server: McpServerSummary, enabled: boolean): McpServerInput {
  const input: McpServerInput = {
    id: server.id,
    name: server.name,
    description: server.description,
    transport: server.transport,
    enabled
  }
  if (server.command !== undefined) input.command = server.command
  if (server.args !== undefined) input.args = server.args
  if (server.url !== undefined) input.url = server.url
  return input
}

function LastTest({ server }: { server: McpServerSummary }): JSX.Element {
  const t = useT()
  if (server.lastTest === undefined) {
    return (
      <span className="settings-mcp-status settings-mcp-status--unknown">
        {t('settings.mcp.status.untested')}
      </span>
    )
  }
  if (!server.lastTest.ok) {
    return (
      <span className="settings-mcp-status settings-mcp-status--error">
        {t('settings.mcp.status.error')}
      </span>
    )
  }
  return (
    <span className="settings-mcp-status settings-mcp-status--ok">
      {t('settings.mcp.status.tools', { count: server.lastTest.tools.length })}
    </span>
  )
}

interface SecretRow {
  id: number
  key: string
  value: string
  existing: boolean
  changing: boolean
}

let nextSecretRowId = 1

function existingSecretRows(keys: string[]): SecretRow[] {
  return keys.map((key) => ({
    id: nextSecretRowId++,
    key,
    value: '',
    existing: true,
    changing: false
  }))
}

function revealExisting(rows: SecretRow[]): SecretRow[] {
  return rows.map((row) => row.existing && !row.changing
    ? { ...row, value: '', changing: true }
    : row)
}

function secretRecord(rows: SecretRow[]): Record<string, string> {
  return Object.fromEntries(rows.map((row) => [row.key.trim(), row.value]))
}

function SecretFields({
  kind,
  rows,
  dirty,
  onChange
}: {
  kind: 'env' | 'headers'
  rows: SecretRow[]
  dirty: boolean
  onChange: (rows: SecretRow[], dirty: boolean) => void
}): JSX.Element {
  const t = useT()
  const beginChange = (change: (current: SecretRow[]) => SecretRow[]): void => {
    onChange(change(revealExisting(rows)), true)
  }
  const kindLabel = t(`settings.mcp.form.${kind}`)

  return (
    <fieldset className="settings-mcp-secrets">
      <legend>{kindLabel}</legend>
      <div className="settings-mcp-secret-list">
        {rows.map((row) => (
          <div className="settings-mcp-secret-row" key={row.id}>
            <input
              type="text"
              value={row.key}
              aria-label={t('settings.mcp.form.secretKey', { kind: kindLabel })}
              placeholder={t('settings.mcp.form.secretKeyPlaceholder')}
              onChange={(event) => {
                const key = event.target.value
                beginChange((current) =>
                  current.map((item) =>
                    item.id === row.id ? { ...item, key } : item
                  )
                )
              }}
            />
            {row.existing && !row.changing && !dirty ? (
              <>
                <span
                  className="settings-mcp-secret-mask"
                  aria-label={t('settings.mcp.form.secretHidden')}
                >
                  ••••
                </span>
                <button
                  type="button"
                  className="settings-mcp-button"
                  onClick={() => beginChange((current) => current)}
                >
                  {t('settings.mcp.form.replace')}
                </button>
              </>
            ) : (
              <input
                type="password"
                value={row.value}
                autoComplete="off"
                aria-label={t('settings.mcp.form.secretValue', {
                  key: row.key || kindLabel
                })}
                placeholder={t('settings.mcp.form.secretValuePlaceholder')}
                onChange={(event) => {
                  const value = event.target.value
                  beginChange((current) =>
                    current.map((item) =>
                      item.id === row.id ? { ...item, value } : item
                    )
                  )
                }}
              />
            )}
            <button
              type="button"
              className="settings-mcp-button settings-mcp-button--icon"
              aria-label={t('settings.mcp.form.removeSecret', {
                key: row.key || kindLabel
              })}
              onClick={() =>
                beginChange((current) =>
                  current.filter((item) => item.id !== row.id)
                )
              }
            >
              {t('settings.mcp.form.remove')}
            </button>
          </div>
        ))}
      </div>
      <button
        type="button"
        className="settings-mcp-button settings-mcp-secret-add"
        onClick={() =>
          beginChange((current) => [
            ...current,
            {
              id: nextSecretRowId++,
              key: '',
              value: '',
              existing: false,
              changing: true
            }
          ])
        }
      >
        {t('settings.mcp.form.addSecret')}
      </button>
    </fieldset>
  )
}

function secretRowsValid(rows: SecretRow[]): boolean {
  const keys = rows.map((row) => row.key.trim())
  return (
    rows.every((row) => row.key.trim().length > 0 && row.value.length > 0) &&
    new Set(keys).size === keys.length
  )
}

function validHttpUrl(value: string): boolean {
  try {
    const url = new URL(value)
    return url.protocol === 'https:' || (url.protocol === 'http:' && (url.hostname === 'localhost' || url.hostname === '[::1]' || url.hostname === '0.0.0.0' || /^127(?:\.\d{1,3}){3}$/u.test(url.hostname)))
  } catch {
    return false
  }
}

export function McpServerEditor({
  server,
  onCancel,
  onSaved,
  disableOnSave = false,
  submitLabel
}: {
  disableOnSave?: boolean
  submitLabel?: string
  server: McpServerSummary | null
  onCancel: () => void
  onSaved: (server: McpServerSummary) => void
}): JSX.Element {
  const t = useT()
  const [name, setName] = useState(server?.name ?? '')
  const [description, setDescription] = useState(server?.description ?? '')
  const [transport, setTransport] = useState<McpTransport>(
    server?.transport ?? 'stdio'
  )
  const [command, setCommand] = useState(server?.command ?? '')
  const [args, setArgs] = useState((server?.args ?? []).join('\n'))
  const [url, setUrl] = useState(server?.url ?? '')
  const [envRows, setEnvRows] = useState(() =>
    existingSecretRows(server?.envKeys ?? [])
  )
  const [headerRows, setHeaderRows] = useState(() =>
    existingSecretRows(server?.headerKeys ?? [])
  )
  const [envDirty, setEnvDirty] = useState(false)
  const [headersDirty, setHeadersDirty] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const handleSubmit = (event: FormEvent<HTMLFormElement>): void => {
    event.preventDefault()
    if (saving) return

    const trimmedName = name.trim()
    if (!MCP_SERVER_NAME_PATTERN.test(trimmedName)) {
      setError(t('settings.mcp.error.name'))
      return
    }
    if (transport === 'stdio' && command.trim().length === 0) {
      setError(t('settings.mcp.error.command'))
      return
    }
    if (transport === 'http' && !validHttpUrl(url.trim())) {
      setError(t('settings.mcp.error.url'))
      return
    }
    if (envDirty && !secretRowsValid(envRows)) {
      setError(t('settings.mcp.error.env'))
      return
    }
    if (headersDirty && !secretRowsValid(headerRows)) {
      setError(t('settings.mcp.error.headers'))
      return
    }

    const input: McpServerInput = {
      name: trimmedName,
      description: description.trim(),
      transport,
      enabled: disableOnSave ? false : server?.enabled ?? false
    }
    if (server !== null) input.id = server.id
    if (transport === 'stdio') {
      input.command = command.trim()
      input.args = args
        .split(/\r?\n/)
        .map((arg) => arg.trim())
        .filter((arg) => arg.length > 0)
    } else {
      input.url = url.trim()
    }
    if (transport === 'stdio' && envDirty) input.env = secretRecord(envRows)
    if (transport === 'http' && headersDirty) {
      input.headers = secretRecord(headerRows)
    }

    setSaving(true)
    setError(null)
    void invoke('mcp:save', input)
      .then(({ server: saved }) => {
        updateServer(saved)
        onSaved(saved)
      })
      .catch((error: unknown) => setError(error instanceof Error ? error.message : t('settings.mcp.error.save')))
      .finally(() => setSaving(false))
  }

  return (
    <form className="settings-mcp-card settings-mcp-form" onSubmit={handleSubmit}>
      <header className="settings-mcp-card-header">
        <div>
          <h2>
            {t(
              server === null
                ? 'settings.mcp.form.addTitle'
                : 'settings.mcp.form.editTitle'
            )}
          </h2>
          <p>{t('settings.mcp.form.description')}</p>
        </div>
      </header>

      <div className="settings-mcp-fields">
        <label className="settings-mcp-field">
          <span>{t('settings.mcp.form.name')}</span>
          <input
            type="text"
            value={name}
            placeholder="notion-search"
            maxLength={32}
            onChange={(event) => setName(event.target.value)}
          />
        </label>
        <label className="settings-mcp-field">
          <span>{t('settings.mcp.form.serverDescription')}</span>
          <input
            type="text"
            value={description}
            onChange={(event) => setDescription(event.target.value)}
          />
        </label>

        <fieldset className="settings-mcp-transport">
          <legend>{t('settings.mcp.form.transport')}</legend>
          <label>
            <input
              type="radio"
              name="mcp-transport"
              value="stdio"
              checked={transport === 'stdio'}
              onChange={() => setTransport('stdio')}
            />
            <span>stdio</span>
          </label>
          <label>
            <input
              type="radio"
              name="mcp-transport"
              value="http"
              checked={transport === 'http'}
              onChange={() => setTransport('http')}
            />
            <span>http</span>
          </label>
        </fieldset>

        {transport === 'stdio' ? (
          <>
            <label className="settings-mcp-field">
              <span>{t('settings.mcp.form.command')}</span>
              <input
                type="text"
                value={command}
                onChange={(event) => setCommand(event.target.value)}
              />
            </label>
            <label className="settings-mcp-field">
              <span>{t('settings.mcp.form.args')}</span>
              <textarea
                value={args}
                rows={4}
                onChange={(event) => setArgs(event.target.value)}
              />
            </label>
            <SecretFields
              kind="env"
              rows={envRows}
              dirty={envDirty}
              onChange={(rows, dirty) => {
                setEnvRows(rows)
                setEnvDirty(dirty)
              }}
            />
          </>
        ) : (
          <>
            <label className="settings-mcp-field">
              <span>{t('settings.mcp.form.url')}</span>
              <input
                type="url"
                value={url}
                onChange={(event) => setUrl(event.target.value)}
              />
            </label>
            <SecretFields
              kind="headers"
              rows={headerRows}
              dirty={headersDirty}
              onChange={(rows, dirty) => {
                setHeaderRows(rows)
                setHeadersDirty(dirty)
              }}
            />
          </>
        )}
      </div>

      {error !== null && (
        <p
          className="settings-mcp-feedback settings-feedback--error"
          role="alert"
        >
          {error}
        </p>
      )}
      <footer className="settings-mcp-form-actions">
        <button
          type="button"
          className="settings-mcp-button"
          disabled={saving}
          onClick={onCancel}
        >
          {t('settings.mcp.action.cancel')}
        </button>
        <button
          type="submit"
          className="settings-mcp-button settings-mcp-button--primary"
          disabled={saving}
        >
          {saving ? t('settings.mcp.action.saving') : submitLabel ?? t('settings.mcp.action.save')}
        </button>
      </footer>
    </form>
  )
}

export function McpServersPanel({
  initialEditingServerId = null
}: {
  initialEditingServerId?: string | null
} = {}): JSX.Element {
  const t = useT()
  const registry = useSyncExternalStore(
    subscribeRegistry,
    getRegistrySnapshot,
    getRegistrySnapshot
  )
  const [adding, setAdding] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(
    initialEditingServerId
  )
  const [manualOpen, setManualOpen] = useState(initialEditingServerId !== null)
  const [pendingId, setPendingId] = useState<string | null>(null)
  const [testingId, setTestingId] = useState<string | null>(null)
  const [confirmDeleteId, setConfirmDeleteId] = useState<string | null>(null)
  const [feedback, setFeedback] = useState<string | null>(null)

  useEffect(() => {
    const unsubscribe = onPush('mcp:changed', () => {
      void loadMcpServers()
    })
    void loadMcpServers()
    return unsubscribe
  }, [])

  const handleEnabled = (server: McpServerSummary, enabled: boolean): void => {
    if (pendingId !== null) return
    setPendingId(server.id)
    setFeedback(null)
    void invoke('mcp:save', summaryInput(server, enabled))
      .then(({ server: saved }) => updateServer(saved))
      .catch(() => setFeedback(t('settings.mcp.error.toggle')))
      .finally(() => setPendingId(null))
  }

  const handleTest = (server: McpServerSummary): void => {
    if (testingId !== null) return
    setTestingId(server.id)
    setFeedback(null)
    void invoke('mcp:test', { id: server.id })
      .then((result) => updateTestResult(server.id, result))
      .catch(() => setFeedback(t('settings.mcp.error.test')))
      .finally(() => setTestingId(null))
  }

  const handleDelete = (server: McpServerSummary): void => {
    if (pendingId !== null) return
    setPendingId(server.id)
    setFeedback(null)
    void invoke('mcp:delete', { id: server.id })
      .then(() => {
        removeServer(server.id)
        setConfirmDeleteId(null)
        if (editingId === server.id) setEditingId(null)
      })
      .catch(() => setFeedback(t('settings.mcp.error.delete')))
      .finally(() => setPendingId(null))
  }

  const available = registry.availability?.available === true
  const editorServer =
    editingId === null
      ? null
      : (registry.servers.find((server) => server.id === editingId) ?? null)

  return (
    <div className="settings-mcp-stack">
      <McpQuickAdd available={available} onSaved={updateServer} />

      <section className="settings-mcp-card">
        <header className="settings-mcp-card-header">
          <div>
            <h2>{t('settings.mcp.title')}</h2>
            <p>{t('settings.mcp.description')}</p>
          </div>
          <button
            type="button"
            className="settings-mcp-button settings-mcp-button--primary"
            disabled={!available || registry.loading}
            onClick={() => {
              setManualOpen(true)
              setAdding(true)
              setEditingId(null)
            }}
          >
            {t('settings.mcp.manual.title')}
          </button>
        </header>

        <div className="settings-mcp-card-body">
          {registry.loading && registry.availability === null ? (
            <p className="settings-mcp-state">
              {t('settings.mcp.loading')}
            </p>
          ) : registry.error && registry.availability === null ? (
            <div className="settings-mcp-state">
              <p className="settings-mcp-feedback settings-feedback--error">
                {t('settings.mcp.error.load')}
              </p>
              <button
                type="button"
                className="settings-mcp-button"
                onClick={() => void loadMcpServers()}
              >
                {t('settings.mcp.action.retry')}
              </button>
            </div>
          ) : !available ? (
            <p className="settings-mcp-state">
              {registry.availability?.reason ?? t('settings.mcp.unavailable')}
            </p>
          ) : registry.servers.length === 0 ? (
            <p className="settings-mcp-state">{t('settings.mcp.empty')}</p>
          ) : (
            <ul
              className="settings-mcp-list"
              aria-label={t('settings.mcp.listLabel')}
            >
              {registry.servers.map((server) => (
                <li className="settings-mcp-row" key={server.id}>
                  <div className="settings-mcp-row-copy">
                    <div className="settings-mcp-row-title">
                      <strong>{server.name}</strong>
                      <span className="settings-mcp-badge">
                        {server.transport}
                      </span>
                    </div>
                    <p>{server.description}</p>
                    <LastTest server={server} />
                  </div>

                  <div className="settings-mcp-row-controls">
                    <button
                      type="button"
                      role="switch"
                      aria-label={t('settings.mcp.enabledLabel', {
                        name: server.name
                      })}
                      aria-checked={server.enabled}
                      className={`settings-mcp-switch${
                        server.enabled ? ' settings-mcp-switch--checked' : ''
                      }`}
                      disabled={pendingId === server.id}
                      onClick={() => handleEnabled(server, !server.enabled)}
                    >
                      <span />
                    </button>
                    <button
                      type="button"
                      className="settings-mcp-button"
                      disabled={testingId === server.id}
                      onClick={() => handleTest(server)}
                    >
                      {t(
                        testingId === server.id
                          ? 'settings.mcp.action.testing'
                          : 'settings.mcp.action.test'
                      )}
                    </button>
                    <button
                      type="button"
                      className="settings-mcp-button"
                      onClick={() => {
                        setManualOpen(true)
                        setAdding(false)
                        setEditingId(server.id)
                      }}
                    >
                      {t('settings.mcp.action.edit')}
                    </button>
                    <button
                      type="button"
                      className="settings-mcp-button"
                      aria-expanded={confirmDeleteId === server.id}
                      onClick={() =>
                        setConfirmDeleteId((current) =>
                          current === server.id ? null : server.id
                        )
                      }
                    >
                      {t('settings.mcp.action.delete')}
                    </button>
                  </div>

                  {confirmDeleteId === server.id && (
                    <div
                      className="settings-mcp-confirm"
                      role="alertdialog"
                      aria-label={t('settings.mcp.delete.title', {
                        name: server.name
                      })}
                    >
                      <p>
                        {t('settings.mcp.delete.message', {
                          name: server.name
                        })}
                      </p>
                      <div className="settings-mcp-confirm-actions">
                        <button
                          type="button"
                          className="settings-mcp-button"
                          disabled={pendingId === server.id}
                          onClick={() => setConfirmDeleteId(null)}
                        >
                          {t('settings.mcp.action.cancel')}
                        </button>
                        <button
                          type="button"
                          className="settings-mcp-button settings-mcp-button--danger"
                          disabled={pendingId === server.id}
                          onClick={() => handleDelete(server)}
                        >
                          {t(
                            pendingId === server.id
                              ? 'settings.mcp.action.deleting'
                              : 'settings.mcp.action.confirmDelete'
                          )}
                        </button>
                      </div>
                    </div>
                  )}
                </li>
              ))}
            </ul>
          )}

          {feedback !== null && (
            <p
              className="settings-mcp-feedback settings-feedback--error"
              role="alert"
            >
              {feedback}
            </p>
          )}
        </div>

        <footer className="settings-mcp-notices">
          <p>{t('settings.mcp.notice.stdio')}</p>
          <p>{t('settings.mcp.notice.codex')}</p>
        </footer>
      </section>

      <details
        className="settings-mcp-manual"
        open={manualOpen}
        onToggle={(event) => {
          const open = event.currentTarget.open
          setManualOpen(open)
          if (open && editingId === null) setAdding(true)
          if (!open) {
            setAdding(false)
            setEditingId(null)
          }
        }}
      >
        <summary>
          <span>{t('settings.mcp.manual.title')}</span>
          <small>{t('settings.mcp.manual.description')}</small>
        </summary>
        {available && (adding || editorServer !== null) && (
          <McpServerEditor
            key={editorServer?.id ?? 'new-server'}
            server={editorServer}
            onCancel={() => {
              setAdding(false)
              setEditingId(null)
              setManualOpen(false)
            }}
            onSaved={() => {
              setAdding(false)
              setEditingId(null)
              setManualOpen(false)
            }}
          />
        )}
      </details>
    </div>
  )
}

export function useMcpRegistry(): RegistrySnapshot {
  const registry = useSyncExternalStore(subscribeRegistry, getRegistrySnapshot, getRegistrySnapshot)
  useEffect(() => {
    const stop = onPush('mcp:changed', () => { void loadMcpServers() })
    void loadMcpServers()
    return stop
  }, [])
  return registry
}
