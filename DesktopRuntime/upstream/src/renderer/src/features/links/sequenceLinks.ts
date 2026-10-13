/**
 * "이전/다음" 순서 연결의 순수 로직.
 *
 * material_links 의 label='next' 한 종류로 양방향을 표현한다:
 * source → target 이 "source 의 다음이 target". 그래서 어떤 탭의
 * - 다음 자료 = outgoing 중 label='next' 인 레코드의 target
 * - 이전 자료 = incoming 중 label='next' 인 레코드의 source
 * 같은 자료에 next 가 여러 개면 최신(createdAt) 하나만 내비게이션에 쓴다 —
 * 체인 관리/삭제는 기존 연결 패널의 몫.
 */

import type { TabDescriptor } from '../../../../shared/tabs'
import type { MaterialLinkRecord } from '../../../../shared/types/link'

export const SEQUENCE_LABEL = 'next'

export type SequenceEdge = 'prev' | 'next'

export interface SequenceNeighbors {
  /** 최신 incoming 'next' 레코드 — 이전 자료는 `prev.source`. */
  prev: MaterialLinkRecord | null
  /** 최신 outgoing 'next' 레코드 — 다음 자료는 `next.target`. */
  next: MaterialLinkRecord | null
}

function latestSequenceRecord(
  records: readonly MaterialLinkRecord[]
): MaterialLinkRecord | null {
  let latest: MaterialLinkRecord | null = null
  for (const record of records) {
    if (record.kind !== 'sequence' && record.label !== SEQUENCE_LABEL) continue
    if (latest === null || record.createdAt > latest.createdAt) latest = record
  }
  return latest
}

export function pickSequence(
  outgoing: readonly MaterialLinkRecord[],
  incoming: readonly MaterialLinkRecord[]
): SequenceNeighbors {
  return {
    prev: latestSequenceRecord(incoming),
    next: latestSequenceRecord(outgoing)
  }
}

export interface SequenceLinkPlan {
  source: TabDescriptor
  target: TabDescriptor
}

/**
 * 드롭 가장자리 → 링크 방향. 오른쪽(next)에 놓으면 "탭의 다음 = 자료",
 * 왼쪽(prev)에 놓으면 "자료의 다음 = 탭"(= 탭의 이전이 자료).
 */
export function edgeDropPlan(
  edge: SequenceEdge,
  tab: TabDescriptor,
  material: TabDescriptor
): SequenceLinkPlan {
  return edge === 'next'
    ? { source: tab, target: material }
    : { source: material, target: tab }
}
