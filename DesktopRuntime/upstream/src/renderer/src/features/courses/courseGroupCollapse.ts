/**
 * 과목 그룹(학기) 섹션의 접힘 상태. courseCollapse.ts 와 같은 패턴이지만
 * 별도 키를 쓴다 — 과목 접힘과 그룹 접힘은 서로 다른 id 공간이다.
 */

export const COLLAPSED_COURSE_GROUPS_STORAGE_KEY =
  'bandal:course-groups:collapsed:v1'

interface StorageReader {
  getItem: (key: string) => string | null
}

interface StorageWriter {
  setItem: (key: string, value: string) => void
}

export function readCollapsedGroupIds(
  storage: StorageReader | null =
    typeof window === 'undefined' ? null : window.localStorage
): Set<string> {
  if (storage === null) return new Set()
  try {
    const parsed: unknown = JSON.parse(
      storage.getItem(COLLAPSED_COURSE_GROUPS_STORAGE_KEY) ?? '[]'
    )
    if (!Array.isArray(parsed)) return new Set()
    return new Set(
      parsed.filter(
        (value): value is string =>
          typeof value === 'string' && value.trim().length > 0
      )
    )
  } catch {
    return new Set()
  }
}

export function persistCollapsedGroupIds(
  ids: ReadonlySet<string>,
  storage: StorageWriter | null =
    typeof window === 'undefined' ? null : window.localStorage
): void {
  if (storage === null) return
  try {
    storage.setItem(
      COLLAPSED_COURSE_GROUPS_STORAGE_KEY,
      JSON.stringify([...ids].sort())
    )
  } catch {
    // localStorage is best-effort (for example, it can be disabled by policy).
  }
}
