import { readFile, mkdir, copyFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { resolve } from 'node:path'
import { runtime } from './dependencies.mjs'
// Keep byte-verified desktop PDF fonts in the reproducible runtime snapshot.
const assets = resolve(runtime, 'assets/PDF'), destination = resolve(runtime, '../App/Resources/DesktopNative')
const manifest = JSON.parse(await readFile(resolve(assets, 'manifest.json'), 'utf8'))
await mkdir(resolve(destination, 'fonts'), { recursive: true })
for (const file of manifest.files) {
  if (!/^[a-zA-Z0-9_.-]+$/.test(file.file)) throw new Error('Invalid PDF font snapshot path')
  const source = resolve(assets, 'fonts', file.file), bytes = await readFile(source)
  if (bytes.length !== file.byteCount || createHash('sha256').update(bytes).digest('hex') !== file.sha256) throw new Error('PDF font snapshot checksum mismatch: ' + file.file)
  await copyFile(source, resolve(destination, 'fonts', file.file))
}
await copyFile(resolve(assets, 'THIRD_PARTY_LICENSES.md'), resolve(destination, 'THIRD_PARTY_LICENSES.md'))
await import('./build-renderer.mjs')
// Vite replaces Desktop output: backend MUST be packaged after the renderer.
await import('../backend/build-backend.mjs')
await import('../backend/hover/build.mjs')
await import('./test-package.mjs')
