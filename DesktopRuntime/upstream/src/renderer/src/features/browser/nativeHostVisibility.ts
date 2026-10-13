import { invoke } from '../../lib/ipc'

const blockers = new Set<string>()
const listeners = new Set<() => void>()
export const isNativeHostBlocked = (): boolean => blockers.size > 0
export function onNativeHostBlocked(listener: () => void): () => void {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}
/** Independent owners cannot release each other's full-window occlusion. */
export function setNativeHostBlocked(owner: string, blocked: boolean): void {
  const wasBlocked = blockers.size > 0
  if (blocked) blockers.add(owner)
  else blockers.delete(owner)
  if (wasBlocked === (blockers.size > 0)) return
  void invoke('browser:setHostOccluded', { occluded: blockers.size > 0 }).catch(error => {
    console.error('[browser] 페이지 표시 상태를 변경하지 못했습니다.', error)
  })
  for (const listener of listeners) listener()
}
