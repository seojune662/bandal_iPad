/**
 * The glass box.
 *
 * While the agent is driving a page, the student sees a strip on that tab
 * saying what it is doing, with a 중지 button. This is not decoration: it is
 * the mitigation for every reliability failure mode in this feature. A model
 * that misreads a Korean portal will do something visibly wrong, and the only
 * thing that turns "the agent did something weird" into "I stopped it" is a
 * person watching a real tab.
 *
 * It is also why the agent gets a VISIBLE tab rather than a hidden one — and
 * that choice has a second benefit: Chromium background-throttles a guest it
 * considers occluded, which would make agent runs mysteriously slow.
 */

import { randomUUID } from 'node:crypto'

export type RunStatus = 'running' | 'waiting' | 'stopped' | 'done'

export interface RunState {
  runId: string
  courseId: string
  tabId: string
  status: RunStatus
  /** One short line: what it is doing right now. */
  action: string
  url: string
}

export class RunStopped extends Error {
  constructor() {
    super('학생이 중지했어요.')
    this.name = 'RunStopped'
  }
}

export interface RunRegistryDeps {
  emit: (state: RunState) => void
}

/**
 * Each conversation owns its run. A tab has at most one live owner, so its
 * single stop control always stops the conversation that is driving it.
 */
export function createRunRegistry(deps: RunRegistryDeps) {
  const runs = new Map<string, RunState>()

  function publish(state: RunState): void {
    runs.set(state.runId, state)
    deps.emit(state)
  }

  function assertTabAvailable(tabId: string, runId?: string): void {
    if (tabId === '') return
    if ([...runs.values()].some(run => run.tabId === tabId && run.runId !== runId && (run.status === 'running' || run.status === 'waiting'))) {
      throw new Error('다른 대화가 이 탭을 사용하고 있어요. 해당 작업을 끝내거나 중지한 뒤 다시 시도하세요.')
    }
  }

  return {
    start(courseId: string, tabId: string, action: string, url: string): RunState {
      assertTabAvailable(tabId)
      const state: RunState = {
        runId: randomUUID(),
        courseId,
        tabId,
        status: 'running',
        action,
        url
      }
      publish(state)
      return state
    },

    /** Updates the line the student is reading. */
    step(runId: string, action: string, url?: string): void {
      const current = runs.get(runId)
      if (current === undefined || current.status !== 'running') return
      publish({ ...current, action, ...(url === undefined ? {} : { url }) })
    },

    /** Marks a run as waiting on the student (handoff). */
    wait(runId: string, action: string): void {
      const current = runs.get(runId)
      if (current === undefined || current.status === 'stopped' || current.status === 'done') return
      publish({ ...current, status: 'waiting', action })
    },

    resume(runId: string): void {
      const current = runs.get(runId)
      if (current === undefined || current.status !== 'waiting') return
      publish({ ...current, status: 'running', action: '이어서 진행하는 중' })
    },

    stop(runId: string): void {
      const current = runs.get(runId)
      if (current === undefined) return
      publish({ ...current, status: 'stopped', action: '중지했어요' })
    },

    finish(runId: string): void {
      const current = runs.get(runId)
      if (current === undefined) return
      publish({ ...current, status: 'done', action: '끝났어요' })
      runs.delete(runId)
    },

    /**
     * Throws once the student has stopped the run. Called before every action
     * so 중지 takes effect at the next step rather than "eventually".
     */
    assertLive(runId: string): void {
      const current = runs.get(runId)
      if (current === undefined) return
      if (current.status === 'stopped') throw new RunStopped()
    },

    /** Binds a run to the tab that was opened for it. */
    attachTab(runId: string, tabId: string): void {
      const current = runs.get(runId)
      if (current === undefined || current.tabId === tabId || current.status === 'stopped') return
      assertTabAvailable(tabId, runId)
      if (current.tabId !== '') deps.emit({ ...current, status: 'done', action: '' })
      publish({ ...current, tabId })
    },

    all(): RunState[] {
      return [...runs.values()]
    },

    get(runId: string): RunState | null {
      return runs.get(runId) ?? null
    },

    forCourse(courseId: string): RunState | null {
      for (const state of runs.values()) {
        if (state.courseId === courseId && state.status !== 'done') return state
      }
      return null
    },

    /** Ends everything, so no strip outlives the app. */
    disposeAll(): void {
      for (const [runId, state] of runs) {
        publish({ ...state, status: 'done', action: '' })
        runs.delete(runId)
      }
    },

    /** Ends every run for a course — used when its chat session goes away. */
    disposeCourse(courseId: string): void {
      for (const [runId, state] of runs) {
        if (state.courseId === courseId) {
          publish({ ...state, status: 'done', action: '' })
          runs.delete(runId)
        }
      }
    }
  }
}

/** A stopped or completed turn cannot resume; the next turn gets a new run. */
export function createConversationRunScope(deps: {
  registry: ReturnType<typeof createRunRegistry>
  courseId: string
  getTurnId(): string
}) {
  let turnId: string | null = null
  let runId: string | null = null
  let finished = false
  const finish = (): void => {
    if (turnId === null) turnId = deps.getTurnId()
    finished = true
    if (runId !== null) deps.registry.finish(runId)
  }
  const assertLive = (tabId?: string): void => {
    const nextTurn = deps.getTurnId()
    if (turnId !== nextTurn) {
      finish()
      turnId = nextTurn
      runId = null
      finished = false
    }
    if (finished) throw new RunStopped()
    if (runId === null) runId = deps.registry.start(deps.courseId, tabId ?? '', '페이지를 살펴보는 중', '').runId
    deps.registry.assertLive(runId)
    if (tabId) deps.registry.attachTab(runId, tabId)
  }
  return {
    assertLive,
    current: (): RunState | null => turnId === deps.getTurnId() && runId !== null ? deps.registry.get(runId) : null,
    step(action: string, url?: string): void {
      assertLive()
      deps.registry.step(runId!, action, url)
    },
    wait(message: string): void {
      assertLive()
      deps.registry.wait(runId!, message)
    },
    finish
  }
}
