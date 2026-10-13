import { join } from './shims/path'
import { env } from './native'
import { createDiagnosticsBundle } from '../upstream/src/main/features/diagnostics/diagnosticsBundle'
import { getSettings } from '../upstream/src/main/settingsStore'

/** The exact desktop redaction and bounded log export; OS presentation stays native. */
export function installApplication(deps: {handle(channel: string, action: (request: any) => any): void; plugins: {list(): any[]}}) {
  const platform = (channel: string, request = {}) => (globalThis as any).__bandalPlatform.invoke(channel, request)
  const logs = join(env().userDataPath, 'Logs')
  const diagnostics = createDiagnosticsBundle({
    tempDir: () => join(env().tempPath, 'Diagnostics'), now: () => new Date(), appVersion: () => env().version,
    electronVersion: () => 'WKWebView / JavaScriptCore', platform: 'ios' as any,
    osVersion: () => (env() as any).osVersion ?? 'iPadOS', getSettings,
    getAgentAvailability: provider => platform('native:aiAvailability', {provider}),
    getPlugins: () => deps.plugins.list(), getPluginLogs: () => [], logsPath: () => logs,
    reveal: () => undefined // Await the native presentation before returning success below.
  })
  deps.handle('app:diagnostics', async () => {
    const result = await diagnostics()
    await platform('native:revealFile', {path: result.path})
    return result
  })
  deps.handle('app:openLogs', () => platform('native:openLogs'))
}
