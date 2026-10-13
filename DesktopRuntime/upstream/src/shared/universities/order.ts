/**
 * Pure helpers for the user-controlled sidebar order (`serviceOrder`).
 *
 * Every function returns a new array and never touches its input. Unknown
 * ids, a source equal to its target, or a move past either end are all
 * no-ops that hand back an equal copy — the store persists whatever comes
 * out, so a no-op must not scramble the list.
 */

/**
 * Sorts `base` by the position of each id in `order`; ids `order` does not
 * mention keep their relative `base` order and follow the ranked ones.
 * Stable: two ranked entries never swap unless `order` says so.
 */
export function applyServiceOrder<T extends { id: string }>(
  base: readonly T[],
  order: readonly string[]
): T[] {
  if (order.length === 0) return [...base]
  const rank = new Map<string, number>()
  order.forEach((id, index) => {
    if (!rank.has(id)) rank.set(id, index)
  })
  const ranked = base
    .filter((item) => rank.has(item.id))
    .map((item, index) => ({ item, index, rank: rank.get(item.id) ?? 0 }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((entry) => entry.item)
  const rest = base.filter((item) => !rank.has(item.id))
  return [...ranked, ...rest]
}

/** Moves `sourceId` so that it sits immediately before `targetId`. */
export function moveServiceBefore(
  ids: readonly string[],
  sourceId: string,
  targetId: string
): string[] {
  if (sourceId === targetId) return [...ids]
  if (!ids.includes(sourceId) || !ids.includes(targetId)) return [...ids]
  const without = ids.filter((id) => id !== sourceId)
  const targetIndex = without.indexOf(targetId)
  return [...without.slice(0, targetIndex), sourceId, ...without.slice(targetIndex)]
}

/** Moves `sourceId` to the very end of the list. */
export function moveServiceToEnd(ids: readonly string[], sourceId: string): string[] {
  if (!ids.includes(sourceId)) return [...ids]
  return [...ids.filter((id) => id !== sourceId), sourceId]
}

/** Swaps `id` with its neighbour one step up (-1) or down (+1). */
export function moveServiceBy(
  ids: readonly string[],
  id: string,
  delta: -1 | 1
): string[] {
  const from = ids.indexOf(id)
  if (from === -1) return [...ids]
  const to = from + delta
  if (to < 0 || to >= ids.length) return [...ids]
  const next = [...ids]
  next[from] = ids[to] as string
  next[to] = id
  return next
}
