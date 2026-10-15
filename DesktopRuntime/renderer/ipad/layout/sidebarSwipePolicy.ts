export type SidebarSwipePhase = 'pending' | 'dragging' | 'cancelled'
export type SidebarSwipe = {
  open: boolean
  startX: number
  startY: number
  lastX: number
  lastTime: number
  velocity: number
  velocityAt: number
  distance: number
  phase: SidebarSwipePhase
}

export const sidebarSwipeThreshold = 48
const recognitionDistance = 8

/** Only a dedicated handle starts a gesture; there is no long-press timer. */
export function beginSidebarSwipe(open: boolean, x: number, y: number, time: number): SidebarSwipe {
  return { open, startX: x, startY: y, lastX: x, lastTime: time, velocity: 0, velocityAt: time, distance: 0, phase: 'pending' }
}

export function moveSidebarSwipe(swipe: SidebarSwipe, x: number, y: number, time: number): SidebarSwipe {
  if (swipe.phase === 'cancelled') return swipe
  const direction = swipe.open ? -1 : 1
  const distance = (x - swipe.startX) * direction
  const vertical = Math.abs(y - swipe.startY)
  const horizontal = Math.abs(x - swipe.startX)
  const elapsed = time - swipe.lastTime
  const moved = x !== swipe.lastX && elapsed > 0
  let phase: SidebarSwipePhase = swipe.phase
  if (distance <= -recognitionDistance || (vertical >= recognitionDistance && vertical * 1.2 >= horizontal)) phase = 'cancelled'
  else if (distance >= recognitionDistance) phase = 'dragging'
  return { ...swipe, lastX: x, lastTime: time, distance: Math.max(0, distance), phase,
    velocity: moved ? (x - swipe.lastX) * direction / elapsed : swipe.velocity,
    velocityAt: moved ? time : swipe.velocityAt }
}

export function shouldCommitSidebarSwipe(swipe: SidebarSwipe, time: number): boolean {
  if (swipe.phase !== 'dragging') return false
  if (swipe.distance >= sidebarSwipeThreshold) return true
  // A short intentional flick is enough, but a slow or reversed drag is not.
  return swipe.distance >= 24 && swipe.velocity >= 0.45 && time - swipe.velocityAt >= 0 && time - swipe.velocityAt <= 90
}
