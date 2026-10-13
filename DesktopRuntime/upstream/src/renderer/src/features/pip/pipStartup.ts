import type { PipState } from '../../../../shared/types/pip'
import type { PipSeekCommand } from './pipPlayerModel'

interface InitialPipSyncOptions {
  getState(): Promise<PipState>
  applySeek(command: PipSeekCommand): void
  shouldApply?(): boolean
}

/**
 * Recovers the initial seek that main can send before React effects subscribe.
 * A caller-supplied guard prevents a late snapshot from replacing a newer push.
 */
export async function syncInitialPipState({
  getState,
  applySeek,
  shouldApply = () => true
}: InitialPipSyncOptions): Promise<void> {
  const state = await getState()
  if (!state.open || !shouldApply()) return

  applySeek({
    positionSec: state.positionSec,
    playbackRate: state.playbackRate,
    play: !state.paused
  })
}

export interface PipPlayable {
  muted: boolean
  play(): Promise<void>
}

export type PipPlayResult = 'playing' | 'muted-playing' | 'blocked'

/** Tries audible playback first, then Chromium's muted-autoplay path. */
export async function playWithMutedFallback(
  video: PipPlayable,
  onMuted: () => void
): Promise<PipPlayResult> {
  try {
    await video.play()
    return 'playing'
  } catch {
    if (video.muted) return 'blocked'
  }

  video.muted = true
  onMuted()
  try {
    await video.play()
    return 'muted-playing'
  } catch {
    return 'blocked'
  }
}
