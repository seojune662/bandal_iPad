/**
 * What "print this page" means, in numbers.
 *
 * Pure, because two of these defaults differ from Chromium's and both
 * differences are the whole point on a Korean 고지서.
 *
 * ⚠ `PrintToPDFOptions.margins` and `WebContentsPrintOptions.margins` share
 * the `Margins` TypeScript interface, but their numeric fields are NOT the
 * same unit — `printToPDF` is Chromium's `Page.printToPDF` and takes inches,
 * while `print` takes device units. Never share a numeric margin object
 * between the two; use `marginType` and let the paths diverge.
 */

export interface PrintPrefs {
  pageSize: 'A4' | 'Letter'
  landscape: boolean
  printBackground: boolean
}

export const DEFAULT_PRINT_PREFS: PrintPrefs = {
  // Electron defaults to Letter. Every Korean bill, form and transcript is A4.
  pageSize: 'A4',
  landscape: false,
  // Chrome defaults this off. A 고지서's table rules, shading and seals are
  // all background graphics, so off prints a page of floating numbers.
  printBackground: true
}

/** Anything past this would have to cross IPC as base64. */
export const PRINT_PDF_MAX_BYTES = 32 * 1024 * 1024

export function toPrintToPdfOptions(
  prefs: PrintPrefs
): Record<string, unknown> {
  return {
    pageSize: prefs.pageSize,
    landscape: prefs.landscape,
    printBackground: prefs.printBackground,
    // Korean report viewers almost always set their own @page; honouring it
    // is the difference between a bill that fits and one cut in half.
    preferCSSPageSize: true,
    // No URL and timestamp stamped across a tuition bill.
    displayHeaderFooter: false,
    scale: 1,
    margins: { marginType: 'default' }
  }
}

const UNSAFE_NAME = /[\\/:*?"<>|\x00-\x1f]/g

/** A file name for the saved or printed job, derived from the page title. */
export function printJobFileName(title: string, at: Date): string {
  const cleaned = title.replace(UNSAFE_NAME, ' ').trim().slice(0, 60)
  const stamp = [
    at.getFullYear(),
    String(at.getMonth() + 1).padStart(2, '0'),
    String(at.getDate()).padStart(2, '0')
  ].join('-')
  const base = cleaned === '' ? '인쇄' : cleaned
  return `${base} ${stamp}.pdf`
}
