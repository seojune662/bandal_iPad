import { readFile, writeFile, unlink } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'
const originalURL = new URL('../test-backend.mjs', import.meta.url)
let source = await readFile(originalURL, 'utf8')
// Reuse the integration suite's real filesystem/SQLite fixture. Only the
// asynchronous external API boundary is replaced; no user's key is consulted.
source = source.replace("'../scripts/dependencies.mjs'", "'../../scripts/dependencies.mjs'")
source = source.replaceAll("new URL('./dist/", "new URL('../dist/").replaceAll("new URL('../assets/", "new URL('../../assets/")
const runtimeFactory = 'function runtime(platform) {'
if (source.split(runtimeFactory).length !== 2) throw new Error('Backend fixture platform injection seam changed')
source = source.replace(runtimeFactory, 'function runtime(platform = { invoke: platformFixture }) {')
const needle = "  assert.equal(initialized.schemaVersion, 37)"
if (!source.includes(needle)) throw new Error('Backend fixture initialize seam changed')
source = source.replace(needle, '  setBackend(backend); await runAITests(invoke, pushes)\n' + needle)
source = "import { platformFixture, setBackend, runAITests } from './tests.mjs'\n" + source
const generated = new URL(`./.harness-${randomUUID()}.mjs`, import.meta.url)
await writeFile(generated, source)
try { await import(generated.href) } finally { await unlink(generated) }
