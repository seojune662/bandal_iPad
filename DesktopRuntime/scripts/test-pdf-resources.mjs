import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { dependencies, runtime } from './dependencies.mjs'
import { adaptPlatformSource } from '../renderer/platform/index.mjs'
import { copyPDFResources, verifyPDFResources } from './pdf-resources.mjs'

const { require } = dependencies(), { webkit } = require('@playwright/test'), ts = require('typescript')
const { PDFDocument, PDFName, PDFHexString, beginText, setFontAndSize, moveText, showText, endText } = require('pdf-lib')
const dist = dirname(require.resolve('pdfjs-dist/package.json'))
const temporary = await mkdtemp(resolve(tmpdir(), 'bandal-pdf-resources-'))
const consumers = [
  'features/pdf/PdfTab.tsx', 'features/pdf/renderClip.ts',
  'features/materials/preview/mediaThumbnails.ts', 'features/studyMarket/renderPreview.ts'
]
for (const consumer of consumers) {
  const path = resolve(runtime, 'upstream/src/renderer/src', consumer), source = await readFile(path, 'utf8')
  const adapted = adaptPlatformSource(source, path)?.code
  assert.ok(adapted?.includes('...pdfResourceOptions,'), `Missing local PDF resources: ${consumer}`)
  assert.ok(adapted.includes('configurePdfWorker()'), `Missing worker initialization: ${consumer}`)
  const anchor = consumer.endsWith('PdfTab.tsx') ? 'const PDF_DOCUMENT_OPTIONS = {' : 'pdfjs.getDocument({'
  assert.throws(() => adaptPlatformSource(source.replace(anchor, '// incompatible source'), path), /anchor changed/)
}
await copyPDFResources(temporary)
const manifest = await verifyPDFResources(temporary)
assert.ok(manifest.files.some(file => file.path === 'cmaps/Adobe-Korea1-UCS2.bcmap'))
for (const path of ['LICENSE', 'cmaps/LICENSE', 'standard_fonts/LICENSE_FOXIT', 'standard_fonts/LICENSE_LIBERATION']) {
  assert.ok(manifest.files.some(file => file.path === path), `Missing redistribution notice: ${path}`)
}
// A tiny generated Korean CID-font PDF with no ToUnicode map. Adobe-Korea1
// CIDs 1086–1088 need the bundled CMap even though no user document is included.
const document = await PDFDocument.create(), page = document.addPage([400, 260])
const descriptor = document.context.register(document.context.obj({ Type: 'FontDescriptor', FontName: 'Arial', Flags: 4, FontBBox: [-6, -145, 1003, 880], ItalicAngle: 0, Ascent: 880, Descent: -145, CapHeight: 700, StemV: 80 }))
const descendant = document.context.register(document.context.obj({ Type: 'Font', Subtype: 'CIDFontType0', BaseFont: 'Arial', CIDSystemInfo: { Registry: 'Adobe', Ordering: 'Korea1', Supplement: 0 }, FontDescriptor: descriptor, DW: 1000 }))
// CIDSystemInfo strings are PDF strings, not names.
const info = document.context.lookup(descendant).lookup(PDFName.of('CIDSystemInfo'))
const { PDFString } = require('pdf-lib')
info.set(PDFName.of('Registry'), PDFString.of('Adobe')); info.set(PDFName.of('Ordering'), PDFString.of('Korea1'))
const font = document.context.register(document.context.obj({ Type: 'Font', Subtype: 'Type0', BaseFont: 'Arial', Encoding: 'Identity-H', DescendantFonts: [descendant] }))
const fontName = page.node.newFontDictionary('KoreanCID', font)
page.pushOperators(beginText(), setFontAndSize(fontName, 32), moveText(40, 190), showText(PDFHexString.of('043E043F0440')), endText())
const pdf = process.argv[2] ? await readFile(resolve(process.argv[2])) : Buffer.from(await document.save())
const helper = ts.transpileModule(await readFile(resolve(runtime, 'renderer/platform/pdfResources.ts'), 'utf8'), { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText
const html = await readFile(resolve(runtime, 'renderer/index.html'), 'utf8')
const csp = html.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)?.[1]
assert.ok(csp)
const requests = [], messages = []
const server = createServer(async (request, response) => {
  try {
    const path = new URL(request.url, 'http://localhost').pathname
    if (path === '/' || path === '/index.html') { response.setHeader('Content-Type', 'text/html'); response.setHeader('Content-Security-Policy', csp); response.end('<canvas id="pdf"></canvas>'); return }
    requests.push(path)
    let bytes
    if (path === '/fixture.pdf') bytes = pdf
    else if (path === '/options.mjs') bytes = helper
    else if (path === '/pdf.mjs') bytes = await readFile(resolve(dist, 'build/pdf.mjs'))
    else if (path === '/pdf.worker.mjs') bytes = await readFile(resolve(dist, 'build/pdf.worker.mjs'))
    else if (path.startsWith('/pdfjs/')) bytes = await readFile(resolve(temporary, '.' + path))
    else { response.statusCode = 404; response.end(); return }
    response.setHeader('Content-Type', path.endsWith('.mjs') ? 'text/javascript' : path.endsWith('.wasm') ? 'application/wasm' : 'application/octet-stream')
    response.end(bytes)
  } catch { response.statusCode = 404; response.end() }
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
const browser = await webkit.launch()
try {
  const results = []
  for (const configured of [false, true]) {
    const page = await browser.newPage()
    const warnings = []
    page.on('console', message => { if (message.type() === 'warning' || message.type() === 'error') warnings.push(message.text()) })
    page.on('pageerror', error => messages.push(error.message))
    await page.goto(`http://127.0.0.1:${server.address().port}/index.html`)
    results.push(await page.evaluate(async configured => {
      const pdfjs = await import('/pdf.mjs'), { pdfResourceOptions } = await import('/options.mjs')
      pdfjs.GlobalWorkerOptions.workerSrc = '/pdf.worker.mjs'
      const document = await pdfjs.getDocument({ url: '/fixture.pdf', ...(configured ? pdfResourceOptions : {}) }).promise
      const page = await document.getPage(1), canvas = window.document.querySelector('canvas'), viewport = page.getViewport({ scale: 1 })
      canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height)
      const context = canvas.getContext('2d', { alpha: false })
      await page.render({ canvas, canvasContext: context, viewport }).promise
      const text = await page.getTextContent()
      const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data
      let dark = 0
      for (let i = 0; i < pixels.length; i += 4) if (pixels[i] < 220 || pixels[i + 1] < 220 || pixels[i + 2] < 220) dark++
      const korean = text.items.reduce((count, item) => count + ((item.str ?? '').match(/[가-힣]/g)?.length ?? 0), 0)
      await document.destroy()
      return { dark, korean }
    }, configured))
    if (!configured) assert.ok(warnings.some(warning => warning.includes('cMapUrl')), 'Fixture must reproduce the missing-CMap font failure')
    else assert.deepEqual(warnings, [], 'Bundled resources render without font or CSP warnings')
    await page.close()
  }
  assert.equal(results[0].korean, 0)
  assert.ok(results[1].korean >= 3)
  assert.ok(results[1].dark > results[0].dark + 200, 'Korean glyphs must be painted, not only extracted')
  assert.ok(requests.includes('/pdfjs/cmaps/Adobe-Korea1-UCS2.bcmap'))
  assert.deepEqual(messages, [])
  // The packaged checksum gate must also detect a missing/corrupt resource.
  await writeFile(resolve(temporary, 'pdfjs/cmaps/Adobe-Korea1-UCS2.bcmap'), 'corrupt')
  await assert.rejects(verifyPDFResources(temporary), /resource (size|hash)/)
  console.log(`PDF local resources: all 4 original consumers, ${manifest.files.length} assets/licenses, WebKit Korean CID text+pixels under production CSP, and corruption gate passed`)
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); await rm(temporary, { recursive: true, force: true }) }
