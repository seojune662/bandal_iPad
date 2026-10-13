import type { App } from 'electron'
import type { BrowserAuthProbeIdentity } from './authProbe'

interface BrowserProduct {
  name: string
  version: string
}

/**
 * Identify the browser as Bandal with its actual Chromium engine. Electron's
 * library product token selects Google's limited embedded-app sign-in flow;
 * it is not the browser brand. Preserve every engine/platform token, rather
 * than impersonating another browser.
 */
export function bandalBrowserUserAgent(runtimeUserAgent: string, product: BrowserProduct): string {
  const userAgent = runtimeUserAgent.replace(/\s+Electron\/\S+/g, '')
  const name = product.name.replace(/\s+/g, '')
  const token = `${name}/${product.version}`
  const existing = new RegExp(`(^|\\s)${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\/\\S+`, 'i')
  // Launching a main JS entry directly makes Electron omit the app product.
  // Use our build's version in that mode, never Electron's version as Bandal's.
  return existing.test(userAgent)
    ? userAgent.replace(existing, (_match, separator: string) => `${separator}${token}`)
    : `${userAgent} ${token}`
}

/** Set once at boot, before any session or WebContents can cache its identity. */
export function configureBrowserIdentity(
  application: Pick<App, 'userAgentFallback'>,
  product: BrowserProduct,
  probeIdentity?: BrowserAuthProbeIdentity
): void {
  // Only the validated, isolated probe may select the unmodified runtime as a
  // comparison control. Product probes use the same path as the installed app.
  if (probeIdentity === 'native') return
  application.userAgentFallback = bandalBrowserUserAgent(application.userAgentFallback, product)
}
