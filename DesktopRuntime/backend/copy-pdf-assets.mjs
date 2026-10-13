import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
const here = dirname(fileURLToPath(import.meta.url)), source = resolve(process.env.BANDAL_DESKTOP_SOURCE ?? resolve(here, '../../../bandal'))
const snapshot = resolve(here, '../assets/PDF'), output = resolve(process.argv[2] ?? resolve(here, '../../App/Resources/DesktopNative'))
mkdirSync(resolve(snapshot, 'fonts'), { recursive: true }); mkdirSync(resolve(output, 'fonts'), { recursive: true })
const files = ['NotoSansKR-Regular.otf', 'NotoSansKR-Bold.otf'], manifest = []
for (const file of files) {
  const origin = resolve(source, 'resources/fonts', file), bytes = readFileSync(origin)
  const sha256 = createHash('sha256').update(bytes).digest('hex')
  copyFileSync(origin, resolve(snapshot, 'fonts', file)); copyFileSync(origin, resolve(output, 'fonts', file))
  manifest.push({ file, sha256, byteCount: bytes.length, source: `resources/fonts/${file}` })
}
const licenses = readFileSync(resolve(source, 'THIRD_PARTY_LICENSES.md'))
writeFileSync(resolve(snapshot, 'THIRD_PARTY_LICENSES.md'), licenses); writeFileSync(resolve(output, 'THIRD_PARTY_LICENSES.md'), licenses)
writeFileSync(resolve(snapshot, 'manifest.json'), JSON.stringify({ source: 'bandal desktop v0.83.1', files: manifest }, null, 2) + '\n')
console.log(`PDF original fonts and third-party notice copied to ${output}`)
