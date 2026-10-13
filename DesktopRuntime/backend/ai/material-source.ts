import { createHash } from '../shims/crypto'
import { readFile, stat } from '../shims/fs-promises'
import { extname } from '../shims/path'
import { native } from '../native'
import { extractMaterialText } from '../../upstream/src/main/features/materials/textExtract'
import type { LearningMaterialSource, LearningMaterialSourceOptions } from '../../upstream/src/main/features/learning/materialSource'
const MAX_BYTES = 50 * 1024 * 1024
const hash = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex')
function cancelled(signal?: AbortSignal) { if (signal?.aborted) { const error = new Error('자료 읽기를 중지했어요.'); error.name = 'AbortError'; throw error } }
/** Callers use the original course real-path validator; native FS validates again. */
export async function extractLearningMaterialSource(absPath: string, options: LearningMaterialSourceOptions = {}): Promise<LearningMaterialSource | null> {
  const maxChars = options.maxChars ?? 200_000, maxPages = options.maxPages ?? 200
  if (!Number.isInteger(maxChars) || maxChars < 1 || maxChars > 200_000 || !Number.isInteger(maxPages) || maxPages < 1 || maxPages > 200) throw new Error('자료 읽기 범위가 올바르지 않아요.')
  cancelled(options.signal)
  const info = await stat(absPath)
  if (!info.isFile() || info.size > MAX_BYTES) throw new Error('학습 자료는 50MiB 이하의 파일이어야 해요.')
  const bytes = await readFile(absPath)
  if (bytes.byteLength > MAX_BYTES) throw new Error('학습 자료는 50MiB 이하의 파일이어야 해요.')
  const contentHash = hash(bytes), extension = extname(absPath).toLowerCase()
  let result: Omit<LearningMaterialSource, 'contentHash'> | null
  if (extension === '.pdf') result = native('pdf.source', { path: absPath, maxChars, maxPages })
  else {
    const text = await extractMaterialText(absPath, extension, maxChars)
    if (text === null) result = null
    else { const marker = text.match(/\n…\(잘림: [\d,]+자 초과분 생략\. maxChars를 늘려 다시 요청할 수 있습니다\.\)$/u); result = { text: marker ? text.slice(0, marker.index) : text, pages: [], truncated: marker !== null } }
  }
  cancelled(options.signal)
  if (hash(await readFile(absPath)) !== contentHash) throw new Error('자료를 읽는 동안 원본이 변경됐어요. 다시 시도해 주세요.')
  return result ? { ...result, contentHash } : null
}
