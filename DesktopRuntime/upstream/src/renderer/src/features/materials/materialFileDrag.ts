/**
 * 자료 파일 행의 네이티브 OS 드래그 공유 상태.
 *
 * 파일 행 드래그는 dragstart 를 취소하고 webContents.startDrag 로 승격되므로
 * (MaterialTree.startMaterialDragEvent) HTML5 dataTransfer 도 dragend 도 없다.
 * 그래도 같은 창의 DOM 에는 dragover/drop(Files) 이 그대로 발생하니, 어떤
 * 자료가 끌리는 중인지는 이 모듈 레벨 상태로 공유한다 — materialMoveDrag 의
 * 폴더 드래그 ref 와 같은 이유, 같은 패턴.
 *
 * 종료 신호: 취소된 dragstart 는 dragend 를 주지 않으므로(BrowserWebviewLayer
 * 의 safety net 과 동일한 사실) window 의 drop(버블)·mouseup·blur 에서 지운다.
 * drop 은 캡처가 아니라 버블 단계다 — 드롭존 핸들러가 상태를 먼저 읽어야 한다.
 */

import type { MaterialKind } from '../../../../shared/types/materials'

export interface MaterialFileDragState {
  courseId: string
  relPath: string
  kind: MaterialKind
}

let current: MaterialFileDragState | null = null
const listeners = new Set<() => void>()
let cleanupInstalled = false

function emit(): void {
  for (const listener of listeners) listener()
}

function clearOnWindowSignal(): void {
  clearMaterialFileDrag()
}

function clearAfterDropHandlers(): void {
  // 버블 단계의 window drop 이후에도 같은 이벤트 사이클의 다른 핸들러가
  // 상태를 읽을 수 있게 한 틱 미룬다.
  window.setTimeout(clearOnWindowSignal, 0)
}

function installCleanup(): void {
  if (cleanupInstalled) return
  cleanupInstalled = true
  window.addEventListener('drop', clearAfterDropHandlers)
  window.addEventListener('mouseup', clearOnWindowSignal)
  window.addEventListener('blur', clearOnWindowSignal)
}

function removeCleanup(): void {
  if (!cleanupInstalled) return
  cleanupInstalled = false
  window.removeEventListener('drop', clearAfterDropHandlers)
  window.removeEventListener('mouseup', clearOnWindowSignal)
  window.removeEventListener('blur', clearOnWindowSignal)
}

export function beginMaterialFileDrag(state: MaterialFileDragState): void {
  current = state
  installCleanup()
  emit()
}

export function clearMaterialFileDrag(): void {
  if (current === null) return
  current = null
  removeCleanup()
  emit()
}

export function getMaterialFileDrag(): MaterialFileDragState | null {
  return current
}

/** `useSyncExternalStore` 계약: 구독 해제 함수를 돌려준다. */
export function subscribeMaterialFileDrag(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}
