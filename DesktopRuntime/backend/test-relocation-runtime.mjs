import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'

export async function testRelocationRuntime({ backend, database, environment, runtime, sourcePdf }) {
  const currentRoot = environment.userDataPath, dataRoot = path.join(currentRoot, 'Courses')
  fs.mkdirSync(dataRoot, { recursive: true })
  await backend.invoke('settings:set', { dataRoot })
  const course = await backend.invoke('courses:create', { name: 'Container relocation fixture', color: 'blue' })
  const note = await backend.invoke('notes:create', { courseId: course.id, dirRelPath: '', title: 'Retained note' })
  const original = '# Retained content and identity'
  await backend.invoke('notes:write', { ...note, markdown: original })
  const pdf = await backend.invoke('materials:writeFile', { courseId: course.id, dirRelPath: '', fileName: 'welcome.pdf', encoding: 'base64', data: sourcePdf.toString('base64') })
  await backend.invoke('materials:tree', { courseId: course.id })
  const drawing = await backend.invoke('drawings:create', { courseId: course.id, relPath: pdf.relPath, page: 1, kind: 'ink', data: { points: [{ x: .1, y: .2, p: .5 }, { x: .3, y: .4, p: 1 }] }, style: { color: 'ink', width: .003, opacity: 1 } })
  const before = database.prepare('SELECT id,rel_path FROM materials_index WHERE course_id=? ORDER BY id').all(course.id)
  const appearance = database.prepare('SELECT * FROM material_added_state WHERE course_id=? ORDER BY rel_path').all(course.id)
  const old = '/private/var/mobile/Containers/Data/Application/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE/Documents/BandalDesktop'
  const oldFolder = old + course.folderPath.slice(currentRoot.length)
  database.prepare('UPDATE courses SET folder_path=? WHERE id=?').run(oldFolder, course.id)
  database.prepare('UPDATE material_added_baselines SET folder=? WHERE course_id=?').run(oldFolder, course.id)
  const settings = JSON.parse(fs.readFileSync(path.join(currentRoot, 'settings.json'), 'utf8'))
  fs.writeFileSync(path.join(currentRoot, 'settings.json'), JSON.stringify({ ...settings, dataRoot: old + '/Courses' }))
  // A fresh JS context is essential: getSettings caches in each runtime.
  const restarted = runtime(); restarted.initialize()
  assert.equal((await restarted.invoke('settings:get')).dataRoot, dataRoot)
  assert.equal((await restarted.invoke('courses:list')).find(c => c.id === course.id).folderPath, course.folderPath)
  assert.equal((await restarted.invoke('notes:read', note)).markdown, original)
  assert.equal((await restarted.invoke('materials:readFile', { courseId: course.id, relPath: pdf.relPath })).data, sourcePdf.toString('base64'))
  assert.equal(await restarted.invokePrivate('nativeMaterial:path', { courseId: course.id, relPath: pdf.relPath }), path.join(course.folderPath, pdf.relPath))
  assert.equal((await restarted.invoke('drawings:listForFile', { courseId: course.id, relPath: pdf.relPath }))[0].id, drawing.id)
  await restarted.invoke('materials:tree', { courseId: course.id })
  assert.deepEqual(database.prepare('SELECT id,rel_path FROM materials_index WHERE course_id=? ORDER BY id').all(course.id), before)
  assert.deepEqual(database.prepare('SELECT * FROM material_added_state WHERE course_id=? ORDER BY rel_path').all(course.id), appearance)
  const again = runtime(); again.initialize()
  assert.equal((await again.invoke('notes:read', note)).markdown, original)
  console.log('PASS: actual backend restart repairs physical container paths; original PDF/note/ink IDs and material history survive')
}
