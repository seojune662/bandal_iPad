import { create } from 'zustand'
import type {
  RunStudyToolInput,
  RunStudyToolResult
} from '../../../../shared/types/study'
import type {
  WorkflowPackFollowUp,
  WorkflowPackOutputs
} from '../../../../shared/types/workflowPack'
import type { NativeStudyExperience } from '../../../../shared/types/workflowPack'
import type { LearningRunResult } from '../../../../shared/ipc/learningContract'
import { invoke } from '../../lib/ipc'
import { useWorkflowPacksStore, type WorkflowPacksState } from '../../stores/workflowPacksStore'
import type { WorkflowPackSummary, WorkflowPackScope } from '../../../../shared/types/workflowPack'

/** Renderer bridge for the pack-derived study tool response. */
export interface PackStudyToolDefinition {
  id: string
  label: string
  description: string
  worksOnCourse: boolean
  source?: 'builtin' | 'user'
  enabled?: boolean
  usesWeb?: boolean
  outputs?: WorkflowPackOutputs
  outputDir?: string
  outputsDir?: string
  followUp?: WorkflowPackFollowUp
  followUpLabel?: string
  experience?: NativeStudyExperience
  worksOn?: readonly WorkflowPackScope[]
  schemaVersion?: 1 | 2
}

export interface RunPackStudyToolInput {
  courseId: string
  tool: string
  relPath: string | null
  selection?: string
  followUpOf?: string
}

type RunningStudyTools = Partial<Record<string, number>>

interface StudyToolsState {
  tools: PackStudyToolDefinition[]
  hasLoaded: boolean
  isLoading: boolean
  error: string | null
  running: RunningStudyTools
  runError: string | null
  loadTools: () => Promise<void>
  run: (input: RunPackStudyToolInput) => Promise<RunStudyToolResult>
  generate: (input: RunPackStudyToolInput) => Promise<LearningRunResult>
}

function errorMessage(error: unknown, fallback: string): string {
  return error instanceof Error && error.message.trim().length > 0
    ? error.message
    : fallback
}

export const useStudyToolsStore = create<StudyToolsState>()((set) => ({
  tools: [],
  hasLoaded: false,
  isLoading: false,
  error: null,
  running: {},
  runError: null,

  loadTools: () => useWorkflowPacksStore.getState().load(),

  run: async (input) => {
    set((state) => ({
      running: {
        ...state.running,
        [input.tool]: (state.running[input.tool] ?? 0) + 1
      },
      runError: null
    }))

    try {
      const request: RunStudyToolInput = {
        courseId: input.courseId,
        tool: input.tool as RunStudyToolInput['tool'],
        relPath: input.relPath,
        ...(input.selection === undefined ? {} : { selection: input.selection })
      }
      if (input.followUpOf !== undefined) {
        Object.assign(request, { followUpOf: input.followUpOf })
      }
      return await invoke('study:run', request)
    } catch (error) {
      set({
        runError: errorMessage(error, 'AI 학습 자료를 만들지 못했어요.')
      })
      throw error
    } finally {
      set((state) => {
        const running = { ...state.running }
        const remaining = (running[input.tool] ?? 1) - 1
        if (remaining === 0) delete running[input.tool]
        else running[input.tool] = remaining
        return { running }
      })
    }
  },

  generate: async (input) => {
    set(state => ({ running: { ...state.running, [input.tool]: (state.running[input.tool] ?? 0) + 1 }, runError: null }))
    try {
      return await invoke('study:generate', { courseId: input.courseId, packId: input.tool, source: input.relPath === null ? { kind: 'course' } : { kind: 'material', relPath: input.relPath, ...(input.selection ? { selection: input.selection } : {}) } })
    } catch (error) {
      set({ runError: errorMessage(error, '학습 자료 생성을 시작하지 못했어요.') }); throw error
    } finally {
      set(state => { const running = { ...state.running }; const remaining = (running[input.tool] ?? 1) - 1; if (remaining > 0) running[input.tool] = remaining; else delete running[input.tool]; return { running } })
    }
  }
}))

export function studyToolFromPack({ pack, source, enabled }: WorkflowPackSummary): PackStudyToolDefinition {
  return { id: pack.id, label: pack.name, description: pack.description,
    worksOnCourse: pack.worksOn.includes('course'), worksOn: pack.worksOn, schemaVersion: pack.schemaVersion,
    source, enabled, usesWeb: pack.usesWeb, outputs: pack.outputs,
    ...(pack.schemaVersion === 2 ? { experience: pack.experience } : {}),
    ...(pack.followUp ? { followUp: pack.followUp } : {}) }
}

function mirrorPacks(state: WorkflowPacksState): void {
  useStudyToolsStore.setState({ tools: state.packs.map(studyToolFromPack), hasLoaded: state.hasLoaded,
    isLoading: state.loading, error: state.error })
}
useWorkflowPacksStore.subscribe(mirrorPacks)
mirrorPacks(useWorkflowPacksStore.getState())
