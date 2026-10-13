import JSZip from 'jszip'
import { sanitizePluginManifest, isSafeRelativeEntry } from './sanitize'
import { PLUGIN_LIMITS, type PluginManifest } from '../types/plugin'

const ALLOWED_EXTENSIONS =
  /\.(js|mjs|json|html|css|svg|png|jpe?g|gif|webp|woff2|txt|md)$/i

export async function readZipEntry(
  entry: JSZip.JSZipObject,
  budget: number,
): Promise<Uint8Array> {
  const chunks: Uint8Array[] = []
  let size = 0
  await new Promise<void>((resolve, reject) => {
    const stream = entry.nodeStream() as import('node:stream').Readable
    stream
      .on('data', (chunk: Uint8Array) => {
        size += chunk.length
        if (size > budget) {
          stream.destroy()
          reject(new Error('Expanded plugin exceeds size limit'))
          return
        }
        chunks.push(chunk)
      })
      .on('error', reject)
      .on('end', resolve)
  })
  const content = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) {
    content.set(chunk, offset)
    offset += chunk.length
  }
  return content
}

/** Stream decompression with a budget, before allocating an entire entry. */
export async function inspectPluginArchive(
  bytes: Uint8Array,
): Promise<{ manifest: PluginManifest; files: Map<string, Uint8Array> }> {
  if (bytes.byteLength > 8 * 1024 * 1024)
    throw new Error('Plugin ZIP exceeds 8 MiB')
  const zip = await JSZip.loadAsync(bytes)
  const entries = Object.values(zip.files)
  if (entries.length > 500) throw new Error('Too many archive entries')
  const files = new Map<string, Uint8Array>()
  let total = 0
  for (const entry of entries) {
    const original = entry.unsafeOriginalName ?? entry.name
    const name = entry.dir ? original.replace(/\/$/, '') : original
    const mode =
      typeof entry.unixPermissions === 'string'
        ? Number.parseInt(entry.unixPermissions, 8)
        : (entry.unixPermissions ?? 0)
    if (
      !isSafeRelativeEntry(name) ||
      name.includes(':') ||
      name.split('/').some((part) => part.startsWith('.')) ||
      (mode & 0o170000) === 0o120000
    )
      throw new Error('Unsafe archive entry')
    if (entry.dir) continue
    if (!ALLOWED_EXTENSIONS.test(name) || files.size >= PLUGIN_LIMITS.files)
      throw new Error('Unsupported or too many plugin files')
    const content = await readZipEntry(entry, 8 * 1024 * 1024 - total)
    total += content.length
    files.set(name, content)
  }
  if (!files.has('manifest.json')) {
    const roots = new Set([...files.keys()].map((name) => name.split('/')[0]))
    if (roots.size !== 1)
      throw new Error('manifest.json must be at the plugin root')
    const prefix = `${[...roots][0]}/`
    for (const [name, value] of [...files]) {
      files.delete(name)
      files.set(name.slice(prefix.length), value)
    }
  }
  const manifestBytes = files.get('manifest.json')
  if (!manifestBytes || manifestBytes.length > PLUGIN_LIMITS.manifestBytes)
    throw new Error('Invalid manifest size')
  const parsed = sanitizePluginManifest(
    JSON.parse(new TextDecoder().decode(manifestBytes)),
  )
  if (parsed.manifest === null) throw new Error(parsed.warnings.join('\n'))
  const main = files.get(parsed.manifest.main)
  if (!main || main.length > PLUGIN_LIMITS.mainBytes)
    throw new Error('Invalid plugin entry point')
  for (const panel of parsed.manifest.contributes.panels)
    if (!files.has(`ui/${panel.entry}`))
      throw new Error(`Missing panel: ${panel.entry}`)
  return { manifest: parsed.manifest, files }
}
