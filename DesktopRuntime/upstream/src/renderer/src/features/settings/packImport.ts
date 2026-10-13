import type { WorkflowPack } from '../../../../shared/types/workflowPack'
import { sanitizeWorkflowPack } from '../../../../shared/workflowPacks/sanitize'

export interface PackImportResult {
  pack?: WorkflowPack
  errors: string[]
}

/** Parses one pasted workflow pack and applies the shared trust-boundary sanitizer. */
export function parsePackImportText(text: string): PackImportResult {
  if (text.trim().length === 0) return { errors: [] }

  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error)
    return { errors: [`Invalid JSON: ${detail}`] }
  }

  const { pack, warnings } = sanitizeWorkflowPack(raw)
  return pack === null ? { errors: warnings } : { pack, errors: warnings }
}
