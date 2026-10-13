/**
 * Runtime evaluated only inside an OS-sandboxed Chromium renderer.
 *
 * This module is a browser-only factory: all plugin-visible objects, functions,
 * errors and promises belong to the renderer realm. The main process transports
 * source text and JSON messages; it never evaluates plugin code. Do not call
 * this factory with untrusted source in Node (including a Node vm context).
 */

import type { PluginManifest } from '../../shared/types/plugin'
import {
  PLUGIN_RPC_LIMITS,
  PLUGIN_RPC_PROTOCOL_VERSION,
  type HostToMain,
  type MainToHost,
  type PluginApiMethod,
  type PluginEventName
} from '../../shared/types/pluginRpc'

export interface PluginHostTransport {
  post(message: HostToMain): void
  onMessage(callback: (message: MainToHost) => void): void
}

export interface PluginHostRuntime {
  dispose(): void
}

export interface PluginHostRuntimeDeps {
  readFile?: (path: string) => string
  now?: () => number
  /** Test-only browser-realm evaluator. Production executes inside Chromium. */
  execute?: (source: string, globals: Record<string, unknown>) => void
}

type PluginHandler = (...args: unknown[]) => unknown

interface PendingApiCall {
  pluginId: string
  resolve(value: unknown): void
  reject(error: Error): void
  timer: NodeJS.Timeout
}

interface PluginInstance {
  id: string
  manifest: PluginManifest
  module: { exports: unknown }
  globals: Record<string, unknown>
  commands: Map<string, PluginHandler>
  events: Map<PluginEventName, Set<PluginHandler>>
  panels: Map<string, Set<PluginHandler>>
  timers: Map<number, NodeJS.Timeout>
  intervals: Map<number, NodeJS.Timeout>
  deactivate: PluginHandler | null
  disposed: boolean
}

export function createHostRuntime(
  transport: PluginHostTransport,
  deps: PluginHostRuntimeDeps = {},
  limits = PLUGIN_RPC_LIMITS,
  protocolVersion: typeof PLUGIN_RPC_PROTOCOL_VERSION = PLUGIN_RPC_PROTOCOL_VERSION
): PluginHostRuntime {
  if (deps.execute === undefined && typeof process !== 'undefined') {
    throw new Error('Plugin source requires the sandboxed browser worker')
  }
  function errorMessage(error: unknown): string {
    if (error instanceof Error && error.message.trim() !== '') return error.message
    return String(error)
  }

  function jsonBytes(value: unknown): number {
    try {
      const json = JSON.stringify(value)
      return json === undefined ? 0 : new TextEncoder().encode(json).byteLength
    } catch {
      return Number.POSITIVE_INFINITY
    }
  }

  function timeout<T>(promise: Promise<T>, milliseconds: number, label: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${label} timed out`)), milliseconds)
      void promise.then(
        (value) => {
          clearTimeout(timer)
          resolve(value)
        },
        (error: unknown) => {
          clearTimeout(timer)
          reject(error instanceof Error ? error : new Error(String(error)))
        }
      )
    })
  }

  function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null
  }

  function exportedHook(exportsValue: unknown, name: 'activate' | 'deactivate'): PluginHandler | null {
    if (!isObject(exportsValue)) return null
    const hook = exportsValue[name]
    return typeof hook === 'function' ? (hook as PluginHandler) : null
  }

  function freezeCapability<T extends object>(value: T): T {
    for (const child of Object.values(value)) {
      if (typeof child === 'object' && child !== null && !Object.isFrozen(child)) {
        Object.freeze(child)
      }
    }
    return Object.freeze(value)
  }


  const readFile = deps.readFile ?? (() => { throw new Error('Plugin source was not supplied by the main process') })
  const now = deps.now ?? Date.now
  const instances = new Map<string, PluginInstance>()
  const pendingApi = new Map<number, PendingApiCall>()
  let nextApiId = 1
  let nextTimerId = 1
  let disposed = false

  const post = (message: HostToMain): void => {
    if (!disposed) transport.post(message)
  }

  function log(
    pluginId: string,
    level: 'info' | 'warn' | 'error',
    values: readonly unknown[]
  ): void {
    const message = values
      .map((value) => {
        if (typeof value === 'string') return value
        try {
          return JSON.stringify(value)
        } catch {
          return String(value)
        }
      })
      .join(' ')
    post({ t: 'log', pluginId, level, message })
  }

  function clearInstanceResources(instance: PluginInstance): void {
    instance.disposed = true
    for (const handle of instance.timers.values()) clearTimeout(handle)
    for (const handle of instance.intervals.values()) clearInterval(handle)
    instance.timers.clear()
    instance.intervals.clear()
    for (const [id, pending] of pendingApi) {
      if (pending.pluginId !== instance.id) continue
      clearTimeout(pending.timer)
      pending.reject(new Error(`plugin "${instance.id}" was unloaded`))
      pendingApi.delete(id)
    }
  }

  function invokeInContext(
    instance: PluginInstance,
    handler: PluginHandler,
    args: readonly unknown[]
  ): Promise<unknown> {
    if (instance.disposed) return Promise.reject(new Error('plugin is unloaded'))
    try {
      return Promise.resolve(handler(...args))
    } catch (error) {
      return Promise.reject(error)
    }
  }

  function apiCall(
    instance: PluginInstance,
    method: PluginApiMethod,
    args: unknown[]
  ): Promise<unknown> {
    if (instance.disposed) return Promise.reject(new Error('plugin is unloaded'))
    if (jsonBytes(args) > limits.messageBytes) {
      return Promise.reject(new Error('plugin API payload is too large'))
    }
    try {
      structuredClone(args)
    } catch {
      return Promise.reject(new Error('plugin API payload is not cloneable'))
    }
    const id = nextApiId++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pendingApi.delete(id)
        reject(new Error(`${method} timed out`))
      }, limits.apiTimeoutMs)
      pendingApi.set(id, { pluginId: instance.id, resolve, reject, timer })
      post({ t: 'api', id, pluginId: instance.id, method, args })
    })
  }

  function assertLocalPermission(instance: PluginInstance, permission: string): void {
    if (!instance.manifest.permissions.includes(permission as never)) {
      throw new Error(`plugin did not request the ${permission} permission`)
    }
  }

  function assertPanel(instance: PluginInstance, panelId: unknown): string {
    if (typeof panelId !== 'string') throw new Error('panel id must be a string')
    if (!instance.manifest.contributes.panels.some((panel) => panel.id === panelId)) {
      throw new Error(`panel "${panelId}" is not declared in the manifest`)
    }
    return panelId
  }

  function createCapability(instance: PluginInstance): object {
    const call = (method: PluginApiMethod, ...args: unknown[]): Promise<unknown> =>
      apiCall(instance, method, args)

    const commands = {
      register(commandId: unknown, handler: unknown): void {
        assertLocalPermission(instance, 'commands')
        if (typeof commandId !== 'string' || typeof handler !== 'function') {
          throw new Error('commands.register expects an id and a function')
        }
        if (
          !instance.manifest.contributes.commands.some(
            (command) => command.id === commandId
          )
        ) {
          throw new Error(`command "${commandId}" is not declared in the manifest`)
        }
        if (instance.commands.has(commandId)) {
          throw new Error(`command "${commandId}" is already registered`)
        }
        instance.commands.set(commandId, handler as PluginHandler)
      }
    }
    const events = {
      on(name: unknown, handler: unknown): () => void {
        assertLocalPermission(instance, 'events')
        if (
          (name !== 'note:saved' && name !== 'course:changed' && name !== 'settings:changed') ||
          typeof handler !== 'function'
        ) {
          throw new Error('events.on received an unsupported event or handler')
        }
        const handlers = instance.events.get(name) ?? new Set<PluginHandler>()
        handlers.add(handler as PluginHandler)
        instance.events.set(name, handlers)
        return () => handlers.delete(handler as PluginHandler)
      }
    }
    const panel = {
      post(panelId: unknown, payload: unknown): Promise<unknown> {
        return call('panel.post', assertPanel(instance, panelId), payload)
      },
      open(panelId: unknown): Promise<unknown> {
        return call('panel.open', assertPanel(instance, panelId))
      },
      close(panelId: unknown): Promise<unknown> {
        return call('panel.close', assertPanel(instance, panelId))
      },
      onMessage(panelId: unknown, handler: unknown): () => void {
        assertLocalPermission(instance, 'panel')
        const id = assertPanel(instance, panelId)
        if (typeof handler !== 'function') {
          throw new Error('panel.onMessage expects a function')
        }
        const handlers = instance.panels.get(id) ?? new Set<PluginHandler>()
        handlers.add(handler as PluginHandler)
        instance.panels.set(id, handlers)
        return () => handlers.delete(handler as PluginHandler)
      }
    }
    const bandal = {
      commands: Object.freeze(commands),
      courses: Object.freeze({
        list: () => call('courses.list'),
        current: () => call('courses.current')
      }),
      notes: Object.freeze({
        list: (courseId: unknown) => call('notes.list', courseId),
        read: (noteId: unknown) => call('notes.read', noteId),
        write: (noteId: unknown, input: unknown) =>
          call('notes.write', noteId, input),
        create: (courseId: unknown, input: unknown) =>
          call('notes.create', courseId, input)
      }),
      materials: Object.freeze({
        list: (courseId: unknown) => call('materials.list', courseId),
        readText: (courseId: unknown, relPath: unknown) =>
          call('materials.readText', courseId, relPath)
      }),
      notices: Object.freeze({
        show: (message: unknown, tone?: unknown) =>
          tone === undefined
            ? call('notices.show', message)
            : call('notices.show', message, tone)
      }),
      settings: Object.freeze({
        get: (key: unknown) => call('settings.get', key),
        set: (key: unknown, value: unknown) => call('settings.set', key, value)
      }),
      editor: Object.freeze({
        getSelection: () => call('editor.getSelection'),
        replaceSelection: (token: unknown, text: unknown) => call('editor.replaceSelection', token, text)
      }),
      panel: Object.freeze(panel),
      events: Object.freeze(events),
      fetch: (url: unknown, options?: unknown) =>
        options === undefined
          ? call('net.fetch', url)
          : call('net.fetch', url, options)
    }
    return freezeCapability(bandal)
  }

  function createInstance(message: Extract<MainToHost, { t: 'load' }>): PluginInstance {
    const module = { exports: {} as unknown }
    const instance: PluginInstance = {
      id: message.pluginId,
      manifest: message.manifest,
      module,
      globals: {},
      commands: new Map(),
      events: new Map(),
      panels: new Map(),
      timers: new Map(),
      intervals: new Map(),
      deactivate: null,
      disposed: false
    }

    const sandboxConsole = Object.freeze({
      log: (...values: unknown[]) => log(instance.id, 'info', values),
      info: (...values: unknown[]) => log(instance.id, 'info', values),
      warn: (...values: unknown[]) => log(instance.id, 'warn', values),
      error: (...values: unknown[]) => log(instance.id, 'error', values)
    })
    const sandbox = {
      module,
      exports: module.exports,
      console: sandboxConsole,
      URL,
      URLSearchParams,
      TextEncoder,
      TextDecoder,
      structuredClone,
      setTimeout: (handler: unknown, delay?: unknown, ...args: unknown[]) => {
        if (typeof handler !== 'function') throw new Error('setTimeout expects a function')
        const id = nextTimerId++
        const milliseconds =
          typeof delay === 'number' && Number.isFinite(delay)
            ? Math.max(0, Math.min(delay, 2_147_483_647))
            : 0
        const handle = setTimeout(() => {
          instance.timers.delete(id)
          void invokeInContext(instance, handler as PluginHandler, args).catch(
            (error: unknown) => log(instance.id, 'error', [errorMessage(error)])
          )
        }, milliseconds)
        instance.timers.set(id, handle)
        return id
      },
      clearTimeout: (id: unknown) => {
        if (typeof id !== 'number') return
        const handle = instance.timers.get(id)
        if (handle !== undefined) clearTimeout(handle)
        instance.timers.delete(id)
      },
      setInterval: (handler: unknown, delay?: unknown, ...args: unknown[]) => {
        if (typeof handler !== 'function') throw new Error('setInterval expects a function')
        const id = nextTimerId++
        const milliseconds =
          typeof delay === 'number' && Number.isFinite(delay)
            ? Math.max(1, Math.min(delay, 2_147_483_647))
            : 1
        const handle = setInterval(() => {
          void invokeInContext(instance, handler as PluginHandler, args).catch(
            (error: unknown) => log(instance.id, 'error', [errorMessage(error)])
          )
        }, milliseconds)
        instance.intervals.set(id, handle)
        return id
      },
      clearInterval: (id: unknown) => {
        if (typeof id !== 'number') return
        const handle = instance.intervals.get(id)
        if (handle !== undefined) clearInterval(handle)
        instance.intervals.delete(id)
      }
    }
    instance.globals = sandbox
    return instance
  }

  async function unload(pluginId: string): Promise<void> {
    const instance = instances.get(pluginId)
    if (instance === undefined) {
      post({ t: 'deactivated', pluginId })
      return
    }
    try {
      if (instance.deactivate !== null) {
        await timeout(
          invokeInContext(instance, instance.deactivate, []),
          limits.activateTimeoutMs,
          'deactivate'
        )
      }
    } catch (error) {
      log(pluginId, 'error', [`deactivate failed: ${errorMessage(error)}`])
    } finally {
      clearInstanceResources(instance)
      instances.delete(pluginId)
      post({ t: 'deactivated', pluginId })
    }
  }

  async function load(message: Extract<MainToHost, { t: 'load' }>): Promise<void> {
    await unload(message.pluginId)
    if (message.manifest.id !== message.pluginId) {
      post({
        t: 'activated',
        pluginId: message.pluginId,
        ok: false,
        error: 'manifest id does not match the requested plugin id'
      })
      return
    }
    let instance: PluginInstance | null = null
    try {
      instance = createInstance(message)
      const source = 'source' in message && typeof message.source === 'string'
        ? message.source : readFile(`${message.dir}/${message.manifest.main}`)
      // CommonJS compatibility in the sandboxed renderer, never the preload world.
      if (deps.execute) deps.execute(source, instance.globals)
      else new Function(...Object.keys(instance.globals), source)(...Object.values(instance.globals))
      const activate = exportedHook(instance.module.exports, 'activate')
      instance.deactivate = exportedHook(instance.module.exports, 'deactivate')
      instances.set(instance.id, instance)
      if (activate !== null) {
        await timeout(
          invokeInContext(instance, activate, [createCapability(instance)]),
          limits.activateTimeoutMs,
          'activate'
        )
      }
      post({
        t: 'activated',
        pluginId: instance.id,
        ok: true,
        commands: [...instance.commands.keys()]
      })
    } catch (error) {
      if (instance !== null) { clearInstanceResources(instance); instances.delete(instance.id) }
      post({
        t: 'activated',
        pluginId: message.pluginId,
        ok: false,
        error: errorMessage(error)
      })
    }
  }

  async function runCommand(
    message: Extract<MainToHost, { t: 'command' }>
  ): Promise<void> {
    const instance = instances.get(message.pluginId)
    const handler = instance?.commands.get(message.commandId)
    if (instance === undefined || handler === undefined) {
      post({
        t: 'commandResult',
        id: message.id,
        pluginId: message.pluginId,
        ok: false,
        error: `command "${message.commandId}" is not registered`
      })
      return
    }
    try {
      await timeout(
        invokeInContext(instance, handler, [message.context ?? null]),
        limits.commandTimeoutMs,
        `command ${message.commandId}`
      )
      post({
        t: 'commandResult',
        id: message.id,
        pluginId: message.pluginId,
        ok: true
      })
    } catch (error) {
      post({
        t: 'commandResult',
        id: message.id,
        pluginId: message.pluginId,
        ok: false,
        error: errorMessage(error)
      })
    }
  }

  function dispatchHandlers(
    instance: PluginInstance | undefined,
    handlers: Iterable<PluginHandler>,
    payload: unknown,
    label: string
  ): void {
    if (instance === undefined) return
    for (const handler of handlers) {
      void invokeInContext(instance, handler, [payload]).catch((error: unknown) => {
        log(instance.id, 'error', [`${label} handler failed: ${errorMessage(error)}`])
      })
    }
  }

  transport.onMessage((message) => {
    if (disposed) return
    switch (message.t) {
      case 'load':
        void load(message)
        return
      case 'unload':
        void unload(message.pluginId)
        return
      case 'apiResult': {
        const pending = pendingApi.get(message.id)
        if (pending === undefined) return
        pendingApi.delete(message.id)
        clearTimeout(pending.timer)
        if (message.ok) {
          pending.resolve(message.value)
        } else {
          const error = new Error(message.error.message)
          error.name = message.error.code
          pending.reject(error)
        }
        return
      }
      case 'command':
        void runCommand(message)
        return
      case 'event': {
        const instance = instances.get(message.pluginId)
        dispatchHandlers(
          instance,
          instance?.events.get(message.name) ?? [],
          message.payload,
          message.name
        )
        return
      }
      case 'panelMessage': {
        const instance = instances.get(message.pluginId)
        dispatchHandlers(
          instance,
          instance?.panels.get(message.panelId) ?? [],
          message.payload,
          `panel ${message.panelId}`
        )
        return
      }
      case 'shutdown':
        for (const pluginId of [...instances.keys()]) void unload(pluginId)
        return
    }
  })

  // `now` is intentionally touched here: production gets a real clock, while
  // tests can prove construction performs no ambient I/O besides transport.
  void now()
  post({ t: 'ready', protocolVersion })

  return {
    dispose() {
      if (disposed) return
      for (const instance of instances.values()) clearInstanceResources(instance)
      instances.clear()
      for (const pending of pendingApi.values()) {
        clearTimeout(pending.timer)
        pending.reject(new Error('plugin host disposed'))
      }
      pendingApi.clear()
      disposed = true
    }
  }
}
