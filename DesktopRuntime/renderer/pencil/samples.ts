export interface InkPointerSample {
  pointerId: number
  clientX: number
  clientY: number
  pressure: number
  pointerType?: string
}

/** Predicted points are intentionally excluded: they must never become saved ink. */
export function pencilSamples(event: PointerEvent): InkPointerSample[] {
  let coalesced: PointerEvent[] = []
  try { coalesced = event.getCoalescedEvents?.() ?? [] } catch { /* iPadOS 18.0 fallback */ }
  const samples = [...coalesced, event]
  const result: InkPointerSample[] = []
  for (const sample of samples) {
    if (sample.pointerId !== event.pointerId || !Number.isFinite(sample.clientX) || !Number.isFinite(sample.clientY)) continue
    const point = { pointerId: sample.pointerId, pointerType: event.pointerType, clientX: sample.clientX, clientY: sample.clientY,
      pressure: Number.isFinite(sample.pressure) ? Math.min(1, Math.max(0, sample.pressure)) : 0.5 }
    const last = result[result.length - 1]
    if (!last || last.clientX !== point.clientX || last.clientY !== point.clientY || last.pressure !== point.pressure) result.push(point)
  }
  return result
}

export function pencilPressure<T extends { p: number }>(point: T | null, sample: InkPointerSample): T | null {
  return point && sample.pointerType === 'pen' ? { ...point, p: sample.pressure } : point
}

export function acceptsInkPointer(event: Pick<PointerEvent, 'pointerType' | 'pointerId'>, activeID?: number): boolean {
  return event.pointerType !== 'touch' && (activeID === undefined || event.pointerId === activeID)
}
