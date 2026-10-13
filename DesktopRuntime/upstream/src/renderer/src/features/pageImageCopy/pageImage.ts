import { captureInkSnapshot } from '../ink/renderInkSnapshot'

export interface RenderedPageImage {
  canvas: HTMLCanvasElement
  /** Only release canvases owned by this render, never a viewer's cache. */
  release?: () => void
}

export interface PageImageTarget {
  node: HTMLElement
  label: string
  render?: ((signal: AbortSignal) => Promise<RenderedPageImage>) | undefined
  disabledReason?: string | undefined
  inkDisabledReason?: string | undefined
}

export function pageImageSize(width: number, height: number): { width: number; height: number } {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    throw new Error('페이지 크기를 읽지 못했어요. 자료를 다시 열어 주세요.')
  }
  const scale = Math.min(1600 / width, 4096 / Math.max(width, height))
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

/** Snapshot is captured synchronously, before closing the menu can commit text. */
export async function copyPageImage(target: PageImageTarget, includeInk: boolean, signal: AbortSignal): Promise<void> {
  signal.throwIfAborted()
  if (!target.render || target.disabledReason || (includeInk && target.inkDisabledReason)) {
    throw new Error(target.disabledReason ?? target.inkDisabledReason ?? '이 미리보기에서는 이미지 복사를 지원하지 않아요.')
  }
  if (!target.node.isConnected) throw new Error('페이지를 다시 선택해 주세요.')
  const snapshot = includeInk ? captureInkSnapshot(target.node) : null
  const canvas = document.createElement('canvas')
  let rendered: RenderedPageImage | undefined
  let image: HTMLImageElement | undefined
  try {
    try {
      rendered = await target.render(signal)
    } catch (cause) {
      signal.throwIfAborted()
      throw new Error('페이지를 이미지로 만들지 못했어요. 자료를 다시 열고 시도해 주세요.', { cause })
    }
    signal.throwIfAborted()
    const size = pageImageSize(rendered.canvas.width, rendered.canvas.height)
    canvas.width = size.width
    canvas.height = size.height
    const context = canvas.getContext('2d')
    if (!context) throw new Error('이미지를 만들지 못했어요. 다시 시도해 주세요.')
    context.fillStyle = 'white'
    context.fillRect(0, 0, canvas.width, canvas.height)
    context.drawImage(rendered.canvas, 0, 0, canvas.width, canvas.height)
    if (snapshot) {
      try {
        image = await snapshot(canvas, signal)
      } catch (cause) {
        signal.throwIfAborted()
        throw new Error('필기를 이미지로 만들지 못했어요. 자료를 다시 열고 시도해 주세요.', { cause })
      }
      signal.throwIfAborted()
      context.drawImage(image, 0, 0, canvas.width, canvas.height)
    }
    const blob = await new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((value) => value ? resolve(value) : reject(new Error('이미지를 만들지 못했어요. 다시 시도해 주세요.')), 'image/png')
    })
    signal.throwIfAborted()
    if (!navigator.clipboard?.write || typeof ClipboardItem === 'undefined') {
      throw new Error('클립보드를 사용할 수 없어요. 앱을 다시 열어 주세요.')
    }
    try {
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })])
    } catch {
      throw new Error('클립보드에 복사하지 못했어요. 앱을 활성화하고 다시 시도해 주세요.')
    }
  } finally {
    image?.removeAttribute('src')
    canvas.width = canvas.height = 0
    rendered?.release?.()
  }
}
