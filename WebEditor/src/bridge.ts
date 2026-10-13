export interface EditorDocument { version: 1; materialID: string; markdown: string }
type EditorMessage = { version: 1; type: 'ready' | 'error' } | (EditorDocument & { type: 'change' })

declare global {
  interface Window {
    webkit?: { messageHandlers?: { bandalEditor?: { postMessage(message: EditorMessage): Promise<{ accepted: boolean }> } } }
    bandalEditor: { load(document: EditorDocument): void; getMarkdown(): string }
  }
}

export async function send(message: EditorMessage): Promise<boolean> {
  const handler = window.webkit?.messageHandlers?.bandalEditor
  if (!handler) return false
  const result = await handler.postMessage(message)
  if (result?.accepted !== true) throw new Error('변경 내용을 반영하지 못했어요.')
  return true
}

export function isEditorDocument(value: unknown): value is EditorDocument {
  if (value === null || typeof value !== 'object') return false
  const candidate = value as Partial<EditorDocument>
  return candidate.version === 1 && typeof candidate.materialID === 'string' && candidate.materialID.length > 0 &&
    typeof candidate.markdown === 'string' && candidate.markdown.length <= 8 * 1024 * 1024
}
