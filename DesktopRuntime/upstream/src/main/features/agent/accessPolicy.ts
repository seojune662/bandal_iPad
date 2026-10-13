import { isAbsolute, relative, resolve, dirname } from 'node:path'
import { realpathSync, existsSync } from 'node:fs'
function canonical(path: string): string {
  if (existsSync(path)) return realpathSync(path)
  const parent = dirname(path)
  if (parent === path) return path
  return resolve(canonical(parent), relative(parent, path))
}
import type { AiAccessPolicy } from '../../../shared/types/aiAccess'
/** Full access handles routine provider tools without interrupting the answer. */
export function cliPermissionAllowed(policy: AiAccessPolicy, tool: string, input: unknown, folder: string): boolean {
  if (policy.mode === 'ask') return false
  // Service authorization can require actual account consent or form input;
  // it is not a request to execute an already-authorized tool.
  if (tool === 'serviceAuthorization') return false
  if (['WebSearch', 'WebFetch', 'webSearch', 'web_fetch', 'google_web_search'].includes(tool)) return policy.mode === 'full' && policy.scope.browser
  if (!policy.scope.course) return false
  if (policy.mode === 'full') return true
  if (!['Read', 'Glob', 'Grep', 'read_file', 'read_many_files', 'glob', 'search_file_content', 'Write', 'Edit', 'write_file', 'replace', 'fileChange'].includes(tool)) return false
  const data = input && typeof input === 'object' ? input as Record<string, unknown> : {}
  const paths = [data.file_path, data.path, data.absolute_path, ...(Array.isArray(data.paths) ? data.paths : [])].filter((p): p is string => typeof p === 'string')
  if (!paths.length) return false
  const inside = paths.every(path => { const r = relative(canonical(folder), canonical(isAbsolute(path) ? path : resolve(folder, path))); return !r.startsWith('..') && !isAbsolute(r) })
  if (!inside) return false
  return ['Read', 'Glob', 'Grep', 'read_file', 'read_many_files', 'glob', 'search_file_content'].includes(tool)
}

/** App actions follow the same scope choices as native provider tools. */
export function appPermissionAllowed(policy: AiAccessPolicy, tool: string, sameCourse: boolean): boolean {
  if (policy.mode !== 'full' || tool.startsWith('cli:')) return false
  if (/^(browser_|lms_)/.test(tool)) return policy.scope.browser
  if (/^(desktop_|clipboard)/.test(tool)) return policy.scope.screen
  return policy.scope.course && sameCourse
}

/** Correlate repeated denied actions even when a provider assigns fresh transport IDs. */
export function permissionFingerprint(input: unknown): string {
  const normalize = (value: unknown): unknown => {
    if (Array.isArray(value)) return value.map(normalize)
    if (!value || typeof value !== 'object') return value
    return Object.fromEntries(Object.entries(value).filter(([key]) => !['requestId', 'threadId', 'turnId', 'itemId', 'toolCallId', 'reason'].includes(key)).sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => [key, normalize(value)]))
  }
  return JSON.stringify(normalize(input)) ?? ''
}
