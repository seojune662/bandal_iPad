import {
  WORKFLOW_PACK_SCHEMA_VERSION,
  LEGACY_WORKFLOW_PACK_SCHEMA_VERSION,
  type WorkflowPack,
  type WorkflowPackExperience,
  type WorkflowPackFollowUp,
  type WorkflowPackScope
} from '../types/workflowPack'
import { WORKFLOW_PACK_ALLOWED_TOOL_NAMES } from './toolNames'

const MAX_NAME_LENGTH = 40
const MAX_RECIPE_BYTES = 8 * 1024
const WORKFLOW_PACK_SCOPES: readonly WorkflowPackScope[] = [
  'course',
  'material',
  'selection',
  'browser-tab'
]
const ALLOWED_TOOL_NAMES = new Set<string>([
  ...WORKFLOW_PACK_ALLOWED_TOOL_NAMES
])

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function warningValue(value: unknown): string {
  try {
    return JSON.stringify(value) ?? String(value)
  } catch {
    return String(value)
  }
}

function requiredString(
  value: unknown,
  field: string,
  warnings: string[]
): string | null {
  if (typeof value !== 'string' || value.trim().length === 0) {
    warnings.push(`${field} must be a non-empty string.`)
    return null
  }
  return value.trim()
}

function truncateCharacters(
  value: string,
  maxLength: number
): { value: string; truncated: boolean } {
  const characters = Array.from(value)
  if (characters.length <= maxLength) return { value, truncated: false }
  return { value: characters.slice(0, maxLength).join(''), truncated: true }
}

function truncateUtf8(
  value: string,
  maxBytes: number
): { value: string; truncated: boolean } {
  const encoder = new TextEncoder()
  if (encoder.encode(value).byteLength <= maxBytes) {
    return { value, truncated: false }
  }

  const kept: string[] = []
  let bytes = 0
  for (const character of value) {
    const characterBytes = encoder.encode(character).byteLength
    if (bytes + characterBytes > maxBytes) break
    kept.push(character)
    bytes += characterBytes
  }
  return { value: kept.join(''), truncated: true }
}

function sanitizeRecipe(
  value: unknown,
  field: string,
  warnings: string[]
): string | null {
  if (typeof value !== 'string' || value.trim().length === 0) {
    warnings.push(`${field} must be a non-empty string.`)
    return null
  }
  const truncated = truncateUtf8(value, MAX_RECIPE_BYTES)
  if (truncated.truncated) {
    warnings.push(`${field} exceeded ${MAX_RECIPE_BYTES} bytes and was truncated.`)
  }
  return truncated.value
}

function sanitizeScopes(
  value: unknown,
  warnings: string[]
): readonly WorkflowPackScope[] | null {
  if (!Array.isArray(value)) {
    warnings.push('worksOn must be an array.')
    return null
  }

  const scopes: WorkflowPackScope[] = []
  for (const item of value) {
    if (!WORKFLOW_PACK_SCOPES.includes(item as WorkflowPackScope)) {
      warnings.push(`worksOn dropped unknown scope ${warningValue(item)}.`)
      continue
    }
    const scope = item as WorkflowPackScope
    if (!scopes.includes(scope)) scopes.push(scope)
  }
  if (scopes.length === 0) {
    warnings.push('worksOn must contain at least one known scope.')
    return null
  }
  return scopes
}

function sanitizeAllowedTools(
  value: unknown,
  warnings: string[]
): readonly string[] | null {
  if (!Array.isArray(value)) {
    warnings.push('allowedTools must be an array.')
    return null
  }

  const tools: string[] = []
  for (const item of value) {
    if (typeof item !== 'string' || !ALLOWED_TOOL_NAMES.has(item)) {
      warnings.push(`allowedTools dropped unknown tool ${warningValue(item)}.`)
      continue
    }
    if (!tools.includes(item)) tools.push(item)
  }
  return tools
}

function sanitizeOutputDirectory(
  value: unknown,
  warnings: string[]
): string | null {
  const dir = requiredString(value, 'outputs.dir', warnings)
  if (dir === null) return null

  const isAbsolute = dir.startsWith('/') || /^[A-Za-z]:\//.test(dir)
  const segments = dir.split('/')
  const hasInvalidSegment = segments.some(
    (segment) => segment.length === 0 || segment === '..' || segment.startsWith('.')
  )
  if (isAbsolute || dir.includes('\\') || dir.includes('\0') || hasInvalidSegment) {
    warnings.push(
      'outputs.dir must be a relative path without backslashes, empty segments, or dot-prefixed segments.'
    )
    return null
  }
  return dir
}

function sanitizeFollowUp(
  value: unknown,
  warnings: string[]
): WorkflowPackFollowUp | null {
  if (!isRecord(value)) {
    warnings.push('followUp was dropped because it must be an object.')
    return null
  }
  const label = requiredString(value['label'], 'followUp.label', warnings)
  const recipe = sanitizeRecipe(value['recipe'], 'followUp.recipe', warnings)
  if (label === null || recipe === null) {
    warnings.push('followUp was dropped because it is invalid.')
    return null
  }
  return { label, recipe }
}

export function sanitizeWorkflowPack(raw: unknown): {
  pack: WorkflowPack | null
  warnings: string[]
} {
  const warnings: string[] = []
  if (!isRecord(raw)) {
    return { pack: null, warnings: ['workflow pack must be an object.'] }
  }
  const schemaVersion = raw['schemaVersion']
  if (schemaVersion !== WORKFLOW_PACK_SCHEMA_VERSION && schemaVersion !== LEGACY_WORKFLOW_PACK_SCHEMA_VERSION) {
    return {
      pack: null,
      warnings: [
        `schemaVersion must be 1 or ${WORKFLOW_PACK_SCHEMA_VERSION}; received ${warningValue(schemaVersion)}.`
      ]
    }
  }

  const experiences: readonly WorkflowPackExperience[] = ['article-vocabulary', 'quiz', 'flashcards']
  const experience = experiences.includes(raw['experience'] as WorkflowPackExperience)
    ? raw['experience'] as WorkflowPackExperience
    : null
  if (schemaVersion === 2 && experience === null) {
    return { pack: null, warnings: ['experience must be "article-vocabulary", "quiz", or "flashcards" for schemaVersion 2.'] }
  }

  const id = requiredString(raw['id'], 'id', warnings)
  const rawName = requiredString(raw['name'], 'name', warnings)
  const description = requiredString(raw['description'], 'description', warnings)
  const author = requiredString(raw['author'], 'author', warnings)
  const version = requiredString(raw['version'], 'version', warnings)
  const locale =
    raw['locale'] === 'ko-KR' || raw['locale'] === 'en-US'
      ? raw['locale']
      : null
  if (locale === null) warnings.push('locale must be "ko-KR" or "en-US".')

  const worksOn = sanitizeScopes(raw['worksOn'], warnings)
  const recipe = sanitizeRecipe(raw['recipe'], 'recipe', warnings)
  const allowedTools = sanitizeAllowedTools(raw['allowedTools'], warnings)
  const usesWeb = typeof raw['usesWeb'] === 'boolean' ? raw['usesWeb'] : null
  if (usesWeb === null) warnings.push('usesWeb must be a boolean.')

  const outputs = isRecord(raw['outputs']) ? raw['outputs'] : null
  if (outputs === null) warnings.push('outputs must be an object.')
  const dir = sanitizeOutputDirectory(outputs?.['dir'], warnings)
  const primary = requiredString(outputs?.['primary'], 'outputs.primary', warnings)

  if (
    id === null ||
    rawName === null ||
    description === null ||
    author === null ||
    version === null ||
    locale === null ||
    worksOn === null ||
    recipe === null ||
    allowedTools === null ||
    usesWeb === null ||
    dir === null ||
    primary === null
  ) {
    return { pack: null, warnings }
  }

  const name = truncateCharacters(rawName, MAX_NAME_LENGTH)
  if (name.truncated) {
    warnings.push(`name exceeded ${MAX_NAME_LENGTH} characters and was truncated.`)
  }

  const pack: WorkflowPack = {
    ...(schemaVersion === 2 ? { schemaVersion: 2 as const, experience: experience! } : { schemaVersion: 1 as const }),
    id,
    name: name.value,
    description,
    author,
    version,
    locale,
    worksOn,
    recipe,
    allowedTools,
    usesWeb,
    outputs: { dir, primary }
  }
  if (raw['followUp'] !== undefined) {
    const followUp = sanitizeFollowUp(raw['followUp'], warnings)
    if (followUp !== null) pack.followUp = followUp
  }
  return { pack, warnings }
}
