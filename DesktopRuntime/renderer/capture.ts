import { installNativeBridge } from './bridge'
installNativeBridge()
// Input-only adaptation: the original selection surface owns a finger or
// Pencil drag, instead of letting WebKit turn it into viewport panning.
const input = document.createElement('style')
input.textContent = '.screen-selection { touch-action: none; }'
document.head.append(input)
void import('../upstream/src/renderer/src/overlay-main').catch(error => {
  const target = document.getElementById('root')
  if (target) { target.setAttribute('role', 'alert'); target.textContent = `화면 선택기를 열지 못했습니다. ${String(error)}` }
})
