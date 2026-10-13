import type { MaterialContext } from '../../../../shared/types/chatContext'
const readers = new Map<string, Set<() => MaterialContext>>()
export function registerDocumentContext(id: string, read: () => MaterialContext): () => void {
  const entries = readers.get(id) ?? new Set(); entries.add(read); readers.set(id, entries)
  return () => { entries.delete(read); if (!entries.size) readers.delete(id) }
}
export function readDocumentContexts(): MaterialContext[] {
  return [...readers].flatMap(([id, entries]) => {
    const values: MaterialContext[] = []
    let unavailable = false
    for (const read of entries) { try { values.push(read()) } catch { unavailable = true } }
    if (!values.length) return []
    return [Object.assign({}, ...values, { documentId: id }, unavailable ? { unavailable: true } : {}) as MaterialContext]
  })
}
