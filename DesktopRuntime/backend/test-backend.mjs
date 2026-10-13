import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as crypto from 'node:crypto'
import * as os from 'node:os'
import vm from 'node:vm'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { dependencies, runtime as runtimeDirectory } from '../scripts/dependencies.mjs'
const { require } = dependencies()
const SQLite = require('better-sqlite3-node')
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'bandal-jscore-test-'))
const environment = { userDataPath: path.join(directory, 'BandalDesktop'), dataRoot: path.join(directory, 'Courses'), homePath: directory,
  tempPath: path.join(directory, 'Temp'), legacyDataPath: path.join(directory, 'Bandal'), platform: 'ios', version: JSON.parse(fs.readFileSync(path.join(runtimeDirectory,'upstream/package.json'),'utf8')).version, pdfFontPath: fileURLToPath(new URL('../assets/PDF/fonts', import.meta.url)) }
const pdfQA = process.argv.includes('--pdf'), qaPath = fileURLToPath(new URL('./dist/qa-pdf/', import.meta.url))
if (pdfQA) fs.mkdirSync(qaPath, { recursive: true })
for (const value of [environment.userDataPath, environment.dataRoot, environment.tempPath]) fs.mkdirSync(value, { recursive: true })
const database = new SQLite(path.join(environment.userDataPath, 'bandal.db'))
let legacy = { records: [], pending: [] }
if (process.argv.includes('--legacy')) {
  const cid = crypto.randomUUID(), mid = crypto.randomUUID(), nid = crypto.randomUUID(), wid = crypto.randomUUID(), pdf = Buffer.from('%PDF-legacy'), revision = crypto.createHash('sha256').update(pdf).digest('hex')
  const target = path.join(environment.legacyDataPath, 'Materials', mid, 'legacy.pdf')
  fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, pdf)
  const record = (kind, id, payload) => ({ kind, id, payload, revision: 1, formatVersion: 1, deleted: false })
  const objects = Array.from({ length: 9 }, (_, i) => ({ id: crypto.randomUUID(), kind: 'ink', data: { points: [{ x: .1, y: .2, p: .3 }, { x: .2, y: .3, p: .8 }] }, style: { width: .003, color: 'ink', opacity: 1 }, createdAt: '2026-10-13T00:00:00Z', updatedAt: '2026-10-13T00:00:00Z' }))
  const page = { schemaVersion: 1, materialID: mid, documentRevision: revision, page: 1, coordinateSpace: 'unrotated-crop-box-top-left-normalized', geometry: { cropX: 10, cropY: 20, width: 600, height: 800, rotation: 90 }, objects, highlights: [], deletedObjectIDs: [], deletedHighlightIDs: [] }
  legacy = { records: [record('course', `course:${cid}`, { id: cid, name: 'Legacy Course', color: 'green' }),
    record('material', `material:${mid}`, { id: mid, courseID: cid, title: 'PDF', fileName: 'legacy.pdf', revision, kind: 'pdf' }),
    record('material', `material:${nid}`, { id: nid, courseID: cid, title: 'Note', fileName: 'note.md', revision: crypto.randomUUID(), kind: 'note' }),
    record('material', `material:${wid}`, { id: wid, courseID: cid, title: 'Whiteboard', fileName: 'canvas.json', revision: crypto.randomUUID(), kind: 'whiteboard' }),
    record('note', `note:${nid}`, { materialID: nid, markdown: 'saved before pending' }),
    record('drawing', `drawing:${mid}:${revision}:1`, { materialID: mid, documentRevision: revision, page: 1, data: Buffer.from(JSON.stringify(page)).toString('base64') })],
    pending: [{ mutationID: crypto.randomUUID(), id: `note:${nid}`, kind: 'note', payload: { materialID: nid, markdown: 'recovered pending edit' }, fileName: '001.json' }] }
  const rid = crypto.randomUUID(), wave = Buffer.alloc(44 + 16000 * 4)
  wave.write('RIFF'); wave.writeUInt32LE(wave.length - 8, 4); wave.write('WAVEfmt ', 8); wave.writeUInt32LE(16, 16)
  wave.writeUInt16LE(3, 20); wave.writeUInt16LE(1, 22); wave.writeUInt32LE(16000, 24); wave.writeUInt32LE(64000, 28); wave.writeUInt16LE(4, 32); wave.writeUInt16LE(32, 34); wave.write('data', 36); wave.writeUInt32LE(16000 * 4, 40)
  for (let index = 0; index < 16000; index++) wave.writeFloatLE(Math.sin(index * .1) * .5, 44 + index * 4)
  const fileName = `Recordings/${rid}.wav`, wavPath = path.join(environment.legacyDataPath, fileName)
  fs.mkdirSync(path.dirname(wavPath), { recursive: true }); fs.writeFileSync(wavPath, wave)
  legacy.records.push(record('recording', `recording:${rid}`, { id: rid, courseID: cid, title: 'Recorded Lecture', fileName, createdAt: '2026-10-13T00:00:00Z', duration: 1, state: 'completed', segments: [{ id: crypto.randomUUID(), time: 0, text: '한글 전사' }], anchors: [{ id: crypto.randomUUID(), time: .5, materialID: mid, page: 1 }], assetRevision: crypto.createHash('sha256').update(wave).digest('hex'), byteCount: wave.length }))
}
environment.fsConstants={O_RDONLY:fs.constants.O_RDONLY,O_NOFOLLOW:fs.constants.O_NOFOLLOW}
const mcpFixtureKey = crypto.randomBytes(32)
const timers = new Set(), pushes = [], hashes = new Map()
const decode = value => value && typeof value === 'object' && value.__buffer ? Buffer.from(value.__buffer, 'base64') : Array.isArray(value) ? value.map(decode) : value
const native = (op, a) => {
  switch (op) {
    case 'mcp.available': return true
    case 'mcp.encrypt': { const nonce = crypto.randomBytes(12), cipher = crypto.createCipheriv('aes-256-gcm', mcpFixtureKey, nonce); const encrypted = Buffer.concat([cipher.update(a.plaintext, 'utf8'), cipher.final()]); return Buffer.concat([nonce, encrypted, cipher.getAuthTag()]).toString('base64') }
    case 'mcp.decrypt': { const bytes = Buffer.from(a.ciphertext, 'base64'), cipher = crypto.createDecipheriv('aes-256-gcm', mcpFixtureKey, bytes.subarray(0, 12)); cipher.setAuthTag(bytes.subarray(-16)); return Buffer.concat([cipher.update(bytes.subarray(12, -16)), cipher.final()]).toString('utf8') }
    case 'environment': return environment
    case 'sqlite.exec': database.exec(a.sql); return null
    case 'sqlite.query': { const s = database.prepare(a.sql), args = Array.isArray(a.params) ? a.params.map(decode) : [a.params]; if (s.reader) return s.all(...args); s.run(...args); return [] }
    case 'sqlite.run': { const result = database.prepare(a.sql).run(...(Array.isArray(a.params) ? a.params.map(decode) : [a.params])); return { ...result, lastInsertRowid: Number(result.lastInsertRowid) } }
    case 'fs.exists': return fs.existsSync(a.path)
    case 'fs.sha256': return crypto.createHash('sha256').update(fs.readFileSync(a.path)).digest('hex')
    case 'fs.realpath': return fs.realpathSync(a.path)
    case 'fs.readdir': return fs.readdirSync(a.path, { withFileTypes: true }).map(v => ({ name: v.name, isFile: v.isFile(), isDirectory: v.isDirectory(), isSymbolicLink: v.isSymbolicLink() }))
    case 'fs.stat': { const s = (a.followSymlinks ? fs.statSync : fs.lstatSync)(a.path, { bigint: true }); return { size: Number(s.size), mtimeMs: Number(s.mtimeNs) / 1e6, mtimeNs: String(s.mtimeNs), mode: Number(s.mode), isFile: s.isFile(), isDirectory: s.isDirectory(), isSymbolicLink: s.isSymbolicLink() } }
    case 'fs.fstat': { const s=fs.fstatSync(a.fd,{bigint:true});return{size:Number(s.size),mtimeMs:Number(s.mtimeNs)/1e6,mtimeNs:String(s.mtimeNs),mode:Number(s.mode),isFile:s.isFile(),isDirectory:s.isDirectory(),isSymbolicLink:s.isSymbolicLink()} }
    case 'fs.readFile': return fs.readFileSync(a.path).toString(a.encoding)
    case 'fs.writeFile': fs.writeFileSync(a.path, Buffer.from(a.data, a.encoding), { flag: a.flag, mode: a.mode }); return null
    case 'fs.mkdir': fs.mkdirSync(a.path, { recursive: a.recursive, mode: a.mode }); return null
    case 'fs.rename': fs.renameSync(a.from, a.to); return null
    case 'fs.remove': { if (fs.existsSync(a.path) && fs.lstatSync(a.path).isDirectory() && !a.recursive) fs.rmdirSync(a.path); else fs.rmSync(a.path, { recursive: a.recursive, force: a.force }); return null }
    case 'fs.copy': fs.cpSync(a.from, a.to, { recursive: a.recursive, force: a.overwrite, errorOnExist: !a.overwrite }); return null
    case 'fs.access': fs.accessSync(a.path, a.mode); return null
    case 'fs.chmod': fs.chmodSync(a.path, a.mode); return null
    case 'fs.open': return fs.openSync(a.path, a.flags, a.mode)
    case 'fs.close': fs.closeSync(a.fd); return null
    case 'fs.fsync': fs.fsyncSync(a.fd); return null
    case 'fs.ftruncate': fs.ftruncateSync(a.fd, a.length); return null
    case 'fs.read': { const bytes = Buffer.alloc(a.length); return bytes.subarray(0, fs.readSync(a.fd, bytes, 0, bytes.length, a.position)).toString('base64') }
    case 'fs.write': { const bytes = Buffer.from(a.data, 'base64'); return fs.writeSync(a.fd, bytes, 0, bytes.length, a.position) }
    case 'crypto.randomUUID': return crypto.randomUUID()
    case 'crypto.randomBytes': return crypto.randomBytes(a.length).toString('base64')
    case 'crypto.sha256': return crypto.createHash('sha256').update(Buffer.from(a.data, a.encoding)).digest('hex')
    case 'crypto.hashCreate': { const id=crypto.randomUUID();hashes.set(id,crypto.createHash(a.algorithm));return id }
    case 'crypto.hashUpdate': hashes.get(a.id).update(Buffer.from(a.data,'base64'));return null
    case 'crypto.hashDigest': { const hash=hashes.get(a.id);hashes.delete(a.id);return hash.digest('hex') }
    case 'url.parse': { const url = new URL(a.url, a.base); return Object.fromEntries(['href', 'protocol', 'hostname', 'host', 'port', 'pathname', 'search', 'hash', 'username', 'password', 'origin'].map(k => [k, url[k]])) }
    case 'legacy.snapshot': return legacy
    case 'pdf.geometry': return pdfQA && /(?:lecture|renamed)\.pdf$/.test(a.path) ? [0,90,180,270].map((rotation,index)=>({page:index+1,cropBox:{x:50,y:50,width:600,height:800},rotation})) : [{ page: 1, cropBox: { x: 10, y: 20, width: 600, height: 800 }, rotation: 90 }]
    default: throw new Error(`Missing native test operation ${op}`)
  }
}
function runtime() {
  const context = vm.createContext({ console, setTimeout, clearTimeout, AbortController,
    __bandalPlatform: { invoke: async (channel, input) => { if (channel !== 'native:saveFile') throw new Error(`Unmocked platform channel: ${channel}`); const output = path.join(qaPath, input.suggestedName); fs.writeFileSync(output, Buffer.from(input.data, 'base64')); return { saved: true, path: output } } },
    setInterval: (fn, delay) => { const timer = setInterval(fn, delay); timers.add(timer); return timer },
    clearInterval: timer => { timers.delete(timer); clearInterval(timer) },
    __bandalNative: { perform: json => { try { const { op, args } = JSON.parse(json); return JSON.stringify({ ok: true, value: native(op, args) }) }
      catch (error) { return JSON.stringify({ ok: false, error: { message: error.message, code: error.code } }) } },
    emit: (channel, payload) => pushes.push({ channel, payload: JSON.parse(payload) }), log: console.log } })
  vm.runInContext(fs.readFileSync(fileURLToPath(new URL('./dist/backend.js', import.meta.url)), 'utf8'), context)
  return context.BandalBackend
}
try {
  if (legacy.records.length) {
    const ink = legacy.records.find(record => record.kind === 'drawing'), original = ink.payload.data
    const page = JSON.parse(Buffer.from(original, 'base64').toString()); page.geometry.width++
    ink.payload.data = Buffer.from(JSON.stringify(page)).toString('base64')
    assert.throws(() => runtime().initialize(), /geometry does not match/)
    assert.equal(database.prepare('SELECT COUNT(*) n FROM courses').get().n, 0)
    assert.equal(database.prepare('SELECT COUNT(*) n FROM ipad_legacy_migrations').get().n, 0)
    assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_drawings').get().n, 0)
    ink.payload.data = original
  }
  const backend = runtime(), initialized = backend.initialize(), invoke = async (channel, req) => JSON.parse(JSON.stringify(await backend.invoke(channel, req)))
  assert.equal(initialized.schemaVersion, 37)
  assert.equal(database.prepare('SELECT COUNT(*) n FROM migrations').get().n, 37)
  if (legacy.records.length) {
    assert.equal(initialized.migration.objects, 9); assert.equal(initialized.migration.courses, 1)
    const row = database.prepare('SELECT data_json,style_json FROM pdf_drawings ORDER BY rowid LIMIT 1').get()
    assert.deepEqual(JSON.parse(row.data_json).points[0], { x: .8, y: .1, p: .3 })
    assert.equal(JSON.parse(row.style_json).width, .003 * 600 / 800)
    const note = database.prepare("SELECT c.folder_path,m.rel_path FROM materials_index m JOIN courses c ON c.id=m.course_id WHERE m.kind='note'").get()
    assert.equal(fs.readFileSync(path.join(note.folder_path, note.rel_path), 'utf8'), 'recovered pending edit')
    assert.equal(database.prepare('SELECT COUNT(*) n FROM ipad_legacy_archive').get().n, legacy.records.length)
    assert.equal(initialized.migration.recordings, 1)
    const recording = JSON.parse(database.prepare('SELECT payload FROM recording_sessions').get().payload)
    const detail = await invoke('recordings:read', { id: recording.id })
    assert.equal(detail.session.samples, 16000); assert.equal(detail.segments[0].text, '한글 전사'); assert.equal(detail.anchors[0].sample, 8000)
    const folder = database.prepare('SELECT folder_path FROM courses WHERE id=?').get(recording.courseId).folder_path
    const pcm = fs.readFileSync(path.join(folder, recording.audioRelPath)); assert.equal(pcm.readUInt16LE(20), 1); assert.equal(pcm.length, 32044)
    assert.equal(fs.readFileSync(path.join(environment.legacyDataPath, `Recordings/${recording.id}.wav`)).length, 64044)
    const exported = await invoke('recordings:export', { id: recording.id }); assert.match(fs.readFileSync(path.join(folder, exported.relPath), 'utf8'), /한글 전사/)
    assert.equal(backend.initialize().schemaVersion, 37)
  }
  assert.ok(initialized.supportedChannels.length > 95)
  fs.writeFileSync(fileURLToPath(new URL('./dist/supported-channels.json', import.meta.url)), JSON.stringify(initialized.supportedChannels.sort(), null, 2))
  await assert.rejects(invoke('not:implemented'), error => error.code === 'UNSUPPORTED_CHANNEL')
  const settings = await invoke('settings:set', { theme: 'dark', browser: { homePage: 'https://example.com/한글' }, tabs: { whiteboardBackground: 'grid' } })
  assert.equal(settings.theme, 'dark'); assert.equal(settings.browser.homePage, 'https://example.com/%ED%95%9C%EA%B8%80')
  const group = await invoke('courseGroups:create', { name: '2026 가을' })
  const course = await invoke('courses:create', { name: '동일한 데스크톱 과목', color: 'blue' })
  await invoke('courses:organize', { courseId: course.id, groupId: group.id, beforeCourseId: null })
  assert.equal((await invoke('courses:list')).find(item => item.id === course.id).groupId, group.id)
  const note = await invoke('notes:create', { courseId: course.id, dirRelPath: '', title: '정리 ✏️' })
  const original = await invoke('notes:read', note)
  assert.equal(await backend.invokePrivate('nativeMaterial:path',note),path.join(course.folderPath,note.relPath))
  await assert.rejects(invoke('nativeMaterial:path',note),error=>error.code==='UNSUPPORTED_CHANNEL')
  await assert.rejects(backend.invokePrivate('nativeMaterial:path',{courseId:course.id,relPath:'../settings.json'}))
  await invoke('notes:write', { ...note, markdown: '# 정리\n\n아이패드와 데스크톱 😀', expectedMtime: original.mtime })
  assert.match((await invoke('notes:read', note)).markdown, /아이패드/)
  await assert.rejects(invoke('notes:write', { ...note, markdown: 'stale', expectedMtime: 1 }), /changed|변경|conflict/i)
  let sourcePdf = Buffer.from('%PDF-test')
  if (pdfQA) {
    const { PDFDocument, degrees, rgb } = require('pdf-lib'), pdf = await PDFDocument.create()
    for (const rotation of [0, 90, 180, 270]) { const page = pdf.addPage([700, 900]); page.setCropBox(50, 50, 600, 800); page.setRotation(degrees(rotation)); page.drawRectangle({ x: 50, y: 50, width: 600, height: 800, color: rgb(.96, .96, .96) }) }
    sourcePdf = Buffer.from(await pdf.save())
  }
  const material = await invoke('materials:writeFile', { courseId: course.id, dirRelPath: '', fileName: 'lecture.pdf', encoding: 'base64', data: sourcePdf.toString('base64') })
  assert.equal((await invoke('materials:readFile', { courseId: course.id, ...material })).data, sourcePdf.toString('base64'))
  const drawing = await invoke('drawings:create', { courseId: course.id, relPath: material.relPath, page: 1, kind: 'ink', data: { points: [{ x: .1, y: .2, p: .3 }, { x: .4, y: .5, p: .8 }] }, style: { color: 'ink', width: .003, opacity: 1 } })
  assert.equal((await invoke('drawings:listForFile', { courseId: course.id, relPath: material.relPath }))[0].id, drawing.id)
  const task = await invoke('board:createTask', { courseId: course.id, title: '시험', kind: 'exam', status: 'in-progress', color: 'violet', allDay: true, startAt: '2026-10-13', dueAt: '2026-10-15' })
  assert.equal((await invoke('board:listTasks'))[0].dueAt, task.dueAt)
  const board = await invoke('canvas:create', { courseId: course.id, title: '판서' })
  assert.equal((await invoke('canvas:open', { boardId: board.id })).board.title, '판서')
  if (pdfQA) {
    const textShape = { kind: 'textbox', data: { box: { x: .1, y: .3, width: .7, height: .2 }, text: '반달 한글 PDF 내보내기\nPencil + Desktop 123' }, style: { color: 'ink', width: .003, opacity: 1, fontSizePt: 24, bold: true } }
    for (let page = 1; page <= 4; page++) {
      await invoke('drawings:create', { courseId: course.id, relPath: material.relPath, page, kind: 'ink', data: { points: [{ x: .1, y: .1, p: 1 }, { x: .4, y: .1, p: .3 }, { x: .4, y: .2, p: .7 }] }, style: { color: 'blue', width: .006, opacity: 1 } })
      await invoke('drawings:create', { courseId: course.id, relPath: material.relPath, page, ...textShape })
    }
    const result = await invoke('pdf:exportAnnotated', { courseId: course.id, relPath: material.relPath })
    assert.ok(fs.statSync(result.savedPath).size > 10000)
    assert.equal((await invoke('materials:readFile', { courseId: course.id, ...material })).data, sourcePdf.toString('base64'))
    await invoke('canvas:putShape', { boardId: board.id, id: crypto.randomUUID(), page: 1, shape: textShape })
    const exported = await invoke('canvas:exportPdf', { boardId: board.id })
    fs.copyFileSync(path.join(course.folderPath, exported.relPath), path.join(qaPath, 'whiteboard.pdf'))
    const { PDFDocument } = require('pdf-lib'), output = await PDFDocument.load(fs.readFileSync(result.savedPath))
    assert.deepEqual(output.getPages().map(p => p.getRotation().angle), [0, 90, 180, 270]); assert.equal(output.getPages()[0].getCropBox().x, 50)
  }
  const layout = { columns: [{ tabs: [{ type: 'note', relPath: note.relPath }, { type: 'pdf', relPath: material.relPath }] }, { tabs: [{ type: 'browser', url: 'https://example.com' }] }], active: 1 }
  await invoke('layout:save', { courseId: course.id, layout })
  assert.deepEqual((await invoke('layout:get', { courseId: course.id })).layout, layout)
  await invoke('materials:rename', { courseId: course.id, relPath: material.relPath, newName: 'renamed.pdf' })
  assert.equal((await invoke('drawings:listForFile', { courseId: course.id, relPath: 'renamed.pdf' }))[0].id, drawing.id)
  assert.equal((await invoke('search:query', { courseId: course.id, query: '아이패드' })).hits[0].relPath, note.relPath)
  await invoke('search:indexPdfPages', { courseId: course.id, relPath: 'renamed.pdf', pages: [{ page: 1, text: '강의 검색을 위한 본문' }] })
  assert.equal((await invoke('search:query', { courseId: course.id, query: '검색' })).hits[0].page, 1)
  assert.deepEqual((await invoke('plugins:list')).plugins, [])
  const pluginPath = path.join(environment.tempPath, 'test-plugin'); fs.mkdirSync(pluginPath)
  fs.writeFileSync(path.join(pluginPath, 'manifest.json'), JSON.stringify({ manifestVersion: 2, id: 'test.metadata', name: 'Test metadata', version: '1.0.0', minAppVersion: '0.1.0', main: 'main.js', permissions: ['settings'], contributes: { settings: [{ key: 'label', title: 'Label', type: 'string', default: 'Default' }] } }))
  fs.writeFileSync(path.join(pluginPath, 'main.js'), 'globalThis.mustNeverExecute = true')
  const installed = await invoke('plugins:installFromFolder', { path: pluginPath })
  assert.equal(installed.plugin.enabled, false)
  assert.equal((await invoke('plugins:list')).plugins[0].manifest.id, 'test.metadata')
  await invoke('plugins:setSetting', { id: 'test.metadata', key: 'label', value: 'Persistent' })
  assert.equal((await invoke('plugins:getSettings', { id: 'test.metadata' })).values.label, 'Persistent')
  const packs = (await invoke('packs:list')).packs
  assert.ok(packs.length > 0)
  await invoke('packs:setEnabled', { id: packs[0].pack?.id ?? packs[0].id, enabled: false })
  await assert.rejects(invoke('notes:read', { courseId: course.id, relPath: '../settings.json' }))
  const project = await invoke('learning:create', { placement: 'in-course', courseId: course.id, name: '복습 자료', topic: '과학' })
  assert.equal((await invoke('learning:get', { binding: project.binding })).projectId, project.projectId)
  const renamed = await invoke('learning:rename', { binding: project.binding, name: '새 학습 이름', expectedRevision: project.revision })
  await assert.rejects(invoke('learning:rename', { binding: project.binding, name: '오래된 변경', expectedRevision: project.revision }), /변경/)
  assert.equal(renamed.name, '새 학습 이름')
  const before = database.prepare('SELECT COUNT(*) n FROM courses').get().n
  assert.throws(() => backend.repositories.db.transaction(() => { backend.repositories.courses.create({ name: 'rollback', color: 'blue' }); throw new Error('rollback') })())
  assert.equal(database.prepare('SELECT COUNT(*) n FROM courses').get().n, before)
  const reopened = runtime(); reopened.initialize()
  assert.equal((await reopened.invoke('settings:get')).theme, 'dark')
  assert.equal((await reopened.invoke('learning:get', { binding: project.binding })).name, '새 학습 이름')
  assert.equal((await reopened.invoke('drawings:listForFile', { courseId: course.id, relPath: 'renamed.pdf' }))[0].id, drawing.id)
  if (legacy.records.length) assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_drawings').get().n, pdfQA ? 18 : 10)
  if (process.argv.includes('--sync')) await (await import('./test-sync.mjs')).testSync({ backend,database,environment,runtime,course,note })
  if (process.argv.includes('--features')) await (await import('./test-features.mjs')).testFeatures({ invoke,course,note,environment,require,qaPath })
  if (process.argv.includes('--view-state')) await (await import('./test-legacy-view-state.mjs')).testLegacyViewState({ backend,database,environment,runtime })
  if (process.argv.includes('--projector')) { assert.ok(pdfQA,'--projector requires --pdf for real document geometry');assert.equal(legacy.records.length,0,'Use separate --legacy fixture');await (await import('./test-projector.mjs')).testProjector({backend,database,environment,course,note}) }
  if (process.argv.includes('--relocation')) await (await import('./test-relocation-runtime.mjs')).testRelocationRuntime({backend,database,environment,runtime,sourcePdf})
  assert.ok(pushes.some(item => item.channel === 'settings:changed'))
  console.log(`PASS: original 37 migrations, ${initialized.supportedChannels.length} channels; settings, courses/groups, notes/conflicts, files, ink/rename, board, canvas, layout, learning, rollback, persistence`)
} finally {
  for (const timer of timers) clearInterval(timer)
  database.close(); fs.rmSync(directory, { recursive: true, force: true })
}
