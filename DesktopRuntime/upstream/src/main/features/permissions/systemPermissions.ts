import { constants as fsConstants, promises as fs } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import {
  SYSTEM_PERMISSIONS,
  type SystemPermissionId,
  type SystemPermissionsReport,
  type SystemPermissionState,
  type SystemPermissionStatus
} from '../../../shared/types/permissions'
import { ValidationError } from '../../db/errors'

type ScreenAccess =
  | 'granted'
  | 'denied'
  | 'restricted'
  | 'not-determined'
  | 'unknown'

interface SystemPermissionsDeps {
  platform?: NodeJS.Platform
  getDataRoot(): string
  getScreenAccess(): ScreenAccess
  requestScreenAccess(): Promise<unknown>
  isTrustedAccessibilityClient(prompt: boolean): boolean
  notificationIsSupported(): boolean
  openExternal(url: string): Promise<unknown>
  access?: (path: string, mode: number) => Promise<void>
  readdir?: (path: string) => Promise<readonly unknown[]>
  homeDir?: () => string
  now?: () => Date
}

type PermissionContext = SystemPermissionsDeps & {
  platform: NodeJS.Platform
  access: (path: string, mode: number) => Promise<void>
  readdir: (path: string) => Promise<readonly unknown[]>
  homeDir: () => string
  now: () => Date
}

const MAC_SETTINGS: Partial<Record<SystemPermissionId, string>> = {
  screen:
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  accessibility:
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
  notifications: 'x-apple.systempreferences:com.apple.preference.notifications',
  documents:
    'x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders'
}

function settingsUrl(
  id: SystemPermissionId,
  platform: NodeJS.Platform
): string | null {
  if (platform === 'darwin') return MAC_SETTINGS[id] ?? null
  if (platform === 'win32' && id === 'notifications') {
    return 'ms-settings:notifications'
  }
  return null
}

function screenState(access: ScreenAccess): SystemPermissionState {
  if (access === 'granted') return 'granted'
  if (access === 'denied' || access === 'restricted') return 'denied'
  if (access === 'not-determined') return 'not-determined'
  return 'unknown'
}

function inaccessibleState(error: unknown): SystemPermissionState {
  const code = (error as NodeJS.ErrnoException).code
  return code === 'EPERM' || code === 'EACCES' ? 'denied' : 'unknown'
}

function canRequestUnknown(
  context: PermissionContext,
  id: SystemPermissionId
): boolean {
  return (
    context.platform === 'darwin' &&
    (id === 'accessibility' || id === 'documents')
  )
}

function result(
  context: PermissionContext,
  id: SystemPermissionId,
  state: SystemPermissionState,
  canRequest: boolean
): SystemPermissionStatus {
  return {
    id,
    state,
    canRequest,
    canOpenSettings: settingsUrl(id, context.platform) !== null
  }
}

async function documentsStatus(
  context: PermissionContext
): Promise<SystemPermissionStatus> {
  const configured = context.getDataRoot().trim()
  const dataRoot =
    configured === ''
      ? join(context.homeDir(), 'Documents', 'Bandal')
      : configured
  try {
    // A writable parent does not prove that an existing study-data folder is
    // writable. Only walk upward when the requested folder does not exist yet.
    let target = dataRoot
    while (true) {
      try {
        await context.access(target, fsConstants.R_OK | fsConstants.W_OK)
        await context.readdir(target)
        break
      } catch (error) {
        const parent = dirname(target)
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT' || parent === target) throw error
        target = parent
      }
    }
    return result(context, 'documents', 'granted', false)
  } catch (error) {
    return result(
      context,
      'documents',
      inaccessibleState(error),
      context.platform === 'darwin'
    )
  }
}

async function unsafeStatus(
  context: PermissionContext,
  id: SystemPermissionId
): Promise<SystemPermissionStatus> {
  if (id === 'screen') {
    if (context.platform === 'win32') {
      return result(context, id, 'not-applicable', false)
    }
    if (context.platform !== 'darwin') {
      return result(context, id, 'unknown', false)
    }
    const state = screenState(context.getScreenAccess())
    return result(context, id, state, state === 'not-determined')
  }
  if (id === 'accessibility') {
    if (context.platform !== 'darwin') {
      return result(context, id, 'not-applicable', false)
    }
    const state = context.isTrustedAccessibilityClient(false)
      ? 'granted'
      : 'denied'
    return result(context, id, state, true)
  }
  if (id === 'notifications') {
    const state = context.notificationIsSupported()
      ? 'unknown'
      : 'not-applicable'
    return result(context, id, state, false)
  }
  return documentsStatus(context)
}

async function permissionStatus(
  context: PermissionContext,
  id: SystemPermissionId
): Promise<SystemPermissionStatus> {
  try {
    return await unsafeStatus(context, id)
  } catch {
    return result(context, id, 'unknown', canRequestUnknown(context, id))
  }
}

async function permissionsReport(
  context: PermissionContext
): Promise<SystemPermissionsReport> {
  const permissions = await Promise.all(
    SYSTEM_PERMISSIONS.map((id) => permissionStatus(context, id))
  )
  return {
    platform: context.platform,
    permissions,
    checkedAt: context.now().toISOString()
  }
}

async function requestPermission(
  context: PermissionContext,
  id: SystemPermissionId
): Promise<SystemPermissionStatus> {
  try {
    if (id === 'screen' && (await permissionStatus(context, id)).canRequest) {
      await context.requestScreenAccess()
    } else if (id === 'accessibility' && context.platform === 'darwin') {
      context.isTrustedAccessibilityClient(true)
    }
  } catch {
    // A rejected OS prompt is reflected by the fresh, isolated query below.
  }
  return permissionStatus(context, id)
}

async function openPermissionSettings(
  context: PermissionContext,
  id: SystemPermissionId
): Promise<{ ok: true }> {
  const url = settingsUrl(id, context.platform)
  if (url === null) {
    throw new ValidationError('이 권한은 시스템 설정 항목이 없어요')
  }
  await context.openExternal(url)
  return { ok: true }
}

export function createSystemPermissions(deps: SystemPermissionsDeps) {
  const context: PermissionContext = {
    ...deps,
    platform: deps.platform ?? process.platform,
    access: deps.access ?? fs.access,
    readdir: deps.readdir ?? fs.readdir,
    homeDir: deps.homeDir ?? homedir,
    now: deps.now ?? (() => new Date())
  }
  return {
    status: () => permissionsReport(context),
    request: (id: SystemPermissionId) => requestPermission(context, id),
    openSettings: (id: SystemPermissionId) =>
      openPermissionSettings(context, id)
  }
}
