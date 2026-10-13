import type { LearningBinding, LearningRun, StartLearningRunInput } from '../../../../shared/types/learning'
import { invoke } from '../../lib/ipc'

export const LEARNING_RUN_STARTED_EVENT = 'bandal:learning-run-started'
const freshRuns = new Map<string, LearningBinding>()

/** Carry a just-started run across the async opening of its destination tab. */
export function rememberStartedLearningRun(result: { binding: LearningBinding; runId: string }): void {
  freshRuns.set(result.runId, result.binding)
  while (freshRuns.size > 100) freshRuns.delete(freshRuns.keys().next().value!)
  window.dispatchEvent(new Event(LEARNING_RUN_STARTED_EVENT))
}

/** Consume only IDs present in this snapshot; future visits remain quiet. */
export function takeStartedLearningRuns(binding: LearningBinding, runs: readonly LearningRun[]): string[] {
  const ids: string[] = []
  for (const run of runs) {
    const pending = freshRuns.get(run.id)
    if (pending?.courseId !== binding.courseId || pending.rootRelPath !== binding.rootRelPath) continue
    ids.push(run.id)
    freshRuns.delete(run.id)
  }
  return ids
}

export async function startLearningRun(input: StartLearningRunInput) {
  const result = await invoke('learning:run', input)
  rememberStartedLearningRun(result)
  return result
}

export async function retryLearningRun(input: { binding: LearningBinding; runId: string }) {
  const result = await invoke('learning:runRetry', input)
  rememberStartedLearningRun(result)
  return result
}
