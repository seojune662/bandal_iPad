import type { TabDescriptor } from '../../../shared/tabs'
import { isTabDescriptor } from '../../../shared/tabs'
import { ValidationError } from '../../db/errors'

function parseAndValidate(
  json: string,
  invalidDescriptorMessage: string
): TabDescriptor {
  let parsed: unknown
  try {
    parsed = JSON.parse(json)
  } catch {
    throw new ValidationError('descriptor must be valid JSON')
  }

  if (!isTabDescriptor(parsed)) {
    throw new ValidationError(invalidDescriptorMessage)
  }
  return parsed
}

/** Parses persisted descriptor JSON and validates the decoded value. */
export function parseDescriptor(json: string): TabDescriptor {
  return parseAndValidate(
    json,
    'descriptor JSON must contain a valid TabDescriptor'
  )
}

/**
 * Validates both sides of the JSON boundary. The second validation matters
 * for unusual objects with custom toJSON methods.
 */
export function serializeDescriptor(value: unknown): {
  json: string
  descriptor: TabDescriptor
} {
  if (!isTabDescriptor(value)) {
    throw new ValidationError('descriptor must be a valid TabDescriptor')
  }

  try {
    const json = JSON.stringify(value)
    if (json === undefined) {
      throw new ValidationError('descriptor must be JSON-serializable')
    }
    return {
      json,
      descriptor: parseAndValidate(
        json,
        'descriptor must remain valid after JSON serialization'
      )
    }
  } catch (error) {
    if (error instanceof ValidationError) throw error
    throw new ValidationError('descriptor must be JSON-serializable')
  }
}
