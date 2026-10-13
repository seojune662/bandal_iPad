import { PDFDocument, degrees } from 'pdf-lib'
import { createPdfExporter } from '../upstream/src/main/features/pdf/exportPdf'
import { createBoardPdfExporter } from '../upstream/src/main/features/canvas/exportBoardPdf'
import { resolveInsideReal } from '../upstream/src/main/db/validate'
import { env } from './native'
import { Buffer } from './shims/buffer'
import { readFile, writeFile } from './shims/fs-promises'
import { join, basename } from './shims/path'

export function installPdfExport(deps: { handle: (channel: string, fn: (request: any) => any) => void; courses: any; drawings: any; annotations: any; canvas: any; materials: any; changed: (id: string) => void }) {
  const fontPath = (file: string) => join((env() as any).pdfFontPath ?? join(env().userDataPath, 'PDF', 'fonts'), file)
  const exporter = createPdfExporter({ getCourseFolder: id => deps.courses.getFolder(id),
    listDrawings: (id, path) => deps.drawings.listForFile(id, path), listAnnotations: (id, path) => deps.annotations.listForFile({ courseId: id, relPath: path }), resolveFontPath: fontPath })
  const boardExporter = createBoardPdfExporter({ openBoard: id => deps.canvas.open(id), getCourseFolder: id => deps.courses.getFolder(id), resolveFontPath: fontPath })
  deps.handle('canvas:exportPdf', async request => {
    const result = await boardExporter.exportBoard(request.boardId), board = deps.canvas.open(request.boardId).board
    deps.materials.invalidateTree(board.courseId); deps.materials.recordAdded(board.courseId, result.relPath); deps.changed(board.courseId)
    return result
  })
  async function annotatedBytes(request:any):Promise<Uint8Array> {
    const source = resolveInsideReal(deps.courses.getFolder(request.courseId), request.relPath)
    const pdf = await PDFDocument.load(await readFile(source)), overlay = await PDFDocument.create()
    const sourcePages = pdf.getPages()
    for (const page of sourcePages) {
      const { width, height } = page.getCropBox(), rotation = ((page.getRotation().angle % 360) + 360) % 360
      if (![0, 90, 180, 270].includes(rotation)) throw new Error('PDF page rotation is unsupported')
      overlay.addPage(rotation === 90 || rotation === 270 ? [height, width] : [width, height])
    }
    // Reuse the desktop text, pressure, style, image and highlight renderer in
    // its own displayed-page coordinates. Only the page placement is adapted.
    await exporter.annotateDocument(overlay, request)
    // pdf-lib embeds font subsets lazily. Flush before copying page resources
    // so Korean search/copy text retains its font stream and ToUnicode CMap.
    await overlay.flush()
    const markedPages = new Set<number>([
      ...deps.drawings.listForFile(request.courseId, request.relPath),
      ...deps.annotations.listForFile({ courseId: request.courseId, relPath: request.relPath })
    ].map((entry: any) => entry.page))
    for (let index = 0; index < sourcePages.length; index++) {
      if (!markedPages.has(index + 1)) continue
      const page = sourcePages[index]!, crop = page.getCropBox(), rotation = ((page.getRotation().angle % 360) + 360) % 360
      const embedded = await pdf.embedPage(overlay.getPages()[index]!)
      page.drawPage(embedded, { x: crop.x + (rotation === 90 || rotation === 180 ? crop.width : 0),
        y: crop.y + (rotation === 180 || rotation === 270 ? crop.height : 0), rotate: degrees(rotation) })
    }
    return pdf.save()
  }
  deps.handle('pdf:exportAnnotated', async request => {
    const bytes=await annotatedBytes(request)
    const save = (globalThis as any).__bandalPlatform?.invoke
    if (!save) throw new Error('Native PDF export destination is unavailable')
    const result = await save('native:saveFile', { suggestedName: basename(request.relPath).replace(/\.pdf$/i, '') + ' (주석).pdf', data: Buffer.from(bytes).toString('base64'), mime: 'application/pdf' })
    return { savedPath: result.saved ? result.path ?? null : null }
  })
  return {exporter,exportAnnotated:async(request:any,savePath:string):Promise<void>=>{await writeFile(savePath,await annotatedBytes(request))}}
}
