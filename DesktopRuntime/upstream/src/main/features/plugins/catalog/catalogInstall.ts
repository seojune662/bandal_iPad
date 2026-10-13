import { createHash, randomUUID } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, isAbsolute, join, relative, resolve } from 'node:path'
import { compareSemver } from '../../../../shared/plugins/semver'
import { readZipEntry } from '../../../../shared/plugins/archive'
import { sanitizeWorkflowPack } from '../../../../shared/workflowPacks/sanitize'
import {
  CATALOG_ARTIFACT_MAX_BYTES,
  type CatalogEntry,
  type CatalogInstallResult
} from '../../../../shared/types/pluginCatalog'
import { ValidationError } from '../../../db/errors'
import type { PackStore } from '../../workflowPacks/packStore'
import { readManifest, type PluginStore } from '../pluginStore'
import type { CatalogFetch, CatalogService } from './catalogService'

interface CatalogInstallerDeps {
  catalog: Pick<CatalogService, 'current'>
  pluginStore: Pick<PluginStore, 'installFromFolder'>
  packStore: Pick<PackStore, 'list' | 'importText'>
  fetch: CatalogFetch
  appVersion(): string
  tempDir?: string
  makeId?: () => string
}

function interop<T>(module: unknown): T {
  const record = module as { default?: T }
  return (record.default ?? module) as T
}

async function downloadArtifact(
  fetch: CatalogFetch,
  entry: CatalogEntry
): Promise<Buffer> {
  const response = await fetch(entry.url, {
    signal: AbortSignal.timeout(30_000)
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  const declared = Number(response.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > CATALOG_ARTIFACT_MAX_BYTES) {
    throw new ValidationError('파일이 허용된 크기를 초과해요')
  }
  if (response.body === null) return verifyArtifact(Buffer.alloc(0), entry.sha256)

  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  const hash = createHash('sha256')
  let size = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    size += value.byteLength
    if (size > CATALOG_ARTIFACT_MAX_BYTES) {
      await reader.cancel()
      throw new ValidationError('파일이 허용된 크기를 초과해요')
    }
    hash.update(value)
    chunks.push(value)
  }
  if (hash.digest('hex') !== entry.sha256) {
    throw new ValidationError('파일이 카탈로그와 달라요')
  }
  return Buffer.concat(chunks.map((chunk) => Buffer.from(chunk)))
}

function verifyArtifact(bytes: Buffer, expected: string): Buffer {
  if (createHash('sha256').update(bytes).digest('hex') !== expected) {
    throw new ValidationError('파일이 카탈로그와 달라요')
  }
  return bytes
}

function unsafeZipPath(name: string): boolean {
  return (
    name === '' ||
    name.startsWith('/') ||
    name.startsWith('\\') ||
    /^[A-Za-z]:[\\/]/.test(name) ||
    name.includes('\\') ||
    name.split('/').includes('..')
  )
}

function isZipSymlink(entry: import('jszip').JSZipObject): boolean {
  const permissions = entry.unixPermissions
  const mode =
    typeof permissions === 'string' ? Number.parseInt(permissions, 8) : permissions
  return typeof mode === 'number' && (mode & 0o170000) === 0o120000
}

function destinationFor(root: string, name: string): string {
  const destination = resolve(root, name)
  const inside = relative(root, destination)
  if (inside === '' || inside.startsWith('..') || isAbsolute(inside)) {
    throw new ValidationError('압축 파일 경로가 임시 폴더를 벗어납니다.')
  }
  return destination
}

async function extractZip(bytes: Buffer, root: string): Promise<void> {
  const JSZip = interop<typeof import('jszip')>(await import('jszip'))
  const zip = await JSZip.loadAsync(bytes)
  const entries = Object.values(zip.files)
  if (entries.length > 500) {
    throw new ValidationError('압축 파일 항목이 500개를 초과해요')
  }

  let extractedBytes = 0
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const originalName = entry.unsafeOriginalName ?? entry.name
    if (unsafeZipPath(originalName)) {
      throw new ValidationError('압축 파일에 안전하지 않은 경로가 있어요')
    }
    const destination = destinationFor(root, entry.name)
    if (isZipSymlink(entry)) continue
    if (entry.dir) {
      await mkdir(destination, { recursive: true })
      continue
    }
    const content = await readZipEntry(entry, CATALOG_ARTIFACT_MAX_BYTES - extractedBytes)
    extractedBytes += content.byteLength
    if (extractedBytes > CATALOG_ARTIFACT_MAX_BYTES) {
      throw new ValidationError('압축을 푼 파일이 허용된 크기를 초과해요')
    }
    await mkdir(dirname(destination), { recursive: true })
    await writeFile(destination, content)
  }
}

async function pluginRoot(extractedRoot: string): Promise<string> {
  if (existsSync(join(extractedRoot, 'manifest.json'))) return extractedRoot
  const topLevel = await readdir(extractedRoot, { withFileTypes: true })
  if (topLevel.length === 1 && topLevel[0]?.isDirectory()) {
    return join(extractedRoot, topLevel[0].name)
  }
  return extractedRoot
}

function catalogEntry(
  service: Pick<CatalogService, 'current'>,
  sourceUrl: string,
  id: string
): CatalogEntry {
  const entry = service
    .current()
    ?.entries.find((candidate) => candidate.sourceUrl === sourceUrl && candidate.id === id)
  if (entry === undefined) {
    throw new ValidationError('카탈로그를 먼저 새로고침하세요')
  }
  return entry
}

function existingPack(
  text: string,
  store: Pick<PackStore, 'list' | 'importText'>
): Extract<CatalogInstallResult, { kind: 'pack' }> | null {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  const sanitized = sanitizeWorkflowPack(raw)
  if (sanitized.pack === null) return null
  const name = sanitized.pack.name
  const found = store
    .list()
    .find(({ pack, source }) => source === 'user' && pack.name === name)
  if (found === undefined) return null
  if (compareSemver(sanitized.pack.version, found.pack.version) > 0) {
    return { kind: 'pack', ...store.importText(text, found.pack.id) }
  }
  return { kind: 'pack', pack: found.pack, warnings: sanitized.warnings }
}

export function createCatalogInstaller(deps: CatalogInstallerDeps): {
  install(sourceUrl: string, id: string): Promise<CatalogInstallResult>
} {
  return {
    async install(sourceUrl, id) {
      const entry = catalogEntry(deps.catalog, sourceUrl, id)
      if (
        entry.minAppVersion !== null &&
        compareSemver(deps.appVersion(), entry.minAppVersion) < 0
      ) {
        throw new ValidationError(`반달 ${entry.minAppVersion} 이상이 필요해요`)
      }
      const bytes = await downloadArtifact(deps.fetch, entry)
      if (entry.kind === 'pack') {
        const text = bytes.toString('utf8')
        const duplicate = existingPack(text, deps.packStore)
        if (duplicate !== null) return duplicate
        const imported = deps.packStore.importText(text)
        return { kind: 'pack', ...imported }
      }

      const root = join(
        deps.tempDir ?? tmpdir(),
        `bandal-catalog-${(deps.makeId ?? randomUUID)()}`
      )
      await mkdir(root)
      try {
        await extractZip(bytes, root)
        const source = await pluginRoot(root)
        const manifest = readManifest(source).manifest
        if (manifest.id !== entry.id) {
          throw new ValidationError('manifest.json의 id가 카탈로그 항목과 달라요')
        }
        if (manifest.version !== entry.version || (entry.minAppVersion !== null && manifest.minAppVersion !== entry.minAppVersion)) {
          throw new ValidationError('플러그인 버전 정보가 카탈로그와 다릅니다.')
        }
        const installed = await deps.pluginStore.installFromFolder(source)
        return { kind: 'extension', ...installed }
      } finally {
        await rm(root, { recursive: true, force: true })
      }
    }
  }
}
