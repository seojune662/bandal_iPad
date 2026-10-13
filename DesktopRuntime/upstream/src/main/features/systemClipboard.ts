import { createHash } from 'node:crypto'
import { clipboard, nativeImage } from 'electron'

let generation = 0
const snapshots = new Map<number, string>()
function fingerprint(): string {
  const hash = createHash('sha256')
  for (const format of clipboard.availableFormats().sort()) {
    hash.update(format)
    hash.update(clipboard.readBuffer(format))
  }
  return hash.digest('hex')
}

export function beginClipboardCopy(): number {
  snapshots.clear()
  const token = ++generation
  snapshots.set(token, fingerprint())
  return token
}

export function writeImageClipboard(input: {
  token: number; png: string | null; html: string; text: string
}): { written: boolean } {
  const snapshot = snapshots.get(input.token)
  snapshots.delete(input.token)
  if (input.token !== generation || snapshot === undefined || snapshot !== fingerprint()) return { written: false }
  if (input.html.length + (input.png?.length ?? 0) > 64 * 1024 * 1024) throw new Error('복사할 이미지가 너무 큽니다.')
  const image = input.png === null ? undefined : nativeImage.createFromDataURL(input.png)
  if (image?.isEmpty()) throw new Error('이미지를 읽지 못했습니다.')
  clipboard.write({ html: input.html, text: input.text, ...(image ? { image } : {}) })
  return { written: true }
}
