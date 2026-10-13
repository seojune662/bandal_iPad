/**
 * Main-side permission check for one broker call. Thin on purpose: the
 * method → permission table lives in `shared/plugins/permissions.ts`; this
 * only knows that `net.fetch` carries its URL as `args[0]`.
 */

import { isMethodAllowed } from '../../../shared/plugins/permissions'
import type { PluginPermission } from '../../../shared/types/plugin'
import type { PluginApiMethod } from '../../../shared/types/pluginRpc'

export function isAllowed(
  granted: readonly PluginPermission[],
  method: PluginApiMethod,
  args: readonly unknown[]
): boolean {
  if (method === 'net.fetch') {
    const url = args[0]
    if (typeof url !== 'string') return false
    return isMethodAllowed(granted, method, url)
  }
  return isMethodAllowed(granted, method)
}
