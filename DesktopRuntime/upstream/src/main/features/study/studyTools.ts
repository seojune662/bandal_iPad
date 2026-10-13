import type {
  RunStudyToolInput,
  StudyToolDefinition
} from '../../../shared/types/study'
import { LEGACY_STUDY_PACKS } from '../../../shared/workflowPacks/builtins'
import {
  buildWorkflowPackPrompt,
  type StudyPlanningContext
} from '../workflowPacks/packRunner'

export type { StudyPlanningContext }

export const STUDY_TOOLS: readonly StudyToolDefinition[] =
  LEGACY_STUDY_PACKS.map((pack) => ({
    id: pack.id,
    label: pack.outputs.primary,
    description: pack.description,
    worksOnCourse: pack.worksOn.includes('course')
  }))

/**
 * Legacy prompt adapter kept for direct callers and regression tests. Actual
 * study runs use packRunner, which supplies the collision-safe destination.
 */
export function buildStudyToolPrompt(
  input: RunStudyToolInput,
  ctx: {
    courseName: string
    targetLabel: string
  } & StudyPlanningContext,
  options: { destinationRelPath?: string } = {}
): string {
  const pack = LEGACY_STUDY_PACKS.find((candidate) => candidate.id === input.tool)
  if (pack === undefined) {
    // RunStudyToolInput is a closed union, but keep this runtime boundary
    // honest for IPC values that arrive as plain JavaScript.
    throw new TypeError(`unknown study tool: ${String(input.tool)}`)
  }
  return buildWorkflowPackPrompt({
    pack,
    source: 'builtin',
    courseName: ctx.courseName,
    targetLabel: ctx.targetLabel,
    ...(input.relPath === null ? {} : { targetRelPath: input.relPath }),
    ...(input.selection === undefined
      ? {}
      : { selectionText: input.selection }),
    ...(options.destinationRelPath === undefined
      ? {}
      : { destinationRelPath: options.destinationRelPath }),
    planning: ctx
  })
}
