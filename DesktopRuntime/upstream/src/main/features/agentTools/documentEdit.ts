/**
 * [R4] 문서 편집 계층 — edit_sheet / edit_docx_text 도구의 심장.
 *
 * exceljs 는 read-modify-write 에서 폰트·채움·열 너비·numFmt·병합·수식·
 * 틀 고정을 보존한다(스파이크 검증). docx 는 jszip 으로 word/document.xml
 * 만 열어 <w:t> 노드 안의 텍스트만 바꾼다 — run 서식이 그대로 남는다.
 * 두 패키지는 devDependencies 지만 textExtract 의 mammoth/xlsx 처럼 동적
 * import 로 out/main 에 지연 청크로 번들된다.
 */

import { existsSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import type { CellValue } from 'exceljs'
import { NotFoundError, ValidationError } from '../../db/errors'
import { writeFileAtomic } from '../../lib/atomicWrite'

/** 한 호출이 메인 프로세스를 오래 잡지 못하게 편집 개수를 제한한다. */
export const MAX_SHEET_EDITS = 200
export const MAX_SHEET_APPEND_ROWS = 200
export const MAX_SHEET_ROW_CELLS = 100
export const MAX_DOCX_REPLACEMENTS = 20

/** A1 형식 셀 주소. exceljs 최대 열 XFD/행 1,048,576 을 넉넉히 덮는다. */
const CELL_REF = /^[A-Za-z]{1,3}[1-9][0-9]{0,6}$/

export type SheetCellInput = string | number | boolean | null

export interface SheetCellEdit {
  cell: string
  value: SheetCellInput
}

export interface SheetEditRequest {
  edits: SheetCellEdit[]
  appendRows: SheetCellInput[][]
}

export interface SheetEditResult {
  sheet: string
  edited: number
  appended: number
}

export interface DocxReplacement {
  find: string
  replace: string
}

export type DocxReplaceScope = 'first' | 'all'

export interface DocxReplacementCount {
  find: string
  count: number
}

/** vitest(ESM)와 번들된 CJS 양쪽에서 동작하는 default interop. */
function interop<T>(mod: unknown): T {
  const record = mod as { default?: T }
  return (record.default ?? mod) as T
}

function cellInput(value: unknown, field: string): SheetCellInput {
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'boolean' ||
    (typeof value === 'number' && Number.isFinite(value))
  ) {
    return value as SheetCellInput
  }
  throw new ValidationError(
    `${field} must be a string, finite number, boolean or null`
  )
}

/** '=SUM(A1:A3)' 처럼 = 로 시작하는 문자열은 수식으로 저장한다. */
function toCellValue(value: SheetCellInput): CellValue {
  if (typeof value === 'string' && value.length > 1 && value.startsWith('=')) {
    return { formula: value.slice(1) }
  }
  return value
}

/** edit_sheet 입력의 edits / appendRows 를 검증해 정규화한다. */
export function parseSheetEditRequest(
  input: Record<string, unknown>
): SheetEditRequest {
  const edits: SheetCellEdit[] = []
  if (input['edits'] !== undefined) {
    const raw = input['edits']
    if (!Array.isArray(raw) || raw.length === 0) {
      throw new ValidationError('edits must be a non-empty array')
    }
    if (raw.length > MAX_SHEET_EDITS) {
      throw new ValidationError(
        `한 호출의 셀 수정 상한은 ${MAX_SHEET_EDITS}개입니다`
      )
    }
    for (const [index, entry] of raw.entries()) {
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
        throw new ValidationError(`edits[${index}] must be an object`)
      }
      const record = entry as Record<string, unknown>
      const cell = record['cell']
      if (typeof cell !== 'string' || !CELL_REF.test(cell.trim())) {
        throw new ValidationError(
          `edits[${index}].cell must be an A1-style address like "B2"`
        )
      }
      if (!Object.prototype.hasOwnProperty.call(record, 'value')) {
        throw new ValidationError(`edits[${index}].value is required`)
      }
      edits.push({
        cell: cell.trim().toUpperCase(),
        value: cellInput(record['value'], `edits[${index}].value`)
      })
    }
  }

  const appendRows: SheetCellInput[][] = []
  if (input['appendRows'] !== undefined) {
    const raw = input['appendRows']
    if (!Array.isArray(raw) || raw.length === 0) {
      throw new ValidationError('appendRows must be a non-empty array')
    }
    if (raw.length > MAX_SHEET_APPEND_ROWS) {
      throw new ValidationError(
        `한 호출의 행 추가 상한은 ${MAX_SHEET_APPEND_ROWS}개입니다`
      )
    }
    for (const [rowIndex, row] of raw.entries()) {
      if (!Array.isArray(row)) {
        throw new ValidationError(`appendRows[${rowIndex}] must be an array`)
      }
      if (row.length > MAX_SHEET_ROW_CELLS) {
        throw new ValidationError(
          `한 행의 셀 상한은 ${MAX_SHEET_ROW_CELLS}개입니다`
        )
      }
      appendRows.push(
        row.map((value, cellIndex) =>
          cellInput(value, `appendRows[${rowIndex}][${cellIndex}]`)
        )
      )
    }
  }

  if (edits.length === 0 && appendRows.length === 0) {
    throw new ValidationError(
      'edits 또는 appendRows 중 적어도 하나는 있어야 합니다'
    )
  }
  return { edits, appendRows }
}

/**
 * .xlsx 를 읽어 셀 수정과 행 추가를 적용하고 같은 자리에 저장한다.
 * exceljs read-modify-write 는 서식·병합·수식·틀 고정을 보존한다.
 */
export async function applySheetEdits(input: {
  absPath: string
  sheetName: string | undefined
  request: SheetEditRequest
}): Promise<SheetEditResult> {
  if (!existsSync(input.absPath)) {
    throw new NotFoundError('material', input.absPath)
  }
  const ExcelJS = interop<typeof import('exceljs')>(await import('exceljs'))
  const workbook = new ExcelJS.Workbook()
  await workbook.xlsx.readFile(input.absPath)

  const worksheet =
    input.sheetName === undefined
      ? workbook.worksheets[0]
      : workbook.getWorksheet(input.sheetName)
  if (worksheet === undefined) {
    const names = workbook.worksheets
      .map((sheet) => `«${sheet.name}»`)
      .join(', ')
    throw new ValidationError(
      input.sheetName === undefined
        ? '시트가 하나도 없는 통합 문서입니다'
        : `시트 «${input.sheetName}» 가 없습니다. 있는 시트: ${names}`
    )
  }

  for (const edit of input.request.edits) {
    worksheet.getCell(edit.cell).value = toCellValue(edit.value)
  }
  for (const row of input.request.appendRows) {
    worksheet.addRow(row.map(toCellValue))
  }
  const buffer = await workbook.xlsx.writeBuffer()
  writeFileAtomic(input.absPath, Buffer.from(buffer))
  return {
    sheet: worksheet.name,
    edited: input.request.edits.length,
    appended: input.request.appendRows.length
  }
}

/** edit_docx_text 입력의 replacements 를 검증해 정규화한다. */
export function parseDocxReplacements(
  input: Record<string, unknown>
): DocxReplacement[] {
  const raw = input['replacements']
  if (!Array.isArray(raw) || raw.length === 0) {
    throw new ValidationError('replacements must be a non-empty array')
  }
  if (raw.length > MAX_DOCX_REPLACEMENTS) {
    throw new ValidationError(
      `한 호출의 찾아 바꾸기 상한은 ${MAX_DOCX_REPLACEMENTS}개입니다`
    )
  }
  return raw.map((entry, index) => {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new ValidationError(`replacements[${index}] must be an object`)
    }
    const record = entry as Record<string, unknown>
    const find = record['find']
    const replace = record['replace']
    if (typeof find !== 'string' || find.length === 0) {
      throw new ValidationError(
        `replacements[${index}].find must be a non-empty string`
      )
    }
    if (typeof replace !== 'string') {
      throw new ValidationError(
        `replacements[${index}].replace must be a string`
      )
    }
    return { find, replace }
  })
}

/**
 * XML 텍스트 노드의 다섯 가지 표준 엔티티. find 문자열은 학생이 보는
 * "해독된" 텍스트이므로, 매칭 전에 해독하고 바꾼 뒤 다시 부호화한다.
 */
function decodeXmlText(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

function encodeXmlText(text: string): string {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

/** 텍스트 노드 내용에 [^<]* — w:t 안에는 마크업이 올 수 없다. */
const W_T_NODE = /(<w:t(?:\s[^>]*)?>)([^<]*)(<\/w:t>)/g

export interface DocxReplaceOutcome {
  xml: string
  replaced: DocxReplacementCount[]
  total: number
}

/**
 * word/document.xml 문자열에서 <w:t> 노드 안의 텍스트만 찾아 바꾼다.
 * 알려진 한계: 한 run 안에서 온전히 나타나는 문구만 매칭된다 — 문구
 * 중간에 서식이 바뀌어 run 이 갈라지면 찾지 못한다.
 */
export function replaceDocumentXmlText(
  xml: string,
  replacements: DocxReplacement[],
  scope: DocxReplaceScope
): DocxReplaceOutcome {
  const replaced: DocxReplacementCount[] = []
  let current = xml
  let total = 0

  for (const { find, replace } of replacements) {
    let count = 0
    current = current.replace(W_T_NODE, (whole, open: string, inner: string, close: string) => {
      if (scope === 'first' && count > 0) return whole
      const decoded = decodeXmlText(inner)
      if (scope === 'first') {
        const index = decoded.indexOf(find)
        if (index === -1) return whole
        count += 1
        const next =
          decoded.slice(0, index) + replace + decoded.slice(index + find.length)
        return open + encodeXmlText(next) + close
      }
      const parts = decoded.split(find)
      if (parts.length === 1) return whole
      count += parts.length - 1
      return open + encodeXmlText(parts.join(replace)) + close
    })
    replaced.push({ find, count })
    total += count
  }

  return { xml: current, replaced, total }
}

export interface PreparedDocxEdit {
  replaced: DocxReplacementCount[]
  total: number
  /** total > 0 이고 확인·백업이 끝난 뒤에만 호출한다. */
  write: () => Promise<void>
}

/**
 * .docx 를 열어 바꾼 결과를 계산만 해 둔다. 실제 쓰기는 확인과 백업이
 * 끝난 뒤 write() 로 미룬다 — 일치가 0이면 아무것도 쓰지 않기 위해서다.
 */
export async function prepareDocxTextEdit(input: {
  absPath: string
  replacements: DocxReplacement[]
  scope: DocxReplaceScope
}): Promise<PreparedDocxEdit> {
  if (!existsSync(input.absPath)) {
    throw new NotFoundError('material', input.absPath)
  }
  const JSZip = interop<typeof import('jszip')>(await import('jszip'))
  const zip = await JSZip.loadAsync(await readFile(input.absPath))
  const entry = zip.file('word/document.xml')
  if (entry === null) {
    throw new ValidationError(
      'word/document.xml 이 없습니다 — 올바른 .docx 파일이 아닙니다'
    )
  }
  const xml = await entry.async('string')
  const outcome = replaceDocumentXmlText(xml, input.replacements, input.scope)
  return {
    replaced: outcome.replaced,
    total: outcome.total,
    async write() {
      zip.file('word/document.xml', outcome.xml)
      const buffer = await zip.generateAsync({
        type: 'nodebuffer',
        compression: 'DEFLATE'
      })
      writeFileAtomic(input.absPath, buffer)
    }
  }
}
