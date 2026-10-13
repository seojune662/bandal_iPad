/** Main-process owner of isolated Chromium plugin execution sandboxes. */

import { createSandboxHost, type PluginHostProcess } from './sandboxHost'
import { ValidationError } from '../../db/errors'
import type { PluginLog } from './pluginLog'
import type { PluginRateLimiter } from './rateLimit'
import {
  createPluginBroker,
  type PluginApiImpl,
  type PluginHostEvent
} from './rpcBroker'
import type { PluginStore } from './pluginStore'
import {
  PLUGIN_RPC_LIMITS,
  PLUGIN_RPC_PROTOCOL_VERSION,
  type HostToMain,
  type MainToHost,
  type PluginEventName
} from '../../../shared/types/pluginRpc'
import type { PluginSummary } from '../../../shared/types/plugin'
import { compareSemver } from '../../../shared/plugins/semver'

export interface PluginRuntime {
  syncEnabled(): Promise<void>
  load(pluginId: string): Promise<PluginSummary>
  unload(pluginId: string): void
  reload(pluginId: string): Promise<PluginSummary>
  runCommand(pluginId: string, commandId: string, context?: unknown): Promise<void>
  sendEvent(name: PluginEventName, payload: unknown): void
  sendPanelMessage(pluginId: string, panelId: string, payload: unknown): void
  dispose(): void
}

export interface PluginRuntimeDeps {
  store: PluginStore
  api: PluginApiImpl
  limiter: PluginRateLimiter
  log: PluginLog
  preloadPath: string
  appVersion: string
  changed(): void
  createHost?: typeof createSandboxHost
}

interface PendingActivation {
  resolve(plugin: PluginSummary): void
  reject(error: Error): void
  timer: NodeJS.Timeout
}

interface PendingCommand {
  pluginId: string
  resolve(): void
  reject(error: Error): void
  timer: NodeJS.Timeout
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function messageText(value: unknown): string {
  return value instanceof Error ? value.message : String(value)
}

export function createPluginRuntime(deps: PluginRuntimeDeps): PluginRuntime {
  const hosts = new Map<string, PluginRuntime>()
  let disposed = false
  function host(id: string): PluginRuntime {
    if (disposed) throw new Error('plugin runtime is disposed')
    let runtime = hosts.get(id)
    if (runtime === undefined) {
      if (deps.store.get(id) === null) throw new ValidationError(`unknown plugin "${id}"`)
      runtime = createPluginProcessRuntime({
        ...deps,
        store: {
          ...deps.store,
          get: (candidate) => candidate === id ? deps.store.get(id) : null,
          list: () => deps.store.list().filter((plugin) => plugin.manifest.id === id)
        }
      }, id)
      hosts.set(id, runtime)
    }
    return runtime
  }
  function unload(id: string): void {
    const runtime = hosts.get(id)
    hosts.delete(id)
    runtime?.unload(id)
    runtime?.dispose()
  }
  return {
    async syncEnabled() {
      await Promise.all(deps.store.list().filter((plugin) => plugin.enabled && plugin.state !== 'needs-approval')
        .map((plugin) => host(plugin.manifest.id).syncEnabled()))
    },
    load: (id) => host(id).load(id),
    unload,
    reload: (id) => { unload(id); return host(id).load(id) },
    runCommand: (id, command, context) => host(id).runCommand(id, command, context),
    sendEvent: (name, payload) => {
      for (const [id, runtime] of hosts) {
        if (name === 'settings:changed' && (!isRecord(payload) || payload['pluginId'] !== id)) continue
        runtime.sendEvent(name, payload)
      }
    },
    sendPanelMessage: (id, panel, payload) => hosts.get(id)?.sendPanelMessage(id, panel, payload),
    dispose() {
      disposed = true
      for (const runtime of hosts.values()) runtime.dispose()
      hosts.clear()
    }
  }
}

function createPluginProcessRuntime(deps: PluginRuntimeDeps, ownerId: string): PluginRuntime {
  const createHost = deps.createHost ?? createSandboxHost
  const activations = new Map<string, PendingActivation>()
  const commands = new Map<number, PendingCommand>()
  let child: PluginHostProcess | null = null
  let hostReady = false
  let hostReadyPromise: Promise<void> | null = null
  let resolveHostReady: (() => void) | null = null
  let rejectHostReady: ((error: Error) => void) | null = null
  let nextCommandId = 1
  let disposed = false
  let hostFailure: string | null = null

  const permissionsFor = (pluginId: string) => {
    const plugin = deps.store.get(pluginId)
    if (
      plugin === null ||
      !plugin.enabled ||
      child === null ||
      (plugin.state !== 'active' && !(plugin.state === 'starting' && activations.has(pluginId))) ||
      plugin.approvedPermissions === null ||
      deps.store.needsApproval(pluginId)
    ) {
      return null
    }
    return plugin.approvedPermissions
  }

  const broker = createPluginBroker({
    api: deps.api,
    permissionsFor,
    limiter: deps.limiter,
    log: (entry) => deps.log.push(entry),
    onEvent: handleHostEvent
  })

  function publishState(
    pluginId: string,
    state: 'starting' | 'active' | 'errored',
    error?: string | null
  ): PluginSummary {
    const plugin = deps.store.setState(pluginId, state, error)
    deps.changed()
    return plugin
  }

  function failPending(error: Error): void {
    rejectHostReady?.(error)
    rejectHostReady = null
    resolveHostReady = null
    for (const pending of activations.values()) {
      clearTimeout(pending.timer)
      pending.reject(error)
    }
    activations.clear()
    for (const pending of commands.values()) {
      clearTimeout(pending.timer)
      pending.reject(error)
    }
    commands.clear()
  }

  function handleExit(code: number): void {
    if (child === null) return
    child = null
    hostReady = false
    hostReadyPromise = null
    const error = new Error(hostFailure ?? `plugin host exited with code ${code}`)
    failPending(error)
    if (disposed) return
    for (const plugin of deps.store.list()) {
      if (!plugin.enabled || plugin.state === 'needs-approval') continue
      try {
        publishState(plugin.manifest.id, 'errored', error.message)
      } catch {
        // The plugin may have been uninstalled while the process was exiting.
      }
    }
  }

  function ensureHost(): PluginHostProcess {
    if (disposed) throw new Error('plugin runtime is disposed')
    if (child !== null) return child

    hostReady = false
    hostFailure = null
    hostReadyPromise = new Promise<void>((resolve, reject) => {
      resolveHostReady = resolve
      rejectHostReady = reject
    })
    const spawned = createHost(deps.preloadPath)
    child = spawned
    spawned.on('message', (message: unknown) => {
      if (child !== spawned) return
      void handleHostMessage(message)
    })
    spawned.on('error', (_type, location) => {
      hostFailure = location || 'Plugin execution sandbox failed'
      deps.log.push({
        pluginId: ownerId,
        level: 'error',
        message: `host fatal error${location === '' ? '' : ` at ${location}`}`
      })
    })
    spawned.on('exit', (code) => { if (child === spawned) handleExit(code) })
    return spawned
  }

  async function readyHost(): Promise<PluginHostProcess> {
    const process = ensureHost()
    const ready = hostReadyPromise
    if (!hostReady && ready !== null) {
      await new Promise<void>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error('plugin host did not become ready')),
          PLUGIN_RPC_LIMITS.activateTimeoutMs
        )
        void ready.then(
          () => {
            clearTimeout(timer)
            resolve()
          },
          (error: unknown) => {
            clearTimeout(timer)
            reject(error instanceof Error ? error : new Error(String(error)))
          }
        )
      })
    }
    return process
  }

  function send(message: MainToHost): void {
    if (child === null || !hostReady) {
      throw new Error('plugin host is not ready')
    }
    child.postMessage(message)
  }

  function handleHostEvent(message: PluginHostEvent): void {
    if (!isRecord(message) || typeof message['t'] !== 'string') return
    switch (message.t) {
      case 'ready': {
        if (message.protocolVersion !== PLUGIN_RPC_PROTOCOL_VERSION) {
          const error = new Error(
            `unsupported plugin host protocol ${String(message.protocolVersion)}`
          )
          failPending(error)
          child?.kill()
          return
        }
        hostReady = true
        resolveHostReady?.()
        resolveHostReady = null
        rejectHostReady = null
        return
      }
      case 'activated': {
        if (typeof message.pluginId !== 'string') return
        const pending = activations.get(message.pluginId)
        if (pending === undefined) return
        activations.delete(message.pluginId)
        clearTimeout(pending.timer)
        try {
          if (message.ok) {
            pending.resolve(publishState(message.pluginId, 'active', null))
          } else {
            const error = new Error(message.error)
            publishState(message.pluginId, 'errored', error.message)
            pending.reject(error)
          }
        } catch (error) {
          pending.reject(error instanceof Error ? error : new Error(String(error)))
        }
        return
      }
      case 'commandResult': {
        const pending = commands.get(message.id)
        if (pending === undefined || pending.pluginId !== message.pluginId) return
        commands.delete(message.id)
        clearTimeout(pending.timer)
        if (message.ok) pending.resolve()
        else pending.reject(new Error(message.error ?? 'plugin command failed'))
        return
      }
      case 'log':
        deps.log.push({
          pluginId: message.pluginId,
          level: message.level,
          message: message.message
        })
        return
      case 'deactivated':
        return
    }
  }

  async function handleHostMessage(raw: unknown): Promise<void> {
    if (!isRecord(raw) || typeof raw['t'] !== 'string') return
    const message = raw as HostToMain
    // Identity is bound to the transport, never supplied by plugin code.
    if (message.t !== 'ready' && (!('pluginId' in message) || message.pluginId !== ownerId)) return
    if (message.t === 'api') {
      const sender = child
      const response = await broker.handle(message)
      if (response !== null && child !== null && child === sender && hostReady) {
        child.postMessage(response)
      }
      return
    }
    // Worker code controls its own transport. Validate every lifecycle/log
    // message too, rather than treating the renderer as trusted host code.
    switch (message.t) {
      case 'ready':
        if (!Number.isInteger(message.protocolVersion)) return
        break
      case 'activated':
        if (typeof message.ok !== 'boolean') return
        if (message.ok) {
          if (!Array.isArray(message.commands) || message.commands.length > 32 || message.commands.some(command => typeof command !== 'string')) return
        } else if (typeof message.error !== 'string') return
        break
      case 'commandResult':
        if (!Number.isSafeInteger(message.id) || typeof message.ok !== 'boolean' || (message.error !== undefined && typeof message.error !== 'string')) return
        break
      case 'log':
        if (!['info', 'warn', 'error'].includes(message.level) || typeof message.message !== 'string') return
        break
      case 'deactivated':
        break
      default:
        return
    }
    await broker.handle(message)
  }

  async function load(pluginId: string): Promise<PluginSummary> {
    const plugin = deps.store.get(pluginId)
    if (plugin === null) throw new ValidationError(`unknown plugin "${pluginId}"`)
    if (!plugin.enabled) return plugin
    if (deps.store.needsApproval(pluginId)) {
      return deps.store.setState(pluginId, 'needs-approval')
    }
    if (compareSemver(deps.appVersion, plugin.manifest.minAppVersion) < 0) {
      const error = new Error(
        `${plugin.manifest.name} requires Bandal ${plugin.manifest.minAppVersion} or newer`
      )
      publishState(pluginId, 'errored', error.message)
      throw error
    }

    const old = activations.get(pluginId)
    if (old !== undefined) {
      clearTimeout(old.timer)
      old.reject(new Error(`plugin "${pluginId}" activation was superseded`))
      activations.delete(pluginId)
    }
    publishState(pluginId, 'starting', null)

    const result = new Promise<PluginSummary>((resolve, reject) => {
      const timer = setTimeout(() => {
        activations.delete(pluginId)
        const error = new Error(`plugin "${pluginId}" activation timed out`)
        try {
          publishState(pluginId, 'errored', error.message)
        } catch {
          // Preserve the timeout as the caller-visible error.
        }
        reject(error)
        child?.kill()
      }, PLUGIN_RPC_LIMITS.activateTimeoutMs + 1_000)
      activations.set(pluginId, { resolve, reject, timer })
    })
    // Activation can time out while we are still awaiting the host handshake.
    void result.catch(() => undefined)

    try {
      await readyHost()
      send({
        t: 'load',
        pluginId,
        dir: deps.store.dirFor(pluginId),
        manifest: plugin.manifest,
        appVersion: deps.appVersion
      })
    } catch (error) {
      const failure = error instanceof Error ? error : new Error(String(error))
      const pending = activations.get(pluginId)
      if (pending !== undefined) {
        clearTimeout(pending.timer)
        activations.delete(pluginId)
        try {
          publishState(pluginId, 'errored', failure.message)
        } catch {
          // The registry entry may have been removed concurrently.
        }
        pending.reject(failure)
      }
    }
    return result
  }

  function unload(pluginId: string): void {
    const activation = activations.get(pluginId)
    if (activation !== undefined) {
      clearTimeout(activation.timer)
      activation.reject(new Error(`plugin "${pluginId}" was unloaded`))
      activations.delete(pluginId)
    }
    for (const [id, pending] of commands) {
      if (pending.pluginId !== pluginId) continue
      clearTimeout(pending.timer)
      pending.reject(new Error(`plugin "${pluginId}" was unloaded`))
      commands.delete(id)
    }
    deps.limiter.reset(pluginId)
    if (child !== null && hostReady) child.postMessage({ t: 'unload', pluginId })
  }

  return {
    async syncEnabled() {
      const enabled = deps.store
        .list()
        .filter(
          (plugin) =>
            plugin.enabled && plugin.state !== 'needs-approval'
        )
      await Promise.all(
        enabled.map(async (plugin) => {
          try {
            await load(plugin.manifest.id)
          } catch (error) {
            deps.log.push({
              pluginId: plugin.manifest.id,
              level: 'error',
              message: `startup failed: ${messageText(error)}`
            })
          }
        })
      )
    },
    load,
    unload,
    async reload(pluginId) {
      const plugin = deps.store.get(pluginId)
      if (plugin === null) throw new ValidationError(`unknown plugin "${pluginId}"`)
      unload(pluginId)
      return plugin.enabled ? load(pluginId) : plugin
    },
    async runCommand(pluginId, commandId, context) {
      const plugin = deps.store.get(pluginId)
      if (plugin === null || !plugin.enabled || plugin.state !== 'active') {
        throw new ValidationError(`plugin "${pluginId}" is not active`)
      }
      if (
        !plugin.manifest.contributes.commands.some(
          (command) => command.id === commandId
        )
      ) {
        throw new ValidationError(`unknown plugin command "${commandId}"`)
      }
      await readyHost()
      const id = nextCommandId++
      const result = new Promise<void>((resolve, reject) => {
        const timer = setTimeout(() => {
          commands.delete(id)
          reject(new Error(`plugin command "${commandId}" timed out`))
          child?.kill()
        }, PLUGIN_RPC_LIMITS.commandTimeoutMs + 1_000)
        commands.set(id, { pluginId, resolve, reject, timer })
      })
      send({ t: 'command', id, pluginId, commandId, ...(context === undefined ? {} : { context }) })
      return result
    },
    sendEvent(name, payload) {
      if (child === null || !hostReady) return
      for (const plugin of deps.store.list()) {
        if (
          plugin.enabled &&
          plugin.state === 'active' &&
          plugin.approvedPermissions?.includes('events')
        ) {
          child.postMessage({
            t: 'event',
            pluginId: plugin.manifest.id,
            name,
            payload
          })
        }
      }
    },
    sendPanelMessage(pluginId, panelId, payload) {
      const plugin = deps.store.get(pluginId)
      if (
        child === null ||
        !hostReady ||
        plugin === null ||
        !plugin.enabled ||
        plugin.state !== 'active' ||
        !plugin.approvedPermissions?.includes('panel')
      ) {
        return
      }
      child.postMessage({ t: 'panelMessage', pluginId, panelId, payload })
    },
    dispose() {
      if (disposed) return
      disposed = true
      failPending(new Error('plugin runtime disposed'))
      if (child !== null) {
        if (hostReady) child.postMessage({ t: 'shutdown' })
        child.kill()
        child = null
      }
      hostReady = false
      hostReadyPromise = null
    }
  }
}
