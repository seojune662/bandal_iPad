import type { CatalogEntry } from '../../../../../shared/types/pluginCatalog'
import { compareSemver, isValidSemver } from '../../../../../shared/plugins/semver'

export function filterEntries(
  entries: readonly CatalogEntry[],
  options: {
    query: string
    installedOnly: boolean
    installedIds: ReadonlySet<string>
    installedPackNames: ReadonlySet<string>
  }
): CatalogEntry[] {
  const query = options.query.trim().toLocaleLowerCase()

  return entries.filter((entry) => {
    const installed =
      entry.kind === 'extension'
        ? options.installedIds.has(entry.id)
        : options.installedPackNames.has(entry.name)
    if (options.installedOnly && !installed) return false
    if (query.length === 0) return true

    return [entry.name, entry.publisher, ...entry.tags].some((value) =>
      value.toLocaleLowerCase().includes(query)
    )
  })
}

export function installState(
  entry: CatalogEntry,
  installedVersion: string | null
): 'install' | 'installed' | 'update' {
  if (installedVersion === null) return 'install'
  if (
    isValidSemver(entry.version) &&
    isValidSemver(installedVersion) &&
    compareSemver(entry.version, installedVersion) > 0
  ) {
    return 'update'
  }
  return 'installed'
}
