export interface ClipboardSnapshot {
  files: readonly File[]
  text: string
  types: readonly string[]
}

export type ClipboardPastePlan =
  | { kind: 'files'; paths: string[] }
  | { kind: 'images'; files: File[] }
  | { kind: 'text'; text: string }
  | { kind: 'empty'; reason: string }
  | { kind: 'unsupported'; reason: string }

const IMAGE_EXTENSIONS: Record<string, string> = {
  'image/png': 'png',
  'image/jpeg': 'jpeg',
  'image/jpg': 'jpg',
  'image/gif': 'gif',
  'image/webp': 'webp',
  'image/bmp': 'bmp',
  'image/avif': 'avif',
  'image/heic': 'heic',
  'image/svg+xml': 'svg'
}

export function snapshotClipboard(data: DataTransfer): ClipboardSnapshot {
  return {
    files: Array.from(data.files),
    text: data.getData('text/plain'),
    types: Array.from(data.types)
  }
}

export function planClipboardPaste(
  snapshot: ClipboardSnapshot,
  getPathForFile: (file: File) => string
): ClipboardPastePlan {
  const paths = snapshot.files
    .map(getPathForFile)
    .filter((path) => path.length > 0)
  if (paths.length > 0) return { kind: 'files', paths }

  const images = snapshot.files.filter((file) => file.type.startsWith('image/'))
  if (images.length > 0) return { kind: 'images', files: images }

  if (snapshot.text.trim().length > 0) {
    return { kind: 'text', text: snapshot.text }
  }
  if (snapshot.types.length === 0 || snapshot.types.includes('text/plain')) {
    return { kind: 'empty', reason: '클립보드가 비어 있어요.' }
  }
  return {
    kind: 'unsupported',
    reason: '이 클립보드 형식은 자료로 추가할 수 없어요.'
  }
}

export function isEditablePasteTarget(target: EventTarget | null): boolean {
  let element = target as
    | (EventTarget & {
        tagName?: string
        isContentEditable?: boolean
        parentElement?: EventTarget | null
      })
    | null
  while (element !== null) {
    const tagName = element.tagName?.toLowerCase()
    if (
      tagName === 'input' ||
      tagName === 'textarea' ||
      element.isContentEditable === true
    ) {
      return true
    }
    element = element.parentElement ?? null
  }
  return false
}

export function shouldHandleMaterialsPaste(
  sidebarFocused: boolean,
  target: EventTarget | null
): boolean {
  return sidebarFocused && !isEditablePasteTarget(target)
}

export function pastedTimestamp(date: Date): string {
  const pad = (value: number): string => String(value).padStart(2, '0')
  return [
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`,
    `${pad(date.getHours())}.${pad(date.getMinutes())}`
  ].join(' ')
}

export function pastedImageFileName(file: File, date: Date): string {
  const extension = IMAGE_EXTENSIONS[file.type.toLowerCase()] ?? 'png'
  return `붙여넣은 이미지 ${pastedTimestamp(date)}.${extension}`
}

export function pastedTextFileName(date: Date): string {
  return `붙여넣은 텍스트 ${pastedTimestamp(date)}.md`
}

export function isShortWebUrl(text: string): boolean {
  const candidate = text.trim()
  if (candidate.length === 0 || candidate.length > 2048) return false
  try {
    const url = new URL(candidate)
    return url.protocol === 'http:' || url.protocol === 'https:'
  } catch {
    return false
  }
}

export function markdownForPastedText(
  text: string,
  saveUrlAsLink: boolean
): string {
  const candidate = text.trim()
  if (saveUrlAsLink && isShortWebUrl(candidate)) {
    return `[링크](${candidate.replaceAll(')', '\\)')})\n`
  }
  return text
}

export async function fileToBase64(file: File): Promise<string> {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const chunkSize = 32 * 1024
  let binary = ''
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize))
  }
  return window.btoa(binary)
}
