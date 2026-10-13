import { existsSync, lstatSync, readFileSync, realpathSync } from 'node:fs'
import { isAbsolute, join, relative, resolve } from 'node:path'

export type BrowserAuthProbeMode = 'product' | 'clean'
export type BrowserAuthProbeIdentity = 'product' | 'native'
export const BROWSER_AUTH_PROBE_PROTOCOL = 'bandal-manual-auth-probe/v1'
export const BROWSER_AUTH_PROBE_NATIVE_IDENTITY_CAPABILITY = 'bandal-manual-auth-probe/native-identity/v1'
export interface BrowserAuthProbe {
  mode: BrowserAuthProbeMode
  identity: BrowserAuthProbeIdentity
  root: string
  userDataDir: string
  dataRoot: string
  launchId: string
}

let activeProbe: BrowserAuthProbe | null = null

function contains(parent: string, child: string): boolean {
  const rel = relative(parent, child)
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))
}

function canonical(value: string): string { return realpathSync(value) }

/** A mode flag alone must never turn the user's installed profile into a probe. */
export function validateBrowserAuthProbe(
  env: NodeJS.ProcessEnv,
  defaultUserDataDir: string,
  executablePath: string,
  argv: readonly string[] = []
): BrowserAuthProbe | null {
  const mode = env.BANDAL_BROWSER_AUTH_PROBE
  if (mode === undefined) return null
  if (mode !== 'product' && mode !== 'clean') throw new Error('Invalid browser authentication probe mode.')
  const identity = env.BANDAL_BROWSER_AUTH_PROBE_IDENTITY ?? 'product'
  if (identity !== 'product' && identity !== 'native') throw new Error('Invalid browser authentication probe identity.')
  if (argv.some(arg => /^--(?:remote-debugging(?:-|=|$)|inspect|no-sandbox|disable-web-security|ignore-certificate-errors|user-agent|user-data-dir)/.test(arg))) {
    throw new Error('Authentication probes must run without automation, UA overrides or weakened security flags.')
  }
  if (['NODE_OPTIONS', 'V8_FLAGS', 'ELECTRON_EXTRA_LAUNCH_ARGS', 'ELECTRON_RUN_AS_NODE', 'ELECTRON_RENDERER_URL', 'BANDAL_DISABLE_SAFE_STORAGE'].some(key => env[key])) {
    throw new Error('Authentication probes must use the clean launch environment provided by the probe launcher.')
  }
  const launchId = env.BANDAL_BROWSER_AUTH_PROBE_LAUNCH_ID
  if (!launchId || !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/.test(launchId)) {
    throw new Error('Authentication probes require a fresh launch identifier.')
  }
  const rootInput = env.BANDAL_BROWSER_AUTH_PROBE_ROOT
  const userDataInput = env.BANDAL_USER_DATA_DIR
  const dataInput = env.BANDAL_DATA_ROOT
  if (!rootInput || !userDataInput || !dataInput ||
    ![rootInput, userDataInput, dataInput].every(isAbsolute)) {
    throw new Error('Authentication probes require isolated absolute data paths from the probe launcher.')
  }
  const root = canonical(rootInput)
  const userDataDir = canonical(userDataInput)
  const dataRoot = canonical(dataInput)
  let defaultUserData = resolve(defaultUserDataDir)
  try { defaultUserData = canonical(defaultUserDataDir) } catch { /* A new installation has no profile yet. */ }
  if (contains(root, defaultUserData) || contains(defaultUserData, root) ||
    userDataDir !== join(root, 'user-data') || dataRoot !== join(root, 'data')) {
    throw new Error('Authentication probe paths must be separate from the installed profile.')
  }
  const settingsPath = join(userDataDir, 'settings.json')
  if (existsSync(settingsPath)) {
    if (lstatSync(settingsPath).isSymbolicLink()) throw new Error('Authentication probe settings must not be redirected.')
    const settings: unknown = JSON.parse(readFileSync(settingsPath, 'utf8'))
    const savedDataRoot = settings && typeof settings === 'object' ? (settings as Record<string, unknown>).dataRoot : undefined
    if (savedDataRoot !== undefined && (typeof savedDataRoot !== 'string' || !isAbsolute(savedDataRoot) || canonical(savedDataRoot) !== dataRoot)) {
      throw new Error('Authentication probe settings must retain the isolated data directory.')
    }
  }
  const marker: unknown = JSON.parse(readFileSync(join(root, 'probe.json'), 'utf8'))
  if (!marker || typeof marker !== 'object') throw new Error('Missing authentication probe launcher marker.')
  const value = marker as Record<string, unknown>
  // Older launchers did not select an identity; they always used product behavior.
  const markerIdentity = value.identity === undefined ? 'product' : value.identity
  const executable = canonical(executablePath)
  if (value.version !== 1 || value.purpose !== 'bandal-browser-auth-probe' || value.mode !== mode ||
    markerIdentity !== identity ||
    value.root !== root || value.userDataDir !== userDataDir || value.dataRoot !== dataRoot ||
    value.executablePath !== executable || !contains(join(root, 'application'), executable)) {
    throw new Error('Authentication probe launcher marker does not match this app copy and data paths.')
  }
  return { mode, identity, root, userDataDir, dataRoot, launchId }
}

/** Called once, before any profile, single-instance lock or window is opened. */
export function initializeBrowserAuthProbe(
  env: NodeJS.ProcessEnv,
  defaultUserDataDir: string,
  executablePath: string,
  argv: readonly string[] = []
): BrowserAuthProbe | null {
  activeProbe = validateBrowserAuthProbe(env, defaultUserDataDir, executablePath, argv)
  return activeProbe
}

export function getBrowserAuthProbeMode(): BrowserAuthProbeMode | null { return activeProbe?.mode ?? null }
export function getBrowserAuthProbeIdentity(): BrowserAuthProbeIdentity | null { return activeProbe?.identity ?? null }
export function isCleanBrowserAuthProbe(): boolean { return activeProbe?.mode === 'clean' }

/** Only this non-secret, immutable setting is passed to the application preload. */
export function browserAuthProbeArguments(): string[] {
  return activeProbe ? [`--bandal-browser-auth-probe=${activeProbe.mode}`] : []
}
