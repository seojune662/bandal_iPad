const PDF_JUMP_RETRY_MS = 50
const PDF_JUMP_MAX_ATTEMPTS = 200
let pendingJumpTimer: number | null = null

function activePdfPanel(): HTMLElement | null {
  const active = document.querySelector<HTMLElement>(
    '.dv-active-group .workspace-panel.pdf-panel'
  )
  if (active !== null) return active

  const panels = [
    ...document.querySelectorAll<HTMLElement>('.workspace-panel.pdf-panel')
  ]
  return panels.find((panel) => panel.getClientRects().length > 0) ?? panels[0] ?? null
}

/** Same scroller-relative positioning used by PdfTab's toolbar/rail jumps. */
export function jumpToPdfPageInPanel(panel: HTMLElement, page: number): boolean {
  const pageElement = panel.querySelector<HTMLElement>(
    `.pdf-page[data-pdf-page="${page}"]`
  )
  const scroller = pageElement?.closest<HTMLElement>('.pdf-scroller') ?? null
  if (pageElement === null || scroller === null) return false

  const scrollerBox = scroller.getBoundingClientRect()
  const pageBox = pageElement.getBoundingClientRect()
  scroller.scrollTop = pageBox.top - scrollerBox.top + scroller.scrollTop - 12
  return true
}

/** Waits for a newly opened/activated PDF panel to finish creating page boxes. */
export function requestPdfPageJump(page: number): void {
  if (pendingJumpTimer !== null) window.clearTimeout(pendingJumpTimer)
  let attempts = 0

  const tryJump = (): void => {
    attempts += 1
    const panel = activePdfPanel()
    if (panel !== null && jumpToPdfPageInPanel(panel, page)) {
      pendingJumpTimer = null
      return
    }
    if (attempts >= PDF_JUMP_MAX_ATTEMPTS) {
      pendingJumpTimer = null
      return
    }
    pendingJumpTimer = window.setTimeout(tryJump, PDF_JUMP_RETRY_MS)
  }

  tryJump()
}
