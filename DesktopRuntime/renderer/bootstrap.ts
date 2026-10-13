import { installNativeBridge } from './bridge'
import { installFileInputAdapter } from './fileInput'
import { installPencilNavigation } from './pencil/navigation'
import { installNativeLifecycle } from './lifecycle'

// Diagnostics are added only when startup fails; product markup and CSS are
// entirely the original desktop renderer loaded below.
function showFailure(reason: unknown): void {
  const text = reason instanceof Error ? reason.message : String(reason ?? 'Unknown error')
  let panel = document.getElementById('bandal-native-diagnostic')
  if (!panel) {
    panel = document.createElement('section')
    panel.id = 'bandal-native-diagnostic'
    panel.setAttribute('role', 'alert')
    Object.assign(panel.style, { position: 'fixed', inset: '16px 16px auto', zIndex: '2147483647', padding: '20px', background: '#fff5f4', color: '#541815', border: '1px solid #d49690', borderRadius: '12px', font: '15px/1.5 system-ui', whiteSpace: 'pre-wrap', maxHeight: '60vh', overflow: 'auto' })
    document.body.append(panel)
  }
  panel.textContent = `반달 실행 연결을 확인해 주세요.\n\n${text}\n\n앱을 다시 열어도 계속되면 이 내용을 진단 기록과 함께 확인해 주세요.`
  void window.webkit?.messageHandlers?.bandal?.postMessage({ channel: 'runtime:diagnostic', request: { message: text.slice(0, 8192) } }).catch(() => undefined)
}
window.addEventListener('error', event => showFailure(event.error ?? event.message))
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
  installFileInputAdapter(showFailure)
  installPencilNavigation()
  installNativeLifecycle()
  // Stores subscribe during module evaluation. No product module may be
  // statically imported before this bridge exists.
  void import('../upstream/src/renderer/src/main').catch(showFailure)
} catch (error) { showFailure(error) }
