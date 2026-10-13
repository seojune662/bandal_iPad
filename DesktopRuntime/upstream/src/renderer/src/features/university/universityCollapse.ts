export const UNIVERSITY_SECTION_COLLAPSED_STORAGE_KEY =
  'bandal:university-section:collapsed:v1'

export const UNIVERSITY_SECTION_SHOW_ALL_STORAGE_KEY =
  'bandal:university-section:show-all:v1'

interface StorageReader {
  getItem: (key: string) => string | null
}

interface StorageWriter {
  setItem: (key: string, value: string) => void
}

function readBoolean(
  key: string,
  storage: StorageReader | null
): boolean {
  if (storage === null) return false
  try {
    return JSON.parse(storage.getItem(key) ?? 'false') === true
  } catch {
    return false
  }
}

function persistBoolean(
  key: string,
  value: boolean,
  storage: StorageWriter | null
): void {
  if (storage === null) return
  try {
    storage.setItem(key, JSON.stringify(value))
  } catch {
    // localStorage is best-effort (for example, it can be disabled by policy).
  }
}

export function readUniversitySectionCollapsed(
  storage: StorageReader | null =
    typeof window === 'undefined' ? null : window.localStorage
): boolean {
  return readBoolean(UNIVERSITY_SECTION_COLLAPSED_STORAGE_KEY, storage)
}

export function persistUniversitySectionCollapsed(
  collapsed: boolean,
  storage: StorageWriter | null =
    typeof window === 'undefined' ? null : window.localStorage
): void {
  persistBoolean(UNIVERSITY_SECTION_COLLAPSED_STORAGE_KEY, collapsed, storage)
}

export function readUniversitySectionShowAll(
  storage: StorageReader | null =
    typeof window === 'undefined' ? null : window.localStorage
): boolean {
  return readBoolean(UNIVERSITY_SECTION_SHOW_ALL_STORAGE_KEY, storage)
}

export function persistUniversitySectionShowAll(
  showAll: boolean,
  storage: StorageWriter | null =
    typeof window === 'undefined' ? null : window.localStorage
): void {
  persistBoolean(UNIVERSITY_SECTION_SHOW_ALL_STORAGE_KEY, showAll, storage)
}
