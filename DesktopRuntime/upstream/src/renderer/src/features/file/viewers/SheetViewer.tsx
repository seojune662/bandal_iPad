import { useEffect, useId, useMemo, useState } from 'react'
import type { CellObject, ColInfo, WorkSheet } from 'xlsx'
import { sheetPreviewBounds } from '../lib/sheetPreviewBounds'
import type { MaterialFileContent } from '../../../../../shared/types/materials'

interface SheetViewerProps {
  content: MaterialFileContent
  fileName: string
  onError: () => void
}

interface LoadedSheet {
  xlsx: typeof import('xlsx')
  workbook: import('xlsx').WorkBook
}

interface VisibleMerge {
  startRow: number
  endRow: number
  startColumn: number
  endColumn: number
  sourceRow: number
  sourceColumn: number
}

interface SheetView {
  worksheet: WorkSheet | null
  startRow: number
  endRow: number
  startColumn: number
  endColumn: number
  rowCount: number
  columnCount: number
  columnWidths: Array<string | undefined>
  mergesByRow: Map<number, VisibleMerge[]>
  truncated: boolean
}

interface RenderedCell {
  cell: CellObject | undefined
  colSpan: number
  rowSpan: number
}

function fallbackCellText(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (value instanceof Date) return value.toLocaleString()
  if (typeof value === 'object') {
    try {
      return JSON.stringify(value)
    } catch {
      return String(value)
    }
  }
  return String(value)
}

function columnWidth(column: ColInfo | undefined): string | undefined {
  if (column?.wpx !== undefined && Number.isFinite(column.wpx)) {
    return `${Math.max(0, column.wpx)}px`
  }
  if (column?.wch !== undefined && Number.isFinite(column.wch)) {
    return `${Math.max(0, column.wch)}ch`
  }
  return undefined
}

function viewForSheet(loaded: LoadedSheet, sheetName: string): SheetView {
  const worksheet = loaded.workbook.Sheets[sheetName]
  const ref = worksheet?.['!ref']
  if (worksheet === undefined || ref === undefined) {
    return {
      worksheet: null,
      startRow: 0,
      endRow: -1,
      startColumn: 0,
      endColumn: -1,
      rowCount: 0,
      columnCount: 0,
      columnWidths: [],
      mergesByRow: new Map(),
      truncated: false
    }
  }

  const preview = sheetPreviewBounds(loaded.xlsx.utils.decode_range(ref))
  const originalRange = preview.range
  const endRow = originalRange.e.r
  const mergesByRow = new Map<number, VisibleMerge[]>()

  for (const merge of worksheet['!merges'] ?? []) {
    const startRow = Math.max(merge.s.r, originalRange.s.r)
    const endMergeRow = Math.min(merge.e.r, endRow)
    const startColumn = Math.max(merge.s.c, originalRange.s.c)
    const endColumn = Math.min(merge.e.c, originalRange.e.c)
    if (startRow > endMergeRow || startColumn > endColumn) continue

    const visibleMerge: VisibleMerge = {
      startRow,
      endRow: endMergeRow,
      startColumn,
      endColumn,
      sourceRow: merge.s.r,
      sourceColumn: merge.s.c
    }
    for (let row = startRow; row <= endMergeRow; row += 1) {
      const rowMerges = mergesByRow.get(row)
      if (rowMerges === undefined) {
        mergesByRow.set(row, [visibleMerge])
      } else {
        rowMerges.push(visibleMerge)
      }
    }
  }

  mergesByRow.forEach((merges) => {
    merges.sort((left, right) => left.startColumn - right.startColumn)
  })

  const columnCount = originalRange.e.c - originalRange.s.c + 1
  return {
    worksheet,
    startRow: originalRange.s.r,
    endRow,
    startColumn: originalRange.s.c,
    endColumn: originalRange.e.c,
    rowCount: endRow - originalRange.s.r + 1,
    columnCount,
    columnWidths: Array.from({ length: columnCount }, (_, index) =>
      columnWidth(worksheet['!cols']?.[originalRange.s.c + index])
    ),
    mergesByRow,
    truncated: preview.truncated
  }
}

function renderedCell(
  loaded: LoadedSheet,
  view: SheetView,
  row: number,
  column: number
): RenderedCell | null {
  const merge = view.mergesByRow
    .get(row)
    ?.find(
      (candidate) =>
        column >= candidate.startColumn && column <= candidate.endColumn
    )

  if (
    merge !== undefined &&
    (row !== merge.startRow || column !== merge.startColumn)
  ) {
    return null
  }

  const sourceRow = merge?.sourceRow ?? row
  const sourceColumn = merge?.sourceColumn ?? column
  const address = loaded.xlsx.utils.encode_cell({ r: sourceRow, c: sourceColumn })
  return {
    cell: view.worksheet?.[address] as CellObject | undefined,
    colSpan:
      merge === undefined ? 1 : merge.endColumn - merge.startColumn + 1,
    rowSpan: merge === undefined ? 1 : merge.endRow - merge.startRow + 1
  }
}

function formattedCellText(
  loaded: LoadedSheet,
  cell: CellObject | undefined
): string {
  if (cell === undefined) return ''
  try {
    return loaded.xlsx.utils.format_cell(cell)
  } catch {
    return fallbackCellText(cell.v)
  }
}

function usesDateFormat(loaded: LoadedSheet, cell: CellObject): boolean {
  const format =
    typeof cell.z === 'number' ? loaded.xlsx.SSF._table?.[cell.z] : cell.z
  return typeof format === 'string' && loaded.xlsx.SSF.is_date(format)
}

function isRightAligned(loaded: LoadedSheet, cell: CellObject | undefined): boolean {
  return (
    cell !== undefined &&
    (cell.t === 'n' || cell.t === 'd' || usesDateFormat(loaded, cell))
  )
}

export function SheetViewer({
  content,
  fileName,
  onError
}: SheetViewerProps): JSX.Element {
  const [loaded, setLoaded] = useState<LoadedSheet | null>(null)
  const [activeSheet, setActiveSheet] = useState('')
  const tabIdPrefix = useId()

  useEffect(() => {
    let cancelled = false
    setLoaded(null)
    setActiveSheet('')

    void import('xlsx')
      .then((xlsx) => {
        const workbook = xlsx.read(content.data, {
          type: content.encoding === 'base64' ? 'base64' : 'string',
          cellDates: true,
          cellNF: true,
          cellStyles: true
        })
        if (cancelled) return
        setLoaded({ xlsx, workbook })
        setActiveSheet(workbook.SheetNames[0] ?? '')
      })
      .catch(() => {
        if (!cancelled) onError()
      })

    return () => {
      cancelled = true
    }
  }, [content, onError])

  const sheetView = useMemo(
    () =>
      loaded === null
        ? null
        : viewForSheet(loaded, activeSheet),
    [activeSheet, loaded]
  )

  if (loaded === null) {
    return (
      <div className="file-status" role="status">
        스프레드시트를 읽는 중…
      </div>
    )
  }

  const panelId = `${tabIdPrefix}-panel`
  const activeSheetIndex = loaded.workbook.SheetNames.indexOf(activeSheet)

  const selectSheet = (index: number): void => {
    const sheetName = loaded.workbook.SheetNames[index]
    if (sheetName === undefined) return
    setActiveSheet(sheetName)
    window.requestAnimationFrame(() => {
      document.getElementById(`${tabIdPrefix}-tab-${index}`)?.focus()
    })
  }

  return (
    <div className="file-sheet">
      <div className="file-sheet__toolbar">
        <div className="file-sheet__tabs" role="tablist" aria-label="시트 선택">
          {loaded.workbook.SheetNames.map((sheetName, index) => {
            const tabId = `${tabIdPrefix}-tab-${index}`
            return (
              <button
                key={sheetName}
                id={tabId}
                type="button"
                className="file-sheet__tab"
                role="tab"
                aria-controls={panelId}
                aria-selected={sheetName === activeSheet}
                tabIndex={sheetName === activeSheet ? 0 : -1}
                onClick={() => setActiveSheet(sheetName)}
                onKeyDown={(event) => {
                  let nextIndex: number | null = null
                  if (event.key === 'ArrowLeft') {
                    nextIndex =
                      (index - 1 + loaded.workbook.SheetNames.length) %
                      loaded.workbook.SheetNames.length
                  } else if (event.key === 'ArrowRight') {
                    nextIndex = (index + 1) % loaded.workbook.SheetNames.length
                  } else if (event.key === 'Home') {
                    nextIndex = 0
                  } else if (event.key === 'End') {
                    nextIndex = loaded.workbook.SheetNames.length - 1
                  }
                  if (nextIndex !== null) {
                    event.preventDefault()
                    selectSheet(nextIndex)
                  }
                }}
              >
                {sheetName}
              </button>
            )
          })}
        </div>
        {sheetView?.truncated && (
          <p className="file-notice" role="status">
            시트가 커서 앞부분 {sheetView.rowCount.toLocaleString()}행 · {sheetView.columnCount.toLocaleString()}열만 표시합니다. 전체 내용은 원본 파일에서 확인해 주세요.
          </p>
        )}
      </div>

      <div
        id={panelId}
        className="file-sheet__viewport"
        role="tabpanel"
        aria-label={activeSheetIndex < 0 ? `${fileName} 시트 내용` : undefined}
        aria-labelledby={
          activeSheetIndex < 0
            ? undefined
            : `${tabIdPrefix}-tab-${activeSheetIndex}`
        }
      >
        {sheetView === null ||
        sheetView.worksheet === null ||
        sheetView.rowCount === 0 ||
        sheetView.columnCount === 0 ? (
          <div className="file-status">빈 시트입니다.</div>
        ) : (
          <table className="file-sheet__table">
            <caption className="file-visually-hidden">
              {fileName}의 {activeSheet} 시트
            </caption>
            <colgroup>
              <col className="file-sheet__row-number-column" />
              {sheetView.columnWidths.map((width, index) => (
                <col
                  key={sheetView.startColumn + index}
                  style={width === undefined ? undefined : { width }}
                />
              ))}
            </colgroup>
            <thead>
              <tr>
                <th
                  className="file-sheet__corner-header"
                  aria-label="행 번호"
                />
                {Array.from(
                  { length: sheetView.columnCount },
                  (_, columnOffset) => {
                    const columnIndex = sheetView.startColumn + columnOffset
                    const width = sheetView.columnWidths[columnOffset]
                    return (
                      <th
                        key={columnIndex}
                        scope="col"
                        className={`file-sheet__column-header${width === undefined ? ' file-sheet__column-header--auto' : ''}`}
                        style={
                          width === undefined
                            ? undefined
                            : {
                                width,
                                minWidth: width,
                                maxWidth: width
                              }
                        }
                      >
                        {loaded.xlsx.utils.encode_col(columnIndex)}
                      </th>
                    )
                  }
                )}
              </tr>
            </thead>
            <tbody>
              {Array.from({ length: sheetView.rowCount }, (_, rowOffset) => {
                const rowIndex = sheetView.startRow + rowOffset
                return (
                  <tr key={rowIndex}>
                    <th scope="row" className="file-sheet__row-header">
                      {rowIndex + 1}
                    </th>
                    {Array.from(
                      { length: sheetView.columnCount },
                      (_, columnOffset) => {
                        const columnIndex =
                          sheetView.startColumn + columnOffset
                        const rendered = renderedCell(
                          loaded,
                          sheetView,
                          rowIndex,
                          columnIndex
                        )
                        if (rendered === null) return null

                        return (
                          <td
                            key={columnIndex}
                            colSpan={rendered.colSpan}
                            rowSpan={rendered.rowSpan}
                            className={
                              isRightAligned(loaded, rendered.cell)
                                ? 'file-sheet__cell--number'
                                : undefined
                            }
                          >
                            {formattedCellText(loaded, rendered.cell)}
                          </td>
                        )
                      }
                    )}
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  )
}
