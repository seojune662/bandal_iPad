/**
 * Packaged apps report their installed runtime version. Development and E2E
 * builds use the package version injected by electron-vite because Electron's
 * app.getVersion() reports Electron's own version while unpackaged.
 */
export function resolveAppVersion(
  isPackaged: boolean,
  runtimeVersion: string,
  buildVersion: string
): string {
  return isPackaged ? runtimeVersion : buildVersion
}
