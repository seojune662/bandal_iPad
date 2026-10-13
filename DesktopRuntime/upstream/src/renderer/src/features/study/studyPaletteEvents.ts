import type { LauncherContext } from '../launcher/launcherContext'

export const STUDY_PALETTE_EVENT = 'bandal:study-palette'

export interface StudyPaletteRequest {
  context: LauncherContext
  returnFocus: HTMLElement | null
}

/** The originating menu captures the source before its focus and DOM disappear. */
export function requestStudyPalette(request: StudyPaletteRequest): void {
  window.dispatchEvent(new CustomEvent(STUDY_PALETTE_EVENT, { detail: request }))
}
