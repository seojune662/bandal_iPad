import type { TourCopyKey } from './tourScript'

export type TourAnchorKey =
  | 'course-sidebar'
  | 'materials-import'
  | 'tab-strip'
  | 'favorites-section'
  | 'assistant-panel'
  | 'document-assistant'
  | 'quiz-tools'
  | 'english-tool'

export type TourPlacement = 'top' | 'right' | 'bottom' | 'left'

export type TourBeforeAction =
  | 'show-materials'
  | 'open-reading'
  | 'show-launcher'
  | 'open-assistant'

export interface TourStep {
  id: string
  target: TourAnchorKey | null
  placement: TourPlacement
  titleKey: TourCopyKey
  bodyKey: TourCopyKey
  before: TourBeforeAction | null
}

export interface TourAnchorRect {
  top: number
  right: number
  bottom: number
  left: number
  width: number
  height: number
}
