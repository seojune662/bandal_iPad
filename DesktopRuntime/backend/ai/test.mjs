import { readFile, writeFile, unlink } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'
const originalURL = new URL('../test-backend.mjs', import.meta.url)
let source = await readFile(originalURL, 'utf8')
// Reuse the integration suite's real filesystem/SQLite fixture. Only the
// asynchronous external API boundary is replaced; no user's key is consulted.
source = source.replace("'../scripts/dependencies.mjs'", "'../../scripts/dependencies.mjs'")
source = source.replaceAll("new URL('./dist/", "new URL('../dist/").replaceAll("new URL('../assets/", "new URL('../../assets/")
const nativeStart = source.indexOf('    __bandalPlatform: { invoke: async (channel, input) =>'), nativeEnd = source.indexOf('\n    setInterval:', nativeStart)
if (nativeStart < 0 || nativeEnd < 0) throw new Error('Backend fixture native seam changed')
source = source.slice(0, nativeStart) + '    __bandalPlatform: { invoke: platformFixture },' + source.slice(nativeEnd)
const needle = "  assert.equal(initialized.schemaVersion, 37)"
if (!source.includes(needle)) throw new Error('Backend fixture initialize seam changed')
source = source.replace(needle, '  setBackend(backend); await runAITests(invoke, pushes)\n' + needle)
source = "import { platformFixture, setBackend, runAITests } from './tests.mjs'\n" + source
const generated = new URL(`./.harness-${randomUUID()}.mjs`, import.meta.url)
await writeFile(generated, source)
try { await import(generated.href) } finally { await unlink(generated) }
