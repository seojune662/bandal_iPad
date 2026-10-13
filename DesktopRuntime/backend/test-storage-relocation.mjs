import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'
import * as os from 'node:os'
import * as crypto from 'node:crypto'
import vm from 'node:vm'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import { dependencies } from '../scripts/dependencies.mjs'

const { require } = dependencies(), SQLite = require('better-sqlite3-node')
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'bandal-storage-relocation-'))
const result = await createRequire(require.resolve('vite'))('esbuild').build({ stdin: { contents: "export {relocateManagedStorage} from './storage-relocation'; export {createFileJournal} from './sync/journal'", resolveDir: path.dirname(fileURLToPath(import.meta.url)), loader: 'ts' }, bundle: true, write: false, format: 'iife', globalName: 'StorageFixture', platform: 'neutral', target: 'es2020' })
const schema = `CREATE TABLE courses(id TEXT PRIMARY KEY,source TEXT,folder_path TEXT);
 CREATE TABLE material_added_baselines(course_id TEXT PRIMARY KEY,folder TEXT,completed INTEGER);
 CREATE TABLE material_added_state(course_id TEXT,rel_path TEXT,added_at INTEGER);
 CREATE TABLE ipad_sync_projection(id TEXT PRIMARY KEY,source_json TEXT,payload_json TEXT,baseline_json TEXT);
 CREATE TABLE ipad_sync_conflicts(id TEXT PRIMARY KEY,assets_json TEXT,local_json TEXT);
 CREATE TABLE ipad_legacy_migrations(version TEXT PRIMARY KEY,report_json TEXT);
 CREATE TABLE ipad_sync_commits(id TEXT PRIMARY KEY);`
function load(root, db, failRename = () => false) {
  const native = (op, a) => {
    switch (op) {
      case 'environment': return { platform: 'ios', userDataPath: root, dataRoot: path.join(root, 'Courses') }
      case 'fs.exists': return fs.existsSync(a.path)
      case 'fs.realpath': return fs.realpathSync(a.path)
      case 'fs.stat': { const s = (a.followSymlinks ? fs.statSync : fs.lstatSync)(a.path); return { isDirectory: s.isDirectory(), isFile: s.isFile(), isSymbolicLink: s.isSymbolicLink(), size: s.size } }
      case 'fs.readdir': return fs.readdirSync(a.path, { withFileTypes: true }).map(e => ({ name: e.name, isDirectory: e.isDirectory(), isFile: e.isFile(), isSymbolicLink: e.isSymbolicLink() }))
      case 'fs.readFile': return fs.readFileSync(a.path).toString(a.encoding)
      case 'fs.open': return fs.openSync(a.path, a.flags, a.mode)
      case 'fs.close': fs.closeSync(a.fd); return null
      case 'fs.fsync': fs.fsyncSync(a.fd); return null
      case 'fs.write': { const bytes = Buffer.from(a.data, 'base64'); return fs.writeSync(a.fd, bytes, 0, bytes.length, a.position) }
      case 'fs.rename': if (failRename(a.to)) throw Error('Injected file publish failure'); fs.renameSync(a.from, a.to); return null
      case 'fs.remove': fs.rmSync(a.path, { recursive: a.recursive, force: a.force }); return null
      case 'fs.mkdir': fs.mkdirSync(a.path, { recursive: a.recursive }); return null
      case 'fs.copy': fs.copyFileSync(a.from, a.to, a.overwrite ? 0 : fs.constants.COPYFILE_EXCL); return null
      case 'crypto.randomBytes': return crypto.randomBytes(a.length).toString('base64')
      default: throw Error('Unexpected relocation primitive: ' + op)
    }
  }
  const context = vm.createContext({ TextEncoder, TextDecoder, __bandalNative: { perform: text => {
    try { const { op, args } = JSON.parse(text); return JSON.stringify({ ok: true, value: native(op, args) }) }
    catch (e) { return JSON.stringify({ ok: false, error: { message: e.message, code: e.code } }) }
  } } })
  vm.runInContext(result.outputFiles[0].text, context)
  return { repair: () => context.StorageFixture.relocateManagedStorage(db), recover: () => context.StorageFixture.createFileJournal(db) }
}
const writeJSON = (file, value) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, JSON.stringify(value)) }
const readJSON = file => JSON.parse(fs.readFileSync(file, 'utf8'))
try {
  const first = path.join(directory, 'before/Documents/BandalDesktop'), second = path.join(directory, 'after/Documents/BandalDesktop')
  fs.mkdirSync(path.join(first, 'Courses/course'), { recursive: true })
  const db1 = new SQLite(path.join(first, 'bandal.db')); db1.exec(schema)
  load(first, db1).repair() // Persist the actual managed root for future installs.
  const folder = path.join(first, 'Courses/course'), original = Buffer.from('original note bytes'), external = path.join(directory, 'external')
  fs.mkdirSync(external); fs.writeFileSync(path.join(folder, 'note.md'), original)
  db1.prepare('INSERT INTO courses VALUES(?,?,?)').run('course', 'managed', folder)
  db1.prepare('INSERT INTO courses VALUES(?,?,?)').run('linked', 'linked', external)
  db1.prepare('INSERT INTO material_added_baselines VALUES(?,?,1)').run('course', folder)
  db1.prepare('INSERT INTO material_added_state VALUES(?,?,?)').run('course', 'note.md', 42)
  const payload = JSON.stringify({ text: folder, id: 'stable-id' })
  db1.prepare('INSERT INTO ipad_sync_projection VALUES(?,?,?,?)').run('note', JSON.stringify({ courseID: 'course', path: path.join(folder, 'note.md'), root: folder }), payload, payload)
  db1.prepare('INSERT INTO ipad_sync_projection VALUES(?,?,?,?)').run('linked', JSON.stringify({ courseID: 'linked', path: external }), payload, payload)
  const asset = path.join(first, 'SyncConflictAssets/hash'); fs.mkdirSync(path.dirname(asset)); fs.writeFileSync(asset, 'conflict bytes')
  db1.prepare('INSERT INTO ipad_sync_conflicts VALUES(?,?,?)').run('conflict', JSON.stringify([{ path: asset, sha256: 'unchanged' }]), payload)
  writeJSON(path.join(first, 'settings.json'), { dataRoot: path.join(first, 'Courses'), arbitraryText: folder, extensions: [{ path: external }] })
  const recovery = path.join(first, 'SyncRecovery/operation'), backup = path.join(recovery, '0.original')
  fs.mkdirSync(recovery, { recursive: true }); fs.writeFileSync(backup, original); fs.writeFileSync(path.join(folder, 'note.md'), 'interrupted replacement')
  writeJSON(path.join(recovery, 'intent.json'), { id: 'operation', entries: [{ target: path.join(folder, 'note.md'), source: asset, existed: true, backup }, { target: path.join(folder, 'new.md'), existed: false, backup: path.join(recovery, '1.original') }] })
  db1.close(); fs.cpSync(first, second, { recursive: true }); fs.rmSync(first, { recursive: true })
  const db = new SQLite(path.join(second, 'bandal.db')), repairedFolder = path.join(second, 'Courses/course')
  // A crash after settings publish must not commit any SQL locations and must
  // retain enough old-root evidence to finish the same repair on restart.
  assert.throws(() => load(second, db, target => target.endsWith('/intent.json')).repair(), /Injected/)
  assert.equal(db.prepare('SELECT folder_path FROM courses WHERE id=?').get('course').folder_path, folder)
  assert.equal(readJSON(path.join(second, 'settings.json')).dataRoot, path.join(second, 'Courses'))
  const fixture = load(second, db); assert.equal(fixture.repair().courses, 1)
  assert.equal(db.prepare('SELECT folder_path FROM courses WHERE id=?').get('course').folder_path, repairedFolder)
  assert.equal(db.prepare('SELECT folder FROM material_added_baselines').get().folder, repairedFolder)
  assert.equal(db.prepare('SELECT added_at FROM material_added_state').get().added_at, 42)
  assert.equal(db.prepare('SELECT folder_path FROM courses WHERE id=?').get('linked').folder_path, external)
  assert.equal(JSON.parse(db.prepare('SELECT source_json FROM ipad_sync_projection WHERE id=?').get('note').source_json).root, repairedFolder)
  assert.equal(db.prepare('SELECT payload_json FROM ipad_sync_projection WHERE id=?').get('note').payload_json, payload)
  assert.equal(db.prepare('SELECT local_json FROM ipad_sync_conflicts').get().local_json, payload)
  assert.equal(readJSON(path.join(second, 'settings.json')).arbitraryText, folder)
  assert.equal(readJSON(path.join(second, 'SyncRecovery/operation/intent.json')).entries[0].source, path.join(second, 'SyncConflictAssets/hash'))
  fixture.recover(); assert.deepEqual(fs.readFileSync(path.join(repairedFolder, 'note.md')), original)
  assert.equal(fs.existsSync(path.join(repairedFolder, 'new.md')), false)
  assert.equal(load(second, db).repair().courses, 0)
  db.close()

  // Upgrade a real pre-receipt iPad layout, while preserving linked folders,
  // arbitrary 'Documents' paths, missing destinations and symlink escapes.
  const fresh = path.join(directory, 'bootstrap'), old = '/var/mobile/Containers/Data/Application/11111111-2222-4333-8444-555555555555/Documents/BandalDesktop'
  fs.mkdirSync(path.join(fresh, 'Courses/iPad/id'), { recursive: true }); fs.mkdirSync(path.join(fresh, 'Courses/private'), { recursive: true }); fs.mkdirSync(path.join(fresh, 'Courses/linked'), { recursive: true })
  fs.symlinkSync(external, path.join(fresh, 'Courses/escape'))
  const bootstrap = new SQLite(path.join(fresh, 'bandal.db')); bootstrap.exec(schema)
  const insert = bootstrap.prepare('INSERT INTO courses VALUES(?,?,?)')
  insert.run('old', 'managed', old + '/Courses/iPad/id'); insert.run('linked', 'linked', old + '/Courses/linked')
  insert.run('private', 'managed', '/private' + old + '/Courses/private')
  insert.run('missing', 'managed', old + '/Courses/missing'); insert.run('outside', 'managed', old + '/Courses/escape')
  insert.run('crafted', 'managed', '/other/Documents/BandalDesktop/Courses/iPad/id')
  insert.run('traversal', 'managed', old + '/Courses/../Courses/iPad/id')
  writeJSON(path.join(fresh, 'settings.json'), { dataRoot: old + '/Courses' })
  assert.equal(load(fresh, bootstrap).repair().courses, 2)
  assert.equal(bootstrap.prepare('SELECT folder_path FROM courses WHERE id=?').get('old').folder_path, path.join(fresh, 'Courses/iPad/id'))
  assert.equal(bootstrap.prepare('SELECT folder_path FROM courses WHERE id=?').get('private').folder_path, path.join(fresh, 'Courses/private'))
  for (const id of ['linked', 'missing', 'outside', 'crafted', 'traversal']) assert.notEqual(bootstrap.prepare('SELECT folder_path FROM courses WHERE id=?').get(id).folder_path, path.join(fresh, 'Courses', id))
  assert.equal(bootstrap.prepare('SELECT folder_path FROM courses WHERE id=?').get('traversal').folder_path, old + '/Courses/../Courses/iPad/id')
  bootstrap.close()
  const settingsOnly = path.join(directory, 'settings-only'); fs.mkdirSync(path.join(settingsOnly, 'Courses'), { recursive: true })
  const settingsDB = new SQLite(path.join(settingsOnly, 'bandal.db')); settingsDB.exec(schema)
  writeJSON(path.join(settingsOnly, 'settings.json'), { dataRoot: old + '/Courses' })
  writeJSON(path.join(settingsOnly, 'SyncRecovery/pending/intent.json'), { id: 'pending', entries: [{ target: old + '/CommonSync/Assets/new', backup: old + '/SyncRecovery/pending/0.original', existed: false }] })
  settingsDB.prepare('INSERT INTO ipad_sync_conflicts VALUES(?,?,?)').run('kept', JSON.stringify([{ path: old + '/SyncConflictAssets/hash' }]), '{}')
  assert.throws(() => load(settingsOnly, settingsDB, target => target.endsWith('/intent.json')).repair(), /Injected/)
  assert.equal(readJSON(path.join(settingsOnly, 'settings.json')).dataRoot, path.join(settingsOnly, 'Courses'))
  load(settingsOnly, settingsDB).repair()
  assert.equal(readJSON(path.join(settingsOnly, 'SyncRecovery/pending/intent.json')).entries[0].backup, path.join(settingsOnly, 'SyncRecovery/pending/0.original'))
  assert.equal(JSON.parse(settingsDB.prepare('SELECT assets_json FROM ipad_sync_conflicts').get().assets_json)[0].path, path.join(settingsOnly, 'SyncConflictAssets/hash'))
  settingsDB.close()
  console.log('PASS: copied container/restart, journal recovery, interrupted migration retry, stable IDs/content/history, managed bootstrap and external/symlink/traversal guards')
} finally { fs.rmSync(directory, { recursive: true, force: true }) }
