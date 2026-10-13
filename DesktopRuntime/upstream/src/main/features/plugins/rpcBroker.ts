/**
 * Host → main RPC broker. Pure (no electron import): every effect goes
 * through `deps`, so the ordering of checks is unit-testable.
 *
 * Order per `api` message:
 *   1. shape validation            → 'validation'
 *   2. payload size                → 'payload-too-large'
 *   3. plugin active (grants ≠ null) → 'plugin-not-active'
 *   4. permission                  → 'permission-denied' (+ log 'denied')
 *   5. rate limit                  → 'rate-limited'
 *   6. api call; ValidationError / NotFoundError / PathTraversalError map to
 *      'validation' / 'not-found' / 'validation'; anything else 'internal'
 *      (+ log 'error').
 *
 * Non-api messages return null and are forwarded to `deps.onEvent`.
 */

import { NotFoundError, PathTraversalError, ValidationError } from '../../db/errors'
import type {
  PluginLogEntry,
  PluginPermission
} from '../../../shared/types/plugin'
import {
  PLUGIN_API_METHODS,
  PLUGIN_RPC_LIMITS,
  type HostToMain,
  type MainToHost,
  type PluginApiMethod,
  type PluginErrorCode
} from '../../../shared/types/pluginRpc'
import { isAllowed } from './permissions'

export type PluginApiImpl = {
  [M in PluginApiMethod]: (pluginId: string, ...args: unknown[]) => Promise<unknown>
}

export type PluginHostEvent = Exclude<HostToMain, { t: 'api' }>

export interface PluginBrokerDeps {
  api: PluginApiImpl
  /** null = plugin is not active (unknown, disabled, still starting). */
  permissionsFor(pluginId: string): readonly PluginPermission[] | null
  limiter: { take(pluginId: string, method: PluginApiMethod): boolean }
  log(entry: Omit<PluginLogEntry, 'at'>): void
  onEvent?(msg: PluginHostEvent): void
  maxPayloadBytes?: number
}

export interface PluginBroker {
  handle(msg: HostToMain): Promise<MainToHost | null>
}

/**
 * Thrown by an API implementation to surface a specific wire code (for
 * example `permission-denied` on a cross-host redirect in `net.fetch`).
 */
export class PluginApiError extends Error {
  readonly code: PluginErrorCode
  constructor(code: PluginErrorCode, message: string) {
    super(message)
    this.name = 'PluginApiError'
    this.code = code
  }
}

const API_METHODS = new Set<string>(PLUGIN_API_METHODS)

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isApiMessage(
  msg: unknown
): msg is Extract<HostToMain, { t: 'api' }> {
  if (!isRecord(msg) || msg['t'] !== 'api') return false
  return (
    typeof msg['id'] === 'number' &&
    Number.isInteger(msg['id']) &&
    typeof msg['pluginId'] === 'string' &&
    msg['pluginId'] !== '' &&
    typeof msg['method'] === 'string' &&
    API_METHODS.has(msg['method']) &&
    Array.isArray(msg['args'])
  )
}

/** Byte length of the structured-clone payload; Infinity when unserializable. */
export function payloadBytes(value: unknown): number {
  try {
    const json = JSON.stringify(value)
    return json === undefined ? 0 : Buffer.byteLength(json, 'utf8')
  } catch {
    return Number.POSITIVE_INFINITY
  }
}

function failure(
  id: number,
  code: PluginErrorCode,
  message: string
): MainToHost {
  return { t: 'apiResult', id, ok: false, error: { code, message } }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function codeForError(error: unknown): PluginErrorCode {
  if (error instanceof PluginApiError) return error.code
  if (error instanceof ValidationError) return 'validation'
  if (error instanceof PathTraversalError) return 'validation'
  if (error instanceof NotFoundError) return 'not-found'
  return 'internal'
}

export function createPluginBroker(deps: PluginBrokerDeps): PluginBroker {
  const maxPayloadBytes = deps.maxPayloadBytes ?? PLUGIN_RPC_LIMITS.messageBytes

  async function handleApi(
    msg: Extract<HostToMain, { t: 'api' }>
  ): Promise<MainToHost> {
    const { id, pluginId, method, args } = msg
    if (payloadBytes(args) > maxPayloadBytes) {
      return failure(id, 'payload-too-large', `${method} payload exceeds ${maxPayloadBytes} bytes`)
    }
    const granted = deps.permissionsFor(pluginId)
    if (granted === null) {
      return failure(id, 'plugin-not-active', `plugin "${pluginId}" is not active`)
    }
    if (!isAllowed(granted, method, args)) {
      deps.log({ pluginId, level: 'denied', message: `${method} denied (missing permission)` })
      return failure(id, 'permission-denied', `${method} requires a permission the user has not granted`)
    }
    if (!deps.limiter.take(pluginId, method)) {
      return failure(id, 'rate-limited', `${method} rate limit exceeded`)
    }
    try {
      const value = await deps.api[method](pluginId, ...args)
      return { t: 'apiResult', id, ok: true, value }
    } catch (error) {
      const code = codeForError(error)
      if (code === 'internal') {
        deps.log({ pluginId, level: 'error', message: `${method} failed: ${errorMessage(error)}` })
      }
      return failure(id, code, errorMessage(error))
    }
  }

  return {
    async handle(msg) {
      if (!isRecord(msg) || typeof msg['t'] !== 'string') return null
      if (msg['t'] === 'api') {
        if (isApiMessage(msg)) return handleApi(msg)
        // Malformed api message: answer if we can address it, else drop.
        const rawId = msg['id']
        return typeof rawId === 'number'
          ? failure(rawId, 'validation', 'malformed api message')
          : null
      }
      deps.onEvent?.(msg as PluginHostEvent)
      return null
    }
  }
}

export { isApiMessage }
