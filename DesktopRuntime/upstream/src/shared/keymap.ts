/**
 * Electron-free keyboard shortcut contract shared by main and renderer.
 *
 * Chords are stored in a platform-neutral form such as `mod+shift+b`.
 * `mod` means Command on macOS and Control elsewhere. Modifier order is
 * canonicalized as mod, alt, shift, then key.
 */

export type ShortcutActionId =
  | 'new-tab'
  | 'new-markdown'
  | 'new-browser-tab'
  | 'new-ai-tab'
  | 'new-recording-tab'
  | 'new-whiteboard'
  | 'open-study-board'
  | 'close-tab'
  | 'quick-search'
  | 'settings'
  | 'activate-tab-1'
  | 'activate-tab-2'
  | 'activate-tab-3'
  | 'activate-tab-4'
  | 'activate-tab-5'
  | 'activate-tab-6'
  | 'activate-tab-7'
  | 'activate-tab-8'
  | 'activate-last-tab'
  | 'browser-back'
  | 'browser-forward'
  | 'browser-reload'
  | 'browser-reload-hard'
  | 'browser-focus-address'
  | 'browser-find'
  | 'browser-bookmark'
  | 'reopen-tab'
  | 'cycle-tab-prev'
  | 'cycle-tab-next'
  | 'browser-zoom-in'
  | 'browser-zoom-out'
  | 'browser-zoom-reset'
  | 'toggle-left-rail'
  | 'toggle-right-rail'
  | 'toggle-board'
  | 'add-course'
  | 'import-materials'
  | 'open-pip'
  | 'shortcut-help'
  | 'send-feedback'
  // Display-only, fixed whiteboard tool shortcuts.
  | 'whiteboard-select'
  | 'whiteboard-pen'
  | 'whiteboard-highlighter'
  | 'whiteboard-eraser'
  | 'whiteboard-text'
  | 'whiteboard-rectangle'
  | 'whiteboard-ellipse'

export interface ShortcutSpec {
  id: ShortcutActionId
  labelKo: string
  labelEn: string
  defaultChord: string | null
  scope: 'global' | 'browser' | 'whiteboard'
  customizable: boolean
  guestAllowed: boolean
}

export interface Chord {
  mod: boolean
  alt: boolean
  shift: boolean
  key: string
}

/** The KeyboardEvent fields needed by the shared, DOM-independent helpers. */
export interface KeyboardChordEvent {
  key: string
  code?: string | undefined
  metaKey: boolean
  ctrlKey: boolean
  altKey: boolean
  shiftKey: boolean
}

const FIXED = false
const CUSTOM = true
const GUEST = true
const HOST_ONLY = false

export const SHORTCUT_SPECS = [
  { id: 'new-tab', labelKo: '새 탭', labelEn: 'New tab', defaultChord: 'mod+t', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'new-markdown', labelKo: '새 마크다운', labelEn: 'New Markdown', defaultChord: 'mod+shift+m', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'new-browser-tab', labelKo: '새 브라우저 탭', labelEn: 'New browser tab', defaultChord: 'mod+shift+b', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'new-ai-tab', labelKo: '새 AI 탭', labelEn: 'New AI tab', defaultChord: 'mod+shift+a', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'new-recording-tab', labelKo: '녹음 탭 열기', labelEn: 'Open recording tab', defaultChord: 'mod+alt+r', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'new-whiteboard', labelKo: '새 화이트보드', labelEn: 'New whiteboard', defaultChord: 'mod+alt+w', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'open-study-board', labelKo: '학업 보드 탭 열기', labelEn: 'Open study board tab', defaultChord: 'mod+alt+d', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'close-tab', labelKo: '탭 닫기', labelEn: 'Close tab', defaultChord: 'mod+w', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'quick-search', labelKo: '빠른 파일 검색', labelEn: 'Quick file search', defaultChord: 'mod+p', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'settings', labelKo: '설정', labelEn: 'Settings', defaultChord: 'mod+,', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'activate-tab-1', labelKo: '첫 번째 탭', labelEn: 'Activate tab 1', defaultChord: 'mod+1', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-2', labelKo: '두 번째 탭', labelEn: 'Activate tab 2', defaultChord: 'mod+2', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-3', labelKo: '세 번째 탭', labelEn: 'Activate tab 3', defaultChord: 'mod+3', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-4', labelKo: '네 번째 탭', labelEn: 'Activate tab 4', defaultChord: 'mod+4', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-5', labelKo: '다섯 번째 탭', labelEn: 'Activate tab 5', defaultChord: 'mod+5', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-6', labelKo: '여섯 번째 탭', labelEn: 'Activate tab 6', defaultChord: 'mod+6', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-7', labelKo: '일곱 번째 탭', labelEn: 'Activate tab 7', defaultChord: 'mod+7', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-tab-8', labelKo: '여덟 번째 탭', labelEn: 'Activate tab 8', defaultChord: 'mod+8', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'activate-last-tab', labelKo: '마지막 탭', labelEn: 'Activate last tab', defaultChord: 'mod+9', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-back', labelKo: '뒤로', labelEn: 'Back', defaultChord: 'mod+[', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-forward', labelKo: '앞으로', labelEn: 'Forward', defaultChord: 'mod+]', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-reload', labelKo: '새로고침', labelEn: 'Reload', defaultChord: 'mod+r', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-reload-hard', labelKo: '캐시 없이 새로고침', labelEn: 'Hard reload', defaultChord: 'mod+shift+r', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-focus-address', labelKo: '주소창으로 이동', labelEn: 'Focus address bar', defaultChord: 'mod+l', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-find', labelKo: '페이지에서 찾기', labelEn: 'Find in page', defaultChord: 'mod+f', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-bookmark', labelKo: '즐겨찾기 전환', labelEn: 'Toggle bookmark', defaultChord: 'mod+d', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'reopen-tab', labelKo: '닫은 탭 다시 열기', labelEn: 'Reopen closed tab', defaultChord: 'mod+shift+t', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'cycle-tab-prev', labelKo: '이전 탭', labelEn: 'Previous tab', defaultChord: 'mod+shift+[', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'cycle-tab-next', labelKo: '다음 탭', labelEn: 'Next tab', defaultChord: 'mod+shift+]', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-zoom-in', labelKo: '확대', labelEn: 'Zoom in', defaultChord: 'mod+=', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-zoom-out', labelKo: '축소', labelEn: 'Zoom out', defaultChord: 'mod+-', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'browser-zoom-reset', labelKo: '확대/축소 초기화', labelEn: 'Reset zoom', defaultChord: 'mod+0', scope: 'browser', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'toggle-left-rail', labelKo: '왼쪽 사이드바 접기/펼치기', labelEn: 'Toggle left sidebar', defaultChord: 'mod+s', scope: 'global', customizable: CUSTOM, guestAllowed: GUEST },
  { id: 'toggle-right-rail', labelKo: '오른쪽 레일 전환', labelEn: 'Toggle right rail', defaultChord: 'mod+alt+b', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'toggle-board', labelKo: '보드 전환', labelEn: 'Toggle board', defaultChord: 'mod+shift+d', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'add-course', labelKo: '과목 추가', labelEn: 'Add course', defaultChord: 'mod+shift+n', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'import-materials', labelKo: '자료 가져오기', labelEn: 'Import materials', defaultChord: 'mod+shift+i', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'open-pip', labelKo: 'PIP 열기', labelEn: 'Open picture in picture', defaultChord: 'mod+shift+p', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'shortcut-help', labelKo: '단축키 도움말', labelEn: 'Keyboard shortcut help', defaultChord: 'mod+/', scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'send-feedback', labelKo: '피드백 보내기', labelEn: 'Send feedback', defaultChord: null, scope: 'global', customizable: CUSTOM, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-select', labelKo: '선택 도구', labelEn: 'Select tool', defaultChord: 'v', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-pen', labelKo: '펜 도구', labelEn: 'Pen tool', defaultChord: 'p', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-highlighter', labelKo: '형광펜 도구', labelEn: 'Highlighter tool', defaultChord: 'h', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-eraser', labelKo: '지우개 도구', labelEn: 'Eraser tool', defaultChord: 'e', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-text', labelKo: '텍스트 도구', labelEn: 'Text tool', defaultChord: 't', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-rectangle', labelKo: '사각형 도구', labelEn: 'Rectangle tool', defaultChord: 'r', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY },
  { id: 'whiteboard-ellipse', labelKo: '타원 도구', labelEn: 'Ellipse tool', defaultChord: 'o', scope: 'whiteboard', customizable: FIXED, guestAllowed: HOST_ONLY }
] as const satisfies readonly ShortcutSpec[]

const MODIFIER_KEYS = new Set([
  'alt',
  'altgraph',
  'control',
  'ctrl',
  'meta',
  'os',
  'shift'
])

const NAMED_KEYS = new Set([
  'arrowdown',
  'arrowleft',
  'arrowright',
  'arrowup',
  'backspace',
  'delete',
  'end',
  'enter',
  'escape',
  'home',
  'insert',
  'pagedown',
  'pageup',
  'space',
  'tab'
])

function normalizeKey(key: string): string | null {
  if (key === ' ') return 'space'
  if (key === '+') return '='
  const normalized = key.trim().toLowerCase()
  if (normalized === '' || normalized === 'unidentified') return null
  if (MODIFIER_KEYS.has(normalized)) return null
  if (normalized.includes('+')) return null
  if (normalized.length === 1 || NAMED_KEYS.has(normalized)) return normalized
  return /^f(?:[1-9]|1[0-9]|2[0-4])$/.test(normalized) ? normalized : null
}

function serializeChord(chord: Chord): string {
  return [
    chord.mod ? 'mod' : null,
    chord.alt ? 'alt' : null,
    chord.shift ? 'shift' : null,
    chord.key
  ].filter((part): part is string => part !== null).join('+')
}

/** Parses and canonicalizes a persisted platform-neutral chord. */
export function parseChord(value: string): Chord | null {
  if (typeof value !== 'string') return null
  const parts = value.trim().toLowerCase().split('+')
  if (parts.length === 0 || parts.some((part) => part.trim() === '')) return null

  let mod = false
  let alt = false
  let shift = false
  let key: string | null = null
  for (const rawPart of parts) {
    const part = rawPart.trim()
    if (part === 'mod') {
      if (mod) return null
      mod = true
    } else if (part === 'alt') {
      if (alt) return null
      alt = true
    } else if (part === 'shift') {
      if (shift) return null
      shift = true
    } else {
      if (key !== null) return null
      key = normalizeKey(part)
      if (key === null) return null
    }
  }
  return key === null ? null : { mod, alt, shift, key }
}

function displayKey(key: string): string {
  if (key === '=') return '+'
  if (key === 'space') return 'Space'
  if (key.length === 1) return key.toUpperCase()
  const labels: Readonly<Record<string, string>> = {
    arrowup: '↑',
    arrowdown: '↓',
    arrowleft: '←',
    arrowright: '→',
    escape: 'Esc',
    backspace: 'Backspace',
    delete: 'Delete',
    enter: 'Enter',
    tab: 'Tab'
  }
  return labels[key] ?? `${key[0]?.toUpperCase() ?? ''}${key.slice(1)}`
}

/** Renders a chord using macOS glyphs or Windows/Linux modifier names. */
export function formatChord(chord: Chord, platform: string): string {
  const key = displayKey(chord.key)
  if (platform === 'darwin' || platform === 'mac' || platform === 'macos') {
    return `${chord.mod ? '⌘' : ''}${chord.alt ? '⌥' : ''}${chord.shift ? '⇧' : ''}${key}`
  }
  return [
    chord.mod ? 'Ctrl' : null,
    chord.alt ? 'Alt' : null,
    chord.shift ? 'Shift' : null,
    key
  ].filter((part): part is string => part !== null).join('+')
}

/** Records a keydown as a canonical chord. Modifier-only keydowns are ignored. */
export function chordFromKeyboardEvent(event: KeyboardChordEvent): string | null {
  // macOS Option can report ∑/®/∂ instead of W/R/D. Only fall back for
  // modified non-ASCII/dead keys; ordinary non-QWERTY letter layouts keep key.
  const physical = event.code?.match(/^Key([A-Z])$/)?.[1]
  const value = physical && (event.metaKey || event.ctrlKey) &&
    (event.key === 'Dead' || /[^\x00-\x7f]/.test(event.key)) ? physical : event.key
  const key = normalizeKey(value)
  if (key === null) return null
  return serializeChord({
    mod: event.metaKey || event.ctrlKey,
    alt: event.altKey,
    shift: event.shiftKey,
    key
  })
}

/**
 * Matches an event against a persisted chord.
 * The caller must reject IME composition (`isComposing` / keyCode 229) before
 * calling; this shared structural event type deliberately has no DOM guards.
 */
export function matchChord(event: KeyboardChordEvent, value: string): boolean {
  const expected = parseChord(value)
  if (expected === null) return false
  return chordFromKeyboardEvent(event) === serializeChord(expected)
}

const SPEC_BY_ID = new Map<ShortcutActionId, ShortcutSpec>(
  SHORTCUT_SPECS.map((spec) => [spec.id, spec])
)

function normalizedChord(value: string): string | null {
  const parsed = parseChord(value)
  return parsed === null ? null : serializeChord(parsed)
}

/**
 * Merges defaults and overrides into a chord → action lookup.
 *
 * Overrides are applied in object insertion order. When two bindings claim
 * one chord, the later override wins and the previous action becomes unbound;
 * this includes displacing an untouched default binding.
 */
export function resolveKeymap(
  overrides: Record<string, string | null>
): Map<string, ShortcutActionId> {
  const result = new Map<string, ShortcutActionId>()
  const chordByAction = new Map<ShortcutActionId, string | null>()

  for (const spec of SHORTCUT_SPECS) {
    const chord = spec.defaultChord === null ? null : normalizedChord(spec.defaultChord)
    chordByAction.set(spec.id, chord)
    if (chord !== null) result.set(chord, spec.id)
  }

  for (const [rawId, override] of Object.entries(overrides)) {
    const spec = SPEC_BY_ID.get(rawId as ShortcutActionId)
    if (spec === undefined || !spec.customizable) continue
    const chord = override === null ? null : normalizedChord(override)
    if (override !== null && chord === null) continue

    const previousChord = chordByAction.get(spec.id) ?? null
    if (previousChord !== null && result.get(previousChord) === spec.id) {
      result.delete(previousChord)
    }
    chordByAction.set(spec.id, chord)
    if (chord === null) continue

    const displaced = result.get(chord)
    if (displaced !== undefined && displaced !== spec.id) {
      chordByAction.set(displaced, null)
    }
    result.set(chord, spec.id)
  }

  return result
}

/** Returns every requested duplicate before the winner rule is applied. */
export function findConflicts(
  overrides: Record<string, string | null>
): Map<string, readonly ShortcutActionId[]> {
  const chordByAction = new Map<ShortcutActionId, string | null>()
  for (const spec of SHORTCUT_SPECS) {
    chordByAction.set(
      spec.id,
      spec.defaultChord === null ? null : normalizedChord(spec.defaultChord)
    )
  }
  for (const [rawId, override] of Object.entries(overrides)) {
    const spec = SPEC_BY_ID.get(rawId as ShortcutActionId)
    if (spec === undefined || !spec.customizable) continue
    const chord = override === null ? null : normalizedChord(override)
    if (override !== null && chord === null) continue
    chordByAction.set(spec.id, chord)
  }

  const claims = new Map<string, ShortcutActionId[]>()
  for (const [action, chord] of chordByAction) {
    if (chord === null) continue
    const actions = claims.get(chord) ?? []
    actions.push(action)
    claims.set(chord, actions)
  }
  return new Map([...claims].filter(([, actions]) => actions.length > 1))
}

/**
 * Printing and quick search intentionally share one chord. The menu derives
 * its accelerator from the resolved quick-search binding, so customizing or
 * unbinding quick search moves or removes both meanings together.
 */
export function printChord(
  keymap: ReadonlyMap<string, ShortcutActionId>
): string | null {
  for (const [chord, action] of keymap) {
    if (action === 'quick-search') return chord
  }
  return null
}
