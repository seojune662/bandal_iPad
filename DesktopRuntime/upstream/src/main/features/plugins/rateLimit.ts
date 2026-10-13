/**
 * Per-plugin sliding-window rate limiter for broker calls.
 *
 * Three buckets from `PLUGIN_RPC_LIMITS`: a generic API bucket every call
 * consumes, plus dedicated per-minute buckets for the two calls that reach
 * the user (`notices.show`) or the network (`net.fetch`). A dedicated bucket
 * is checked FIRST so a burst of toasts never eats the generic budget.
 */

import { PLUGIN_RPC_LIMITS } from '../../../shared/types/pluginRpc'
import type { PluginApiMethod } from '../../../shared/types/pluginRpc'

export interface PluginRateLimiter {
  /** Consumes one token; false means the call must be refused. */
  take(pluginId: string, method: PluginApiMethod): boolean
  /** Forgets every window for the plugin (unload / uninstall). */
  reset(pluginId: string): void
}

interface Bucket {
  limit: number
  windowMs: number
}

const MINUTE_MS = 60_000

const GENERIC: Bucket = {
  limit: PLUGIN_RPC_LIMITS.apiCallsPerWindow,
  windowMs: PLUGIN_RPC_LIMITS.apiWindowMs
}

const DEDICATED: Partial<Record<PluginApiMethod, Bucket>> = {
  'notices.show': { limit: PLUGIN_RPC_LIMITS.noticesPerMinute, windowMs: MINUTE_MS },
  'net.fetch': { limit: PLUGIN_RPC_LIMITS.fetchesPerMinute, windowMs: MINUTE_MS }
}

export function createPluginRateLimiter(
  now: () => number = Date.now
): PluginRateLimiter {
  /** key → timestamps of calls still inside the window (oldest first). */
  const windows = new Map<string, number[]>()

  function tryTake(key: string, bucket: Bucket): boolean {
    const at = now()
    const cutoff = at - bucket.windowMs
    const recent = (windows.get(key) ?? []).filter((stamp) => stamp > cutoff)
    if (recent.length >= bucket.limit) {
      windows.set(key, recent)
      return false
    }
    windows.set(key, [...recent, at])
    return true
  }

  return {
    take(pluginId, method) {
      const dedicated = DEDICATED[method]
      if (dedicated !== undefined) {
        if (!tryTake(`${pluginId}|${method}`, dedicated)) return false
      }
      return tryTake(`${pluginId}|*`, GENERIC)
    },
    reset(pluginId) {
      for (const key of [...windows.keys()]) {
        if (key.startsWith(`${pluginId}|`)) windows.delete(key)
      }
    }
  }
}
