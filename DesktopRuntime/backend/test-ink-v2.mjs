import assert from 'node:assert/strict'
import { randomUUID, createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

export async function testInkV2({ invoke, runtime, database, course }) {
  const pdfPath = join(course.folderPath, 'renamed.pdf'), originalBytes = readFileSync(pdfPath)
  const documentRevision = createHash('sha256').update(originalBytes).digest('hex')
  const input = { courseId: course.id, relPath: 'renamed.pdf', page: 1, kind: 'ink', clientMutationId: randomUUID(),
    documentRevision,
    data: { inkVersion: 2, points: [{ x: .3, y: .3, p: 0, t: 0, tiltX: 30, tiltY: -20 }, { x: .3, y: .3, p: 1, t: 14, tiltX: 31, tiltY: -21 }] },
    style: { color: 'blue', width: .004, opacity: .8 } }
  const first = await invoke('drawings:create', input)
  assert.deepEqual(first.data, input.data, 'Actual backend validates and preserves all measured metadata')
  assert.equal((await invoke('drawings:create', input)).id, first.id)
  const reopened = runtime(); reopened.initialize()
  assert.equal((await reopened.invoke('drawings:create', input)).id, first.id, 'Lost reply + process restart cannot duplicate a committed stroke')
  assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_drawings WHERE id=?').get(first.id).n, 1)
  await assert.rejects(invoke('drawings:create', { ...input, page: 2 }), /operation.*reused/i)
  const beforeReplacement = database.prepare('SELECT COUNT(*) n FROM pdf_drawings').get().n
  writeFileSync(pdfPath, Buffer.from('a different PDF revision at the same path'))
  try {
    await assert.rejects(invoke('drawings:create', { ...input, clientMutationId: randomUUID() }), /PDF 원본이 (변경|기존 필기와 다릅니다)/)
    assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_drawings').get().n, beforeReplacement, 'Old native snapshot cannot write into a replacement PDF')
    assert.equal((await invoke('drawings:create', input)).id, first.id, 'Already committed receipt remains recoverable without creating another stroke')
  } finally { writeFileSync(pdfPath, originalBytes) }
  await assert.rejects(invoke('drawings:create', { ...input, clientMutationId: randomUUID(), documentRevision: 'invalid' }), /SHA-256/)
  for (const data of [{ ...input.data, inkVersion: 3 }, { ...input.data, points: [{ x: .3, y: .3, p: .5, t: -1 }] },
    { ...input.data, points: [{ x: .3, y: .3, p: .5, tiltX: 91 }] }]) {
    await assert.rejects(invoke('drawings:create', { ...input, clientMutationId: randomUUID(), data }))
  }
  const count = database.prepare('SELECT COUNT(*) n FROM pdf_drawings').get().n
  database.exec("CREATE TEMP TRIGGER fail_receipt BEFORE INSERT ON drawing_create_receipts BEGIN SELECT RAISE(ABORT, 'fixture disk full'); END")
  await assert.rejects(invoke('drawings:create', { ...input, clientMutationId: randomUUID() }), /disk full/)
  database.exec('DROP TRIGGER fail_receipt')
  assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_drawings').get().n, count, 'Failure to save receipt rolls back the stroke too')
  await invoke('drawings:update', { id: first.id, style: { ...input.style, color: 'red' } })
  assert.equal((await invoke('drawings:create', input)).style.color, 'red', 'Recovery must not overwrite a later edit')
  await invoke('drawings:delete', { ids: [first.id] })
  await assert.rejects(invoke('drawings:create', input), /^NotFoundError: \[not-found\]/)
  assert.equal(database.prepare('SELECT COUNT(*) n FROM pdf_drawings WHERE id=? AND deleted_at IS NULL').get(first.id).n, 0)
  console.log('PASS: v2 metadata, document replacement guard, durable idempotent create/restart, changed-operation rejection, atomic receipt failure, and no edit/delete resurrection')
}
