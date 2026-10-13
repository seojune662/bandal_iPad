import { ensureSettingsLoaded } from './settingsSnapshot'
/**
 * [M8] The chosen school and its shortcut list.
 *
 * Mirrors the onboarding store's shape: settings.json is the source of truth,
 * this store caches it, every mutation writes back through `settings:set`,
 * and the `settings:changed` broadcast keeps the main window and the settings
 * window in sync (the school can be changed from either).
 *
 * All catalog logic lives in `shared/universities` — this file only holds
 * state and IPC.
 */

import { create } from 'zustand'
import { v4 as uuidv4 } from 'uuid'
import {
  CATALOG_VERIFIED_AT,
  CUSTOM_UNIVERSITY_PREFIX,
  inferCourseLinkSpec,
  moveServiceBy,
  resolveServices,
  resolveUniversity,
  type ResolvedService
} from '../../../shared/universities'
import {
  DEFAULT_UNIVERSITY_SETTINGS,
  type CustomUniversityInput,
  type University,
  type UniversitySettings
} from '../../../shared/types/university'
import { invoke, onPush } from '../lib/ipc'

interface UniversityStore {
  settings: UniversitySettings
  /** Resolved preset (or the user's custom definition); null = 아직 안 골랐어요. */
  university: University | null
  /** Sidebar-ready list: presets + custom, hidden removed, overrides applied. */
  services: readonly ResolvedService[]
  loaded: boolean
  error: string | null
  init: () => Promise<void>
  /** Pick a preset school by catalog id. */
  selectPreset: (universityId: string) => Promise<void>
  /** Create (and select) a school the catalog does not know. */
  addCustom: (input: CustomUniversityInput) => Promise<void>
  /** 학교 선택 해제 — the sidebar section disappears. */
  clearSelection: () => Promise<void>
  setServiceHidden: (serviceId: string, hidden: boolean) => Promise<void>
  setOpenExternally: (serviceId: string, external: boolean) => Promise<void>
  /** Persists the complete sidebar order (drag & drop hands over every id). */
  reorderServices: (ids: readonly string[]) => Promise<void>
  /** Nudges one service up (-1) or down (+1) within the full list, hidden included. */
  moveService: (id: string, delta: -1 | 1) => Promise<void>
  /** true = tuck behind 더보기, false = always visible. */
  setServiceSecondary: (id: string, secondary: boolean) => Promise<void>
  /** Back to catalog order and preset tiers; hidden/external tweaks survive. */
  resetServiceLayout: () => Promise<void>
}

let initialized = false
let unsubscribe: (() => void) | null = null
let generation = 0

function derive(
  settings: UniversitySettings
): Pick<UniversityStore, 'settings' | 'university' | 'services'> {
  const university = resolveUniversity(settings)
  return {
    settings,
    university,
    services: resolveServices(university, settings)
  }
}

/** Builds the custom-school definition from the 직접 추가 form. */
function buildCustomUniversity(input: CustomUniversityInput): University {
  const nameKo = input.nameKo.trim()
  // A pasted course URL is enough to switch on Canvas/Moodle deep links for
  // free — Korean LMS is a duopoly (docs/university-sites.md §6.3-3).
  const courseLink =
    input.courseUrl === undefined ? null : inferCourseLinkSpec(input.courseUrl)
  const university: University = {
    id: `${CUSTOM_UNIVERSITY_PREFIX}${uuidv4()}`,
    nameKo,
    nameEn: '',
    aliases: [],
    domain: '',
    services: [],
    verifiedAt: CATALOG_VERIFIED_AT
  }
  if (courseLink !== null) university.courseLink = courseLink
  return university
}

export const useUniversityStore = create<UniversityStore>()((set, get) => {
  /** Persists a whole UniversitySettings and optimistically applies it. */
  const persist = async (next: UniversitySettings): Promise<void> => {
    const previous = get().settings
    const current = ++generation
    set({ ...derive(next), error: null })
    try {
      const saved = await invoke('settings:set', { university: next })
      if (current === generation && saved.university !== undefined) set({ ...derive(saved.university), error: null })
    } catch (error) {
      console.error('[Bandal] 학교 설정을 저장하지 못했습니다.', error)
      if (current === generation) set({ ...derive(previous), error: '학교 설정을 저장하지 못했어요. 잠시 후 다시 시도해주세요.' })
    }
  }

  return {
    settings: DEFAULT_UNIVERSITY_SETTINGS,
    university: null,
    services: [],
    loaded: false,
    error: null,

    init: async () => {
      if (initialized) return
      initialized = true

      if (unsubscribe === null) unsubscribe = onPush('settings:changed', ({ settings }) => {
        generation += 1
        set({ ...derive(settings.university), loaded: true, error: null })
      })

      const current = generation
      try {
        const settings = await ensureSettingsLoaded()
        if (current === generation) set({ ...derive(settings.university), loaded: true })
      } catch (error) {
        initialized = false
        console.error('[Bandal] 학교 설정을 불러오지 못했습니다.', error)
        set({ loaded: true })
      }
    },

    selectPreset: async (universityId) => {
      const current = get().settings
      // Switching schools drops the previous school's per-service tweaks —
      // they reference ids that no longer exist.
      await persist({
        ...DEFAULT_UNIVERSITY_SETTINGS,
        universityId,
        customUniversity:
          current.customUniversity !== null &&
          current.customUniversity.id === universityId
            ? current.customUniversity
            : null
      })
    },

    addCustom: async (input) => {
      const university = buildCustomUniversity(input)
      await persist({
        ...DEFAULT_UNIVERSITY_SETTINGS,
        universityId: university.id,
        customUniversity: university
      })
    },

    clearSelection: async () => {
      await persist({ ...DEFAULT_UNIVERSITY_SETTINGS })
    },

    setServiceHidden: async (serviceId, hidden) => {
      const current = get().settings
      const without = current.hiddenServiceIds.filter((id) => id !== serviceId)
      await persist({
        ...current,
        hiddenServiceIds: hidden ? [...without, serviceId] : without
      })
    },

    setOpenExternally: async (serviceId, external) => {
      const current = get().settings
      await persist({
        ...current,
        openExternallyOverrides: {
          ...current.openExternallyOverrides,
          [serviceId]: external
        }
      })
    },

    reorderServices: async (ids) => {
      const current = get().settings
      await persist({ ...current, serviceOrder: [...ids] })
    },

    moveService: async (id, delta) => {
      const current = get().settings
      // Move within the *full* list (hidden entries keep their slot) so a
      // service unhidden later lands where the user last left it.
      const fullOrder = resolveServices(get().university, {
        ...current,
        hiddenServiceIds: []
      }).map((service) => service.id)
      await persist({ ...current, serviceOrder: moveServiceBy(fullOrder, id, delta) })
    },

    setServiceSecondary: async (id, secondary) => {
      const current = get().settings
      await persist({
        ...current,
        secondaryOverrides: { ...current.secondaryOverrides, [id]: secondary }
      })
    },

    resetServiceLayout: async () => {
      const current = get().settings
      await persist({ ...current, serviceOrder: [], secondaryOverrides: {} })
    }
  }
})

/** Test-only: allow re-initialization. */
export function resetUniversityStoreForTests(): void {
  unsubscribe?.()
  unsubscribe = null
  generation += 1
  initialized = false
  useUniversityStore.setState({
    ...derive(DEFAULT_UNIVERSITY_SETTINGS),
    loaded: false,
    error: null
  })
}
