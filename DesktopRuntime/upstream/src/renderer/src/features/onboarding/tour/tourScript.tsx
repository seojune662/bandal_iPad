import { onboardingCopy } from '../onboardingCopy'
import type { TourStep } from './tourTypes'

export const TOUR_STEPS = [
  { id: 'materials', target: 'materials-import', placement: 'left', before: 'show-materials', titleKey: 'materialsTitle', bodyKey: 'materialsBody' },
  { id: 'reading', target: 'tab-strip', placement: 'bottom', before: 'open-reading', titleKey: 'readingTitle', bodyKey: 'readingBody' },
  { id: 'assistant', target: 'document-assistant', placement: 'left', before: 'open-assistant', titleKey: 'assistantTitle', bodyKey: 'assistantBody' },
  { id: 'review', target: 'quiz-tools', placement: 'right', before: 'show-launcher', titleKey: 'reviewTitle', bodyKey: 'reviewBody' },
  { id: 'english', target: 'english-tool', placement: 'right', before: 'show-launcher', titleKey: 'englishTitle', bodyKey: 'englishBody' }
] as const satisfies readonly TourStep[]
export const TOUR_STEP_COUNT = TOUR_STEPS.length
export type TourCopyKey = keyof ReturnType<typeof onboardingCopy>
