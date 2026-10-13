/**
 * Session-scoped scroll/zoom memory for PDF tabs, keyed by
 * (courseId, relPath). A small LRU keeps the ~20 most recently used
 * documents so reopening a tab lands where the user left off (idea ported
 * from Orca's PdfViewer scroll-position cache — see docs/orca-analysis.md).
 *
 * Module-level singleton on purpose: it must outlive tab mount/unmount but
 * not the window session.
 */

export interface ScrollMemoryEntry {
  /** Last scroll offset of the page scroller, in px. */
  scrollTop: number
  /** scrollHeight at save time — lets restore scale proportionally. */
  scrollHeight: number
  /** Zoom factor relative to fit-width (1 = fit width). */
  zoom: number
  /**
   * Pixel-independent reading position. Older entries may not have it, so
   * restore keeps the scroll-height fallback above for compatibility.
   */
  anchor?: {
    page: number
    pageOffset: number
  }
}

export const SCROLL_MEMORY_CAPACITY = 20

export interface ScrollMemory {
  get(courseId: string, relPath: string): ScrollMemoryEntry | null
  set(courseId: string, relPath: string, entry: ScrollMemoryEntry): void
  /** Number of live entries (exposed for tests). */
  size(): number
  /** Keys in least→most recently used order (exposed for tests). */
  keys(): string[]
}

const keyFor = (courseId: string, relPath: string): string =>
  `${courseId}\u0000${relPath}`

/** Creates an isolated LRU — exported for tests. */
export function createScrollMemory(
  capacity: number = SCROLL_MEMORY_CAPACITY
): ScrollMemory {
  const entries = new Map<string, ScrollMemoryEntry>()

  return {
    get(courseId, relPath) {
      const key = keyFor(courseId, relPath)
      const entry = entries.get(key)
      if (entry === undefined) return null
      // Touch: Map preserves insertion order, so re-insert to mark as MRU.
      entries.delete(key)
      entries.set(key, entry)
      return entry
    },
    set(courseId, relPath, entry) {
      const key = keyFor(courseId, relPath)
      entries.delete(key)
      entries.set(key, entry)
      while (entries.size > capacity) {
        const oldest = entries.keys().next()
        if (oldest.done === true) break
        entries.delete(oldest.value)
      }
    },
    size: () => entries.size,
    keys: () => [...entries.keys()]
  }
}

/** The shared per-window instance used by PdfTab. */
export const pdfScrollMemory: ScrollMemory = createScrollMemory()
