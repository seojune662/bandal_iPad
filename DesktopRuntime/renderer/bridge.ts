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
  const invoke = async (channel: string, request: unknown): Promise<unknown> => {
    if (!channel || typeof channel !== 'string') throw new Error('잘못된 IPC 채널입니다.')
    // WKScriptMessageHandlerWithReply rejects this promise on a native error.
    // Do not turn failure into an empty list or a synthetic successful result.
    return reviveNativeBytes(await handler.postMessage({ channel, request }))
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
      try { listener(reviveNativeBytes(payload)) } catch (error) { target.dispatchEvent(new ErrorEvent('error', { error, message: error instanceof Error ? error.message : String(error) })) }
    }
  }
  target.__bandalFilePaths = new WeakMap()
  Object.defineProperty(target, 'bandal', {
    configurable: false, writable: false,
    value: Object.freeze({
      invoke, on, platform: 'ipad',
      pathForFile: (file: File): string => target.__bandalFilePaths?.get(file) ?? '',
      startMaterialDrag: (courseId: string, relPath: string): void => {
        void invoke('materials:startDrag', { courseId, relPath }).catch(error => {
          target.dispatchEvent(new ErrorEvent('error', { error, message: error instanceof Error ? error.message : String(error) }))
        })
      },
      openSettings: async (): Promise<void> => { await invoke('window:openSettings', {}) }
    })
  })
}
