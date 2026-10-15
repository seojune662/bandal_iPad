import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { mkdtemp, readFile, rm, writeFile, mkdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { createRequire } from 'node:module'
import { dependencies, runtime } from './dependencies.mjs'

// Render the actual shared exporter with WebKit/PDF.js, then compare the
// displayed pixels against a zero-rotation reference. No user PDFs are used.
const { require } = dependencies(), { PDFDocument, degrees } = require('pdf-lib')
const { build } = createRequire(require.resolve('vite'))('esbuild'), { webkit } = require('@playwright/test')
const folder = await mkdtemp(resolve(tmpdir(), 'bandal-export-geometry-'))
const output = process.env.BANDAL_PDF_EVIDENCE ? resolve(process.env.BANDAL_PDF_EVIDENCE) : null
if (output) await mkdir(output, { recursive: true })
await build({ entryPoints: [resolve(runtime, 'upstream/src/main/features/pdf/exportPdf.ts')], outfile: resolve(folder, 'export.cjs'), bundle: true, platform: 'node', format: 'cjs', external: ['electron'], plugins: [{ name: 'shared-pdf-runtime', setup(build) { build.onResolve({ filter: /^(pdf-lib|@pdf-lib\/fontkit)$/ }, args => ({ path: require.resolve(args.path), external: true })) } }] })
const { createPdfExporter } = createRequire(import.meta.url)(resolve(folder, 'export.cjs'))
const timestamp = '2026-10-14T00:00:00Z'
const objects = [
  { kind: 'ink', data: { inkVersion: 5, points: [{ x: .15, y: .87, p: .1, t: 0 }, { x: .3, y: .9, p: .8, t: 8 }, { x: .45, y: .85, p: .2, t: 16 }, { x: .6, y: .9, p: .5, t: 24 }] }, style: { color: 'green', width: .012, opacity: .7 } },
  { kind: 'highlighter', data: { inkVersion: 5, points: [{ x: .6, y: .5, p: .1, t: 0 }, { x: .7, y: .55, p: .8, t: 8 }, { x: .8, y: .5, p: .2, t: 16 }, { x: .9, y: .55, p: .5, t: 24 }] }, style: { color: 'yellow', width: .04, opacity: .3 } },
  { kind: 'ink', data: { inkVersion: 4, points: [{ x: .15, y: .87, p: .1, t: 0 }, { x: .3, y: .9, p: .8, t: 8 }, { x: .45, y: .85, p: .2, t: 16 }, { x: .6, y: .9, p: .5, t: 24 }] }, style: { color: 'green', width: .012, opacity: .7 } },
  { kind: 'highlighter', data: { inkVersion: 4, points: [{ x: .6, y: .5, p: .1, t: 0 }, { x: .7, y: .55, p: .8, t: 8 }, { x: .8, y: .5, p: .2, t: 16 }, { x: .9, y: .55, p: .5, t: 24 }] }, style: { color: 'yellow', width: .04, opacity: .3 } },
  { kind: 'ink', data: { inkVersion: 3, points: [{ x: .1, y: .12, p: 0, t: 0 }, { x: .2, y: .18, p: .3, t: 4 }, { x: .3, y: .13, p: .05, t: 8 }, { x: .45, y: .2, p: .35, t: 12 }] }, style: { color: 'violet', width: .012, opacity: .7 } },
  { kind: 'ink', data: { inkVersion: 2, points: [{ x: .2, y: .3, p: 0 }] }, style: { color: 'blue', width: .04, opacity: 1 } },
  { kind: 'ink', data: { inkVersion: 2, points: [{ x: .2, y: .55, p: 0 }, { x: .4, y: .7, p: .4 }, { x: .8, y: .6, p: 1 }] }, style: { color: 'ink', width: .012, opacity: 1 } },
  { kind: 'highlighter', data: { inkVersion: 2, points: [{ x: .55, y: .15, p: 1 }, { x: .7, y: .35, p: 0 }, { x: .55, y: .15, p: .5 }] }, style: { color: 'yellow', width: .05, opacity: .3 } },
  { kind: 'rect', data: { box: { x: .15, y: .78, width: .28, height: .08 } }, style: { color: 'red', width: .008, opacity: 1 } },
  { kind: 'textbox', data: { text: '필기 좌표 ABC', box: { x: .15, y: .04, width: .7, height: .08 } }, style: { color: 'ink', width: .003, fontSizePt: 14, opacity: 1 } }
]
for (const rotation of [0, 90, 180, 270]) {
  for (const reference of [false, true]) {
    const pdf = await PDFDocument.create(), quarter = rotation === 90 || rotation === 270
    const page = pdf.addPage(reference ? (quarter ? [560, 400] : [400, 560]) : [640, 800])
    if (!reference) { page.setCropBox(40, 60, 400, 560); page.setRotation(degrees(rotation)) }
    const exporter = createPdfExporter({ getCourseFolder: () => folder,
      listDrawings: () => objects.map((object, i) => ({ ...object, id: String(i), courseId: 'fixture', relPath: 'source.pdf', page: 1, createdAt: timestamp, updatedAt: timestamp })),
      listAnnotations: () => [{ id: 'highlight', courseId: 'fixture', relPath: 'source.pdf', page: 1, anchor: { quote: 'fixture' }, rects: [{ x: .4, y: .4, width: .18, height: .06 }], color: 'green', createdAt: timestamp, updatedAt: timestamp }],
      resolveFontPath: name => resolve(runtime, '../App/Resources/DesktopNative/fonts', name) })
    await exporter.annotateDocument(pdf, { courseId: 'fixture', relPath: 'source.pdf' })
    const name = `${rotation}${reference ? '-reference' : ''}.pdf`, data = await pdf.save()
    await writeFile(resolve(folder, name), data)
    if (output) await writeFile(resolve(output, name), data)
  }
}
const dist = dirname(require.resolve('pdfjs-dist/package.json'))
const server = createServer(async (request, response) => {
  try {
    const name = new URL(request.url, 'http://localhost').pathname.slice(1)
    if (!name) { response.setHeader('Content-Type', 'text/html'); response.end('<canvas id="pdf"></canvas>'); return }
    if (name === 'pdf.mjs' || name === 'pdf.worker.mjs') { response.setHeader('Content-Type', 'text/javascript'); response.end(await readFile(resolve(dist, 'build', name))); return }
    if (!/^(0|90|180|270)(-reference)?\.pdf$/.test(name)) { response.writeHead(404).end(); return }
    response.end(await readFile(resolve(folder, name)))
  } catch (error) { response.writeHead(500).end(String(error)) }
})
await new Promise(done => server.listen(0, '127.0.0.1', done))
const browser = await webkit.launch()
try {
  const page = await browser.newPage({ viewport: { width: 1120, height: 1120 } })
  await page.goto(`http://127.0.0.1:${server.address().port}/`)
  const errors = []; page.on('pageerror', error => errors.push(error.message))
  const results = await page.evaluate(async () => {
    const { getDocument, GlobalWorkerOptions } = await import('/pdf.mjs'); GlobalWorkerOptions.workerSrc = '/pdf.worker.mjs'
    const render = async name => {
      const document = await getDocument(name).promise, page = await document.getPage(1), viewport = page.getViewport({ scale: 1.5 })
      const canvas = window.document.createElement('canvas'); canvas.width = viewport.width; canvas.height = viewport.height
      const context = canvas.getContext('2d'); await page.render({ canvasContext: context, viewport }).promise
      const data = context.getImageData(0, 0, canvas.width, canvas.height).data
      await document.destroy(); return { data, png: canvas.toDataURL(), width: canvas.width, height: canvas.height }
    }
    const results = []
    for (const rotation of [0, 90, 180, 270]) {
      const actual = await render(`${rotation}.pdf`), expected = await render(`${rotation}-reference.pdf`)
      let mismatch = 0, ink = 0, difference = 0
      for (let i = 0; i < actual.data.length; i += 4) {
        if (actual.data[i] < 245 || actual.data[i + 1] < 245 || actual.data[i + 2] < 245) ink++
        const delta = Math.max(...[0, 1, 2].map(c => Math.abs(actual.data[i+c] - expected.data[i+c])))
        if (delta > 8) mismatch++; difference += delta
      }
      results.push({ rotation, mismatch, ink, averageDifference: difference / (actual.data.length / 4), width: actual.width, height: actual.height, expectedWidth: expected.width, expectedHeight: expected.height, png: actual.png })
    }
    return results
  })
  for (const { png, ...result } of results) {
    assert.equal(result.width, result.expectedWidth); assert.equal(result.height, result.expectedHeight)
    assert.ok(result.ink > 1000, 'A blank render cannot pass')
    assert.ok(result.mismatch / result.ink < .03 && result.averageDifference < .2, JSON.stringify(result))
    if (output) await writeFile(resolve(output, `${result.rotation}.png`), Buffer.from(png.split(',')[1], 'base64'))
    console.log('PASS: shared ink, dots, pressure, highlights, shapes and Korean text at CropBox rotation', result)
  }
  assert.deepEqual(errors, [])
} finally { await browser.close(); await new Promise(done => server.close(done)); await rm(folder, { recursive: true, force: true }) }
