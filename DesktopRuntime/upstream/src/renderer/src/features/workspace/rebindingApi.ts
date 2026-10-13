interface Disposable { dispose(): void }
type Listener = (...args: unknown[]) => unknown

/** Async callbacks and subscriptions keep one API while its presentation moves. */
export function createRebindingApi<T extends object>(initial: T): {
  api: T
  rebind(next: T): void
  dispose(): void
} {
  let current = initial
  const callbacks = new Map<PropertyKey, Set<Listener>>()
  const subscriptions = new Map<PropertyKey, Disposable>()
  const methods = new Map<PropertyKey, (...args: unknown[]) => unknown>()
  const attach = (key: PropertyKey): void => {
    subscriptions.get(key)?.dispose()
    subscriptions.delete(key)
    const event = Reflect.get(current, key, current)
    if (typeof event !== 'function' || !callbacks.get(key)?.size) return
    subscriptions.set(key, (event as (listener: Listener) => Disposable)((...args: unknown[]) => {
      for (const listener of [...(callbacks.get(key) ?? [])]) listener(...args)
    }))
  }
  const api = new Proxy({} as T, {
    get: (_target, key) => {
      const value = Reflect.get(current, key, current)
      if (typeof value !== 'function') return value
      if (!methods.has(key)) {
        if (typeof key === 'string' && /^on(?:Did|Will)/.test(key)) {
          methods.set(key, (...args) => {
            const listener = args[0] as Listener
            const listeners = callbacks.get(key) ?? new Set<Listener>()
            listeners.add(listener)
            callbacks.set(key, listeners)
            if (!subscriptions.has(key)) attach(key)
            return { dispose: () => {
              listeners.delete(listener)
              if (!listeners.size) {
                subscriptions.get(key)?.dispose()
                subscriptions.delete(key)
              }
            } }
          })
        } else methods.set(key, (...args) => Reflect.apply(Reflect.get(current, key, current) as Listener, current, args))
      }
      return methods.get(key)
    }
  })
  return {
    api,
    rebind(next) {
      current = next
      for (const key of callbacks.keys()) attach(key)
      const states: Record<string, unknown> = {
        onDidActiveChange: { isActive: Reflect.get(next, 'isActive') },
        onDidVisibilityChange: { isVisible: Reflect.get(next, 'isVisible') },
        onDidTitleChange: { title: Reflect.get(next, 'title') },
        onDidGroupChange: {},
        onDidDimensionsChange: { width: Reflect.get(next, 'width'), height: Reflect.get(next, 'height') }
      }
      for (const [key, value] of Object.entries(states)) {
        if (value === undefined) continue
        for (const listener of [...(callbacks.get(key) ?? [])]) listener(value)
      }
    },
    dispose() {
      for (const disposable of subscriptions.values()) disposable.dispose()
      subscriptions.clear()
      callbacks.clear()
    }
  }
}
