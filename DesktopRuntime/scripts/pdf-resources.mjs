import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { copyFile, mkdir, readFile, readdir, writeFile } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { dependencies } from './dependencies.mjs'

const { require } = dependencies()
const packageRoot = dirname(require.resolve('pdfjs-dist/package.json'))
const packageInfo = JSON.parse(await readFile(resolve(packageRoot, 'package.json'), 'utf8'))
assert.equal(packageInfo.version, '5.4.296', 'PDF resource version must match the pinned renderer and worker')
const directories = ['cmaps', 'standard_fonts', 'wasm']
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')

async function sourceFiles() {
  const files = []
  for (const directory of directories) {
    for (const entry of (await readdir(resolve(packageRoot, directory), { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      assert.ok(entry.isFile(), `Unexpected PDF resource entry: ${directory}/${entry.name}`)
      files.push(`${directory}/${entry.name}`)
    }
  }
  files.push('LICENSE')
  return files
}

export async function copyPDFResources(output) {
  const destination = resolve(output, 'pdfjs'), files = []
  for (const path of await sourceFiles()) {
    const source = resolve(packageRoot, path), bytes = await readFile(source)
    await mkdir(dirname(resolve(destination, path)), { recursive: true })
    await copyFile(source, resolve(destination, path))
    files.push({ path, byteCount: bytes.length, sha256: sha256(bytes) })
  }
  await writeFile(resolve(destination, 'manifest.json'), JSON.stringify({ format: 1, package: 'pdfjs-dist', version: packageInfo.version, files }, null, 2) + '\n')
  await verifyPDFResources(output)
}

export async function verifyPDFResources(output) {
  const destination = resolve(output, 'pdfjs')
  const manifest = JSON.parse(await readFile(resolve(destination, 'manifest.json'), 'utf8'))
  assert.equal(manifest.version, packageInfo.version)
  assert.deepEqual(manifest.files.map(file => file.path), await sourceFiles(), 'All PDF resources and licenses must be packaged')
  for (const file of manifest.files) {
    const expected = await readFile(resolve(packageRoot, file.path)), actual = await readFile(resolve(destination, file.path))
    assert.equal(actual.length, file.byteCount, `PDF resource size: ${file.path}`)
    assert.equal(sha256(actual), file.sha256, `PDF resource hash: ${file.path}`)
    assert.equal(file.sha256, sha256(expected), `PDF resource source: ${file.path}`)
  }
  return manifest
}
