import type { StudyMarketAction, StudyMarketApi, StudyMarketRequest } from '../../../../shared/types/studyMarket'
import { invoke } from '../../lib/ipc'

export async function marketRequest<K extends StudyMarketAction>(action: K, input: StudyMarketApi[K]['req']): Promise<StudyMarketApi[K]['res']> {
  return await invoke('studyMarket:request', { action, input } as StudyMarketRequest) as StudyMarketApi[K]['res']
}

export function readCourseBindings(universityId: string): Record<string, string> {
  try {
    const value: unknown = JSON.parse(localStorage.getItem(`bandal:study-market:bindings:${universityId}`) ?? '{}')
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {}
    return Object.fromEntries(Object.entries(value).filter((entry): entry is [string, string] => typeof entry[1] === 'string'))
  } catch { return {} }
}

export function saveCourseBinding(universityId: string, localCourseId: string, marketCourseId: string): void {
  const bindings = readCourseBindings(universityId)
  bindings[localCourseId] = marketCourseId
  try { localStorage.setItem(`bandal:study-market:bindings:${universityId}`, JSON.stringify(bindings)) } catch { /* The current sale may still continue. */ }
}
