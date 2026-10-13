import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import crypto from 'node:crypto'
import { deflateSync } from 'node:zlib'

// A generated image fixture, independent of a raster editor or renderer. Its
// borders make unintended page scaling/cropping visible in exported PDF QA.
function slidePng(width, height) {
  const crc = data => { let value = 0xffffffff; for (const byte of data) { value ^= byte; for (let bit = 0; bit < 8; bit++) value = (value >>> 1) ^ (0xedb88320 & -(value & 1)) } return (value ^ 0xffffffff) >>> 0 }
  const chunk = (type, bytes) => { const data = Buffer.concat([Buffer.from(type), bytes]), result = Buffer.alloc(bytes.length + 12); result.writeUInt32BE(bytes.length); data.copy(result, 4); result.writeUInt32BE(crc(data), result.length - 4); return result }
  const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2
  const scanlines = Buffer.alloc((width * 3 + 1) * height)
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) { const offset = y * (width * 3 + 1) + 1 + x * 3, border = x < 8 || y < 8 || x >= width - 8 || y >= height - 8; scanlines[offset] = border ? 30 : 242; scanlines[offset + 1] = border ? 100 : 247; scanlines[offset + 2] = border ? 180 : 253 }
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', header), chunk('IDAT', deflateSync(scanlines)), chunk('IEND', Buffer.alloc(0))])
}

export async function testFeatures({ invoke, course, note, environment, require, qaPath }) {
  await invoke('materials:tree', { courseId: course.id })
  await invoke('context:rebuild', { courseId: course.id })
  const dossier = fs.readFileSync(path.join(course.folderPath, '.bandal/COURSE.md'), 'utf8')
  assert.ok(dossier.includes(course.name)); assert.ok(dossier.includes(note.relPath)); assert.match(dossier, /인용 데이터/)
  const attachment = path.join(environment.tempPath, '첨부 원본.txt'); fs.writeFileSync(attachment, 'original attachment bytes')
  const imported = await invoke('chat:importAttachments', { courseId: course.id, paths: [attachment, attachment] })
  assert.equal(imported.length, 2); assert.notEqual(imported[0].relPath, imported[1].relPath)
  for (const file of imported) { assert.equal(file.name, '첨부 원본.txt'); assert.equal(fs.readFileSync(path.join(course.folderPath, file.relPath), 'utf8'), 'original attachment bytes') }
  await assert.rejects(invoke('chat:importAttachments', { courseId: course.id, paths: ['relative.txt'] }), /파일/)
  assert.equal(fs.readFileSync(attachment, 'utf8'), 'original attachment bytes')
  const tools = await invoke('study:tools', {}); assert.ok(tools.tools.some(tool => tool.id === 'summary' && tool.worksOnCourse))
  await assert.rejects(invoke('study:run', { courseId: course.id, tool: 'does-not-exist', relPath: null }))

  const Zip = require('jszip'), zip = new Zip()
  zip.file('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>')
  zip.file('ppt/presentation.xml', '<?xml version="1.0"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldSz cx="9144000" cy="6096000"/></p:presentation>')
  const source = await zip.generateAsync({ type: 'nodebuffer' })
  const material = await invoke('materials:writeFile', { courseId: course.id, dirRelPath: '', fileName: '발표 자료.pptx', encoding: 'base64', data: source.toString('base64') })
  const ref = { courseId: course.id, relPath: material.relPath }
  const prepared = await invoke('presentation:prepare', { ...ref, requestId: crypto.randomUUID() })
  assert.equal(prepared.data, source.toString('base64')); assert.equal(prepared.sizeBytes, source.length)
  await assert.rejects(invoke('presentation:prepare', { courseId: course.id, relPath: note.relPath, requestId: crypto.randomUUID() }), /PPT/)
  await assert.rejects(invoke('presentation:pdfStart', { ...ref, pageCount: 0, includeInk: false }), /1,000/)
  const { sessionId } = await invoke('presentation:pdfStart', { ...ref, pageCount: 1, includeInk: true })
  await assert.rejects(invoke('presentation:pdfFinish', { sessionId }), /슬라이드/)
  const slide = { sessionId, index: 0, width: 900, height: 600, pngBase64: slidePng(900, 600).toString('base64'), text: [{ text: '반달 프레젠테이션 검색 가능한 본문', x: 48, y: 48, width: 650, height: 28, fontSize: 24, rotation: 0 }] }
  await assert.rejects(invoke('presentation:pdfPage', { ...slide, index: 1 }), /순서/)
  await invoke('drawings:create', { ...ref, page: 1, kind: 'textbox', data: { box: { x: .06, y: .12, width: .82, height: .3 }, text: '원본 PPTX → PDF\n반달 발표 필기' }, style: { color: 'ink', width: .003, opacity: 1, fontSizePt: 28, bold: true } })
  await invoke('presentation:pdfPage', slide)
  await assert.rejects(invoke('presentation:pdfPage', slide), /순서/)
  const output = await invoke('presentation:pdfFinish', { sessionId })
  const outputPath = path.join(course.folderPath, output.relPath), { PDFDocument } = require('pdf-lib'), pdf = await PDFDocument.load(fs.readFileSync(outputPath))
  assert.equal(pdf.getPageCount(), 1); assert.deepEqual(pdf.getPage(0).getSize(), { width: 900, height: 600 }); assert.equal(pdf.getTitle(), '발표 자료')
  assert.ok(fs.statSync(outputPath).size > 5000); assert.deepEqual(fs.readFileSync(path.join(course.folderPath, material.relPath)), source)
  fs.mkdirSync(qaPath, { recursive: true }); fs.copyFileSync(outputPath, path.join(qaPath, 'presentation.pdf'))
  await assert.rejects(invoke('presentation:pdfFinish', { sessionId }), /만료/)
  const cancel = await invoke('presentation:pdfStart', { ...ref, pageCount: 1, includeInk: false })
  await invoke('presentation:pdfCancel', cancel); await assert.rejects(invoke('presentation:pdfPage', { ...slide, sessionId: cancel.sessionId }), /만료/)
  assert.deepEqual(fs.readdirSync(path.join(environment.userDataPath, 'presentation-pdf')), [])
  console.log('PASS: original context dossier/attachments/catalog, PPTX prepare, searchable Korean PDF+ink, sequence validation, cancellation, source preservation')
}
