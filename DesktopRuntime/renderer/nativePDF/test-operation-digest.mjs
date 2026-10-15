import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { performance } from 'node:perf_hooks'
import { dependencies, runtime } from '../../scripts/dependencies.mjs'

const { require } = dependencies(), ts = require('typescript')
const temporary = await mkdtemp(join(tmpdir(), 'bandal-operation-digest-'))
try {
  const source = await readFile(resolve(runtime, 'renderer/nativePDF/operationDigest.ts'), 'utf8')
  await writeFile(join(temporary, 'digest.mjs'), ts.transpileModule(source,
    { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext } }).outputText)
  const { sha256UTF8 } = await import(pathToFileURL(join(temporary, 'digest.mjs')))
  const oracle = text => createHash('sha256').update(text, 'utf8').digest('hex')
  const vectors = ['', 'abc', '한글😀é e\u0301\u0000', '\ud800', '\udc00', '\ud800x\udc00', 'a'.repeat(1_048_576)]
  for (const size of [1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 127, 128, 129, 255, 256, 257]) vectors.push('x'.repeat(size))
  // Deterministic varied UTF-16: includes valid pairs and replacement cases;
  // the independent oracle applies Node's UTF-8 conversion, not our encoder.
  let seed = 0x13579bdf
  for (let count = 0; count < 64; count++) {
    let value = ''
    for (let n = 0; n < count * 7; n++) { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; value += String.fromCharCode(seed >>> 16) }
    vectors.push(value)
  }
  for (const text of vectors) assert.equal(sha256UTF8(text), oracle(text), `UTF-8 bytes=${Buffer.byteLength(text)}`)
  assert.equal(sha256UTF8('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
  assert.notEqual(sha256UTF8('é'), sha256UTF8('e\u0301'), 'Do not normalize Unicode')
  console.log(`PASS SHA-256 ${vectors.length} independent Node crypto vectors; padding boundaries, Unicode, lone surrogates, 1 MiB`)

  // Informational desktop Node costs, no thresholds or physical iPad claim.
  // Input normalization/JSON and hashing stay on the receiving JS thread.
  if (process.argv.includes('--benchmark')) {
    const results = []
    for (const count of [96, 4096, 100_000]) {
      const input = { type: 'stroke', operationSequence: 1, data: { inkVersion: 4,
        points: Array.from({ length: count }, (_, i) => ({ x: i / count, y: Math.sin(i / 20) / 5 + .5, p: (i % 101) / 100, t: i / 120 })) } }
      const stringifyStart = performance.now(), text = JSON.stringify(input), stringifyMs = performance.now() - stringifyStart
      const hashStart = performance.now(), digest = sha256UTF8(text), hashMs = performance.now() - hashStart
      assert.equal(digest, oracle(text))
      results.push({ pointCount: count, normalizedUTF8Bytes: Buffer.byteLength(text), retainedDigestCharacters: digest.length,
        stringifyMs: +stringifyMs.toFixed(3), hashMs: +hashMs.toFixed(3) })
    }
    console.log(JSON.stringify({ runtime: process.version, platform: process.platform, architecture: process.arch, results }))
  }
} finally { await rm(temporary, { recursive: true, force: true }) }
