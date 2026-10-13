/**
 * The text box that the toolbar's format row is editing right now.
 *
 * `InkLayer` is mounted once per PDF page (and once per board), and each
 * instance keeps its own selection/draft state. The toolbar lives outside all
 * of them, so the layer that owns the current text box PUBLISHES a target here
 * and the format row reads it. `ownerId` scopes `clear` so a layer losing its
 * selection cannot wipe a target another page just published.
 *
 * Rules for consumers (the format row):
 * - Read `useTextFormatStore.getState().target?.apply` AT EVENT TIME, never a
 *   captured closure: a draft turns into a committed shape on blur, which can
 *   happen between render and click.
 * - Every control that must not commit the edit calls `preventDefault()` on
 *   `onMouseDown`/`onPointerDown`, otherwise the editing textarea blurs.
 * - The row root carries `TEXT_FORMAT_ROW_ATTR`; the layer treats clicks inside
 *   it as "inside" for its outside-click deselect.
 */

import { create } from 'zustand'
import type { DrawingStyle } from '../../../../shared/types/drawing'

export type TextFormatMode = 'draft' | 'editing' | 'selected'

/**
 * A style change. `undefined` REMOVES the field (e.g. `{ fill: undefined }`
 * clears the background) — `Partial<DrawingStyle>` alone cannot express that
 * under `exactOptionalPropertyTypes`, and a stored `fill: undefined` would be
 * dropped by the validators anyway. Merge with `mergeTextStyle`.
 */
export type TextStylePatch = {
  [K in keyof DrawingStyle]?: DrawingStyle[K] | undefined
}

/** `{ ...base, ...patch }` with `undefined` patch values deleting the key. */
export function mergeTextStyle(
  base: DrawingStyle,
  patch: TextStylePatch
): DrawingStyle {
  const next: Record<string, unknown> = { ...base }
  for (const [key, value] of Object.entries(patch)) {
    if (value === undefined) delete next[key]
    else next[key] = value
  }
  return next as unknown as DrawingStyle
}

export interface TextFormatTarget {
  /** The publishing `InkLayer` instance (React `useId`). */
  ownerId: string
  mode: TextFormatMode
  style: DrawingStyle
  /** Draft → local draft style; committed shape → `onUpdate(id, { style })`. */
  apply: (patch: TextStylePatch) => void
  /** Editing only: applies character-level fields to the current selection. */
  applyInline?: (patch: TextStylePatch) => void
}

export interface TextFormatStore {
  target: TextFormatTarget | null
  /** Last writer wins — only one text box is ever being edited. */
  publish: (target: TextFormatTarget) => void
  /** No-op unless the current target belongs to `ownerId`. */
  clear: (ownerId: string) => void
}

export const useTextFormatStore = create<TextFormatStore>()((set) => ({
  target: null,
  publish: (target) => set({ target }),
  clear: (ownerId) =>
    set((state) =>
      state.target !== null && state.target.ownerId === ownerId
        ? { target: null }
        : state
    )
}))

export const TEXT_FORMAT_ROW_ATTR = 'data-ink-format-row'

/** True when `target` sits inside a format row (or is the row itself). */
export function isInsideTextFormatRow(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false
  return target.closest(`[${TEXT_FORMAT_ROW_ATTR}]`) !== null
}
