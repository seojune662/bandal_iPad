import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import vm from 'node:vm'
import { dependencies, runtime } from './dependencies.mjs'
const { require } = dependencies(), ts = require('typescript')
const source = await readFile(resolve(runtime, 'renderer/diagnostics.ts'), 'utf8')
const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS } }).outputText
const context = { exports: {} }; vm.runInNewContext(code, context)
const inspect = (reason, location) => JSON.parse(JSON.stringify(context.exports.rendererDiagnostic(reason, location)))
const failure = { name: 'TypeError', message: "undefined is not an object (evaluating 't.trim')", stack: "private function label@bandal-app://shell/assets/main-AbCd12.js:414:872\nsecretText@bandal-app://shell/assets/vendor-XYZ.mjs:12:4" }
assert.deepEqual(inspect(failure), { errorClass: 'TypeError', frames: ['main-AbCd12.js:414:872', 'vendor-XYZ.mjs:12:4'], expression: 't.trim' })
assert.deepEqual(inspect({ name: 'ReferenceError', message: 'private content', stack: 'ReferenceError: private content\n    at anonymous (bandal-app://shell/assets/main-AbCd12.js:22:9)' }), { errorClass: 'ReferenceError', frames: ['main-AbCd12.js:22:9'] })
assert.deepEqual(inspect('private rejection', { filename: 'bandal-app://shell/assets/index-hash.js', lineno: 7, colno: 9 }), { errorClass: 'UnknownError', frames: ['index-hash.js:7:9'] })
const secret = 'document-title_credential-token'
for (const url of [`https://example.com/${secret}.js`, `http://localhost:5173/assets/${secret}.js`, `file:///Documents/${secret}.js`, `bandal-media://material/${secret}.pdf`, `bandal-app://shell/assets/${secret}.js?token=secret`, 'bandal-app://shell/assets/../secret.js', 'bandal-app://shell/assets/%2e%2e/secret.js']) {
  const value = inspect({ name: secret, message: secret, stack: `${secret}@${url}:1:2` }, { filename: url, lineno: 1, colno: 2 })
  assert.deepEqual(value, { errorClass: 'UnknownError', frames: [] })
  assert.ok(!JSON.stringify(value).includes(secret))
}
for (const expression of ["t['private title']", 'fetch(token)', 'https://example.com', 't.마크다운', 't.x + userText']) assert.equal(inspect({ name: 'TypeError', message: `undefined is not an object (evaluating '${expression}')` }).expression, undefined)
assert.equal(inspect({ name: 'Error', message: failure.message }).expression, undefined)
assert.deepEqual(inspect({ get name() { throw Error(secret) }, get stack() { throw Error(secret) } }), { errorClass: 'UnknownError', frames: [] })
const many = Array.from({ length: 30 }, (_, i) => `f@bandal-app://shell/assets/main.js:${i + 1}:2`).join('\n')
assert.equal(inspect({ name: 'Error', stack: many }).frames.length, 5)
assert.deepEqual(inspect({ name: 'Error', stack: 'f@bandal-app://shell/assets/main.js:0:2\nf@bandal-app://shell/assets/main.js:99999999999:2' }).frames, [])
const bootstrap = await readFile(resolve(runtime, 'renderer/bootstrap.ts'), 'utf8')
assert.match(bootstrap, /rendererDiagnostic\(reason, source\)/)
assert.match(bootstrap, /showFailure\(event\.error \?\? event\.message, \{ filename: event\.filename, lineno: event\.lineno, colno: event\.colno \}\)/)
assert.ok(!bootstrap.includes('request: { message:'))
assert.ok(!bootstrap.includes('preventDefault()'))
console.log('PASS: Safari/Chromium bundled frames, stackless error location, strict property expression, bounded output, and rejection of messages/URLs/document paths/credentials')
