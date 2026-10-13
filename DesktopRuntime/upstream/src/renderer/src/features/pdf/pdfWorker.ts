/**
 * pdf.js worker wiring for electron-vite.
 *
 * `?url` makes Vite emit the worker file as an asset and hand us its URL —
 * dev server serves it from node_modules, production build copies it into
 * the renderer output. `pdfjs-dist` is a direct dependency pinned to the
 * exact version react-pdf resolves (5.4.296) so the API and worker versions
 * always match (mismatch is a hard pdf.js error).
 *
 * Call configurePdfWorker once from the lazy PDF component module before
 * rendering <Document>. The assignment is idempotent.
 */

import { pdfjs } from 'react-pdf'
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'

/**
 * react-pdf also assigns its own fallback worker URL while its module is
 * evaluated. With a lazy PDF chunk that assignment can happen after this
 * helper module's imports have run, so callers configure the worker from
 * their module body once react-pdf has finished initializing.
 */
export function configurePdfWorker(): void {
  if (pdfjs.GlobalWorkerOptions.workerSrc !== workerUrl) {
    pdfjs.GlobalWorkerOptions.workerSrc = workerUrl
  }
}
