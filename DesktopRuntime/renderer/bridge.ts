type Listener = (payload: unknown) => void
type NativeHandler = { postMessage(message: { channel: string; request: unknown }): Promise<unknown> }
type NativeWindow = Window & {
  webkit?: { messageHandlers?: { bandal?: NativeHandler } }
  __bandalReceive?: (channel: string, payload: unknown) => void
  __bandalFilePaths?: WeakMap<File, string>
}

/** WK replies contain JSON; native byte buffers have an explicit wire marker. */
export function reviveNativeBytes(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(reviveNativeBytes)
  if (value && typeof value === 'object') {
    const object = value as Record<string, unknown>
    if (Object.keys(object).length === 1 && typeof object.__bandalBytes === 'string') {
      const raw = atob(object.__bandalBytes)
      return Uint8Array.from(raw, character => character.charCodeAt(0))
    }
    return Object.fromEntries(Object.entries(object).map(([key, entry]) => [key, reviveNativeBytes(entry)]))
  }
  return value
}

/** Transport only: every product response comes from the native handler. */
export function installNativeBridge(target: NativeWindow = window): void {
  const handler = target.webkit?.messageHandlers?.bandal
  if (!handler || typeof handler.postMessage !== 'function') {
    throw new Error('iPad 네이티브 연결을 찾을 수 없습니다. 이 화면은 반달 앱 안에서 실행해야 합니다.')
  }
  const listeners = new Map<string, Set<Listener>>()
  const rendererSessionId = target.crypto?.randomUUID?.() ?? `renderer-${Date.now()}-${target.performance?.now?.() ?? 0}`
  const invoke = async (channel: string, request: unknown): Promise<unknown> => {
    if (!channel || typeof channel !== 'string') throw new Error('잘못된 IPC 채널입니다.')
    const input = ['runtime:rendererReady', 'materials:watch', 'materials:unwatch'].includes(channel)
      ? { ...(request && typeof request === 'object' ? request : {}), rendererSessionId } : request
    let value: unknown
    try { value = await handler.postMessage({ channel, request: input }) }
    catch (reason) {
      throw new BandalOperationError({ code: 'NATIVE_TRANSPORT', channel, category: 'transport', retryable: false,
        message: reason instanceof Error ? reason.message : String(reason) })
    }
    const failure = decodeOperationFailure(value, channel)
    if (failure) throw failure
    return reviveNativeBytes(value)
  }
  const on = (channel: string, callback: Listener): (() => void) => {
    let group = listeners.get(channel)
    if (!group) { group = new Set(); listeners.set(channel, group) }
    const subscriptions = group
    subscriptions.add(callback)
    return () => { subscriptions.delete(callback); if (!subscriptions.size) listeners.delete(channel) }
  }
  target.__bandalReceive = (channel, payload) => {
    for (const listener of [...(listeners.get(channel) ?? [])]) {
      try { listener(reviveNativeBytes(payload)) } catch (error) { reportOperationError(error, { operation: '화면 갱신' }, target) }
    }
  }
  target.__bandalFilePaths = new WeakMap()
  Object.defineProperty(target, 'bandal', {
    configurable: false, writable: false,
    value: Object.freeze({
      invoke, on, platform: 'ipad',
      pathForFile: (file: File): string => target.__bandalFilePaths?.get(file) ?? '',
      startMaterialDrag: (_courseId: string, _relPath: string): void => {
        // The iPad material adapter supplies an internal HTML drag. The legacy
        // Electron fire-and-forget method cannot start an iPad drag session.
        reportOperationError(new BandalOperationError({ code: 'UNSUPPORTED_ACTION', channel: 'materials:startDrag', category: 'unsupported', retryable: false,
          message: '다른 앱으로 보낼 때는 자료 메뉴의 공유를 사용해 주세요.' }), {}, target)
      },
      openSettings: async (): Promise<void> => { await invoke('window:openSettings', {}) }
    })
  })
}
import { BandalOperationError, decodeOperationFailure, reportOperationError } from './ipad/stability/operations'
