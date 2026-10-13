/**
 * One print job at a time.
 *
 * Rendering a page to PDF is slow enough to see, so the overlay opens
 * immediately in `rendering` and fills in. Changing paper size or orientation
 * re-renders, the way Chrome's preview does — which is why the prefs live
 * here beside the job rather than in the component.
 *
 * Session-scoped on purpose: 고지서 are A4 and lecture slides are landscape,
 * and persisting whichever came last would be wrong for the next one.
 */

import { create } from 'zustand'
import { invoke } from '../../lib/ipc'
import { guestActions } from '../browser/guestActions'
import type { PrintTarget } from './printTarget'

export interface PrintPrefs {
  pageSize: 'A4' | 'Letter'
  landscape: boolean
  printBackground: boolean
}

export const DEFAULT_PRINT_PREFS: PrintPrefs = {
  pageSize: 'A4',
  landscape: false,
  printBackground: true
}

export type PrintPhase =
  | { status: 'rendering' }
  | { status: 'ready'; base64: string }
  | { status: 'error'; message: string }

interface PrintStoreState {
  target: PrintTarget | null
  title: string
  phase: PrintPhase
  prefs: PrintPrefs
  open: (target: PrintTarget, title: string) => void
  setPrefs: (patch: Partial<PrintPrefs>) => void
  close: () => void
}

function toBase64(bytes: Uint8Array): string {
  let binary = ''
  // Chunked: a 30MB PDF spread over one apply() call blows the argument limit.
  const CHUNK = 0x8000
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + CHUNK))
  }
  return btoa(binary)
}

async function renderBrowserTab(
  tabId: string,
  prefs: PrintPrefs
): Promise<string> {
  // printToPDF does not rasterize plugin content, so a tab whose top-level
  // document IS a PDF would come out blank. Fetch the original bytes instead.
  const contentType = await guestActions.contentType(tabId)
  if (contentType === 'application/pdf') {
    const url = guestActions.currentUrl(tabId)
    if (url === null) throw new Error('이 탭을 인쇄할 수 없어요.')
    const result = await invoke('print:pdfFromUrl', { url, tabId })
    return result.base64
  }
  const bytes = await guestActions.printToPdf(tabId, {
    pageSize: prefs.pageSize,
    landscape: prefs.landscape,
    printBackground: prefs.printBackground,
    preferCSSPageSize: true,
    displayHeaderFooter: false,
    scale: 1,
    margins: { marginType: 'default' }
  })
  return toBase64(bytes)
}

async function renderPdfMaterial(
  courseId: string,
  relPath: string
): Promise<string> {
  const content = await invoke('materials:readFile', { courseId, relPath })
  if (content.encoding !== 'base64') {
    throw new Error('PDF 파일이 아니거나 손상된 파일이에요.')
  }
  return content.data
}

/** Increments per open so a slow render cannot land on a newer job. */
let generation = 0

export const usePrintStore = create<PrintStoreState>()((set, get) => ({
  target: null,
  title: '',
  phase: { status: 'rendering' },
  prefs: DEFAULT_PRINT_PREFS,

  open: (target, title) => {
    set({ target, title, phase: { status: 'rendering' } })
    void render(get, set)
  },

  setPrefs: (patch) => {
    set({ prefs: { ...get().prefs, ...patch }, phase: { status: 'rendering' } })
    void render(get, set)
  },

  close: () => {
    generation += 1
    set({ target: null, title: '', phase: { status: 'rendering' } })
  }
}))

async function render(
  get: () => PrintStoreState,
  set: (partial: Partial<PrintStoreState>) => void
): Promise<void> {
  generation += 1
  const mine = generation
  const { target, prefs } = get()
  if (target === null) return
  try {
    const base64 =
      target.kind === 'browser'
        ? await renderBrowserTab(target.tabId, prefs)
        : await renderPdfMaterial(target.courseId, target.relPath)
    if (mine !== generation) return
    set({ phase: { status: 'ready', base64 } })
  } catch (error) {
    if (mine !== generation) return
    set({
      phase: {
        status: 'error',
        message:
          error instanceof Error ? error.message : '인쇄할 내용을 만들지 못했어요.'
      }
    })
  }
}
