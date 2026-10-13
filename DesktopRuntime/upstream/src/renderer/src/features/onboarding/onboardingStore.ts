import { ensureSettingsLoaded } from '../../stores/settingsSnapshot'
/**
 * [M6-A] Onboarding visibility + persistence glue.
 *
 * Owns: fetching the persisted OnboardingState at boot, showing the wizard
 * when `shouldShowOnboarding` says so, writing transitions back through
 * `settings:set`, and reacting to the `settings:changed` broadcast (that is
 * how 설정 > "온보딩 다시 보기" from the settings WINDOW reopens the wizard
 * in the main window). All decisions are made by onboardingModel.
 */

import { create } from 'zustand'
import {
  DEFAULT_ONBOARDING,
  type OnboardingState
} from '../../../../shared/types/settings'
import { invoke, onPush } from '../../lib/ipc'
import {
  closeOnboarding,
  completeStep,
  initialStep,
  ONBOARDING_STEP_COUNT,
  shouldShowOnboarding,
  type OnboardingStep
} from './onboardingModel'

interface OnboardingStore {
  visible: boolean
  step: OnboardingStep
  /** Last known persisted state (source of truth for transitions). */
  persisted: OnboardingState
  /** Boot: load settings, decide visibility, subscribe to changes. */
  init: () => Promise<void>
  setStep: (step: OnboardingStep) => void
  /** Mark `step` done and advance (or finish when it was the last). */
  completeAndAdvance: (step: OnboardingStep) => void
  /** Dismiss from anywhere — persists closedAt; never auto-reopens. */
  dismiss: () => void
}

let initialized = false

function persist(next: OnboardingState): void {
  void invoke('settings:set', { onboarding: next }).catch((error: unknown) => {
    console.error('[Bandal] 온보딩 상태를 저장하지 못했습니다.', error)
  })
}

export const useOnboardingStore = create<OnboardingStore>()((set, get) => ({
  visible: false,
  step: 0,
  persisted: DEFAULT_ONBOARDING,

  init: async () => {
    if (initialized) return
    initialized = true

    // The settings window can reset onboarding ("온보딩 다시 보기") — the
    // broadcast is how the wizard reappears here without polling.
    onPush('settings:changed', ({ settings }) => {
      const next = settings.onboarding
      set({ persisted: next })
      if (!get().visible && shouldShowOnboarding(next)) {
        set({ visible: true, step: initialStep(next) })
      }
    })

    try {
      const settings = await ensureSettingsLoaded()
      const state = settings.onboarding
      set({ persisted: state })
      if (shouldShowOnboarding(state)) {
        set({ visible: true, step: initialStep(state) })
      }
    } catch (error) {
      // No settings → treat as already onboarded rather than blocking boot.
      console.error('[Bandal] 온보딩 상태를 불러오지 못했습니다.', error)
    }
  },

  setStep: (step) => {
    set({ step })
  },

  completeAndAdvance: (step) => {
    const done = completeStep(get().persisted, step)
    if (step >= ONBOARDING_STEP_COUNT - 1) {
      const closed = closeOnboarding(done, new Date())
      set({ persisted: closed, visible: false })
      persist(closed)
      return
    }
    set({ persisted: done, step: (step + 1) as OnboardingStep })
    persist(done)
  },

  dismiss: () => {
    const closed = closeOnboarding(get().persisted, new Date())
    set({ persisted: closed, visible: false })
    persist(closed)
  }
}))
