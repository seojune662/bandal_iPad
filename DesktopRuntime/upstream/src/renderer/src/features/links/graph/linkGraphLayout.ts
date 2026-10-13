/**
 * 의존성 없는 결정적 정적 레이아웃 — linkGraphSim 의 틱을 한 번에 수렴시키고
 * 화면 안으로 정규화(fit)한다. 오버레이의 라이브 애니메이션은 sim 을 직접
 * 돌리고, 이 함수는 테스트·스냅샷 등 "완성된 그림"이 필요한 곳용이다.
 */

import type { GraphEdge, GraphNode } from './linkGraphModel'
import { createSimulation, type GraphPoint } from './linkGraphSim'

export type { GraphPoint } from './linkGraphSim'
export { hashString } from './linkGraphSim'

interface LayoutOptions {
  width: number
  height: number
}

const TICKS = 200

export function layoutGraph(
  nodes: readonly GraphNode[],
  edges: readonly GraphEdge[],
  { width, height }: LayoutOptions
): Map<string, GraphPoint> {
  const positions = new Map<string, GraphPoint>()
  if (nodes.length === 0) return positions

  const simulation = createSimulation(nodes, edges, { width, height })
  for (let tick = 0; tick < TICKS; tick += 1) simulation.tick(1)
  for (const [id, point] of simulation.positions) {
    positions.set(id, { ...point })
  }

  // 결과를 화면 안으로 정규화(fit) — 패딩 40px.
  let minX = Number.POSITIVE_INFINITY
  let minY = Number.POSITIVE_INFINITY
  let maxX = Number.NEGATIVE_INFINITY
  let maxY = Number.NEGATIVE_INFINITY
  for (const point of positions.values()) {
    minX = Math.min(minX, point.x)
    minY = Math.min(minY, point.y)
    maxX = Math.max(maxX, point.x)
    maxY = Math.max(maxY, point.y)
  }
  const padding = 40
  const spanX = Math.max(maxX - minX, 1)
  const spanY = Math.max(maxY - minY, 1)
  const scale = Math.min(
    (width - padding * 2) / spanX,
    (height - padding * 2) / spanY,
    1
  )
  const centerX = width / 2
  const centerY = height / 2
  for (const point of positions.values()) {
    point.x = centerX + (point.x - (minX + spanX / 2)) * scale
    point.y = centerY + (point.y - (minY + spanY / 2)) * scale
  }

  return positions
}
