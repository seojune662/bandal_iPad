import type {
  RunStudyToolInput,
  RunStudyToolResult,
  StudyToolDefinition
} from '../../../shared/types/study'
import type { AgentConfirmScope } from '../../../shared/types/agentTools'
import type { WorkflowPackSummary } from '../../../shared/types/workflowPack'
import { LEGACY_STUDY_PACKS, LEGACY_BUILTIN_PACKS, getLegacyPack } from '../../../shared/workflowPacks/builtins'
import type { PackStore } from '../workflowPacks/packStore'
import {
  createPackRunner,
  type PackRunnerConfirmRequest
} from '../workflowPacks/packRunner'
import {
  createPackRunGuard,
  type PackRunGuard
} from '../workflowPacks/runGuard'
import { STUDY_TOOLS, type StudyPlanningContext } from './studyTools'

export interface StudyRunnerDeps {
  getCourse: (courseId: string) => { name: string; folder: string }
  /** Sends a prompt through the course's existing agent session. */
  ask: (courseId: string, prompt: string) => Promise<void>
  recordActivity?: (courseId: string, summary: string, relPath: string) => void
  /** Optional board + insights snapshot supplied by the main orchestrator. */
  getPlanningContext?: (courseId: string) => StudyPlanningContext
  /** Integration seams used when study:run shares the general pack runtime. */
  packStore?: Pick<PackStore, 'resolve' | 'list' | 'approve'>
  packRunGuard?: Pick<PackRunGuard, 'arm' | 'clear'>
  confirmPack?: (
    request: PackRunnerConfirmRequest
  ) => Promise<AgentConfirmScope | false>
  now?: () => Date
}

function builtinSummary(): WorkflowPackSummary[] {
  return LEGACY_STUDY_PACKS.map((pack) => ({
    pack,
    source: 'builtin',
    enabled: true,
    approvedAt: null
  }))
}

function builtinStore(): Pick<PackStore, 'resolve' | 'list' | 'approve'> {
  return {
    resolve(id) {
      return LEGACY_STUDY_PACKS.find((pack) => pack.id === id) ?? null
    },
    list: builtinSummary,
    approve() {
      throw new TypeError('Built-in study packs do not require approval')
    }
  }
}

/** Legacy study API implemented as a narrow adapter over packRunner. */
export function createStudyRunner(deps: StudyRunnerDeps): {
  run(input: RunStudyToolInput): Promise<RunStudyToolResult>
  tools(): StudyToolDefinition[]
} {
  const packRunner = createPackRunner({
    store: deps.packStore === undefined ? builtinStore() : {
      ...deps.packStore,
      resolve: (id) => {
        const pack = deps.packStore!.resolve(id)
        return pack === null ? null : getLegacyPack(pack)
      },
      list: () => deps.packStore!.list().flatMap(summary =>
        summary.pack.schemaVersion === 1 || LEGACY_BUILTIN_PACKS.some(pack => pack.id === summary.pack.id)
          ? [{ ...summary, pack: getLegacyPack(summary.pack) }]
          : [])
    },
    runGuard: deps.packRunGuard ?? createPackRunGuard(),
    getCourse: deps.getCourse,
    ask: deps.ask,
    confirm: deps.confirmPack ?? (async () => 'once'),
    ...(deps.recordActivity === undefined
      ? {}
      : { recordActivity: deps.recordActivity }),
    ...(deps.getPlanningContext === undefined
      ? {}
      : { getPlanningContext: deps.getPlanningContext }),
    ...(deps.now === undefined ? {} : { now: deps.now })
  })

  return {
    run(input) {
      return packRunner.run({
        courseId: input.courseId,
        packId: input.tool,
        ...(input.relPath === null ? {} : { targetRelPath: input.relPath }),
        ...(input.selection === undefined
          ? {}
          : { selectionText: input.selection })
      })
    },
    tools() {
      return STUDY_TOOLS.map((tool) => ({ ...tool }))
    }
  }
}
