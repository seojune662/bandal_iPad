import { useEffect, useRef, useState } from 'react'
import { reportOperationError } from './operations'

interface WatchStatus { courseId: string; error: string | null; pending: boolean }
interface Subscription { retry(): Promise<void>; dispose(): void }

/** Retries reuse the same idempotent lease. Retiring a view also retires its
 * callbacks, including an initial scan that finishes after unmount. */
export function createMaterialWatchSubscription(courseId: string, changed: (courseId: string) => void | Promise<void>, status: (value: WatchStatus) => void, target: Window = window): Subscription {
  const subscriptionId = target.crypto.randomUUID()
  const invoke = target.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>
  let active = true, flight: Promise<void> | undefined, error: string | null = null
  const publish = (pending: boolean) => { if (active) status({ courseId, error, pending }) }
  const unsubscribe = (target.bandal.on as (channel: string, callback: (payload: { courseId: string }) => void) => () => void)('materials:changed', payload => {
    if (active && payload.courseId === courseId) {
      // Mutations also emit this event, even while polling is broken. Only a
      // successful watch acknowledgement can clear the previous watch error.
      if (error !== null) void retry()
      void Promise.resolve().then(() => { if (active) return changed(courseId) }).catch(reason => {
        if (active) reportOperationError(reason, { operation: '자료 새로고침' }, target)
      })
    }
  })
  const retry = (): Promise<void> => {
    if (!active) return Promise.resolve()
    if (flight) return flight
    publish(true)
    let request: Promise<unknown>
    try { request = Promise.resolve(invoke('materials:watch', { courseId, subscriptionId })) }
    catch (reason) { request = Promise.reject(reason) }
    flight = request.then(() => { error = null }, reason => {
      error = reason instanceof Error ? reason.message : String(reason ?? '자료 폴더를 읽지 못했습니다.')
    }).finally(() => { flight = undefined; publish(false) })
    return flight
  }
  void retry()
  return { retry, dispose() {
    if (!active) return
    active = false
    unsubscribe()
    void invoke('materials:unwatch', { courseId, subscriptionId }).catch(() => undefined)
  } }
}

export function MaterialWatchNotice({ courseId, onChange }: { courseId: string | null; onChange: (courseId: string) => void | Promise<void> }): JSX.Element | null {
  const [status, setStatus] = useState<WatchStatus | null>(null)
  const change = useRef(onChange), subscription = useRef<Subscription | null>(null)
  change.current = onChange
  useEffect(() => {
    setStatus(null)
    if (courseId === null) return
    const current = createMaterialWatchSubscription(courseId, id => change.current(id), setStatus)
    subscription.current = current
    return () => { subscription.current = null; current.dispose() }
  }, [courseId])
  if (!status || status.courseId !== courseId || status.error === null) return null
  return <div className="rail-error" role="alert" aria-label="자료 변경 감시 오류" data-bandal-native-overlay="">
    <span>자료 변경 감시에서 오류가 발생했습니다. 자동 갱신 상태를 다시 확인해 주세요. {status.error}</span>
    <button type="button" style={{ minHeight: 44, minWidth: 44 }} disabled={status.pending} onClick={() => { void subscription.current?.retry() }}>
      {status.pending ? '다시 연결 중…' : '자료 감시 다시 시도'}
    </button>
  </div>
}
