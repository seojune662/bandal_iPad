import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as crypto from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export async function testLearningFirstPull({ backend, database, fixture }) {
  assert.equal(database.prepare('SELECT COUNT(*) n FROM courses').get().n, 0, 'fresh process has no local course')
  const input = JSON.parse(fs.readFileSync(fixture, 'utf8'))
  const imported = await backend.invokePrivate('nativeSync:import', { records: input.records, assets: input.assets })
  assert.equal(imported.applied, 2); assert.equal(imported.conflicts.length, 0)
  const project = await backend.invoke('learning:get', { binding: input.binding })
  assert.equal(project.projectId, input.projectID)
  assert.equal(project.cards[0].sourceRefs[0].relPath, 'renamed.md')
  assert.equal(project.pathAliases.length, 1)
  assert.ok((await backend.invokePrivate('nativeSync:export', {})).records.some(record => record.id === `artifact:learning-project:${input.projectID}`))
  console.log('PASS: empty native backend first pull imports a new course and its learning project in one batch')
}

// Run in the real JSCore-compatible backend fixture, with its native SQLite
// and OS-lock bridge. This is not a simulated repository or physical-device test.
export async function testLearningPaths({ backend, database, environment }) {
  const invoke = (channel, input) => backend.invoke(channel, input)
  const projects = []
  for (const name of ['Learning paths A', 'Learning paths B']) {
    const course = await invoke('courses:create', { name, color: 'green' })
    fs.writeFileSync(path.join(course.folderPath, 'source.md'), '# Source\n\nRetained source evidence.')
    const project = await invoke('learning:create', { placement: 'in-course', courseId: course.id, name: 'Study', topic: 'Preserved links' })
    const saved = await backend.repositories.learning.putArtifact({ binding: project.binding, artifact: { kind: 'cards', title: 'Evidence', cards: [
      { id: 'draft', front: 'Kept?', back: 'Yes', sourceRefs: [{ kind: 'material', pathScope: 'course', relPath: 'source.md', quote: 'Retained source evidence.' }] }
    ] } })
    projects.push({ course, project: saved })
  }
  const lists = await Promise.all(projects.map(({ course }) => invoke('learning:list', { courseId: course.id })))
  assert.ok(lists.every(list => list.projects.length === 1), 'concurrent course discovery must not reject our own path lock')
  await Promise.all(projects.map(({ project }) => invoke('learning:get', { binding: project.binding })))

  // Exercise the original material journal -> canonical SQL + outbox -> JSON
  // path, including two projects discovered concurrently by ordinary UI calls.
  for (const { course, project } of projects) {
    await invoke('notes:rename', { courseId: course.id, relPath: 'source.md', newName: 'renamed.md' })
    const current = await invoke('learning:get', { binding: project.binding })
    assert.equal(current.cards[0].sourceRefs[0].relPath, 'renamed.md')
    assert.equal(current.cards[0].id, project.cards[0].id)
    assert.equal(current.pathAliases.length, 1)
    assert.ok(current.pathAliases[0].operationId)
  }
  assert.equal(database.prepare('SELECT COUNT(*) n FROM learning_path_outbox').get().n, 0)

  // A fresh exporter uses one explicit lease for both project reads. A remote
  // update to both projects pauses them before acquiring that same lease.
  const snapshot = await backend.invokePrivate('nativeSync:export', {})
  const assets = snapshot.assets.map(asset => ({ sha256: asset.sha256, path: asset.path }))
  const exportedProject = snapshot.records.find(record => record.payload.recordType === 'desktop-learning-project' && record.payload.id === projects[0].project.projectId)
  const exportedCourse = snapshot.records.find(record => record.id === `course:${projects[0].course.id}`)
  const firstPull = path.join(environment.tempPath, 'learning-first-pull.json')
  fs.writeFileSync(firstPull, JSON.stringify({ records: [exportedProject, exportedCourse], assets,
    binding: projects[0].project.binding, projectID: projects[0].project.projectId }))
  const child = spawnSync(process.execPath, [fileURLToPath(new URL('./test-backend.mjs', import.meta.url)), '--learning-first-pull', firstPull], { encoding: 'utf8' })
  assert.equal(child.status, 0, child.stderr); assert.match(child.stdout, /empty native backend first pull/)
  console.log(child.stdout.split('\n').find(line => line.startsWith('PASS: empty native backend')))
  const records = []
  for (const { project } of projects) {
    const record = snapshot.records.find(record => record.payload.recordType === 'desktop-learning-project' && record.payload.id === project.projectId)
    assert.ok(record)
    const ref = record.payload.files.find(file => file.relPath === 'state.json')
    const source = assets.find(asset => asset.sha256 === ref.assetRevision)
    const state = JSON.parse(fs.readFileSync(source.path, 'utf8'))
    state.name = `Remote ${project.projectId}`; state.revision++
    const bytes = Buffer.from(JSON.stringify(state)), sha256 = crypto.createHash('sha256').update(bytes).digest('hex')
    const target = path.join(environment.tempPath, `${sha256}.json`); fs.writeFileSync(target, bytes)
    assets.push({ sha256, path: target })
    records.push({ ...record, payload: { ...record.payload, stateRevision: state.revision,
      files: record.payload.files.map(file => file.relPath === 'state.json' ? { ...file, assetRevision: sha256, byteCount: bytes.length } : file) } })
  }
  const imported = await backend.invokePrivate('nativeSync:import', { records, assets })
  assert.equal(imported.applied, 2); assert.equal(imported.conflicts.length, 0)
  const corruptPath = path.join(projects[1].course.folderPath, projects[1].project.binding.rootRelPath, '.bandal/learning/state.json')
  const corruptPrevious = path.join(path.dirname(corruptPath), 'state.previous.json')
  const currentBytes = fs.readFileSync(corruptPath), previousBytes = fs.readFileSync(corruptPrevious)
  fs.writeFileSync(corruptPath, '{broken-current'); fs.writeFileSync(corruptPrevious, '{broken-previous')
  try {
    await assert.rejects(backend.invokePrivate('nativeSync:import', { records: [records[1]], assets }), /학습 원본/)
    assert.equal(fs.readFileSync(corruptPath, 'utf8'), '{broken-current')
    assert.equal(fs.readFileSync(corruptPrevious, 'utf8'), '{broken-previous')
  } finally { fs.writeFileSync(corruptPath, currentBytes); fs.writeFileSync(corruptPrevious, previousBytes) }
  const after = await Promise.all(projects.map(({ project }) => invoke('learning:get', { binding: project.binding })))
  for (const [index, state] of after.entries()) {
    assert.equal(state.name, `Remote ${projects[index].project.projectId}`)
    assert.equal(state.cards[0].sourceRefs[0].relPath, 'renamed.md')
    assert.equal(state.pathAliases.length, 1)
  }
  await backend.invokePrivate('nativeSync:export', {})
  // A queued AI run must settle before the sync lease is acquired. Its local
  // cancellation is a real edit, so an older remote state becomes a conflict.
  const first = projects[0].project, timestamp = new Date().toISOString()
  await backend.repositories.learning.updateRun({ binding: first.binding, run: { id: 'pending-path-test', kind: 'import-material', provider: 'codex',
    status: 'queued', articleIds: [], wordIds: [], message: '', error: null, draft: null, createdAt: timestamp, updatedAt: timestamp } })
  const pendingSnapshot = await backend.invokePrivate('nativeSync:export', {})
  const pendingRecord = pendingSnapshot.records.find(record => record.payload.recordType === 'desktop-learning-project' && record.payload.id === first.projectId)
  const pendingRef = pendingRecord.payload.files.find(file => file.relPath === 'state.json')
  const pendingAssets = pendingSnapshot.assets.map(asset => ({ sha256: asset.sha256, path: asset.path }))
  const pendingState = JSON.parse(fs.readFileSync(pendingAssets.find(asset => asset.sha256 === pendingRef.assetRevision).path, 'utf8'))
  pendingState.name = 'Must not overwrite a cancelled local run'; pendingState.revision++
  const pendingBytes = Buffer.from(JSON.stringify(pendingState)), pendingHash = crypto.createHash('sha256').update(pendingBytes).digest('hex')
  const pendingPath = path.join(environment.tempPath, `${pendingHash}.json`); fs.writeFileSync(pendingPath, pendingBytes)
  pendingAssets.push({ sha256: pendingHash, path: pendingPath })
  const incoming = { ...pendingRecord, payload: { ...pendingRecord.payload, stateRevision: pendingState.revision,
    files: pendingRecord.payload.files.map(file => file.relPath === 'state.json' ? { ...file, assetRevision: pendingHash, byteCount: pendingBytes.length } : file) } }
  await assert.rejects(backend.invokePrivate('nativeSync:import', { records: [incoming, { ...incoming, id: 'invalid', formatVersion: 2 }], assets: pendingAssets }), /Invalid/)
  await assert.rejects(backend.invokePrivate('nativeSync:import', { records: [incoming, incoming], assets: pendingAssets }), /Duplicate/)
  // Read the canonical repo directly: learning:get separately recovers orphaned
  // AI sessions, which is not the import preflight being tested here.
  const unchangedRun = await backend.repositories.learning.read(first.binding)
  assert.equal(unchangedRun.runs.find(run => run.id === 'pending-path-test').status, 'queued', 'invalid batches must not pause or cancel existing runs')
  const collision = await backend.invokePrivate('nativeSync:import', { records: [incoming], assets: pendingAssets })
  assert.equal(collision.applied, 0); assert.equal(collision.conflicts.length, 1)
  const cancelled = await invoke('learning:get', { binding: first.binding })
  assert.equal(cancelled.runs.find(run => run.id === 'pending-path-test').status, 'cancelled')
  assert.equal(cancelled.name, `Remote ${first.projectId}`)
  const restored = await backend.invokePrivate('nativeSync:restoreConflict', { conflictID: collision.conflicts[0].id, variant: 'local', assets: pendingAssets })
  assert.equal(restored.applied, 1)
  console.log('PASS: native backend two-course concurrent learning, note rename outbox, scoped sync export/import, cards and immutable citation aliases')
}
