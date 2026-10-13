import { constants } from 'node:fs'
import { access } from 'node:fs/promises'

export interface FinderIconExecResult {
  code: number
  stdout: string
  stderr: string
}

export interface FinderIconApplierDeps {
  appBundlePath: string
  exec(command: string, args: string[]): Promise<FinderIconExecResult>
}

/**
 * Returns the enclosing .app bundle for an Electron executable path.
 * A development Electron.app must still be excluded by the caller's
 * `app.isPackaged` guard.
 */
export function resolveAppBundlePath(executablePath: string): string | null {
  const match = /^(.+?\.app)(?:\/|$)/.exec(executablePath)
  return match?.[1] ?? null
}

/**
 * Applies a Finder custom-icon metadata override to the app bundle.
 *
 * Finder stores this metadata outside the signed code seal, so Gatekeeper and
 * spctl still pass. `codesign --verify --strict` does not, however. Since
 * electron-updater replaces the app bundle and loses the metadata, callers
 * should reapply it at startup.
 */
export function createFinderIconApplier(deps: FinderIconApplierDeps): {
  apply(pngPath: string | null): Promise<void>
} {
  return {
    async apply(pngPath: string | null): Promise<void> {
      try {
        await access(deps.appBundlePath, constants.W_OK)
      } catch {
        return
      }

      const imageExpression =
        pngPath === null
          ? '$()'
          : `$.NSImage.alloc.initWithContentsOfFile(${JSON.stringify(pngPath)})`
      const script =
        `ObjC.import('AppKit'); const img = ${imageExpression}; ` +
        `$.NSWorkspace.sharedWorkspace.setIconForFileOptions(` +
        `img, ${JSON.stringify(deps.appBundlePath)}, 0)`

      try {
        const result = await deps.exec('osascript', [
          '-l',
          'JavaScript',
          '-e',
          script
        ])
        if (result.stdout.trim() !== 'true') {
          console.warn(
            '[finder-icon] Finder did not accept the app icon:',
            result.stderr || result.stdout
          )
        }
      } catch (error) {
        console.warn('[finder-icon] failed to update the Finder app icon:', error)
      }
    }
  }
}
