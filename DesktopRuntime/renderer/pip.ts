import { installNativeBridge } from './bridge'
installNativeBridge()
// Electron's window drag CSS has no effect on iPad. Keep the exact original
// controls and send header movement through the existing PiP contract.
let drag: { id: number; x: number; y: number; target: HTMLElement } | undefined
document.addEventListener('pointerdown', event => {
  if (!(event.target instanceof Element) || event.target.closest('button,input,select')) return
  const header = event.target.closest<HTMLElement>('.pip-player__header')
  if (!header || event.button !== 0) return
  drag = { id: event.pointerId, x: event.screenX, y: event.screenY, target: header }
  header.setPointerCapture(event.pointerId); event.preventDefault()
})
document.addEventListener('pointermove', event => {
  if (!drag || drag.id !== event.pointerId) return
  const dx = event.screenX - drag.x, dy = event.screenY - drag.y
  drag.x = event.screenX; drag.y = event.screenY
  void window.bandal.invoke('pip:moveBy', { dx, dy }).catch(() => undefined)
})
for (const type of ['pointerup', 'pointercancel'] as const) document.addEventListener(type, event => {
  if (!drag || drag.id !== event.pointerId) return
  if (drag.target.hasPointerCapture(event.pointerId)) drag.target.releasePointerCapture(event.pointerId)
  drag = undefined
})
void import('../upstream/src/renderer/src/pip-main').catch(error => {
  const target = document.getElementById('root')
  if (target) { target.setAttribute('role', 'alert'); target.textContent = `영상 플레이어를 열지 못했습니다. ${String(error)}` }
})
