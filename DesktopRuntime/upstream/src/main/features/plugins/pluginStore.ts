/**
 * Installed-extension registry: `<userData>/plugins.json` envelope plus the
 * copied plugin folders under `<userData>/plugins/<id>/`.
 *
 * Install is a validated COPY, never a symlink or an in-place load — the
 * source folder can change after the user approved it, the copy cannot. The
 * approval record stores the permission set AND a sha256 over
 * manifest.json + main.js + panel/assets, so different code or grants
 * flips the plugin back to `needs-approval`.
 *
 * Runtime state (`starting`/`active`/`errored`) is held in memory here and
 * projected onto every `PluginSummary`; only `enabled`, approvals and the
 * last error are persisted.
 */

import { createHash } from 'node:crypto'
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync
} from 'node:fs'
import { extname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { sanitizePluginManifest } from '../../../shared/plugins/sanitize'
import {
  PLUGIN_ID_MAX_LENGTH,
  PLUGIN_ID_PATTERN,
  PLUGIN_LIMITS,
  type PluginManifest,
  type PluginPermission,
  type PluginState,
  type PluginSummary
} from '../../../shared/types/plugin'
import { ConflictError, NotFoundError, ValidationError } from '../../db/errors'
import { quarantineFile, writeFileAtomic } from '../../lib/atomicWrite'

export const PLUGINS_ENVELOPE_FILE = 'plugins.json'
export const PLUGINS_DIR = 'plugins'
const ENVELOPE_FORMAT = 'bandal-plugins'
const ENVELOPE_VERSION = 1
const MANIFEST_FILE = 'manifest.json'

export const PLUGIN_FILE_EXTENSIONS: ReadonlySet<string> = new Set([
  '.js',
  '.mjs',
  '.json',
  '.html',
  '.css',
  '.svg',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.woff2',
  '.txt',
  '.md'
])

interface PluginRecord {
  id: string
  enabled: boolean
  installedAt: string
  approvedPermissions: readonly PluginPermission[] | null
  /** Content digest at approval time; null until approved. */
  sha256: string | null
  lastError: string | null
}

interface PluginEnvelope {
  format: typeof ENVELOPE_FORMAT
  version: typeof ENVELOPE_VERSION
  plugins: PluginRecord[]
}

export interface PluginStoreDeps {
  userDataDir: string
  now?: () => string
}

export interface PluginStore {
  list(): PluginSummary[]
  get(id: string): PluginSummary | null
  installFromFolder(
    sourceDir: string
  ): Promise<{ plugin: PluginSummary; warnings: string[] }>
  uninstall(id: string): Promise<void>
  setEnabled(id: string, enabled: boolean): PluginSummary
  approve(id: string): PluginSummary
  manifestFor(id: string): PluginManifest | null
  needsApproval(id: string): boolean
  dirFor(id: string): string
  setState(id: string, state: PluginState, lastError?: string | null): PluginSummary
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isValidPluginId(id: unknown): id is string {
  return (
    typeof id === 'string' &&
    id.length <= PLUGIN_ID_MAX_LENGTH &&
    PLUGIN_ID_PATTERN.test(id)
  )
}

function parseRecord(raw: unknown): PluginRecord | null {
  if (!isRecord(raw) || !isValidPluginId(raw['id'])) return null
  const approved = raw['approvedPermissions']
  return {
    id: raw['id'],
    enabled: raw['enabled'] === true,
    installedAt:
      typeof raw['installedAt'] === 'string' ? raw['installedAt'] : '',
    approvedPermissions: Array.isArray(approved)
      ? (approved.filter((p): p is string => typeof p === 'string') as PluginPermission[])
      : null,
    sha256: typeof raw['sha256'] === 'string' ? raw['sha256'] : null,
    lastError: typeof raw['lastError'] === 'string' ? raw['lastError'] : null
  }
}

function parseEnvelope(text: string): PluginEnvelope {
  const parsed: unknown = JSON.parse(text)
  if (
    !isRecord(parsed) ||
    parsed['format'] !== ENVELOPE_FORMAT ||
    parsed['version'] !== ENVELOPE_VERSION ||
    !Array.isArray(parsed['plugins'])
  ) {
    throw new ValidationError('plugins.json has an unknown format')
  }
  const plugins = parsed['plugins']
    .map(parseRecord)
    .filter((record): record is PluginRecord => record !== null)
  return { format: ENVELOPE_FORMAT, version: ENVELOPE_VERSION, plugins }
}

function emptyEnvelope(): PluginEnvelope {
  return { format: ENVELOPE_FORMAT, version: ENVELOPE_VERSION, plugins: [] }
}

/** Reads + sanitizes `<dir>/manifest.json`; throws ValidationError. */
export function readManifest(dir: string): {
  manifest: PluginManifest
  warnings: string[]
} {
  const file = join(dir, MANIFEST_FILE)
  let stats
  try {
    stats = lstatSync(file)
  } catch {
    throw new ValidationError('manifest.json is missing')
  }
  if (!stats.isFile()) throw new ValidationError('manifest.json must be a file')
  if (stats.size > PLUGIN_LIMITS.manifestBytes) {
    throw new ValidationError(
      `manifest.json exceeds ${PLUGIN_LIMITS.manifestBytes} bytes`
    )
  }
  let raw: unknown
  try {
    raw = JSON.parse(readFileSync(file, 'utf8'))
  } catch {
    throw new ValidationError('manifest.json is not valid JSON')
  }
  const { manifest, warnings } = sanitizePluginManifest(raw)
  if (manifest === null) {
    throw new ValidationError(`manifest.json rejected: ${warnings.join(' ')}`)
  }
  return { manifest, warnings }
}

interface ScannedFile {
  /** POSIX-relative path inside the plugin folder. */
  relPath: string
  size: number
  modified: number
  changed: number
}

/**
 * Walks a plugin folder applying the install caps. Every entry must be a
 * regular allow-listed file or a directory; dotfiles, symlinks and unknown
 * extensions reject the whole install so an author cannot smuggle unreviewed
 * content beside the copied runtime.
 */
export function scanPluginFolder(
  sourceDir: string
): ScannedFile[] {
  const files: ScannedFile[] = []
  let totalBytes = 0
  let entries = 0

  const walk = (dir: string, depth = 0): void => {
    if (depth > 32) throw new ValidationError('plugin folder nesting exceeds 32 levels')
    for (const name of readdirSync(dir).sort()) {
      if (++entries > 500) throw new ValidationError('plugin has more than 500 entries')
      if (name.startsWith('.')) {
        throw new ValidationError(`dotfiles are not allowed (${name})`)
      }
      const abs = join(dir, name)
      const stats = lstatSync(abs)
      if (stats.isSymbolicLink()) {
        throw new ValidationError(`symlinks are not allowed (${name})`)
      }
      if (stats.isDirectory()) {
        walk(abs, depth + 1)
        continue
      }
      if (!stats.isFile()) {
        throw new ValidationError(`unsupported entry ${name}`)
      }
      const relPath = relative(sourceDir, abs).split(sep).join('/')
      if (relPath.split('/').some((segment) => segment.startsWith('.'))) {
        throw new ValidationError(`dotfiles are not allowed (${relPath})`)
      }
      if (!PLUGIN_FILE_EXTENSIONS.has(extname(name).toLowerCase())) {
        throw new ValidationError(`extension is not allowed (${relPath})`)
      }
      files.push({ relPath, size: stats.size, modified: stats.mtimeMs, changed: stats.ctimeMs })
      totalBytes += stats.size
      if (files.length > PLUGIN_LIMITS.files) {
        throw new ValidationError(
          `plugin has more than ${PLUGIN_LIMITS.files} files`
        )
      }
      if (totalBytes > PLUGIN_LIMITS.totalBytes) {
        throw new ValidationError(
          `plugin exceeds ${PLUGIN_LIMITS.totalBytes} bytes`
        )
      }
    }
  }
  walk(sourceDir)
  return files
}

/** Include panel scripts/assets too. Two-file v1 plugins retain their digest. */
export function hashPluginCode(dir: string, main: string, files = scanPluginFolder(dir)): string {
  const hash = createHash('sha256')
  hash.update(readFileSync(join(dir, MANIFEST_FILE)))
  hash.update(readFileSync(join(dir, main)))
  for (const file of files.filter((file) => file.relPath !== MANIFEST_FILE && file.relPath !== main).sort((a, b) => a.relPath.localeCompare(b.relPath))) {
    const content = readFileSync(join(dir, file.relPath))
    hash.update(`\0${file.relPath}\0${content.length}\0`)
    hash.update(content)
  }
  return hash.digest('hex')
}

export function createPluginStore(deps: PluginStoreDeps): PluginStore {
  const now = deps.now ?? (() => new Date().toISOString())
  const envelopePath = join(deps.userDataDir, PLUGINS_ENVELOPE_FILE)
  const pluginsRoot = join(deps.userDataDir, PLUGINS_DIR)
  const runtimeState = new Map<string, PluginState>()
  const manifestCache = new Map<string, PluginManifest | null>()
  const digestCache = new Map<string, { fingerprint: string; digest: string }>()
  function currentDigest(id: string, main: string): string {
    const files = scanPluginFolder(dirFor(id))
    const fingerprint = JSON.stringify([main, files])
    const cached = digestCache.get(id)
    if (cached?.fingerprint === fingerprint) return cached.digest
    const digest = hashPluginCode(dirFor(id), main, files)
    digestCache.set(id, { fingerprint, digest })
    return digest
  }

  function load(): PluginEnvelope {
    if (!existsSync(envelopePath)) return emptyEnvelope()
    const text = readFileSync(envelopePath, 'utf8')
    try {
      return parseEnvelope(text)
    } catch (error) {
      const quarantined = quarantineFile(envelopePath, new Date(now()))
      console.error(
        `[plugins] plugins.json was unreadable; moved to ${quarantined ?? '(gone)'}`,
        error
      )
      return emptyEnvelope()
    }
  }

  function persist(next: PluginEnvelope): void {
    mkdirSync(deps.userDataDir, { recursive: true })
    writeFileAtomic(envelopePath, JSON.stringify(next, null, 2), { mode: 0o600 })
  }

  function dirFor(id: string): string {
    if (!isValidPluginId(id)) throw new ValidationError('invalid plugin id')
    return join(pluginsRoot, id)
  }

  function manifestFor(id: string): PluginManifest | null {
    if (!isValidPluginId(id)) return null
    if (manifestCache.has(id)) return manifestCache.get(id) ?? null
    let manifest: PluginManifest | null = null
    try {
      manifest = readManifest(dirFor(id)).manifest
      if (manifest.id !== id) manifest = null
    } catch {
      manifest = null
    }
    manifestCache.set(id, manifest)
    return manifest
  }

  function findRecord(envelope: PluginEnvelope, id: string): PluginRecord {
    const record = envelope.plugins.find((plugin) => plugin.id === id)
    if (record === undefined) throw new NotFoundError('plugin', id)
    return record
  }

  function computeNeedsApproval(record: PluginRecord, manifest: PluginManifest): boolean {
    if (record.approvedPermissions === null || record.sha256 === null) return true
    const approved = new Set<string>(record.approvedPermissions)
    if (!manifest.permissions.every((permission) => approved.has(permission))) {
      return true
    }
    try {
      return currentDigest(record.id, manifest.main) !== record.sha256
    } catch {
      return true
    }
  }

  function summaryFor(record: PluginRecord): PluginSummary | null {
    const manifest = manifestFor(record.id)
    if (manifest === null) return null
    const runtime = runtimeState.get(record.id)
    let state: PluginState
    if (runtime !== undefined) {
      state = runtime
    } else if (computeNeedsApproval(record, manifest)) {
      state = 'needs-approval'
    } else if (record.enabled) {
      // Enabled + approved but the runtime has not reported yet (host boot).
      state = 'starting'
    } else {
      state = 'disabled'
    }
    return {
      manifest,
      enabled: record.enabled,
      state,
      approvedPermissions: record.approvedPermissions,
      installedAt: record.installedAt,
      lastError: record.lastError
    }
  }

  function update(
    id: string,
    patch: Partial<Omit<PluginRecord, 'id'>>
  ): PluginSummary {
    const envelope = load()
    const record = findRecord(envelope, id)
    const nextRecord: PluginRecord = { ...record, ...patch }
    persist({
      ...envelope,
      plugins: envelope.plugins.map((plugin) =>
        plugin.id === id ? nextRecord : plugin
      )
    })
    const summary = summaryFor(nextRecord)
    if (summary === null) throw new NotFoundError('plugin', id)
    return summary
  }

  function copyFolder(sourceDir: string, files: ScannedFile[], target: string): void {
    for (const file of files) {
      const dest = join(target, ...file.relPath.split('/'))
      mkdirSync(join(dest, '..'), { recursive: true })
      copyFileSync(join(sourceDir, ...file.relPath.split('/')), dest)
    }
  }

  return {
    list() {
      return load()
        .plugins.map(summaryFor)
        .filter((summary): summary is PluginSummary => summary !== null)
    },
    get(id) {
      if (!isValidPluginId(id)) return null
      const record = load().plugins.find((plugin) => plugin.id === id)
      return record === undefined ? null : summaryFor(record)
    },
    async installFromFolder(sourceDir) {
      if (typeof sourceDir !== 'string' || sourceDir === '') {
        throw new ValidationError('source folder is required')
      }
      const source = resolve(sourceDir)
      let sourceStats
      try {
        sourceStats = statSync(source)
      } catch {
        throw new ValidationError('source folder does not exist')
      }
      if (!sourceStats.isDirectory()) {
        throw new ValidationError('source must be a folder')
      }
      const within = relative(pluginsRoot, source)
      if (within === '' || (!within.startsWith('..') && !isAbsolute(within))) {
        throw new ValidationError('cannot install from the plugins folder itself')
      }

      const { manifest, warnings } = readManifest(source)
      // Read the registry before touching any installed files. I/O failures
      // must not strand an unregistered replacement on disk.
      const envelope = load()
      const existing = envelope.plugins.find((plugin) => plugin.id === manifest.id)
      const files = scanPluginFolder(source)
      const mainFile = files.find((file) => file.relPath === manifest.main)
      if (mainFile === undefined) {
        throw new ValidationError(`${manifest.main} is missing`)
      }
      if (mainFile.size > PLUGIN_LIMITS.mainBytes) {
        throw new ValidationError(
          `${manifest.main} exceeds ${PLUGIN_LIMITS.mainBytes} bytes`
        )
      }
      if (manifest.styles !== null && !files.some((file) => file.relPath === manifest.styles)) {
        warnings.push(`${manifest.styles} declared but missing; ignored.`)
      }
      for (const panel of manifest.contributes.panels) {
        const entry = `ui/${panel.entry}`
        if (!files.some((file) => file.relPath === entry)) {
          warnings.push(`panel "${panel.id}" entry ${entry} is missing.`)
        }
      }

      const target = dirFor(manifest.id)
      const staging = join(pluginsRoot, `.${manifest.id}.${process.pid}.staging`)
      const previous = join(pluginsRoot, `.${manifest.id}.${process.pid}.previous`)
      const previousState = runtimeState.get(manifest.id)
      mkdirSync(pluginsRoot, { recursive: true })
      rmSync(staging, { recursive: true, force: true })
      try {
        mkdirSync(staging, { recursive: true })
        copyFolder(source, files, staging)
        rmSync(previous, { recursive: true, force: true })
        if (existsSync(target)) renameSync(target, previous)
        try {
          renameSync(staging, target)
        } catch (error) {
          if (existsSync(previous)) renameSync(previous, target)
          throw error
        }
      } catch (error) {
        rmSync(staging, { recursive: true, force: true })
        throw error
      }
      manifestCache.delete(manifest.id)
      runtimeState.delete(manifest.id)

      const record: PluginRecord = {
        id: manifest.id,
        enabled: false,
        installedAt: now(),
        // Re-install keeps the approval record; needsApproval() re-derives
        // from the hash, so changed code or grants still prompt again.
        approvedPermissions: existing?.approvedPermissions ?? null,
        sha256: existing?.sha256 ?? null,
        lastError: null
      }
      let plugin: PluginSummary | null
      try {
        plugin = summaryFor(record)
        if (plugin === null) throw new ConflictError('installed plugin could not be read back')
        persist({ ...envelope, plugins: [...envelope.plugins.filter((item) => item.id !== manifest.id), record] })
      } catch (error) {
        // The folder and registry are one transaction. A disk-full registry
        // write must not leave new executable bytes under an old approval.
        rmSync(target, { recursive: true, force: true })
        if (existsSync(previous)) renameSync(previous, target)
        manifestCache.delete(manifest.id)
        if (previousState !== undefined) runtimeState.set(manifest.id, previousState)
        throw error
      }
      try { rmSync(previous, { recursive: true, force: true }) } catch { /* Recoverable backup; install already committed. */ }
      return { plugin, warnings }
    },
    async uninstall(id) {
      const envelope = load()
      findRecord(envelope, id)
      persist({
        ...envelope,
        plugins: envelope.plugins.filter((plugin) => plugin.id !== id)
      })
      rmSync(dirFor(id), { recursive: true, force: true })
      manifestCache.delete(id)
      digestCache.delete(id)
      runtimeState.delete(id)
    },
    setEnabled(id, enabled) {
      if (!enabled) runtimeState.delete(id)
      return update(id, { enabled, ...(enabled ? {} : { lastError: null }) })
    },
    approve(id) {
      const manifest = manifestFor(id)
      if (manifest === null) throw new NotFoundError('plugin', id)
      const sha256 = hashPluginCode(dirFor(id), manifest.main)
      runtimeState.delete(id)
      return update(id, {
        approvedPermissions: [...manifest.permissions],
        sha256,
        lastError: null
      })
    },
    manifestFor,
    needsApproval(id) {
      const manifest = manifestFor(id)
      if (manifest === null) return true
      const record = load().plugins.find((plugin) => plugin.id === id)
      if (record === undefined) return true
      return computeNeedsApproval(record, manifest)
    },
    dirFor,
    setState(id, state, lastError) {
      runtimeState.set(id, state)
      if (lastError === undefined) {
        const record = findRecord(load(), id)
        const summary = summaryFor(record)
        if (summary === null) throw new NotFoundError('plugin', id)
        return summary
      }
      return update(id, { lastError })
    }
  }
}
