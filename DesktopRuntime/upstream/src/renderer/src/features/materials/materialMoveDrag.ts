/**
 * 자료 트리 안에서의 이동(파일/폴더 → 다른 폴더) 드래그의 순수 로직.
 *
 * OS 파일 드롭(importDrop.ts)이나 즐겨찾기 드래그(favoriteDrop.ts)와 MIME 을
 * 분리해, 트리 내부 이동만 이 페이로드를 받는다. dragover 에서는 getData 를
 * 읽을 수 없으므로 진행 중 드래그를 모듈 레벨 ref 로 공유한다.
 */

import type { MaterialKind } from '../../../../shared/types/materials'

export const MATERIAL_MOVE_MIME = 'application/x-bandal-material-move'

export interface MaterialMoveDragPayload {
  version: 1
  courseId: string
  relPath: string
  kind: 'dir' | MaterialKind
}

const MATERIAL_KINDS = new Set(['dir', 'pdf', 'note', 'image', 'video', 'other'])

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0
}

export function serializeMaterialMoveDrag(
  payload: Omit<MaterialMoveDragPayload, 'version'>
): string {
  return JSON.stringify({
    version: 1,
    ...payload
  } satisfies MaterialMoveDragPayload)
}

/** 적대적/깨진 데이터에도 절대 throw 하지 않는다. */
export function parseMaterialMoveDrag(
  raw: string
): MaterialMoveDragPayload | null {
  try {
    const value: unknown = JSON.parse(raw)
    if (!isRecord(value)) return null
    if (value['version'] !== 1) return null
    if (!nonEmptyString(value['courseId'])) return null
    if (!nonEmptyString(value['relPath'])) return null
    const kind = value['kind']
    if (typeof kind !== 'string' || !MATERIAL_KINDS.has(kind)) return null
    return {
      version: 1,
      courseId: value['courseId'].trim(),
      relPath: value['relPath'],
      kind: kind as MaterialMoveDragPayload['kind']
    }
  } catch {
    return null
  }
}

export function canAcceptMaterialMove(types: readonly string[]): boolean {
  return types.includes(MATERIAL_MOVE_MIME)
}

// dragover 는 getData 를 읽을 수 없으므로(브라우저 보안 제약) 진행 중인
// 드래그를 모듈 레벨 ref 로 공유한다. dragstart 에서 set, dragend 에서 clear.
let currentMaterialDrag: MaterialMoveDragPayload | null = null

export function setCurrentMaterialDrag(payload: MaterialMoveDragPayload): void {
  currentMaterialDrag = payload
}

export function clearCurrentMaterialDrag(): void {
  currentMaterialDrag = null
}

export function getCurrentMaterialDrag(): MaterialMoveDragPayload | null {
  return currentMaterialDrag
}
