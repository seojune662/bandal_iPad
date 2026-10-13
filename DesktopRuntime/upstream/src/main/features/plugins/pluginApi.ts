/** Permission-gated broker implementations backed by Bandal repositories. */

import { extname, posix } from 'node:path'
import { net } from 'electron'
import type { CoursesRepo } from '../courses/coursesRepo'
import type { MaterialsRepo } from '../materials/materialsRepo'
import { extractMaterialText } from '../materials/textExtract'
import type { NotesRepo } from '../notes/notesRepo'
import { NotFoundError, ValidationError } from '../../db/errors'
import type { PluginDataStore } from './pluginDataStore'
import { PluginApiError, type PluginApiImpl } from './rpcBroker'
import { PLUGIN_RPC_LIMITS } from '../../../shared/types/pluginRpc'
import type { MaterialNode } from '../../../shared/types/materials'

const NOTE_ID_PREFIX = 'bandal-note:v1:'
const MAX_NOTE_CONTENT_BYTES = 1024 * 1024
const MAX_TEXT_RESULT_CHARS = 200_000

interface NoteAddress {
  courseId: string
  relPath: string
}

export interface PluginApiDeps {
  editor?: { request(input: Omit<import('../../../shared/types/pluginEditor').PluginEditorRequest, 'requestId'>): Promise<unknown> }
  configuration?: {
    has(id: string, key: string): boolean
    get(id: string): Record<string, unknown>
    set(id: string, key: string, value: unknown): void
  }
  courses: CoursesRepo
  notes: NotesRepo
  materials: MaterialsRepo
  data: PluginDataStore
  currentCourseId(): string | null
  onNoteSaved(courseId: string, relPath: string): void
  showNotice(pluginId: string, message: string, tone: 'info' | 'danger'): void
  openPanel(pluginId: string, panelId: string): void
  closePanel?(pluginId: string, panelId: string): void
  postPanel(pluginId: string, panelId: string, payload: unknown): void
  panelExists(pluginId: string, panelId: string): boolean
  networkAllowed(pluginId: string, url: string): boolean
}

function stringArg(value: unknown, name: string, max = 4096): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new ValidationError(`${name} must be a non-empty string`)
  }
  if (value.length > max) throw new ValidationError(`${name} is too long`)
  return value
}

function objectArg(value: unknown, name: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new ValidationError(`${name} must be an object`)
  }
  return value as Record<string, unknown>
}

function noteId(address: NoteAddress): string {
  return `${NOTE_ID_PREFIX}${Buffer.from(JSON.stringify(address)).toString('base64url')}`
}

function parseNoteId(value: unknown): NoteAddress {
  const id = stringArg(value, 'noteId', 8192)
  if (!id.startsWith(NOTE_ID_PREFIX)) throw new ValidationError('invalid note id')
  let parsed: unknown
  try {
    parsed = JSON.parse(
      Buffer.from(id.slice(NOTE_ID_PREFIX.length), 'base64url').toString('utf8')
    )
  } catch {
    throw new ValidationError('invalid note id')
  }
  const record = objectArg(parsed, 'noteId')
  return {
    courseId: stringArg(record['courseId'], 'courseId'),
    relPath: stringArg(record['relPath'], 'relPath')
  }
}

function flatten(nodes: readonly MaterialNode[]): MaterialNode[] {
  const result: MaterialNode[] = []
  for (const node of nodes) {
    if (node.kind === 'dir') result.push(...flatten(node.children ?? []))
    else result.push(node)
  }
  return result
}

function publicCourse(course: ReturnType<CoursesRepo['getById']>) {
  return {
    id: course.id,
    name: course.name,
    color: course.color,
    archived: course.archived,
    groupId: course.groupId
  }
}

function publicNote(address: NoteAddress, markdown: string, mtime: number) {
  return {
    id: noteId(address),
    courseId: address.courseId,
    relPath: address.relPath,
    title: posix.basename(address.relPath).replace(/\.md$/iu, ''),
    content: markdown,
    mtime
  }
}

function assertPanel(deps: PluginApiDeps, pluginId: string, value: unknown): string {
  const panelId = stringArg(value, 'panelId', 48)
  if (!deps.panelExists(pluginId, panelId)) {
    throw new NotFoundError('plugin panel', panelId)
  }
  return panelId
}

function safeHeaders(value: unknown): Record<string, string> {
  if (value === undefined) return {}
  const input = objectArg(value, 'headers')
  const headers: Record<string, string> = {}
  const forbidden = new Set([
    'cookie',
    'host',
    'content-length',
    'origin',
    'referer',
    'connection',
    'upgrade'
  ])
  for (const [name, raw] of Object.entries(input)) {
    const normalized = name.trim().toLowerCase()
    if (normalized === '' || forbidden.has(normalized)) continue
    if (typeof raw !== 'string') {
      throw new ValidationError(`header ${name} must be a string`)
    }
    if (name.length > 128 || raw.length > 8192 || /[\r\n]/.test(name + raw)) {
      throw new ValidationError(`header ${name} is invalid`)
    }
    headers[name] = raw
  }
  return headers
}

async function responseBytes(response: Response): Promise<Uint8Array> {
  const declared = Number(response.headers.get('content-length'))
  if (Number.isFinite(declared) && declared > PLUGIN_RPC_LIMITS.fetchResponseBytes) {
    throw new PluginApiError('payload-too-large', 'network response is too large')
  }
  if (response.body === null) return new Uint8Array()
  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  while (true) {
    const next = await reader.read()
    if (next.done) break
    total += next.value.byteLength
    if (total > PLUGIN_RPC_LIMITS.fetchResponseBytes) {
      await reader.cancel()
      throw new PluginApiError('payload-too-large', 'network response is too large')
    }
    chunks.push(next.value)
  }
  const combined = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    combined.set(chunk, offset)
    offset += chunk.byteLength
  }
  return combined
}

async function pluginFetch(
  deps: PluginApiDeps,
  pluginId: string,
  urlValue: unknown,
  optionsValue: unknown
): Promise<unknown> {
  let url = stringArg(urlValue, 'url', 16_384)
  const options =
    optionsValue === undefined ? {} : objectArg(optionsValue, 'fetch options')
  const methodValue = options['method'] ?? 'GET'
  let method = stringArg(methodValue, 'method', 16).toUpperCase()
  if (!['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) {
    throw new ValidationError(`unsupported HTTP method ${method}`)
  }
  const headers = safeHeaders(options['headers'])
  const requestedBody = options['body']
  if (requestedBody !== undefined && typeof requestedBody !== 'string') {
    throw new ValidationError('fetch body must be a string')
  }
  let bodyValue: string | undefined = requestedBody
  if (
    typeof bodyValue === 'string' &&
    Buffer.byteLength(bodyValue, 'utf8') > PLUGIN_RPC_LIMITS.messageBytes
  ) {
    throw new PluginApiError('payload-too-large', 'fetch body is too large')
  }

  const controller = new AbortController()
  const timer = setTimeout(
    () => controller.abort(),
    PLUGIN_RPC_LIMITS.fetchTimeoutMs
  )
  try {
    for (let redirects = 0; redirects <= 5; redirects += 1) {
      if (!deps.networkAllowed(pluginId, url)) {
        throw new PluginApiError(
          'permission-denied',
          `network access to ${new URL(url).hostname} is not approved`
        )
      }
      const init: RequestInit = {
        method,
        headers,
        redirect: 'manual',
        signal: controller.signal,
        ...(bodyValue === undefined || method === 'GET' || method === 'HEAD'
          ? {}
          : { body: bodyValue })
      }
      const response = await net.fetch(url, init)
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get('location')
        if (location !== null) {
          await response.body?.cancel()
          if (redirects === 5) {
            throw new ValidationError('network request has too many redirects')
          }
          const next = new URL(location, url)
          // A grant to contact both hosts does not grant the second host the
          // first host's credentials. Match fetch's cross-origin behavior.
          if (next.origin !== new URL(url).origin) {
            for (const key of Object.keys(headers)) {
              if (['authorization', 'proxy-authorization'].includes(key.toLowerCase())) delete headers[key]
            }
          }
          if (((response.status === 301 || response.status === 302) && method === 'POST') ||
              (response.status === 303 && method !== 'GET' && method !== 'HEAD')) {
            method = 'GET'
            bodyValue = undefined
            for (const key of Object.keys(headers)) {
              if (['content-type', 'content-encoding', 'content-language', 'content-location'].includes(key.toLowerCase())) delete headers[key]
            }
          }
          url = next.toString()
          continue
        }
      }
      const bytes = await responseBytes(response)
      return {
        url: response.url || url,
        status: response.status,
        statusText: response.statusText,
        headers: Object.fromEntries(response.headers.entries()),
        body: new TextDecoder().decode(bytes)
      }
    }
    throw new ValidationError('network redirect is missing a location')
  } catch (error) {
    if (controller.signal.aborted) {
      throw new PluginApiError('timeout', 'network request timed out')
    }
    throw error
  } finally {
    clearTimeout(timer)
  }
}

export function createPluginApi(deps: PluginApiDeps): PluginApiImpl {
  return {
    'courses.list': async () =>
      deps.courses.list({ includeArchived: false }).map(publicCourse),
    'courses.current': async () => {
      const courseId = deps.currentCourseId()
      return courseId === null ? null : publicCourse(deps.courses.getById(courseId))
    },
    'notes.list': async (_pluginId, courseIdValue) => {
      const courseId = stringArg(courseIdValue, 'courseId')
      deps.courses.getById(courseId)
      return flatten(await deps.materials.tree(courseId))
        .filter((node) => node.kind === 'note')
        .map((node) => ({
          id: noteId({ courseId, relPath: node.relPath }),
          courseId,
          relPath: node.relPath,
          title: node.name.replace(/\.md$/iu, ''),
          mtime: node.mtime ?? null
        }))
    },
    'notes.read': async (_pluginId, noteIdValue) => {
      const address = parseNoteId(noteIdValue)
      const note = deps.notes.read(address)
      return publicNote(address, note.markdown, note.mtime)
    },
    'notes.write': async (_pluginId, noteIdValue, inputValue) => {
      const address = parseNoteId(noteIdValue)
      const input = objectArg(inputValue, 'note input')
      const content = input['content'] ?? input['markdown']
      if (typeof content !== 'string') {
        throw new ValidationError('note content must be a string')
      }
      if (Buffer.byteLength(content, 'utf8') > MAX_NOTE_CONTENT_BYTES) {
        throw new PluginApiError('payload-too-large', 'note content is too large')
      }
      const expected = input['expectedMtime']
      if (expected !== undefined && typeof expected !== 'number') {
        throw new ValidationError('expectedMtime must be a number')
      }
      const result = deps.notes.write({
        ...address,
        markdown: content,
        ...(typeof expected === 'number' ? { expectedMtime: expected } : {})
      })
      deps.materials.invalidateTree(address.courseId)
      deps.onNoteSaved(address.courseId, address.relPath)
      return publicNote(address, content, result.mtime)
    },
    'notes.create': async (_pluginId, courseIdValue, inputValue) => {
      const courseId = stringArg(courseIdValue, 'courseId')
      const input = objectArg(inputValue, 'note input')
      const title = stringArg(input['title'], 'title', 120)
      const dirRelPath = input['dirRelPath'] ?? ''
      if (typeof dirRelPath !== 'string') {
        throw new ValidationError('dirRelPath must be a string')
      }
      const content = input['content'] ?? input['markdown']
      if (content !== undefined && typeof content !== 'string') {
        throw new ValidationError('note content must be a string')
      }
      if (
        typeof content === 'string' &&
        Buffer.byteLength(content, 'utf8') > MAX_NOTE_CONTENT_BYTES
      ) {
        throw new PluginApiError('payload-too-large', 'note content is too large')
      }
      const created = deps.notes.create({ courseId, dirRelPath, title })
      let note = deps.notes.read(created)
      if (typeof content === 'string') {
        const written = deps.notes.write({ ...created, markdown: content })
        note = { ...created, markdown: content, mtime: written.mtime }
      }
      deps.materials.invalidateTree(courseId)
      deps.onNoteSaved(courseId, created.relPath)
      return publicNote(created, note.markdown, note.mtime)
    },
    'materials.list': async (_pluginId, courseIdValue) => {
      const courseId = stringArg(courseIdValue, 'courseId')
      deps.courses.getById(courseId)
      return deps.materials.tree(courseId)
    },
    'materials.readText': async (_pluginId, courseIdValue, relPathValue) => {
      const courseId = stringArg(courseIdValue, 'courseId')
      const relPath = stringArg(relPathValue, 'relPath')
      const text = await extractMaterialText(
        deps.materials.absolutePathFor(courseId, relPath),
        extname(relPath),
        MAX_TEXT_RESULT_CHARS
      )
      if (text === null) throw new ValidationError('material is not a supported text file')
      return text
    },
    'notices.show': async (pluginId, messageValue, toneValue) => {
      const message = stringArg(messageValue, 'message', 500)
      const tone = toneValue === undefined ? 'info' : toneValue
      if (tone !== 'info' && tone !== 'danger') {
        throw new ValidationError('notice tone must be info or danger')
      }
      deps.showNotice(pluginId, message, tone)
      return null
    },
    'settings.get': async (pluginId, keyValue) => {
      const key = stringArg(keyValue, 'key', 120)
      if (deps.configuration?.has(pluginId, key)) return deps.configuration.get(pluginId)[key] ?? null
      const current = deps.data.get(pluginId)
      if (typeof current !== 'object' || current === null || Array.isArray(current)) {
        return null
      }
      return Object.hasOwn(current, key) ? (current as Record<string, unknown>)[key] ?? null : null
    },
    'settings.set': async (pluginId, keyValue, value) => {
      const key = stringArg(keyValue, 'key', 120)
      if (deps.configuration?.has(pluginId, key)) {
        deps.configuration.set(pluginId, key, value)
        return null
      }
      const stored = deps.data.get(pluginId)
      const current =
        typeof stored === 'object' && stored !== null && !Array.isArray(stored)
          ? (stored as Record<string, unknown>)
          : {}
      deps.data.set(pluginId, { ...current, [key]: value ?? null })
      return null
    },
    'panel.post': async (pluginId, panelIdValue, payload) => {
      const panelId = assertPanel(deps, pluginId, panelIdValue)
      deps.postPanel(pluginId, panelId, payload)
      return null
    },
    'panel.open': async (pluginId, panelIdValue) => {
      const panelId = assertPanel(deps, pluginId, panelIdValue)
      deps.openPanel(pluginId, panelId)
      return null
    },
    'panel.close': async (pluginId, panelIdValue) => {
      deps.closePanel?.(pluginId, assertPanel(deps, pluginId, panelIdValue))
      return null
    },
    'net.fetch': async (pluginId, url, options) =>
      pluginFetch(deps, pluginId, url, options),
    'editor.getSelection': async (pluginId) => {
      if (deps.editor === undefined) throw new ValidationError('Editor is unavailable')
      return deps.editor.request({ pluginId, action: 'getSelection' })
    },
    'editor.replaceSelection': async (pluginId, token, text) => {
      if (deps.editor === undefined) throw new ValidationError('Editor is unavailable')
      if (typeof text !== 'string' || text.length > 100_000) throw new ValidationError('Invalid replacement text')
      return deps.editor.request({ pluginId, action: 'replaceSelection', token: stringArg(token, 'token', 120), text })
    }
  }
}
