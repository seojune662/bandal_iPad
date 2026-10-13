import { mkdir, open, readFile, readdir, stat } from 'node:fs/promises'
import JSZip from 'jszip'
import { randomUUID } from 'node:crypto'
import { join, extname } from 'node:path'
import type { ChatArtifact, CreationKind } from '../../../shared/types/chatCapabilities'
import { assertRealInside } from '../../db/validate'
const extensions: Record<CreationKind, string[]> = {
  image: ['.png', '.jpg', '.jpeg', '.webp', '.svg'], document: ['.docx'], pdf: ['.pdf'], spreadsheet: ['.xlsx'], presentation: ['.pptx']
}
export async function createArtifactFolder(folder: string): Promise<string> {
  const relPath = `생성 결과/${randomUUID()}`
  assertRealInside(folder, join(folder, '생성 결과'))
  await mkdir(join(folder, relPath), { recursive: true })
  return relPath
}
export async function collectChatArtifacts(courseId: string, folder: string, relDir: string, creation: CreationKind): Promise<ChatArtifact[]> {
  const results: ChatArtifact[] = []
  let visited = 0
  async function walk(relPath: string, depth: number): Promise<void> {
    if (depth > 4 || results.length >= 20) return
    const dir = join(folder, relPath)
    assertRealInside(folder, dir)
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      if (++visited > 4000 || results.length >= 20) break
      if (entry.isSymbolicLink()) continue
      const child = `${relPath}/${entry.name}`
      if (entry.isDirectory()) { await walk(child, depth + 1); continue }
      const extension = extname(entry.name).toLowerCase()
      if (!extensions[creation].includes(extension)) continue
      const path = join(folder, child)
      assertRealInside(folder, path)
      const info = await stat(path)
      if (!info.isFile() || info.size === 0 || info.size > 64 * 1024 * 1024) continue
      const handle = await open(path, 'r')
      let valid = false
      try {
        const buffer = Buffer.alloc(512)
        const { bytesRead } = await handle.read(buffer)
        const head = buffer.subarray(0, bytesRead)
        valid = extension === '.pdf' ? head.subarray(0, 5).toString() === '%PDF-'
          : ['.docx', '.xlsx', '.pptx'].includes(extension) ? head[0] === 0x50 && head[1] === 0x4b
          : extension === '.png' ? head.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))
          : ['.jpg', '.jpeg'].includes(extension) ? head[0] === 255 && head[1] === 216
          : extension === '.webp' ? head.subarray(0, 4).toString() === 'RIFF' && head.subarray(8, 12).toString() === 'WEBP'
          : /<svg[\s>]/i.test(head.toString())
      } finally { await handle.close() }
      if (valid && ['.docx', '.xlsx', '.pptx'].includes(extension)) {
        try {
          const archive = await JSZip.loadAsync(await readFile(path))
          const documentPath = extension === '.docx' ? 'word/document.xml' : extension === '.xlsx' ? 'xl/workbook.xml' : 'ppt/presentation.xml'
          valid = archive.file('[Content_Types].xml') !== null && archive.file(documentPath) !== null
        } catch { valid = false }
      }
      if (valid) results.push({ courseId, relPath: child, name: entry.name, kind: creation === 'image' ? 'image' : creation === 'pdf' ? 'pdf' : 'other' })
    }
  }
  await walk(relDir, 0)
  return results
}
