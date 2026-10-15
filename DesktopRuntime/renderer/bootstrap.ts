import { installNativeBridge } from './bridge'
import { installFileInputAdapter } from './fileInput'
import { installPencilNavigation } from './pencil/navigation'
import { installScribblePolicy } from './pencil/scribble'
import { installNativeLifecycle } from './lifecycle'
import { installNativeKeyboardCompatibility } from './keyboard'
import { rendererDiagnostic, type DiagnosticSource } from './diagnostics'
import { BandalOperationError, installBackendOperationErrors, reportOperationError, type OperationFailure } from './ipad/stability/operations'
import { installOperationNotices, showOperationNotice, showStartupFailure } from './ipad/stability/recovery'
import { flushNativeSurfaceLayout } from './ipad/nativeSurfaces'

function showFailure(reason: unknown, source?: DiagnosticSource): void {
  if (document.getElementById('root')?.childElementCount) showOperationNotice({ reason })
  else showStartupFailure(reason)
  void window.webkit?.messageHandlers?.bandal?.postMessage({ channel: 'runtime:diagnostic', request: rendererDiagnostic(reason, source) }).catch(() => undefined)
}
installOperationNotices()
window.addEventListener('error', event => showFailure(event.error ?? event.message, { filename: event.filename, lineno: event.lineno, colno: event.colno }))
window.addEventListener('unhandledrejection', event => showFailure(event.reason))
if (!window.requestIdleCallback) {
  window.requestIdleCallback = callback => window.setTimeout(() => callback({ didTimeout: false, timeRemaining: () => 15 }), 1)
  window.cancelIdleCallback = window.clearTimeout
}
// WebKit's custom app origin can omit secure-context randomUUID. Preserve
// cryptographic UUID generation using getRandomValues; never use Math.random.
if (!crypto.randomUUID && crypto.getRandomValues) {
  Object.defineProperty(crypto, 'randomUUID', { value: () => {
    const bytes = crypto.getRandomValues(new Uint8Array(16))
    bytes[6] = (bytes[6]! & 0x0f) | 0x40
    bytes[8] = (bytes[8]! & 0x3f) | 0x80
    const hex = Array.from(bytes, value => value.toString(16).padStart(2, '0')).join('')
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  } })
}
try {
  installNativeBridge()
  installBackendOperationErrors()
  ;(window.bandal.on as (channel: string, listener: (payload: unknown) => void) => () => void)('runtime:operationError', payload => {
    reportOperationError(new BandalOperationError(payload as OperationFailure))
  })
  void flushNativeSurfaceLayout().catch(error => reportOperationError(error, { operation: '화면 표시 갱신' }))
  installNativeKeyboardCompatibility(window, () => {
    void window.webkit?.messageHandlers?.bandal?.postMessage({ channel: 'runtime:inputDiagnostic', request: { event: 'keyboard.missing-key' } }).catch(() => undefined)
  })
  installFileInputAdapter(reason => reportOperationError(reason, { operation: '파일 가져오기' }))
  installPencilNavigation()
  installScribblePolicy()
  installNativeLifecycle()
  // Stores subscribe during module evaluation. No product module may be
  // statically imported before this bridge exists.
  void (window.bandal.invoke as (channel: string, request: unknown) => Promise<unknown>)('runtime:rendererReady', {})
    .then(() => import('../upstream/src/renderer/src/main')).catch(showFailure)
} catch (error) { showFailure(error) }
