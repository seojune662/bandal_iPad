/** Shared matching rules for local shortcuts and persisted browsing history. */
export function addressSearchTerms(input: string): string[] {
  return searchableAddress(input).trim().split(/\s+/u).filter(Boolean).slice(0, 8)
}

function searchableAddress(value: string): string {
  try { value = decodeURI(value) } catch { /* A partially typed escape is valid input. */ }
  return value.normalize('NFC').toLowerCase()
}

/** null excludes non-matches; smaller ranks win. All words may span title and URL. */
export function addressMatchRank(title: string, url: string, terms: string[]): number | null {
  const label = searchableAddress(title)
  const address = searchableAddress(url)
  if (!terms.every((term) => `${label} ${address}`.includes(term))) return null
  if (terms.length === 0) return 0
  const query = terms.join(' ')
  try {
    const host = new URL(url).host.replace(/^www\./iu, '').toLowerCase()
    if (host.startsWith(query.replace(/^https?:\/\/(?:www\.)?/u, ''))) return 0
  } catch { /* Non-URL candidates can still match their title. */ }
  if (label.startsWith(query)) return 1
  return 2
}
