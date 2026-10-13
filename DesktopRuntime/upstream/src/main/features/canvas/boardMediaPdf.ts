import { readFile } from 'node:fs/promises'
import { degrees, PDFDocument, type PDFEmbeddedPage, type PDFImage, type PDFPage } from 'pdf-lib'
import type { DrawingBox, DrawingShape } from '../../../shared/types/drawing'
import { resolveInsideReal } from '../../db/validate'

/** PDF clip crops are measured in the displayed page, including its rotation. */
export function clipPdfBounds(page: PDFPage, crop: DrawingBox) {
  const box = page.getCropBox()
  const rotation = ((page.getRotation().angle % 360) + 360) % 360
  let x = crop.x, y = 1 - crop.y - crop.height, width = crop.width, height = crop.height
  if (rotation === 90) {
    x = crop.y; y = crop.x; width = crop.height; height = crop.width
  } else if (rotation === 180) {
    x = 1 - crop.x - crop.width; y = crop.y
  } else if (rotation === 270) {
    x = 1 - crop.y - crop.height; y = 1 - crop.x - crop.width; width = crop.height; height = crop.width
  }
  return {
    rotation,
    bounds: {
      left: box.x + x * box.width, bottom: box.y + y * box.height,
      right: box.x + (x + width) * box.width, top: box.y + (y + height) * box.height
    }
  }
}

export function createBoardMediaRenderer(pdf: PDFDocument, folder: string) {
  const documents = new Map<string, Promise<PDFDocument>>()
  const images = new Map<string, Promise<PDFImage>>()
  const clips = new Map<string, Promise<{ page: PDFEmbeddedPage; rotation: number }>>()
  return async (page: PDFPage, shape: DrawingShape): Promise<void> => {
    const box = shape.data.box
    if (box === undefined) throw new Error('사진 또는 클립의 위치를 읽지 못했어요.')
    const { width: pageWidth, height: pageHeight } = page.getSize()
    const x = box.x * pageWidth, y = (1 - box.y - box.height) * pageHeight
    const width = box.width * pageWidth, height = box.height * pageHeight
    const opacity = shape.style.opacity
    if (shape.kind === 'image') {
      const source = shape.data.image
      if (source === undefined) throw new Error('사진의 원본 경로를 찾지 못했어요.')
      let image = images.get(source.relPath)
      if (image === undefined) {
        image = (async () => {
          const bytes = await readFile(resolveInsideReal(folder, source.relPath))
          if (bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) return pdf.embedPng(bytes)
          if (bytes[0] === 0xff && bytes[1] === 0xd8) return pdf.embedJpg(bytes)
          const { nativeImage } = await import('electron')
          const converted = nativeImage.createFromBuffer(bytes)
          if (converted.isEmpty()) throw new Error('사진 형식을 읽지 못했어요.')
          return pdf.embedPng(converted.toPNG())
        })()
        images.set(source.relPath, image)
      }
      try { page.drawImage(await image, { x, y, width, height, opacity }) }
      catch (cause) { throw new Error(`사진 “${source.label}”을 내보내지 못했어요. 원본 파일을 확인해 주세요.`, { cause }) }
      return
    }
    const source = shape.data.clip
    if (source === undefined) throw new Error('클립의 원본 경로를 찾지 못했어요.')
    const key = JSON.stringify([source.relPath, source.page, source.crop])
    let clip = clips.get(key)
    if (clip === undefined) {
      clip = (async () => {
        let document = documents.get(source.relPath)
        if (document === undefined) {
          document = readFile(resolveInsideReal(folder, source.relPath)).then(bytes => PDFDocument.load(bytes))
          documents.set(source.relPath, document)
        }
        const sourcePage = (await document).getPages()[source.page - 1]
        if (sourcePage === undefined) throw new Error('클립의 원본 페이지를 찾지 못했어요.')
        const { bounds, rotation } = clipPdfBounds(sourcePage, source.crop ?? { x: 0, y: 0, width: 1, height: 1 })
        return { page: await pdf.embedPage(sourcePage, bounds), rotation }
      })()
      clips.set(key, clip)
    }
    try {
      const embedded = await clip
      const rotation = embedded.rotation
      page.drawPage(embedded.page, {
        x: x + (rotation === 180 || rotation === 270 ? width : 0),
        y: y + (rotation === 90 || rotation === 180 ? height : 0),
        width: rotation === 90 || rotation === 270 ? height : width,
        height: rotation === 90 || rotation === 270 ? width : height,
        rotate: degrees(-rotation), opacity
      })
    } catch (cause) { throw new Error(`클립 “${source.label}”을 내보내지 못했어요. 원본 PDF를 확인해 주세요.`, { cause }) }
  }
}
