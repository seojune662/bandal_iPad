import type { LearningRun } from '../../../../shared/types/learning'

export function isLearningRunActive(run: LearningRun): boolean {
  return ['queued', 'running', 'validating'].includes(run.status)
}

/** Historical failures remain accessible without taking over each space visit. */
export function visibleLearningRuns(runs: LearningRun[], historicalIds: ReadonlySet<string>): LearningRun[] {
  const active = runs.filter(isLearningRunActive)
  const latest = [...runs].reverse().find(run => !isLearningRunActive(run) && run.status !== 'awaiting-confirmation')
  return latest && ['failed', 'interrupted'].includes(latest.status) && !latest.dismissedAt && !historicalIds.has(latest.id)
    ? [...active, latest] : active
}
