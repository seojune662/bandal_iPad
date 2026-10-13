import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import vm from 'node:vm'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { dependencies } from '../scripts/dependencies.mjs'
const { require } = dependencies(), esbuild = createRequire(require.resolve('vite'))('esbuild')
const built = await esbuild.build({ entryPoints: [fileURLToPath(new URL('./cloud.ts', import.meta.url))], bundle: true, platform: 'neutral', format: 'iife', globalName: 'Cloud', target: 'es2020', write: false })
const bodies = new Map(), requests = [], cancelled = []
let fixture = Buffer.from(JSON.stringify({ title: '한글 자료', ok: true })), reportedSize, pending
const invoke = async (channel, value) => {
  if (channel === 'native:cloudCancel') { cancelled.push(value.id); bodies.delete(value.id); return { ok: true } }
  if (channel === 'native:cloudRequest') {
    requests.push(value)
    if (pending) await pending
    bodies.set(value.id, { bytes: fixture, offset: 0 })
    return { status: 200, headers: { 'Content-Type': 'application/json' }, bodyID: value.id, byteCount: reportedSize ?? fixture.length }
  }
  if (channel === 'native:cloudRead') {
    const item = bodies.get(value.bodyID); assert.ok(item, 'Response must not read after native cleanup')
    if (item.offset >= item.bytes.length) { bodies.delete(value.bodyID); return { data: '', done: true } }
    const bytes = item.bytes.subarray(item.offset, item.offset + 512 * 1024); item.offset += bytes.length
    return { data: bytes.toString('base64'), done: false }
  }
  throw new Error('Unexpected cloud operation ' + channel)
}
const context = vm.createContext({ setTimeout, clearTimeout, __bandalPlatform: { invoke }, __bandalNative: { perform: input => {
  const { op } = JSON.parse(input); assert.equal(op, 'crypto.randomUUID')
  return JSON.stringify({ ok: true, value: crypto.randomUUID() })
} } })
vm.runInContext(built.outputFiles[0].text, context)
const { cloudFetch, boundCloudFetch, cloudSession } = context.Cloud
const state = { accountID: 'user-a', signedIn: true }
const session = await cloudSession(state).auth.getSession()
assert.equal(session.data.session.access_token, 'native-keychain')
let response = await boundCloudFetch(state)('https://fixture.supabase.co/functions/v1/study-market', { method: 'POST', body: '{}', headers: { Authorization: 'Bearer native-keychain' } })
assert.equal(requests.at(-1).accountID, 'user-a'); assert.equal(requests.at(-1).bodyBase64, 'e30=')
assert.equal(bodies.size, 0, 'Unused small JSON response must release its native file')
assert.equal(response.headers.get('content-type'), 'application/json')
assert.deepEqual(JSON.parse(JSON.stringify(await response.json())), { title: '한글 자료', ok: true })
await assert.rejects(response.text(), /already used/)
response = await cloudFetch('https://fixture.supabase.co/storage/v1/object/sign/file')
const cachedReader = response.body.getReader(); await cachedReader.cancel()
assert.equal((await cachedReader.read()).done, true, 'Cancelling eagerly cached JSON must close the reader')
fixture = crypto.randomBytes(2 * 1024 * 1024 + 17)
response = await cloudFetch('https://fixture.supabase.co/storage/v1/object/sign/file')
assert.equal(bodies.size, 1)
let reader = response.body.getReader(); const chunks = []
while (true) { const part = await reader.read(); if (part.done) break; assert.ok(part.value.length <= 512 * 1024); chunks.push(Buffer.from(part.value)) }
assert.deepEqual(Buffer.concat(chunks), fixture); assert.equal(bodies.size, 0)
reportedSize = fixture.length + 1
response = await cloudFetch('https://fixture.supabase.co/storage/v1/object/sign/file'); reader = response.body.getReader()
await assert.rejects(async () => { while (!(await reader.read()).done) {} }, /truncated/)
reportedSize = undefined
const controller = vm.runInContext('new AbortController()', context)
let release; pending = new Promise(resolve => { release = resolve })
const loading = cloudFetch('https://fixture.supabase.co/storage/v1/object/sign/file', { signal: controller.signal })
controller.abort(); release(); pending = undefined
await assert.rejects(loading, error => error.name === 'AbortError')
assert.ok(cancelled.length >= 1)
console.log('PASS: account-bound private auth marker, JSON cleanup, bounded stream/integrity, cached reader cancellation and in-flight abort')
