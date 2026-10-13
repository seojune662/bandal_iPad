import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'

const { require } = dependencies(), { build } = createRequire(require.resolve('vite'))('esbuild')
const SQLite = require('better-sqlite3-node')
const built = await build({ stdin: { contents: "export {importBookmarkHTML} from './backend/bookmark-import'; export {createFavoritesRepo} from './upstream/src/main/features/favorites/favoritesRepo';", resolveDir: runtime, loader: 'ts' }, bundle: true, write: false, format: 'cjs', platform: 'node', plugins: [{ name: 'native-boundary', setup(b) {
  b.onResolve({ filter: /shims\/crypto$/ }, () => ({ path: 'node:crypto', external: true }))
  b.onResolve({ filter: /shims\/buffer$/ }, () => ({ path: 'node:buffer', external: true }))
}}] })
const exports = {}, context = vm.createContext({ exports, module: { exports }, require, URL, Buffer, console })
vm.runInContext(built.outputFiles[0].text, context)
const { importBookmarkHTML, createFavoritesRepo } = context.module.exports
const db = new SQLite(':memory:')
try {
  db.exec('CREATE TABLE favorites (id TEXT PRIMARY KEY, course_id TEXT, label TEXT NOT NULL, descriptor_json TEXT NOT NULL, sort_order INTEGER NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT)')
  const repo = createFavoritesRepo(db), profile = '00000000-0000-4000-8000-000000000001'
  const html = '<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><H3>과목</H3><DL><DT><A HREF="https://example.test/lecture?x=1&amp;y=2">수업 &amp; 읽기</A><DT><A HREF="javascript:alert(1)">unsafe</A><DT><A HREF="https://name:secret@example.test/">credential URL</A><DT><A HREF="https://example.test/lecture?x=1&amp;y=2">duplicate</A></DL></DL>'
  const plain = value => JSON.parse(JSON.stringify(value))
  assert.deepEqual(plain(importBookmarkHTML(db, repo, { html, profileId: profile })), { imported: 1, skipped: 1, ignored: 1, cancelled: false })
  const imported = repo.list(null)[0]
  assert.equal(imported.label, '수업 & 읽기')
  assert.equal(imported.courseId, null)
  assert.equal(imported.descriptor.payload.profileId, profile)
  assert.equal(imported.descriptor.payload.initialUrl, 'https://example.test/lecture?x=1&y=2')
  assert.match(imported.descriptor.payload.tabId, /^[0-9a-f-]{36}$/i)
  assert.equal(importBookmarkHTML(db, repo, { html, profileId: profile }).imported, 0)
  assert.equal(repo.list(null)[0].label, '수업 & 읽기', 'Reimports never rename an existing favorite silently')
  assert.equal(importBookmarkHTML(db, repo, { html, profileId: 'default' }).imported, 1, 'Same address is independent in another profile')
  const count = repo.list(null).length
  for (const bad of [{ html, profileId: '../../invalid' }, { html: '<a href="file:///private/secret">bad</a>', profileId: profile }, { html: '<a href="https://example.test">&#999999999;</a>', profileId: profile }, { html: '<a href="https://example.test">a</a>'.repeat(10_001), profileId: profile }, { html: 'a'.repeat(8 * 1024 * 1024 + 1), profileId: profile }]) assert.throws(() => importBookmarkHTML(db, repo, bad))
  assert.equal(repo.list(null).length, count)
  db.exec("CREATE TRIGGER import_fail BEFORE INSERT ON favorites WHEN NEW.label = 'Fail' BEGIN SELECT RAISE(ABORT,'fixture disk failure'); END")
  assert.throws(() => importBookmarkHTML(db, repo, { profileId: profile, html: '<a href="https://first.test">First</a><a href="https://second.test">Fail</a>' }), /fixture disk failure/)
  assert.equal(repo.list(null).length, count, 'A write failure rolls back every bookmark in the selected file')
  console.log('Original bookmark parser + actual favorites repository: profile descriptors, entities, URL filtering, duplicate keep, limits, invalid file and atomic SQLite rollback passed')
} finally { db.close() }
