import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { dirname, resolve, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const runtime = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const source = resolve(process.argv[2] ?? resolve(runtime, '../../bandal'))
const destination = resolve(runtime, 'upstream')
const previous = await readFile(resolve(destination, 'manifest.json'), 'utf8').then(JSON.parse).catch(error => { if (error.code === 'ENOENT') return null; throw error })
const directories = ['src/renderer', 'src/shared', 'src/main', 'src/preload']
// The real desktop guided tour imports this PDF; no demo entry point, adapter,
// sample state, or demo stylesheet is copied or executed.
const files = ['package.json', 'pnpm-lock.yaml', 'LICENSE', 'THIRD_PARTY_LICENSES.md', 'web-demo/public/sample.pdf']
const entries = []
async function visit(path) {
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const full = resolve(path, entry.name)
    if (entry.name === '.DS_Store') continue
    if (entry.isDirectory()) await visit(full)
    else if (entry.isFile()) {
      const data = await readFile(full)
      entries.push({ path: relative(source, full).replaceAll('\\', '/'), bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') })
    } else throw new Error(`Snapshot refuses a non-regular source: ${full}`)
  }
}
await mkdir(destination, { recursive: true })
for (const path of directories) {
  await visit(resolve(source, path))
  await rm(resolve(destination, path), { recursive: true, force: true })
  await cp(resolve(source, path), resolve(destination, path), { recursive: true, filter: path => !path.endsWith('/.DS_Store') })
}
for (const path of files) {
  const data = await readFile(resolve(source, path))
  entries.push({ path, bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') })
  await mkdir(dirname(resolve(destination, path)), { recursive: true })
  await writeFile(resolve(destination, path), data)
}
const packageJSON = JSON.parse(await readFile(resolve(source, 'package.json'), 'utf8'))
const manifest = {
  format: 'bandal-desktop-source-snapshot', version: 1,
  sourceCommit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: source, encoding: 'utf8' }).trim(),
  appVersion: packageJSON.version,
  capturedAt: new Date().toISOString(),
  sourceWorkingChanges: execFileSync('git', ['status', '--porcelain', '--', ...directories, ...files], { cwd: source, encoding: 'utf8' }).trimEnd().split('\n').filter(Boolean),
  policy: 'Original renderer, styles, fonts imports, shared contracts and native backend sources are copied byte-for-byte. Platform code lives outside upstream.',
  files: entries.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0)
}
await writeFile(resolve(destination, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
if (previous && previous.sourceCommit !== manifest.sourceCommit) {
  const history = resolve(runtime, 'provenance')
  await mkdir(history, { recursive: true })
  await writeFile(resolve(history, `manifest-${previous.sourceCommit.slice(0, 12)}.json`), JSON.stringify(previous, null, 2) + '\n')
  await writeFile(resolve(history, `manifest-${manifest.sourceCommit.slice(0, 12)}.json`), JSON.stringify(manifest, null, 2) + '\n')
  const before = new Map(previous.files.map(file => [file.path, file])), after = new Map(manifest.files.map(file => [file.path, file]))
  const changes = [...new Set([...before.keys(), ...after.keys()])].sort().flatMap(path => {
    const old = before.get(path), next = after.get(path)
    return old?.sha256 === next?.sha256 ? [] : [{ path, kind: !old ? 'added' : !next ? 'removed' : 'changed', before: old ?? null, after: next ?? null }]
  })
  await writeFile(resolve(history, `${previous.sourceCommit.slice(0, 12)}-to-${manifest.sourceCommit.slice(0, 12)}.json`), JSON.stringify({ before: { commit: previous.sourceCommit, appVersion: previous.appVersion, files: previous.files.length }, after: { commit: manifest.sourceCommit, appVersion: manifest.appVersion, files: manifest.files.length, sourceWorkingChanges: manifest.sourceWorkingChanges }, changes }, null, 2) + '\n')
}
console.log(`Snapshotted ${entries.length} original files at ${manifest.sourceCommit} (${manifest.appVersion})`)
