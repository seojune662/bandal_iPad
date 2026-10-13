/**
 * Minimal semver (2.0.0 core + pre-release) — enough to validate a manifest
 * `version` / `minAppVersion` and compare against `__APP_VERSION__`. Build
 * metadata (`+…`) is accepted and ignored for ordering, as the spec says.
 */

const SEMVER_PATTERN =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$/

interface ParsedSemver {
  major: string
  minor: string
  patch: string
  prerelease: readonly string[]
}

export function parseSemver(value: string): ParsedSemver | null {
  if (typeof value !== 'string') return null
  const match = SEMVER_PATTERN.exec(value.trim())
  if (match === null) return null
  const [, major, minor, patch, prerelease] = match
  return {
    major: major!,
    minor: minor!,
    patch: patch!,
    prerelease: prerelease === undefined ? [] : prerelease.split('.')
  }
}

export function isValidSemver(value: unknown): value is string {
  return typeof value === 'string' && parseSemver(value) !== null
}

function compareIdentifiers(a: string, b: string): number {
  const aNumeric = /^\d+$/.test(a)
  const bNumeric = /^\d+$/.test(b)
  // SemVer numeric identifiers have no precision limit. They cannot have
  // leading zeroes, so length followed by lexicographic order is exact.
  if (aNumeric && bNumeric) {
    if (a.length !== b.length) return a.length < b.length ? -1 : 1
    return a < b ? -1 : a > b ? 1 : 0
  }
  if (aNumeric) return -1
  if (bNumeric) return 1
  return a < b ? -1 : a > b ? 1 : 0
}

/**
 * -1 / 0 / 1 like `Array.prototype.sort` comparators. Throws on an invalid
 * input so callers validate first (`isValidSemver`).
 */
export function compareSemver(a: string, b: string): -1 | 0 | 1 {
  const left = parseSemver(a)
  const right = parseSemver(b)
  if (left === null || right === null) {
    throw new Error(`compareSemver: invalid version "${left === null ? a : b}"`)
  }
  for (const key of ['major', 'minor', 'patch'] as const) {
    const comparison = compareIdentifiers(left[key], right[key])
    if (comparison !== 0) return comparison < 0 ? -1 : 1
  }
  if (left.prerelease.length === 0 && right.prerelease.length === 0) return 0
  if (left.prerelease.length === 0) return 1
  if (right.prerelease.length === 0) return -1
  const length = Math.max(left.prerelease.length, right.prerelease.length)
  for (let index = 0; index < length; index += 1) {
    const l = left.prerelease[index]
    const r = right.prerelease[index]
    if (l === undefined) return -1
    if (r === undefined) return 1
    const cmp = compareIdentifiers(l, r)
    if (cmp !== 0) return cmp < 0 ? -1 : 1
  }
  return 0
}
