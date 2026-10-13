import type { PutPersonalShapeInput } from '../../../shared/types/whiteboard'
import { ValidationError } from '../../db/errors'
import {
  assertDrawingData,
  assertDrawingKind,
  assertDrawingStyle
} from '../drawingValidation'

type BoardShapeInput = PutPersonalShapeInput['shape']

/** Validate the complete whiteboard shape accepted at the agent boundary. */
export function assertAgentBoardShape(value: unknown): BoardShapeInput {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError('shape must be an object')
  }
  const candidate = value as { kind?: unknown; data?: unknown; style?: unknown }
  const kind = assertDrawingKind(candidate.kind)
  return {
    kind,
    data: assertDrawingData(candidate.data, kind, { allowClip: true }),
    style: assertDrawingStyle(candidate.style)
  }
}
