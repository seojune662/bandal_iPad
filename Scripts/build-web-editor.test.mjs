import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { dirname, join, resolve, extname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const modules = [join(root, 'WebEditor/node_modules'), resolve(root, '../bandal/node_modules')].find(directory => existsSync(join(directory, 'playwright/package.json')))
assert.ok(modules, 'Playwright dependency is required for editor interaction checks')
const { chromium } = await import(pathToFileURL(join(modules, 'playwright/index.mjs')).href)
const JSZip = (await import(pathToFileURL(join(modules, 'jszip/lib/index.js')).href)).default
const fixtures = new Map()
fixtures.set('sample.csv', Buffer.from('Name,Score\nAlice,95\nBob,88\n'))
const docx = new JSZip()
docx.file('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>')
docx.file('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>')
docx.file('word/document.xml', '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Office document hello</w:t></w:r></w:p></w:body></w:document>')
fixtures.set('sample.docx', await docx.generateAsync({ type: 'nodebuffer' }))
const pptx = new JSZip()
pptx.file('[Content_Types].xml', '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>')
pptx.file('_rels/.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>')
pptx.file('ppt/presentation.xml', '<?xml version="1.0"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>')
pptx.file('ppt/_rels/presentation.xml.rels', '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>')
pptx.file('ppt/slides/slide1.xml', '<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="7315200" cy="1828800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="3200"/><a:t>Slide hello</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>')
fixtures.set('sample.pptx', await pptx.generateAsync({ type: 'nodebuffer' }))
const assets = join(root, 'App/Resources/Editor')
const server = createServer((request, response) => {
  const path = new URL(request.url ?? '/', 'http://localhost').pathname
  if (path.startsWith('/fixture/')) {
    const fixture = fixtures.get(path.slice('/fixture/'.length))
    if (fixture) { response.setHeader('Content-Type', 'application/octet-stream'); response.end(fixture); return }
  }
  const file = resolve(assets, '.' + (path === '/' ? '/index.html' : path))
  if (!file.startsWith(assets + '/') || !existsSync(file)) { response.writeHead(404).end(); return }
  response.setHeader('Content-Type', ({ '.js': 'text/javascript', '.css': 'text/css', '.html': 'text/html', '.wasm': 'application/wasm' })[extname(file)] ?? 'application/octet-stream')
  response.end(readFileSync(file))
})
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
let browser
try {
  const chrome = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
  browser = await chromium.launch({ headless: true, ...(existsSync(chrome) ? { executablePath: chrome } : {}) })
  const page = await browser.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error.message))
  await page.addInitScript(() => {
    window.savedDocuments = []
    window.webkit = { messageHandlers: { bandalEditor: { postMessage: async message => {
      if (message.type === 'ready') queueMicrotask(() => window.bandalEditor.load({ version: 1, materialID: 'note-a', markdown: '# 첫 번째 필기\n\n원래 내용\n' }))
      if (message.type === 'change') {
        if (window.rejectEditorSave) throw new Error('저장 한도를 넘었습니다. 내용을 복사해 보관해 주세요.')
        window.savedDocuments.push(message)
      }
      return { accepted: true }
    } } } }
  })
  await page.goto(`http://127.0.0.1:${server.address().port}`)
  await page.locator('.ProseMirror h1').waitFor()
  assert.equal(await page.locator('.ProseMirror h1').textContent(), '첫 번째 필기')
  assert.equal(await page.evaluate(() => window.savedDocuments.length), 0, 'initial load must not save or normalize existing markdown')
  await page.locator('.ProseMirror').click()
  await page.keyboard.press('ControlOrMeta+End')
  await page.keyboard.type(' updated')
  await page.waitForFunction(() => window.savedDocuments.at(-1)?.markdown.includes('updated'))
  const first = await page.evaluate(() => window.savedDocuments.at(-1))
  assert.equal(first.materialID, 'note-a')
  assert.equal(first.version, 1)
  await page.evaluate(() => window.bandalEditor.load({ version: 1, materialID: 'note-b', markdown: '# 다른 필기\n\n- [x] 완료\n\n| A | B |\n| - | - |\n| 1 | 2 |\n' }))
  assert.equal(await page.locator('.ProseMirror h1').textContent(), '다른 필기')
  await page.locator('.ProseMirror table').waitFor()
  const before = await page.evaluate(() => window.savedDocuments.length)
  await page.locator('.ProseMirror h1').click()
  await page.keyboard.press('End')
  await page.keyboard.type(' 변경')
  await page.waitForFunction(count => window.savedDocuments.length > count, before)
  assert.equal(await page.evaluate(() => window.savedDocuments.at(-1).materialID), 'note-b')
  await page.evaluate(() => window.bandalEditor.load({ version: 1, materialID: 'note-links', markdown: '[PDF 원문](bandal://material/test-material?page=3)\n\n[외부 자료](https://example.org/lesson)\n' }))
  await page.locator('.ProseMirror a').first().click()
  assert.equal(await page.getByRole('link', { name: '링크 열기' }).getAttribute('href'), 'bandal://material/test-material?page=3')
  assert.match(page.url(), /^http:\/\/127\.0\.0\.1:/, 'selecting a link must not replace the bridged editor')
  await page.locator('.ProseMirror a').nth(1).click()
  assert.equal(await page.getByRole('link', { name: '링크 열기' }).getAttribute('href'), 'https://example.org/lesson')
  await page.evaluate(() => window.bandalEditor.load({ version: 1, materialID: 'after-links', markdown: '다음 문서' }))
  await page.getByRole('link', { name: '링크 열기' }).waitFor({ state: 'detached' })
  assert.equal(await page.getByRole('link', { name: '링크 열기' }).count(), 0, 'selected links must reset when switching documents')
  const countBeforeRejection = await page.evaluate(() => { window.rejectEditorSave = true; return window.savedDocuments.length })
  await page.locator('.ProseMirror').click()
  await page.keyboard.press('ControlOrMeta+End')
  await page.keyboard.type(' rejected text')
  await page.getByText('저장 확인 필요', { exact: true }).waitFor()
  assert.match(await page.locator('.error').textContent(), /저장 한도/)
  assert.match(await page.locator('.ProseMirror').textContent(), /rejected text/, 'rejected edits remain copyable in the editor')
  assert.equal(await page.evaluate(() => window.savedDocuments.length), countBeforeRejection, 'a rejected edit is not acknowledged as saved')
  await page.evaluate(() => { window.rejectEditorSave = false })
  await page.keyboard.type(' now accepted')
  await page.waitForFunction(() => window.savedDocuments.at(-1)?.markdown.includes('now accepted'))
  await page.getByText('자동 저장', { exact: true }).waitFor()
  assert.deepEqual(errors, [])
  console.log('Editor interaction checks passed: load isolation, WYSIWYG edits, native save identity, GFM table/task round trip, document switching.')
  await page.addInitScript(() => {
    window.officeMessages = []
    window.webkit = { messageHandlers: { bandalDocument: { postMessage: async message => {
      window.officeMessages.push(message)
      if (message.type === 'ready') {
        const name = new URL(location.href).searchParams.get('fixture')
        queueMicrotask(() => window.bandalOffice.load({ version: 1, materialID: name, fileName: name, extension: name.split('.').at(-1), source: location.origin + '/fixture/' + name }))
      }
      return { accepted: true }
    } } } }
  })
  await page.goto(`http://127.0.0.1:${server.address().port}/documents.html?fixture=sample.docx`)
  await page.getByText('Office document hello').waitFor()
  await page.goto(`http://127.0.0.1:${server.address().port}/documents.html?fixture=sample.csv`)
  await page.getByText('Alice', { exact: true }).waitFor()
  await page.getByText('95', { exact: true }).waitFor()
  await page.goto(`http://127.0.0.1:${server.address().port}/documents.html?fixture=sample.pptx`)
  await page.waitForFunction(() => window.officeMessages.some(message => message.type === 'complete' || message.type === 'error'))
  const messages = await page.evaluate(() => window.officeMessages)
  assert.equal(messages.find(message => message.type === 'error'), undefined, JSON.stringify(messages))
  const slide = messages.find(message => message.type === 'slide')
  assert.ok(slide, 'PPTX must produce an actual slide bitmap')
  assert.equal(slide.index, 0)
  assert.ok(slide.width > 0 && slide.height > 0)
  assert.ok(slide.png.length > 100)
  assert.ok(slide.text.some(run => run.text.includes('Slide hello')), 'PPTX export must retain searchable text')
  assert.ok(messages.some(message => message.type === 'complete' && message.count === 1))
  assert.deepEqual(errors, [])
  console.log('Office interaction checks passed: actual DOCX conversion, CSV sheet rendering, local PPTX WASM parse/render, ordered native slide transport, searchable text.')
} finally {
  await browser?.close()
  await new Promise(resolve => server.close(resolve))
}
