export interface InkPointerSample {
  pointerId: number
  clientX: number
  clientY: number
  pressure: number
  pointerType?: string
  timestamp?: number
  tiltX?: number
  tiltY?: number
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
      pressure: Number.isFinite(sample.pressure) ? Math.min(1, Math.max(0, sample.pressure)) : 0.5,
      timestamp: sample.timeStamp, tiltX: sample.tiltX, tiltY: sample.tiltY }
    const last = result[result.length - 1]
    if (!last || last.clientX !== point.clientX || last.clientY !== point.clientY || last.pressure !== point.pressure) result.push(point)
  }
  return result
}

/** Browser predictions are a short, replaceable visual tail, never measured
 * input. Do not extrapolate when WebKit does not expose predictions. */
export function pencilPredictions(event: PointerEvent): InkPointerSample[] {
  if (event.pointerType !== 'pen') return []
  let predicted: PointerEvent[] = []
  try { predicted = event.getPredictedEvents?.() ?? [] } catch { return [] }
  const result: InkPointerSample[] = []
  let timestamp = event.timeStamp
  for (const sample of predicted) {
    if (result.length === 8) break
    if (sample.pointerId !== event.pointerId || !Number.isFinite(sample.timeStamp) ||
        sample.timeStamp <= timestamp || sample.timeStamp > event.timeStamp + 24 ||
        !Number.isFinite(sample.clientX) || !Number.isFinite(sample.clientY)) continue
    result.push({ pointerId: event.pointerId, pointerType: event.pointerType,
      clientX: sample.clientX, clientY: sample.clientY,
      pressure: Number.isFinite(sample.pressure) ? Math.min(1, Math.max(0, sample.pressure)) : 0.5,
      timestamp: sample.timeStamp, tiltX: sample.tiltX, tiltY: sample.tiltY })
    timestamp = sample.timeStamp
  }
  return result
}

export function pencilPressure<T extends { p: number }>(point: T | null, sample: InkPointerSample): T | null {
  if (!point || sample.pointerType !== 'pen') return point
  return { ...point, p: Number.isFinite(sample.pressure) ? Math.min(1, Math.max(0, sample.pressure)) : 0.5,
    ...(Number.isFinite(sample.tiltX) ? { tiltX: Math.min(90, Math.max(-90, sample.tiltX!)) } : {}),
    ...(Number.isFinite(sample.tiltY) ? { tiltY: Math.min(90, Math.max(-90, sample.tiltY!)) } : {}) }
}

export function acceptsInkPointer(event: Pick<PointerEvent, 'pointerType' | 'pointerId'>, activeID?: number): boolean {
  return event.pointerType !== 'touch' && (activeID === undefined || event.pointerId === activeID)
}
