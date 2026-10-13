/** Attribution travels with a saved dictionary meaning. */
export interface DictionarySource {
  datasetVersion: string
  headword: string
  url: string
  /** Attribution survives personal edits without presenting them as a verbatim dictionary sense. */
  modified?: true
}

export interface DictionaryEntry {
  id: string
  headword: string
  partOfSpeech: string
  pronunciation: string
  senses: Array<{ meaning: string; definition?: string }>
  source: DictionarySource
}

export interface DictionaryLookupResult {
  status: 'found' | 'not-found' | 'unavailable'
  entries: DictionaryEntry[]
}
