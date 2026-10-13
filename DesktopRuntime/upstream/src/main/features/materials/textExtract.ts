/**
 * [R3] 문서 텍스트 추출 계층 — read_material MCP 도구의 심장.
 *
 * CLI 에이전트는 텍스트 파일과 PDF 는 스스로 읽지만 .docx/.xlsx 같은
 * 바이너리 문서는 못 읽는다. 여기서 mammoth(docx)와 xlsx 로 텍스트를
 * 뽑아 준다. 두 패키지는 devDependencies 지만 main 번들은 electron-vite
 * (rollup)가 만들고 externalizeDepsPlugin 은 `dependencies` 만 외부화하므로
 * 동적 import 가 out/main 에 함께 번들된다 — 설치본 용량은 처음 호출 전에는
 * 로드되지 않는 지연 청크로 지킨다.
 */

import { readFile } from 'node:fs/promises'

/** materialsRepo.TEXT_EXTENSIONS 와 같은 목록 — 그대로 UTF-8 로 읽는다. */
const TEXT_EXTENSIONS = new Set([
  '.md', '.markdown', '.txt', '.csv', '.tsv', '.json', '.yml', '.yaml',
  '.xml', '.html', '.css', '.js', '.ts', '.tex', '.log', '.srt', '.vtt'
])

/** 시트 하나가 통째로 결과를 삼키지 않게 시트당 CSV 행 수를 자른다. */
const MAX_ROWS_PER_SHEET = 500
const MAX_COLUMNS_PER_SHEET = 100

/** 도구 기본값과 같다 — schemas.ts 의 read_material 설명과 짝. */
export const DEFAULT_EXTRACT_MAX_CHARS = 20_000

interface MammothModule {
  extractRawText: (input: { buffer: Buffer }) => Promise<{ value: string }>
}

/** vitest(ESM)와 번들된 CJS 양쪽에서 동작하는 default interop. */
function interop<T>(mod: unknown): T {
  const record = mod as { default?: T }
  return (record.default ?? mod) as T
}

function truncate(text: string, maxChars: number): string {
  const chars = Array.from(text)
  if (chars.length <= maxChars) return text
  return (
    chars.slice(0, maxChars).join('') +
    `\n…(잘림: ${maxChars.toLocaleString()}자 초과분 생략. maxChars를 늘려 다시 요청할 수 있습니다.)`
  )
}

async function extractDocx(absPath: string): Promise<string> {
  const mammoth = interop<MammothModule>(await import('mammoth'))
  const buffer = await readFile(absPath)
  const result = await mammoth.extractRawText({ buffer })
  return result.value
}

async function extractXlsx(absPath: string): Promise<string> {
  const XLSX = interop<typeof import('xlsx')>(await import('xlsx'))
  // readFile 대신 buffer 로 읽는다 — ESM 로드 시 xlsx 의 내부 fs 바인딩
  // (set_fs)이 비어 있을 수 있어 node fs 를 직접 쓰는 쪽이 안전하다.
  const buffer = await readFile(absPath)
  const workbook = XLSX.read(buffer, { type: 'buffer', sheetRows: MAX_ROWS_PER_SHEET })
  const sections: string[] = []
  for (const sheetName of workbook.SheetNames) {
    const sheet = workbook.Sheets[sheetName]
    if (sheet === undefined) continue
    const reference = sheet['!ref']
    if (!reference) { sections.push(`## 시트: ${sheetName}\n`); continue }
    const original = XLSX.utils.decode_range(sheet['!fullref'] ?? reference)
    const range = XLSX.utils.decode_range(reference)
    range.e.r = Math.min(range.e.r, range.s.r + MAX_ROWS_PER_SHEET - 1)
    range.e.c = Math.min(range.e.c, range.s.c + MAX_COLUMNS_PER_SHEET - 1)
    // Clamp BEFORE CSV generation. A sparse !ref can otherwise enumerate
    // billions of empty cells, even though the final text is truncated.
    const csv = XLSX.utils.sheet_to_csv({ ...sheet, '!ref': XLSX.utils.encode_range(range) })
    const omittedRows = Math.max(0, original.e.r - range.e.r)
    const omittedColumns = Math.max(0, original.e.c - range.e.c)
    sections.push(
      `## 시트: ${sheetName}\n${csv}` +
        (omittedRows > 0 ? `\n…(행 ${omittedRows}개 생략)` : '') +
        (omittedColumns > 0 ? `\n…(열 ${omittedColumns}개 생략)` : '')
    )
  }
  return sections.join('\n\n')
}

/**
 * 파일에서 일반 텍스트를 뽑는다. 지원하지 않는 형식(그리고 CLI 가 스스로
 * 읽는 .pdf)은 null. `ext`는 소문자 여부와 무관하게 점 포함 확장자.
 */
export async function extractMaterialText(
  absPath: string,
  ext: string,
  maxChars: number = DEFAULT_EXTRACT_MAX_CHARS
): Promise<string | null> {
  if (!Number.isInteger(maxChars) || maxChars < 1) {
    throw new Error('maxChars must be an integer >= 1')
  }
  const extension = ext.toLowerCase()
  if (extension === '.docx') {
    return truncate(await extractDocx(absPath), maxChars)
  }
  if (extension === '.xlsx' || extension === '.xls') {
    return truncate(await extractXlsx(absPath), maxChars)
  }
  if (TEXT_EXTENSIONS.has(extension)) {
    return truncate(await readFile(absPath, 'utf8'), maxChars)
  }
  // .pdf 포함 — CLI 에이전트가 네이티브로 읽거나 애초에 지원하지 않는 형식.
  return null
}
