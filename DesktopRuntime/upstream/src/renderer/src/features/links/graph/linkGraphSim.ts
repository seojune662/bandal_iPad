/**
 * 그래프 물리 시뮬레이션 — 오버레이의 라이브 애니메이션과 정적 레이아웃
 * (linkGraphLayout.layoutGraph)이 같은 틱 로직을 공유한다.
 *
 * 결정적이다: Math.random/Date 없이 FNV-1a 해시 지터만 쓴다. 시간·프레임은
 * 호출자가 tick() 횟수로 공급한다. 드래그 중인 노드는 pin 으로 고정되고,
 * 놓은 뒤에도 고정이 유지된다(사용자가 배치한 자리 존중 — 옵시디언 관례).
 */

import type { GraphEdge, GraphNode } from './linkGraphModel'

export interface GraphPoint {
  x: number
  y: number
}

export interface GraphSimulationOptions {
  width: number
  height: number
}

const DAMPING = 0.85
const REPULSION = 6000
const SPRING_LENGTH = 110
const SPRING_STRENGTH = 0.02
const CENTER_PULL = 0.005
const MAX_STEP = 24
const MIN_DISTANCE = 0.01
const BOUNDS_PADDING = 48

/** FNV-1a — 결정적 지터 시드. */
export function hashString(value: string): number {
  let hash = 0x811c9dc5
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

function jitter(id: string, salt: string): number {
  // [-0.5, 0.5) 결정적 난수 대용.
  return hashString(`${id}:${salt}`) / 0xffffffff - 0.5
}

export interface GraphSimulation {
  readonly positions: ReadonlyMap<string, GraphPoint>
  /** 한 스텝 전진. alpha(0..1)가 변위를 스케일 — 정착 애니메이션의 온도. */
  tick(alpha: number): void
  /** 노드를 좌표에 고정한다(이후 틱에서 움직이지 않음). */
  pin(id: string, x: number, y: number): void
  isPinned(id: string): boolean
}

export function createSimulation(
  nodes: readonly GraphNode[],
  edges: readonly GraphEdge[],
  { width, height }: GraphSimulationOptions
): GraphSimulation {
  const centerX = width / 2
  const centerY = height / 2
  const radius = Math.min(width, height) * 0.35

  const ordered = [...nodes].sort((a, b) => a.id.localeCompare(b.id))
  const positions = new Map<string, GraphPoint>()
  ordered.forEach((node, index) => {
    const angle = (index / Math.max(1, ordered.length)) * Math.PI * 2
    positions.set(node.id, {
      x: centerX + Math.cos(angle) * radius + jitter(node.id, 'x') * 40,
      y: centerY + Math.sin(angle) * radius + jitter(node.id, 'y') * 40
    })
  })
  const velocities = new Map<string, GraphPoint>(
    ordered.map((node) => [node.id, { x: 0, y: 0 }])
  )
  const pinned = new Set<string>()
  let tickCount = 0

  return {
    positions,

    pin(id, x, y) {
      const position = positions.get(id)
      if (position === undefined) return
      position.x = x
      position.y = y
      const velocity = velocities.get(id)
      if (velocity !== undefined) {
        velocity.x = 0
        velocity.y = 0
      }
      pinned.add(id)
    },

    isPinned(id) {
      return pinned.has(id)
    },

    tick(alpha) {
      if (!(alpha > 0)) return
      tickCount += 1
      const forces = new Map<string, GraphPoint>(
        ordered.map((node) => [node.id, { x: 0, y: 0 }])
      )

      // 전 쌍 반발
      for (let a = 0; a < ordered.length; a += 1) {
        for (let b = a + 1; b < ordered.length; b += 1) {
          const nodeA = ordered[a]!
          const nodeB = ordered[b]!
          const pa = positions.get(nodeA.id)!
          const pb = positions.get(nodeB.id)!
          let dx = pa.x - pb.x
          let dy = pa.y - pb.y
          let distance = Math.hypot(dx, dy)
          if (distance < MIN_DISTANCE) {
            // 겹친 노드는 해시 기반 미소 벡터로 갈라놓는다(NaN 방지).
            dx = jitter(nodeA.id, `${tickCount}`) + 0.01
            dy = jitter(nodeB.id, `${tickCount}`) + 0.01
            distance = Math.hypot(dx, dy)
          }
          const force = REPULSION / (distance * distance)
          const fx = (dx / distance) * force
          const fy = (dy / distance) * force
          const forceA = forces.get(nodeA.id)!
          const forceB = forces.get(nodeB.id)!
          forceA.x += fx
          forceA.y += fy
          forceB.x -= fx
          forceB.y -= fy
        }
      }

      // 엣지 스프링
      for (const edge of edges) {
        const pa = positions.get(edge.sourceId)
        const pb = positions.get(edge.targetId)
        if (pa === undefined || pb === undefined) continue
        const dx = pb.x - pa.x
        const dy = pb.y - pa.y
        const distance = Math.max(Math.hypot(dx, dy), MIN_DISTANCE)
        const stretch = (distance - SPRING_LENGTH) * SPRING_STRENGTH
        const fx = (dx / distance) * stretch
        const fy = (dy / distance) * stretch
        const forceA = forces.get(edge.sourceId)
        const forceB = forces.get(edge.targetId)
        if (forceA !== undefined) {
          forceA.x += fx
          forceA.y += fy
        }
        if (forceB !== undefined) {
          forceB.x -= fx
          forceB.y -= fy
        }
      }

      // 약한 중심 인력 + 적분 + 경계 클램프
      for (const node of ordered) {
        if (pinned.has(node.id)) continue
        const position = positions.get(node.id)!
        const velocity = velocities.get(node.id)!
        const force = forces.get(node.id)!
        force.x += (centerX - position.x) * CENTER_PULL
        force.y += (centerY - position.y) * CENTER_PULL

        velocity.x = (velocity.x + force.x) * DAMPING
        velocity.y = (velocity.y + force.y) * DAMPING
        const step = Math.hypot(velocity.x, velocity.y)
        const scale = (step > MAX_STEP ? MAX_STEP / step : 1) * alpha
        position.x += velocity.x * scale
        position.y += velocity.y * scale
        position.x = Math.max(
          BOUNDS_PADDING,
          Math.min(width - BOUNDS_PADDING, position.x)
        )
        position.y = Math.max(
          BOUNDS_PADDING,
          Math.min(height - BOUNDS_PADDING, position.y)
        )
      }
    }
  }
}
