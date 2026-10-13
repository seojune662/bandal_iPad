import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { runtime } from './dependencies.mjs'

export async function verifySnapshot(source) {
  const manifest = JSON.parse(await readFile(resolve(runtime, 'upstream/manifest.json'), 'utf8'))
  for (const entry of manifest.files) {
    for (const root of [resolve(runtime, 'upstream'), ...(source ? [resolve(source)] : [])]) {
      const bytes = await readFile(resolve(root, entry.path))
      if (bytes.length !== entry.bytes || createHash('sha256').update(bytes).digest('hex') !== entry.sha256) throw new Error(`Original source differs: ${resolve(root, entry.path)}`)
    }
  }
  const sourceCategories = await readFile(resolve(runtime, 'upstream/src/shared/settingsCategories.ts'), 'utf8')
  const categories = [...sourceCategories.matchAll(/\{ id: '([^']+)', group:/g)].map(match => match[1])
  const expected = ['ai', 'assistant', 'account', 'general', 'university', 'packs', 'calendar', 'browser', 'appearance', 'tabs', 'widgets', 'notifications', 'shortcuts', 'usage', 'permissions', 'privacy', 'advanced', 'experimental', 'courses', 'about']
  if (JSON.stringify(categories) !== JSON.stringify(expected)) throw new Error('Desktop settings route inventory changed; review native coverage before refreshing the fixture.')
  console.log(`Verified ${manifest.files.length} original source hashes and all ${categories.length} settings routes${source ? ' against desktop checkout' : ''}`)
  return manifest
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await verifySnapshot(process.argv[2])
