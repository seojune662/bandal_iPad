import type { Range } from 'xlsx'

const MAX_ROWS = 2_000
const MAX_COLUMNS = 100
const MAX_CELLS = 20_000

/** Bound both axes: a sparse worksheet may still declare Excel's entire grid. */
export function sheetPreviewBounds(range: Range): { range: Range; truncated: boolean } {
  const columnCount = Math.min(MAX_COLUMNS, Math.max(1, range.e.c - range.s.c + 1))
  const rowLimit = Math.min(MAX_ROWS, Math.floor(MAX_CELLS / columnCount))
  const endRow = Math.min(range.e.r, range.s.r + rowLimit - 1)
  const endColumn = Math.min(range.e.c, range.s.c + columnCount - 1)
  return {
    range: { s: { ...range.s }, e: { r: endRow, c: endColumn } },
    truncated: endRow < range.e.r || endColumn < range.e.c
  }
}
