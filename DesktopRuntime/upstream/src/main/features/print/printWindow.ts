/**
 * Printing the bytes the student just looked at.
 *
 * The obvious implementation — call `webContents.print()` on the guest — is
 * wrong twice over:
 *
 *  1. **It prints something else.** `printToPDF` (Chromium's
 *     `Page.printToPDF`) and the platform print job are different pipelines
 *     that disagree on pagination and scaling, so the paper would not match
 *     the preview. Printing the previewed PDF is byte-exact by construction.
 *  2. **It re-enters the "only works once" family** (electron#21195, #14705,
 *     #16219) — every one of those is about repeated prints on the SAME
 *     WebContents. A window created per job and destroyed afterwards can
 *     never reach a second call.
 *
 * Two things about the window matter. It must be VISIBLE before `print()`:
 * on macOS the print panel is a sheet on the owning NSWindow, and a sheet on
 * a hidden window is an invisible dialog with a hung-looking app. And it needs
 * `plugins: true`, or it has no PDF viewer to print from.
 */

import { randomUUID } from 'node:crypto'
import { mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { app, BrowserWindow } from 'electron'

export interface PrintPdfInput {
  bytes: Buffer
  /** Shown as the window title, so the print panel names the job. */
  jobName: string
  parent: BrowserWindow | null
}

export async function printPdfBytes(
  input: PrintPdfInput
): Promise<{ printed: boolean }> {
  const dir = join(app.getPath('temp'), 'bandal-print', randomUUID())
  mkdirSync(dir, { recursive: true })
  const file = join(dir, 'print.pdf')
  writeFileSync(file, input.bytes)

  const cleanup = (): void => {
    try {
      rmSync(dir, { recursive: true, force: true })
    } catch {
      // A temp directory we could not remove is not worth failing a print for.
    }
  }

  const win = new BrowserWindow({
    show: false,
    width: 820,
    height: 1000,
    title: input.jobName,
    ...(input.parent === null ? {} : { parent: input.parent }),
    webPreferences: {
      // NOT the browsing partition: this is our own document, and it must not
      // be able to touch the student's portal cookies.
      partition: 'print-preview',
      plugins: true,
      sandbox: true,
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true,
      webviewTag: false
    }
  })

  return new Promise<{ printed: boolean }>((resolve) => {
    let settled = false
    const finish = (printed: boolean): void => {
      if (settled) return
      settled = true
      resolve({ printed })
      if (!win.isDestroyed()) win.close()
    }

    win.once('closed', () => {
      cleanup()
      finish(false)
    })
    win.once('ready-to-show', () => {
      win.show()
      try {
        win.webContents.print(
          { silent: false, printBackground: true, margins: { marginType: 'none' } },
          (success) => finish(success)
        )
      } catch {
        finish(false)
      }
    })
    win.webContents.once('render-process-gone', () => finish(false))
    void win.loadFile(file).catch(() => finish(false))
  })
}
