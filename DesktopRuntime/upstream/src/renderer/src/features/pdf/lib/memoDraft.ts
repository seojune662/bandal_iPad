/**
 * Draft state for a highlight's memo.
 *
 * This lives outside React state on purpose. The highlight popover is
 * dismissed from a **capture-phase** `pointerdown` listener, which unmounts the
 * textarea *before* the browser moves focus — and Chrome fires no `blur` for a
 * focused element that is removed from the DOM. A commit that hangs off `blur`
 * alone therefore drops the memo silently, which is the single worst bug in the
 * lecture-note loop.
 *
 * So the authoritative value lives here, and every exit path (outside click,
 * Escape, ⌘↩, the save button, the AI button, unmount) funnels through
 * `commit()`. `commit()` is idempotent, so wiring it to several paths at once —
 * belt *and* braces — is safe.
 */

/** What actually gets persisted: trimmed, with "empty" collapsed to `null`. */
export function normalizeMemo(draft: string): string | null {
  const trimmed = draft.trim()
  return trimmed.length === 0 ? null : trimmed
}

export interface MemoDraft {
  /** Current editor value. */
  value(): string
  /** True when the value differs from what is known to be persisted. */
  isDirty(): boolean
  /** Record a keystroke. */
  setValue(next: string): void
  /**
   * Adopt a value persisted elsewhere (the annotation prop changed). Only
   * moves the visible value when the user has no unsaved edits, so a late
   * round trip can never clobber live typing.
   */
  syncSaved(saved: string | null): void
  /**
   * Persist when dirty. Idempotent, and a no-op after `abandon()`.
   * Returns whether it actually saved.
   */
  commit(): boolean
  /** Drop unsaved edits, restoring the last persisted value. */
  revert(): void
  /** Give up on this draft entirely — the annotation is being deleted. */
  abandon(): void
}

export function createMemoDraft(
  saved: string | null,
  onSave: (comment: string | null) => void
): MemoDraft {
  let baseline = saved ?? ''
  let value = baseline
  let abandoned = false

  const isDirty = (): boolean => !abandoned && value !== baseline

  return {
    value: () => value,
    isDirty,
    setValue: (next) => {
      value = next
    },
    syncSaved: (next) => {
      const nextBaseline = next ?? ''
      if (!isDirty()) value = nextBaseline
      baseline = nextBaseline
    },
    commit: () => {
      if (!isDirty()) return false
      const normalized = normalizeMemo(value)
      // Treat the draft as persisted immediately so a second exit path (the
      // unmount cleanup, say) does not save the same edit twice.
      baseline = value
      onSave(normalized)
      return true
    },
    revert: () => {
      value = baseline
    },
    abandon: () => {
      abandoned = true
    }
  }
}
