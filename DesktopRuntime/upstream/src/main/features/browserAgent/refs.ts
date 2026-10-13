/**
 * Element references handed to the agent.
 *
 * A ref names one element in one frame of one page state: `f0:e12@3`, where
 * the trailing number is the tab's snapshot GENERATION. Any navigation bumps
 * the generation, which makes every earlier ref invalid.
 *
 * That generation is the whole point. Without it, an agent that snapshots a
 * page, the page navigates, and the agent then clicks `e12` would click
 * whatever happens to be the twelfth element of a completely different
 * document. A stale ref must be an error, never a different button.
 */

export interface ParsedRef {
  frameIndex: number
  elementIndex: number
  generation: number
}

const REF_PATTERN = /^f(\d+):e(\d+)@(\d+)$/

export function formatRef(
  frameIndex: number,
  elementIndex: number,
  generation: number
): string {
  return `f${frameIndex}:e${elementIndex}@${generation}`
}

export function parseRef(ref: unknown): ParsedRef | null {
  if (typeof ref !== 'string') return null
  const match = REF_PATTERN.exec(ref.trim())
  if (match === null) return null
  const [, frame, element, generation] = match
  return {
    frameIndex: Number(frame),
    elementIndex: Number(element),
    generation: Number(generation)
  }
}

export type RefResolution =
  | { ok: true; frameIndex: number; elementIndex: number }
  | { ok: false; reason: 'malformed' | 'stale'; message: string }

/**
 * Validates a ref against the tab's current generation.
 *
 * Deliberately refuses a ref from the FUTURE as well: that can only mean the
 * agent invented one, and inventing coordinates is exactly the failure mode
 * refs exist to prevent.
 */
export function resolveRef(ref: unknown, generation: number): RefResolution {
  const parsed = parseRef(ref)
  if (parsed === null) {
    return {
      ok: false,
      reason: 'malformed',
      message: '요소 참조 형식이 올바르지 않아요. 페이지를 다시 살펴봐 주세요.'
    }
  }
  if (parsed.generation !== generation) {
    return {
      ok: false,
      reason: 'stale',
      message:
        '페이지가 그 사이에 바뀌었어요. 다시 살펴본 뒤에 진행해 주세요.'
    }
  }
  return {
    ok: true,
    frameIndex: parsed.frameIndex,
    elementIndex: parsed.elementIndex
  }
}

/** Per-tab snapshot generation. Bumped on every navigation. */
export class GenerationTracker {
  private readonly generations = new Map<string, number>()

  current(tabId: string): number {
    return this.generations.get(tabId) ?? 0
  }

  /** Called when a tab navigates; every outstanding ref for it dies. */
  invalidate(tabId: string): number {
    const next = this.current(tabId) + 1
    this.generations.set(tabId, next)
    return next
  }

  forget(tabId: string): void {
    this.generations.delete(tabId)
  }
}
