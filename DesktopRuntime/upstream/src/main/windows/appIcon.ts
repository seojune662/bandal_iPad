import { existsSync } from 'node:fs'
import { join } from 'node:path'
import {
  nativeImage,
  type BrowserWindow,
  type NativeImage
} from 'electron'
import {
  getTheme,
  resolveThemeId
} from '../../shared/theme'
import type { Settings } from '../../shared/types/settings'

export type IconBase = 'dark' | 'light'

export function resolveIconVariant(
  settings: Pick<Settings, 'theme' | 'palette'>,
  prefersDark: boolean
): `bandal-${IconBase}` {
  const theme = getTheme(resolveThemeId(settings.theme, prefersDark))
  return `bandal-${theme.base}`
}

export function resolveIconDir(
  variant: string,
  opts: {
    isPackaged: boolean
    resourcesPath: string
    bundleDir: string
  }
): string {
  return opts.isPackaged
    ? join(opts.resourcesPath, 'icons', variant)
    : join(opts.bundleDir, '../../resources/icons', variant)
}

export interface AppIconDeps {
  getSettings(): Settings
  prefersDark(): boolean
  platform: NodeJS.Platform
  isPackaged: boolean
  resourcesPath: string
  bundleDir: string
  dock?: { setIcon(img: NativeImage): void }
  windows(): BrowserWindow[]
  tray?: { setIconVariant(dir: string): void }
  finder?: { apply(pngPath: string | null): Promise<void> }
}

export function createAppIconApplier(deps: AppIconDeps): {
  apply(): Promise<void>
  current(): string
} {
  let currentVariant = ''

  const assetExists = (path: string): boolean => {
    if (existsSync(path)) return true
    console.warn(`[app-icon] icon asset not found; skipping: ${path}`)
    failed = true
    return false
  }

  let failed = false
  const safely = (surface: string, apply: () => void): void => {
    try {
      apply()
    } catch (error) {
      failed = true
      console.warn(`[app-icon] failed to update ${surface}; skipping:`, error)
    }
  }

  return {
    async apply(): Promise<void> {
      const variant = resolveIconVariant(deps.getSettings(), deps.prefersDark())
      if (variant === currentVariant) return
      failed = false

      const dir = resolveIconDir(variant, deps)
      const icon512 = join(dir, 'icon-512.png')

      if (deps.platform === 'darwin') {
        const hasIcon512 = assetExists(icon512)
        if (hasIcon512 && deps.dock !== undefined) {
          safely('dock icon', () => {
            const icon = nativeImage.createFromPath(icon512)
            if (icon.isEmpty()) throw new Error('Empty app icon')
            deps.dock?.setIcon(icon)
          })
        }

        // Finder custom icons are deliberately disabled for Electron.app in
        // development. A packaged app reapplies the metadata after updates.
        if (deps.isPackaged && deps.finder !== undefined) {
          const finderPath = variant === 'bandal-dark' ? null : icon512
          if (finderPath === null || hasIcon512) {
            try {
              await deps.finder.apply(finderPath)
            } catch (error) {
              failed = true
              console.warn('[app-icon] failed to update Finder icon; skipping:', error)
            }
          }
        }
      } else if (deps.platform === 'win32') {
        const icon256 = join(dir, 'icon-256.png')
        if (assetExists(icon256)) {
          safely('window icons', () => {
            for (const win of deps.windows()) win.setIcon(icon256)
          })
        }
      }

      if (deps.tray !== undefined) {
        const trayIcon = join(
          dir,
          deps.platform === 'win32' ? 'tray.ico' : 'trayTemplate.png'
        )
        if (assetExists(trayIcon)) {
          safely('tray icon', () => deps.tray?.setIconVariant(dir))
        }
      }
      if (!failed) currentVariant = variant
    },

    current(): string {
      return currentVariant
    }
  }
}
