import { useEffect, useMemo, useRef, useState } from 'react'
import type { KeyboardEvent, MouseEvent, RefObject } from 'react'
import {
  SHORTCUT_SPECS,
  chordFromKeyboardEvent,
  findConflicts,
  formatChord,
  parseChord,
  type ShortcutActionId,
  type ShortcutSpec
} from '../../../../../shared/keymap'
import type {
  Settings,
  SettingsPatch,
  ShortcutPriority
} from '../../../../../shared/types/settings'
import { showToast } from '../../../app/toast'
import { useLocale, useT } from '../../../i18n'
import { invoke } from '../../../lib/ipc'
import { SettingsCard } from '../primitives'
import { Icon } from '../SettingsIcon'
import {
  assignChord,
  conflictingAction,
  effectiveChords,
  formattedChordParts,
  importedKeybindings,
  restoreDefault,
  type KeybindingOverrides
} from './shortcutModel'
import './shortcuts-panel.css'

type Scope = ShortcutSpec['scope']
type StatusFilter = 'all' | 'changed' | 'unassigned' | 'conflict'

interface PendingConflict {
  actionId: ShortcutActionId
  chord: string
  displaced: ShortcutActionId
  restore: boolean
}

const SCOPES: readonly Scope[] = ['global', 'browser', 'whiteboard']
const EMPTY_OVERRIDES: KeybindingOverrides = {}

function labelFor(spec: ShortcutSpec, locale: string): string {
  return locale === 'en-US' ? spec.labelEn : spec.labelKo
}

function specFor(actionId: ShortcutActionId): ShortcutSpec {
  const spec = SHORTCUT_SPECS.find((candidate) => candidate.id === actionId)
  if (spec === undefined) throw new Error(`Unknown shortcut action: ${actionId}`)
  return spec
}

function isChanged(spec: ShortcutSpec, overrides: KeybindingOverrides): boolean {
  if (!Object.prototype.hasOwnProperty.call(overrides, spec.id)) return false
  const value = overrides[spec.id]
  return value === null || value !== spec.defaultChord
}

function chordText(chord: string | undefined, platform: string): string {
  if (chord === undefined) return '—'
  const parsed = parseChord(chord)
  return parsed === null ? '—' : formatChord(parsed, platform)
}

interface ShortcutGroupView {
  scope: Scope
  specs: readonly ShortcutSpec[]
}

function useShortcutView(
  overrides: KeybindingOverrides,
  query: string,
  filter: StatusFilter,
  locale: string,
  platform: string
): {
  effective: ReadonlyMap<ShortcutActionId, string>
  counts: FilterCounts
  groups: readonly ShortcutGroupView[]
} {
  const effective = useMemo(() => effectiveChords(overrides), [overrides])
  const conflicts = useMemo(() => findConflicts(overrides), [overrides])
  const conflictIds = useMemo(
    () => new Set([...conflicts.values()].flat()),
    [conflicts]
  )
  const counts = useMemo<FilterCounts>(
    () => ({
      all: SHORTCUT_SPECS.length,
      changed: SHORTCUT_SPECS.filter((spec) => isChanged(spec, overrides)).length,
      unassigned: SHORTCUT_SPECS.filter((spec) => !effective.has(spec.id)).length,
      conflict: conflicts.size
    }),
    [conflicts, effective, overrides]
  )
  const normalized = query.trim().toLocaleLowerCase(locale)
  const matches = (spec: ShortcutSpec): boolean => {
    const text = `${labelFor(spec, locale)} ${chordText(
      effective.get(spec.id),
      platform
    )}`.toLocaleLowerCase(locale)
    if (normalized !== '' && !text.includes(normalized)) return false
    if (filter === 'changed') return isChanged(spec, overrides)
    if (filter === 'unassigned') return !effective.has(spec.id)
    return filter !== 'conflict' || conflictIds.has(spec.id)
  }
  const groups = SCOPES.map((scope) => ({
    scope,
    specs: SHORTCUT_SPECS.filter((spec) => spec.scope === scope && matches(spec))
  })).filter((group) => group.specs.length > 0)
  return { effective, counts, groups }
}

function ShortcutKeycaps({
  chord,
  platform
}: {
  chord: string | undefined
  platform: string
}): JSX.Element {
  return (
    <span className="settings-shortcuts-keycaps">
      {formattedChordParts(chord, platform).map((part, index) => (
        <kbd key={`${part}-${index}`}>{part}</kbd>
      ))}
    </span>
  )
}

function ShortcutOverflow({
  disabled,
  onDefault,
  onUnassign
}: {
  disabled: boolean
  onDefault: () => void
  onUnassign: () => void
}): JSX.Element {
  const t = useT()
  const closeAndRun = (
    event: MouseEvent<HTMLButtonElement>,
    action: () => void
  ): void => {
    event.currentTarget.closest('details')?.removeAttribute('open')
    action()
  }
  return (
    <details className="settings-shortcuts-overflow">
      <summary aria-label={t('settings.shortcuts.actions')}>•••</summary>
      <div className="settings-shortcuts-overflow__menu">
        <button
          type="button"
          disabled={disabled}
          onClick={(event) => closeAndRun(event, onDefault)}
        >
          {t('settings.shortcuts.default')}
        </button>
        <button
          type="button"
          disabled={disabled}
          onClick={(event) => closeAndRun(event, onUnassign)}
        >
          {t('settings.shortcuts.unassign')}
        </button>
      </div>
    </details>
  )
}

function ConflictNotice({
  conflict,
  locale,
  onReplace,
  onCancel
}: {
  conflict: PendingConflict
  locale: string
  onReplace: () => void
  onCancel: () => void
}): JSX.Element {
  const t = useT()
  return (
    <div className="settings-shortcuts-conflict" role="alert">
      <span>
        {t('help.shortcuts.conflict', {
          label: labelFor(specFor(conflict.displaced), locale)
        })}
      </span>
      <button type="button" className="secondary-button" onClick={onReplace}>
        {t('help.shortcuts.replace')}
      </button>
      <button type="button" className="secondary-button" onClick={onCancel}>
        {t('help.cancel')}
      </button>
    </div>
  )
}

interface ShortcutRowProps {
  spec: ShortcutSpec
  chord: string | undefined
  platform: string
  locale: string
  recording: boolean
  saving: boolean
  conflict: PendingConflict | null
  recorderRef: RefObject<HTMLButtonElement>
  onRecord: () => void
  onCapture: (event: KeyboardEvent<HTMLButtonElement>) => void
  onDefault: () => void
  onUnassign: () => void
  onReplace: () => void
  onCancelConflict: () => void
}

function ShortcutRow(props: ShortcutRowProps): JSX.Element {
  const t = useT()
  const { spec } = props
  const label = labelFor(spec, props.locale)
  return (
    <div className="settings-shortcuts-row-wrap">
      <div className="settings-shortcuts-row">
        <button
          ref={props.recording ? props.recorderRef : undefined}
          type="button"
          className="settings-shortcuts-row__main"
          disabled={!spec.customizable || props.saving}
          aria-label={`${label}: ${props.recording ? t('settings.shortcuts.recording') : chordText(props.chord, props.platform)}`}
          aria-pressed={props.recording}
          data-recording={props.recording || undefined}
          onClick={props.onRecord}
          onKeyDown={props.recording ? props.onCapture : undefined}
        >
          <span className="settings-shortcuts-row__copy">
            <span className="settings-shortcuts-row__label">{label}</span>
            <span className="settings-shortcuts-row__badges">
              {spec.guestAllowed && (
                <span className="status-pill">{t('settings.shortcuts.guestBadge')}</span>
              )}
              {!spec.customizable && (
                <span className="status-pill">{t('settings.shortcuts.fixedBadge')}</span>
              )}
            </span>
          </span>
          {props.recording ? (
            <span className="settings-shortcuts-recording">
              {t('settings.shortcuts.recording')}
            </span>
          ) : (
            <ShortcutKeycaps chord={props.chord} platform={props.platform} />
          )}
        </button>
        {spec.customizable && (
          <ShortcutOverflow
            disabled={props.saving}
            onDefault={props.onDefault}
            onUnassign={props.onUnassign}
          />
        )}
      </div>
      {props.conflict !== null && (
        <ConflictNotice
          conflict={props.conflict}
          locale={props.locale}
          onReplace={props.onReplace}
          onCancel={props.onCancelConflict}
        />
      )}
    </div>
  )
}

function PriorityCard({
  priority,
  disabled,
  onChange
}: {
  priority: ShortcutPriority
  disabled: boolean
  onChange: (priority: ShortcutPriority) => void
}): JSX.Element {
  const t = useT()
  return (
    <SettingsCard title={t('settings.shortcuts.priority.title')}>
      <div className="setting-row">
        <div className="setting-row__copy">
          <span className="setting-row__label">
            {t(`settings.shortcuts.priority.${priority}`)}
          </span>
          <span className="setting-row__description">
            {t(`settings.shortcuts.priority.${priority}Description`)}
          </span>
        </div>
        <select
          className="language-select"
          aria-label={t('settings.shortcuts.priority.selectLabel')}
          value={priority}
          disabled={disabled}
          onChange={(event) => onChange(event.target.value as ShortcutPriority)}
        >
          <option value="bandal">{t('settings.shortcuts.priority.bandal')}</option>
          <option value="site">{t('settings.shortcuts.priority.site')}</option>
        </select>
      </div>
    </SettingsCard>
  )
}

interface FilterCounts {
  all: number
  changed: number
  unassigned: number
  conflict: number
}

function FilterSidebar({
  query,
  filter,
  counts,
  onQuery,
  onFilter
}: {
  query: string
  filter: StatusFilter
  counts: FilterCounts
  onQuery: (query: string) => void
  onFilter: (filter: StatusFilter) => void
}): JSX.Element {
  const t = useT()
  const filters: readonly StatusFilter[] = [
    'all',
    'changed',
    'unassigned',
    'conflict'
  ]
  return (
    <aside className="settings-shortcuts-sidebar">
      <label className="settings-shortcuts-search">
        <Icon name="search" />
        <span className="sr-only">{t('settings.shortcuts.searchLabel')}</span>
        <input
          type="search"
          value={query}
          placeholder={t('settings.shortcuts.search')}
          onChange={(event) => onQuery(event.target.value)}
        />
      </label>
      <div
        className="settings-shortcuts-filters"
        role="radiogroup"
        aria-label={t('settings.shortcuts.filterLabel')}
      >
        {filters.map((value) => (
          <button
            type="button"
            role="radio"
            aria-checked={filter === value}
            className="settings-shortcuts-filter"
            data-selected={filter === value || undefined}
            key={value}
            onClick={() => onFilter(value)}
          >
            <span>{t(`settings.shortcuts.filter.${value}`)}</span>
            <span>{counts[value]}</span>
          </button>
        ))}
      </div>
    </aside>
  )
}

function useShortcutSave(): {
  saving: boolean
  error: string | null
  save: (patch: SettingsPatch) => Promise<boolean>
} {
  const t = useT()
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const save = async (patch: SettingsPatch): Promise<boolean> => {
    setSaving(true)
    setError(null)
    try {
      await invoke('settings:set', patch)
      return true
    } catch (saveError) {
      console.error('[Bandal] 단축키 설정을 저장하지 못했습니다.', saveError)
      setError(t('help.shortcuts.saveFailed'))
      return false
    } finally {
      setSaving(false)
    }
  }
  return { saving, error, save }
}

function useShortcutEditor(
  overrides: KeybindingOverrides,
  save: (patch: SettingsPatch) => Promise<boolean>
) {
  const recorderRef = useRef<HTMLButtonElement>(null)
  const [recording, setRecording] = useState<ShortcutActionId | null>(null)
  const [conflict, setConflict] = useState<PendingConflict | null>(null)
  useEffect(() => recorderRef.current?.focus(), [recording])

  const persist = async (keybindings: KeybindingOverrides): Promise<boolean> => {
    const saved = await save({ keybindings })
    if (saved) {
      setRecording(null)
      setConflict(null)
    }
    return saved
  }
  const request = (
    actionId: ShortcutActionId,
    chord: string,
    restore: boolean
  ): void => {
    const displaced = conflictingAction(overrides, actionId, chord)
    if (displaced !== null) {
      setConflict({ actionId, chord, displaced, restore })
      setRecording(null)
      return
    }
    const next = restore
      ? restoreDefault(overrides, actionId, null)
      : assignChord(overrides, actionId, chord, null)
    void persist(next)
  }
  const capture = (
    event: KeyboardEvent<HTMLButtonElement>,
    actionId: ShortcutActionId
  ): void => {
    event.stopPropagation()
    if (event.key === 'Escape') {
      event.preventDefault()
      setRecording(null)
      return
    }
    if (event.nativeEvent.isComposing || event.keyCode === 229) return
    const chord = chordFromKeyboardEvent(event)
    if (chord === null) return
    event.preventDefault()
    request(actionId, chord, false)
  }
  return {
    recorderRef,
    recording,
    conflict,
    persist,
    request,
    capture,
    record: (actionId: ShortcutActionId) => {
      setConflict(null)
      setRecording(actionId)
    },
    cancelConflict: () => setConflict(null)
  }
}

type ShortcutEditor = ReturnType<typeof useShortcutEditor>

function replacementFor(
  overrides: KeybindingOverrides,
  conflict: PendingConflict
): KeybindingOverrides {
  return conflict.restore
    ? restoreDefault(overrides, conflict.actionId, conflict.displaced)
    : assignChord(
        overrides,
        conflict.actionId,
        conflict.chord,
        conflict.displaced
      )
}

function ShortcutScopeGroup({
  group,
  effective,
  overrides,
  editor,
  platform,
  locale,
  disabled
}: {
  group: ShortcutGroupView
  effective: ReadonlyMap<ShortcutActionId, string>
  overrides: KeybindingOverrides
  editor: ShortcutEditor
  platform: string
  locale: string
  disabled: boolean
}): JSX.Element {
  const t = useT()
  return (
    <section className="settings-shortcuts-group">
      <h3>{t(`settings.shortcuts.scope.${group.scope}`)}</h3>
      <div className="settings-shortcuts-list">
        {group.specs.map((spec) => {
          const rowConflict = editor.conflict?.actionId === spec.id
            ? editor.conflict
            : null
          return (
            <ShortcutRow
              key={spec.id}
              spec={spec}
              chord={effective.get(spec.id)}
              platform={platform}
              locale={locale}
              recording={editor.recording === spec.id}
              saving={disabled}
              conflict={rowConflict}
              recorderRef={editor.recorderRef}
              onRecord={() => editor.record(spec.id)}
              onCapture={(event) => editor.capture(event, spec.id)}
              onDefault={() =>
                spec.defaultChord === null
                  ? void editor.persist({ ...overrides, [spec.id]: null })
                  : editor.request(spec.id, spec.defaultChord, true)
              }
              onUnassign={() =>
                void editor.persist({ ...overrides, [spec.id]: null })
              }
              onReplace={() =>
                rowConflict !== null &&
                void editor.persist(replacementFor(overrides, rowConflict))
              }
              onCancelConflict={editor.cancelConflict}
            />
          )
        })}
      </div>
    </section>
  )
}

function ShortcutWorkspace({
  view,
  overrides,
  editor,
  platform,
  locale,
  disabled
}: {
  view: ReturnType<typeof useShortcutView>
  overrides: KeybindingOverrides
  editor: ShortcutEditor
  platform: string
  locale: string
  disabled: boolean
}): JSX.Element {
  const t = useT()
  if (view.groups.length === 0) {
    return (
      <div className="settings-shortcuts-empty">
        <Icon name="search" />
        <span>{t('settings.shortcuts.empty')}</span>
      </div>
    )
  }
  return (
    <>
      {view.groups.map((group) => (
        <ShortcutScopeGroup
          key={group.scope}
          group={group}
          effective={view.effective}
          overrides={overrides}
          editor={editor}
          platform={platform}
          locale={locale}
          disabled={disabled}
        />
      ))}
    </>
  )
}

function JsonActions({
  overrides,
  disabled,
  persist
}: {
  overrides: KeybindingOverrides
  disabled: boolean
  persist: ShortcutEditor['persist']
}): JSX.Element {
  const t = useT()
  const paste = async (): Promise<void> => {
    let parsed: unknown
    try {
      parsed = JSON.parse(await navigator.clipboard.readText()) as unknown
    } catch {
      showToast(t('settings.shortcuts.json.invalid'), 'danger')
      return
    }
    const keybindings = importedKeybindings(parsed)
    if (keybindings === null) {
      showToast(t('settings.shortcuts.json.invalid'), 'danger')
      return
    }
    if (await persist(keybindings)) {
      showToast(t('settings.shortcuts.json.pasted'))
    }
  }
  const copy = async (): Promise<void> => {
    try {
      await navigator.clipboard.writeText(JSON.stringify(overrides, null, 2))
      showToast(t('settings.shortcuts.json.copied'))
    } catch {
      showToast(t('settings.shortcuts.json.copyFailed'), 'danger')
    }
  }
  return (
    <div className="settings-shortcuts-json">
      <button
        type="button"
        className="secondary-button"
        disabled={disabled}
        onClick={() => void copy()}
      >
        {t('settings.shortcuts.json.copy')}
      </button>
      <button
        type="button"
        className="secondary-button"
        disabled={disabled}
        onClick={() => void paste()}
      >
        {t('settings.shortcuts.json.paste')}
      </button>
    </div>
  )
}

export function ShortcutsPanel({
  settings
}: {
  settings: Settings | null
}): JSX.Element {
  const locale = useLocale()
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<StatusFilter>('all')
  const overrides = settings?.keybindings ?? EMPTY_OVERRIDES
  const platform =
    typeof window === 'undefined'
      ? 'darwin'
      : (window.bandal?.platform ?? 'darwin')
  const view = useShortcutView(overrides, query, filter, locale, platform)
  const { saving, error, save } = useShortcutSave()
  const editor = useShortcutEditor(overrides, save)
  const priority = settings?.shortcutPriority ?? 'bandal'
  const disabled = settings === null || saving
  return (
    <div className="settings-stack">
      <PriorityCard
        priority={priority}
        disabled={disabled}
        onChange={(shortcutPriority) => void save({ shortcutPriority })}
      />

      {error !== null && (
        <p className="settings-shortcuts-error" role="alert">
          {error}
        </p>
      )}

      <div className="settings-shortcuts-layout">
        <FilterSidebar
          query={query}
          filter={filter}
          counts={view.counts}
          onQuery={setQuery}
          onFilter={setFilter}
        />
        <div className="settings-shortcuts-groups">
          <ShortcutWorkspace
            view={view}
            overrides={overrides}
            editor={editor}
            platform={platform}
            locale={locale}
            disabled={disabled}
          />
        </div>
      </div>
      <JsonActions
        overrides={overrides}
        disabled={disabled}
        persist={editor.persist}
      />
    </div>
  )
}
