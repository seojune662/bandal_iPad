import { utilityProcess } from 'electron'
import type { EngineRequest, EngineResponse } from './engineProtocol'
type RequestBody = EngineRequest extends infer R
  ? R extends EngineRequest
    ? Omit<R, 'seq'>
    : never
  : never

export function createEngineClient(entry: string) {
  const child = utilityProcess.fork(entry, [], { serviceName: 'Bandal Speech', stdio: 'pipe' })
  let sequence = 0
  let dead = false
  let pending: {
    resolve(value: Exclude<EngineResponse, { error: string }>): void
    reject(error: Error): void
    timer: NodeJS.Timeout
    seq: number
  } | null = null
  const fail = (message: string): void => {
    dead = true
    if (pending) {
      clearTimeout(pending.timer)
      pending.reject(new Error(message))
      pending = null
    }
  }
  // Drain native logging; do not retain audio/transcript diagnostics in logs.
  child.stderr?.on('data', () => undefined)
  child.stdout?.on('data', () => undefined)
  child.on('exit', () => fail('음성 엔진이 종료되었습니다. 원음은 계속 저장됩니다.'))
  child.on('message', (response: EngineResponse) => {
    if (!pending || response.seq !== pending.seq) return
    const request = pending
    pending = null
    clearTimeout(request.timer)
    if ('error' in response) request.reject(new Error(response.error))
    else request.resolve(response)
  })
  return {
    request(body: RequestBody): Promise<Exclude<EngineResponse, { error: string }>> {
      if (dead) return Promise.reject(new Error('음성 엔진이 종료되었습니다.'))
      if (pending) return Promise.reject(new Error('음성 엔진 요청이 이미 진행 중입니다.'))
      return new Promise((resolve, reject) => {
        const seq = ++sequence
        const timer = setTimeout(() => {
          fail('음성 인식 응답이 지연되었습니다. 저장한 음성으로 다시 시도해 주세요.')
          child.kill()
        }, 120_000)
        pending = { resolve, reject, timer, seq }
        child.postMessage({ ...body, seq })
      })
    },
    dispose() {
      fail('음성 엔진이 닫혔습니다.')
      child.kill()
    }
  }
}
