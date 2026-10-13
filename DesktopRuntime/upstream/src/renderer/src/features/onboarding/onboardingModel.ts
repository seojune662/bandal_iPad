/**
 * [M6-A] Pure onboarding-flow logic (no React, no IPC — unit-testable).
 *
 * The wizard is versioned (docs/orca-analysis.md §8): OnboardingState lives
 * in settings.json and this module owns every transition on it. The overlay
 * component only renders steps and calls these functions.
 *
 * One welcome screen; existing completion records remain acknowledged.
 */

import {
  ONBOARDING_FLOW_VERSION,
  type OnboardingState
} from '../../../../shared/types/settings'

export const ONBOARDING_STEP_COUNT = 1
export type OnboardingStep = 0

/**
 * Should the wizard show for this persisted state?
 *  - never dismissed (`closedAt === null`) → show
 *  - any dismissed state → stay closed, including older flow versions
 *  - anything else → stay closed; the wizard never auto-reopens
 */
export function shouldShowOnboarding(
  state: OnboardingState | null | undefined
): boolean {
  if (state === null || state === undefined) return true
  if (state.closedAt === null) return true
  return false
}

/** Step the wizard opens on: resume after the last completed step. */
export function initialStep(
  state: OnboardingState | null | undefined
): OnboardingStep {
  if (state === null || state === undefined) return 0
  // A state carried over from an older flow version starts from the top.
  if (state.flowVersion < ONBOARDING_FLOW_VERSION) return 0
  const step = Math.min(
    Math.max(state.lastCompletedStep, 0),
    ONBOARDING_STEP_COUNT - 1
  )
  return step as OnboardingStep
}

/** Mark a step finished. Progress is monotonic — going back never regresses. */
export function completeStep(
  state: OnboardingState,
  step: OnboardingStep
): OnboardingState {
  return {
    flowVersion: ONBOARDING_FLOW_VERSION,
    closedAt: state.closedAt,
    lastCompletedStep: Math.max(state.lastCompletedStep, step + 1)
  }
}

/**
 * Close the wizard (finish or dismiss — both stamp `closedAt`, both stamp
 * the current flow version so a stale version can't re-trigger the reopen).
 */
export function closeOnboarding(
  state: OnboardingState,
  now: Date
): OnboardingState {
  return {
    flowVersion: ONBOARDING_FLOW_VERSION,
    closedAt: now.toISOString(),
    lastCompletedStep: state.lastCompletedStep
  }
}

/** 설정 > General > "온보딩 다시 보기": a fresh, deliberate reopen. */
export function reopenedOnboarding(): OnboardingState {
  return {
    flowVersion: ONBOARDING_FLOW_VERSION,
    closedAt: null,
    lastCompletedStep: 0
  }
}
