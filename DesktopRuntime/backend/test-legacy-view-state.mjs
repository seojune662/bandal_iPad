import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as crypto from 'node:crypto'
import vm from 'node:vm'
import { createRequire } from 'node:module'
import { dependencies, runtime as sourceRoot } from '../scripts/dependencies.mjs'

export async function testLegacyViewState({ backend, database, environment, runtime }) {
  const invoke = (channel, request = {}) => backend.invoke(channel, request)
  const cid = (await invoke('courses:create', { name: 'Legacy view state', color: 'blue' })).id
  const other = (await invoke('courses:create', { name: 'Other restored course', color: 'green' })).id
  const preserved = (await invoke('courses:create', { name: 'New desktop state', color: 'green' })).id
  const removed = (await invoke('courses:create', { name: 'Removed course', color: 'green' })).id
  const archive = (kind, id, payload, deleted = false) => database.prepare('INSERT INTO ipad_legacy_archive VALUES(?,?,?,?)').run(id, kind, JSON.stringify(payload), JSON.stringify({ id, kind, payload, deleted, revision: 1, formatVersion: 1 }))
  const material = async (courseID, name, kind, bytes = Buffer.from('%PDF-view-fixture')) => {
    const { relPath } = await invoke('materials:writeFile', { courseId: courseID, dirRelPath: '', fileName: name, encoding: 'base64', data: bytes.toString('base64') })
    await invoke('materials:tree', { courseId: courseID })
    const row = database.prepare('SELECT id FROM materials_index WHERE course_id=? AND rel_path=?').get(courseID, relPath)
    assert.ok(row)
    const revision = crypto.createHash('sha256').update(bytes).digest('hex')
    archive('material', `material:${row.id}`, { id: row.id, courseID, fileName: name, title: name, kind, revision })
    return { id: row.id, courseID, relPath, revision }
  }
  const pdf = await material(cid, 'reading.pdf', 'pdf'), note = await material(cid, 'same-title.md', 'note', Buffer.from('# Original'))
  const image = await material(cid, 'image.png', 'image'), duplicate = await material(cid, 'same-title.md', 'note', Buffer.from('# Second'))
  assert.notEqual(note.relPath, duplicate.relPath, 'Use actual repository collision-renamed path')
  const stale = await material(cid, 'stale.pdf', 'pdf'), changed = await material(cid, 'changed.pdf', 'pdf')
  const tooFar = await material(cid, 'page.pdf', 'pdf'), deleted = await material(cid, 'deleted.pdf', 'pdf')
  const retained = await material(preserved, 'keep.pdf', 'pdf'), otherPDF = await material(other, 'other.pdf', 'pdf')
  const missing = await material(cid, 'missing.pdf', 'pdf'), unsafe = await material(cid, 'unsafe.pdf', 'pdf')
  const folder = database.prepare('SELECT folder_path FROM courses WHERE id=?').get(cid).folder_path
  fs.writeFileSync(path.join(folder, changed.relPath), '%PDF-new-version')
  fs.unlinkSync(path.join(folder, missing.relPath))
  fs.unlinkSync(path.join(folder, unsafe.relPath)); fs.symlinkSync(path.join(environment.userDataPath, 'bandal.db'), path.join(folder, unsafe.relPath))
  database.prepare('UPDATE materials_index SET deleted_at=? WHERE id=?').run('2026-10-14T00:00:00Z', deleted.id)
  database.prepare('UPDATE courses SET deleted_at=? WHERE id=?').run('2026-10-14T00:00:00Z', removed)
  const whiteboard = await invoke('canvas:create', { courseId: cid, title: 'Legacy board' })
  archive('material', `material:${whiteboard.id}`, { id: whiteboard.id, courseID: cid, kind: 'whiteboard', title: 'Legacy board' })
  const tab = (kind, courseID = cid, extra = {}) => ({ id: crypto.randomUUID(), courseID, kind, title: kind, isPrivate: false, ...extra })
  const first = tab('pdf', cid, { materialID: pdf.id }), second = tab('browser', cid, { url: 'https://example.com/reading' })
  const tabs = [first, tab('note', cid, { materialID: note.id }), second, tab('file', cid, { materialID: image.id }),
    tab('note', cid, { materialID: duplicate.id }), tab('whiteboard', cid, { materialID: whiteboard.id }),
    tab('board'), tab('board'), tab('recording'), tab('learning'),
    tab('browser', cid, { isPrivate: true, url: 'https://private.example/secret' }), tab('browser', cid, { url: 'file:///etc/passwd' }),
    tab('chat'), tab('calendar'), tab('pdf', cid, { materialID: deleted.id }), tab('pdf', cid, { materialID: otherPDF.id }),
    tab('pdf', cid, { materialID: missing.id }), tab('pdf', cid, { materialID: unsafe.id }),
    tab('pdf', removed, { materialID: pdf.id }), tab('pdf', other, { materialID: otherPDF.id }), tab('pdf', preserved, { materialID: retained.id }), first]
  archive('workspace', 'workspace:ipad', { selectedCourseID: cid, tabs, primaryID: first.id, secondaryID: second.id, focusedPane: 1, splitEnabled: true })
  for (const [item, override] of [[pdf, {}], [stale, { documentRevision: '0'.repeat(64) }], [changed, {}], [tooFar, { page: 500 }], [deleted, {}], [retained, {}], [otherPDF, {}]]) {
    archive('artifact', `position:${item.id}`, { recordType: 'reading-position', courseID: item.courseID, materialID: item.id, documentRevision: item.revision, page: 1, ...override })
  }
  archive('artifact', 'position:deleted-record', { recordType: 'reading-position', courseID: cid, materialID: pdf.id, documentRevision: pdf.revision, page: 1 }, true)
  // Unrelated large archived content must not be decoded by this upgrade.
  const unrelatedID = `drawing:${crypto.randomUUID()}`
  database.prepare('INSERT INTO ipad_legacy_archive VALUES(?,?,?,?)').run(unrelatedID, 'drawing', 'x'.repeat(3 * 1024 * 1024), '{}')
  const existingLayout = { desktopSaved: ['preserve byte-for-byte'], grid: null }
  await invoke('layout:save', { courseId: preserved, layout: existingLayout })
  await invoke('pdf:setViewState', { courseId: preserved, relPath: retained.relPath, page: 7, zoom: 2.25 })
  await invoke('settings:set', { lastActiveCourseId: null, restoreLastCourse: true })
  const before = database.prepare('SELECT * FROM ipad_legacy_archive ORDER BY record_id').all()
  const preservedLayout = database.prepare('SELECT * FROM tabs_layout WHERE course_id=?').get(preserved)
  const preservedPosition = database.prepare('SELECT * FROM pdf_view_state WHERE course_id=? AND rel_path=?').get(preserved, retained.relPath)
  // A DB failure rolls back every newly projected view and cannot select a
  // half-published workspace. The original archived payload remains unchanged.
  database.exec("CREATE TRIGGER fail_view_receipt BEFORE INSERT ON ipad_legacy_view_state_migrations BEGIN SELECT RAISE(ABORT,'fixture receipt failure'); END")
  assert.throws(() => runtime().initialize(), /fixture receipt failure/)
  assert.equal(database.prepare('SELECT COUNT(*) n FROM tabs_layout WHERE course_id=?').get(cid).n, 0)
  assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_view_state WHERE course_id=?').get(cid).n, 0)
  assert.equal(JSON.parse(fs.readFileSync(path.join(environment.userDataPath, 'settings.json'), 'utf8')).lastActiveCourseId, null)
  database.exec('DROP TRIGGER fail_view_receipt')
  const settingsFile = path.join(environment.userDataPath, 'settings.json'), settingsBackup = settingsFile + '.fixture-backup'
  database.function('fixture_block_view_settings', () => { fs.renameSync(settingsFile, settingsBackup); fs.mkdirSync(settingsFile); return 1 })
  database.exec('CREATE TRIGGER fail_settings_after_views BEFORE INSERT ON ipad_legacy_view_state_migrations BEGIN SELECT fixture_block_view_settings(); END')
  try {
    assert.throws(() => runtime().initialize(), /EISDIR|ENOTEMPTY|directory/i)
    const pending = JSON.parse(database.prepare('SELECT report_json FROM ipad_legacy_view_state_migrations').get().report_json)
    assert.equal(pending.phase, 'views-saved'); assert.equal(pending.selection.status, 'pending')
    assert.equal(database.prepare('SELECT COUNT(*) n FROM tabs_layout WHERE course_id=?').get(cid).n, 1)
    assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_view_state WHERE course_id=?').get(cid).n, 1)
  } finally {
    database.exec('DROP TRIGGER fail_settings_after_views')
    fs.rmdirSync(settingsFile); fs.renameSync(settingsBackup, settingsFile)
  }
  const migrated = runtime(), report = JSON.parse(JSON.stringify(migrated.initialize().viewStateMigration))
  assert.equal(report.phase, 'complete'); assert.equal(report.layouts, 2); assert.equal(report.positions, 2)
  assert.equal(report.selection.status, 'restored')
  assert.equal((await migrated.invoke('settings:get')).lastActiveCourseId, cid)
  const reasons = new Set(report.skipped.map(item => item.reason))
  assert.ok(!report.skipped.some(item => item.recordID === unrelatedID))
  for (const reason of ['private-tab','unsupported-browser-url','duplicate-tab-id','chat-content-not-projected','unsupported-native-tab:calendar',
    'deleted-or-missing-material','deleted-or-missing-course','missing-or-unsafe-material-file','document-revision-mismatch',
    'current-document-revision-mismatch','page-out-of-range','deleted-position','existing-pdf-view-state',`existing-layout:${preserved}`]) assert.ok(reasons.has(reason), reason)
  assert.deepEqual(database.prepare('SELECT * FROM ipad_legacy_archive ORDER BY record_id').all(), before)
  assert.deepEqual(database.prepare('SELECT * FROM tabs_layout WHERE course_id=?').get(preserved), preservedLayout)
  assert.deepEqual(database.prepare('SELECT * FROM pdf_view_state WHERE course_id=? AND rel_path=?').get(preserved, retained.relPath), preservedPosition)
  const state = await migrated.invoke('pdf:getViewState', { courseId: cid, relPath: pdf.relPath })
  assert.equal(state.page, 1); assert.equal(state.zoom, 1)
  const main = JSON.parse(JSON.stringify((await migrated.invoke('layout:get', { courseId: cid })).layout))
  const single = JSON.parse(JSON.stringify((await migrated.invoke('layout:get', { courseId: other })).layout))
  const privateID = tabs.find(item => item.isPrivate).id
  assert.ok(!JSON.stringify(main).includes(privateID)); assert.ok(!JSON.stringify(main).includes('private.example'))
  assert.equal(main.grid.root.data.length, 2); assert.equal(main.activeGroup, main.grid.root.data[1].data.id)
  assert.equal(main.grid.root.data[0].data.activeView, `pdf:${cid}:${pdf.relPath}`)
  assert.deepEqual(main.grid.root.data[1].data.views, [`browser:${second.id}`])
  assert.ok(main.panels[`image:${cid}:${image.relPath}`]); assert.ok(main.panels[`note:${cid}:${duplicate.relPath}`])
  assert.ok(main.panels[`recording:${cid}`]); assert.ok(main.panels[`learning:${cid}:overview`])
  assert.equal(single.grid.root.data.length, 1)
  await validateOriginalDockview([main, single])
  // Change state through the real original APIs, then start a new JSCore-shaped
  // VM. Reopening must never replay this one-time import over newer choices.
  await migrated.invoke('layout:save', { courseId: cid, layout: { savedAfterMigration: true } })
  await migrated.invoke('pdf:setViewState', { courseId: cid, relPath: pdf.relPath, page: 9, zoom: 1.75 })
  await migrated.invoke('settings:set', { lastActiveCourseId: preserved })
  const reopened = runtime(); reopened.initialize()
  assert.deepEqual(JSON.parse(JSON.stringify((await reopened.invoke('layout:get', { courseId: cid })).layout)), { savedAfterMigration: true })
  assert.equal((await reopened.invoke('pdf:getViewState', { courseId: cid, relPath: pdf.relPath })).page, 9)
  assert.equal((await reopened.invoke('settings:get')).lastActiveCourseId, preserved)
  assert.equal(database.prepare('SELECT COUNT(*) n FROM ipad_legacy_view_state_migrations').get().n, 1)
  // Resume the file-backed settings step after a simulated interrupted commit.
  // A user's intervening selection wins; the committed layouts stay untouched.
  report.phase = 'views-saved'; report.selection = { target: cid, status: 'pending' }
  database.prepare('UPDATE ipad_legacy_view_state_migrations SET report_json=?').run(JSON.stringify(report))
  const resumed = runtime(), resumedReport = resumed.initialize().viewStateMigration
  assert.equal(resumedReport.selection.status, 'preserved'); assert.equal(resumedReport.selection.reason, 'selection-changed')
  assert.equal((await resumed.invoke('settings:get')).lastActiveCourseId, preserved)
  // Even without a receipt, existing original records/settings take priority.
  database.exec('DELETE FROM ipad_legacy_view_state_migrations')
  const repeated = runtime(), repeatedReport = repeated.initialize().viewStateMigration
  assert.equal(repeatedReport.layouts, 0); assert.equal(repeatedReport.positions, 0)
  assert.equal(repeatedReport.selection.reason, 'existing-last-course')
  assert.deepEqual(database.prepare('SELECT * FROM ipad_legacy_archive ORDER BY record_id').all(), before)
  console.log('PASS: legacy workspace/read-page projection; original APIs + WebKit Dockview restoration, privacy/deletion/revision/path guards, rollback, resumable receipt, no overwrite')
}

async function validateOriginalDockview(layouts) {
  const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
  const compiled = await build({ stdin: { contents: `export {validateLayout} from './upstream/src/renderer/src/features/workspace/layoutPersistence';`, resolveDir: sourceRoot, loader: 'ts' },
    bundle: true, write: false, platform: 'browser', format: 'iife', globalName: 'Original', plugins: [{ name: 'unused-plugin-label-store', setup(b) {
      b.onResolve({ filter: /stores\/pluginsStore$/ }, () => ({ path: 'plugins', namespace: 'fixture' }))
      b.onLoad({ filter: /.*/, namespace: 'fixture' }, () => ({ contents: 'export const usePluginsStore = {getState:()=>({plugins:[]})}' }))
    } }] })
  const context = { console, crypto }; vm.runInNewContext(compiled.outputFiles[0].text, context)
  for (const layout of layouts) {
    const validated = context.Original.validateLayout(layout)
    assert.ok(validated); assert.equal(validated.droppedPanelIds.length, 0)
    assert.deepEqual(JSON.parse(JSON.stringify(validated.layout)), layout)
  }
  const corePath = createRequire(require.resolve('dockview')).resolve('dockview-core')
  const dockview = await build({ stdin: { contents: `import {createDockview} from ${JSON.stringify(corePath)}; window.restore = layout => {
    const element=document.createElement('div'); element.style.cssText='width:1024px;height:768px';document.body.append(element);
    const api=createDockview(element,{createComponent:()=>({element:document.createElement('div'),init(){},dispose(){}})});
    api.fromJSON(layout);const out=api.toJSON();api.dispose();element.remove();return out;
  }`, resolveDir: sourceRoot, loader: 'ts' }, bundle: true, write: false, platform: 'browser', format: 'iife' })
  const { webkit } = require('@playwright/test'), browser = await webkit.launch()
  try {
    const page = await browser.newPage(); await page.setContent('<!doctype html><html><body></body></html>')
    await page.addScriptTag({ content: dockview.outputFiles[0].text })
    for (const layout of layouts) {
      const restored = await page.evaluate(layout => window.restore(layout), layout)
      assert.deepEqual(Object.keys(restored.panels).sort(), Object.keys(layout.panels).sort())
      assert.equal(restored.activeGroup, layout.activeGroup)
      assert.deepEqual(restored.grid.root.data.map(leaf => leaf.data.views), layout.grid.root.data.map(leaf => leaf.data.views))
      for (const id of Object.keys(layout.panels)) assert.deepEqual(restored.panels[id].params.descriptor, layout.panels[id].params.descriptor)
    }
  } finally { await browser.close() }
}
