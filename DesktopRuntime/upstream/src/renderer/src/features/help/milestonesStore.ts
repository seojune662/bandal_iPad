import { create } from 'zustand'
import type { MaterialNode } from '../../../../shared/types/materials'
import type { Settings } from '../../../../shared/types/settings'
import { invoke, onPush } from '../../lib/ipc'

export type MilestoneId =
  | 'university'
  | 'course'
  | 'materials'
  | 'agent'
  | 'tutorial'
  | 'favorite'
  | 'question'
  | 'pip'

export interface MilestoneFacts {
  university: boolean
  course: boolean
  materials: boolean
  agent: boolean
  tutorial: boolean
  favorite: boolean
  question: boolean
  pip: boolean
}

export interface MilestoneItem {
  id: MilestoneId
  completed: boolean
}

export const EMPTY_MILESTONE_FACTS: MilestoneFacts = {
  university: false,
  course: false,
  materials: false,
  agent: false,
  tutorial: false,
  favorite: false,
  question: false,
  pip: false
}

export function deriveMilestones(facts: MilestoneFacts): MilestoneItem[] {
  const items: MilestoneItem[] = [
    { id: 'university', completed: facts.university },
    { id: 'course', completed: facts.course },
    { id: 'materials', completed: facts.materials },
    { id: 'agent', completed: facts.agent },
    { id: 'tutorial', completed: facts.tutorial },
    { id: 'favorite', completed: facts.favorite },
    { id: 'question', completed: facts.question }
  ]
  items.push({ id: 'pip', completed: facts.pip })
  return items
}

export function milestoneProgress(items: readonly MilestoneItem[]): number {
  if (items.length === 0) return 0
  const completed = items.filter((item) => item.completed).length
  return Math.round((completed / items.length) * 100)
}

export function treeHasFile(nodes: readonly MaterialNode[]): boolean {
  return nodes.some(
    (node) =>
      node.kind !== 'dir' ||
      (node.children !== undefined && treeHasFile(node.children))
  )
}

interface MilestonesState {
  facts: MilestoneFacts
  items: MilestoneItem[]
  progress: number
  loading: boolean
  error: string | null
  refresh: (selectedCourseId: string | null) => Promise<void>
}

let refreshSequence = 0

function updateFacts(
  set: (partial: Partial<MilestonesState>) => void,
  facts: MilestoneFacts
): void {
  const items = deriveMilestones(facts)
  set({ facts, items, progress: milestoneProgress(items) })
}

export const useMilestones = create<MilestonesState>()((set) => ({
  facts: EMPTY_MILESTONE_FACTS,
  items: deriveMilestones(EMPTY_MILESTONE_FACTS),
  progress: 0,
  loading: false,
  error: null,

  refresh: async (selectedCourseId) => {
    const sequence = ++refreshSequence
    set({ loading: true, error: null })
    try {
      const [settings, courses] = await Promise.all([
        invoke('settings:get', {}),
        invoke('courses:list', {})
      ])
      const selectedCourse = courses.find(
        (course) => course.id === selectedCourseId && !course.missing
      )
      const favoriteScopes = [null, ...courses.map((course) => course.id)]
      const [availability, materialTree, favoriteLists, activityLists] =
        await Promise.all([
          invoke('agent:availability', { provider: settings.agentProvider }),
          selectedCourse === undefined
            ? Promise.resolve([] as MaterialNode[])
            : invoke('materials:tree', { courseId: selectedCourse.id }),
          Promise.all(
            favoriteScopes.map((courseId) =>
              invoke('favorites:list', { courseId })
            )
          ),
          Promise.all(
            courses.map((course) =>
              invoke('activity:recent', { courseId: course.id, limit: 50 })
            )
          )
        ])
      if (sequence !== refreshSequence) return

      const facts: MilestoneFacts = {
        university: settings.university.universityId !== null,
        course: courses.length > 0,
        materials: treeHasFile(materialTree),
        agent: availability.installed && availability.loggedIn,
        tutorial: settings.tutorial.seenVersion > 0,
        favorite: favoriteLists.some((favorites) => favorites.length > 0),
        question: activityLists.some((events) =>
          events.some((event) => event.kind === 'question-asked')
        ),
        pip: settings.milestones.pipUsedAt !== null
      }
      updateFacts(set, facts)
      set({ loading: false })
    } catch (error) {
      if (sequence !== refreshSequence) return
      console.error('[Bandal] 마일스톤을 불러오지 못했습니다.', error)
      set({ loading: false, error: 'help.milestones.loadFailed' })
    }
  }
}))

let pipTrackingInstalled = false
let pipRecording: Promise<void> | null = null

function applyPipSetting(settings: Settings): void {
  if (settings.milestones.pipUsedAt === null) return
  const state = useMilestones.getState()
  const facts = { ...state.facts, pip: true }
  const items = deriveMilestones(facts)
  useMilestones.setState({
    facts,
    items,
    progress: milestoneProgress(items)
  })
}

async function recordPipMilestone(): Promise<void> {
  if (useMilestones.getState().facts.pip || pipRecording !== null) return
  const request = (async () => {
    const settings = await invoke('settings:get', {})
    if (settings.milestones.pipUsedAt !== null) {
      applyPipSetting(settings)
      return
    }
    const saved = await invoke('settings:set', {
      milestones: { pipUsedAt: new Date().toISOString() }
    })
    applyPipSetting(saved)
  })()
  pipRecording = request
  try {
    await request
  } catch (error) {
    console.error('[Bandal] PiP 사용 기록을 저장하지 못했습니다.', error)
  } finally {
    if (pipRecording === request) pipRecording = null
  }
}

/** Installs the app-lifetime PiP listener. Idempotent under React strict mode. */
export function installPipMilestoneTracking(): void {
  if (pipTrackingInstalled || typeof window === 'undefined') return
  pipTrackingInstalled = true
  onPush('pip:state', (state) => {
    if (state.open) void recordPipMilestone()
  })
}

installPipMilestoneTracking()
