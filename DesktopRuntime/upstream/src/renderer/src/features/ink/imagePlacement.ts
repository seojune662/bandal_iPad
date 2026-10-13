import type { DrawingBox, DrawingPoint } from '../../../../shared/types/drawing'

const MAX_IMAGE_WIDTH = 0.4
const MAX_IMAGE_HEIGHT = 0.4

function finitePositive(value: number): boolean {
  return Number.isFinite(value) && value > 0
}

/** Fits an image around a normalized point while preserving its screen ratio. */
export function imageBoxAtPoint(
  point: Pick<DrawingPoint, 'x' | 'y'>,
  surfaceAspect: number,
  imageAspect: number
): DrawingBox {
  const safeSurfaceAspect = finitePositive(surfaceAspect) ? surfaceAspect : 1
  const safeImageAspect = finitePositive(imageAspect) ? imageAspect : 1
  const width = Math.min(
    MAX_IMAGE_WIDTH,
    MAX_IMAGE_HEIGHT * safeSurfaceAspect / safeImageAspect
  )
  const height = width * safeImageAspect / safeSurfaceAspect
  const x = Math.min(1 - width, Math.max(0, point.x - width / 2))
  const y = Math.min(1 - height, Math.max(0, point.y - height / 2))
  return { x, y, width, height }
}

/** healedImageBox 의 무한 루프 차단 게이트 — 이 오차 안이면 손대지 않는다. */
const ASPECT_TOLERANCE = 0.01

/**
 * box 의 화면 비율이 이미지 원본 비율과 다르면(로드 실패 시 `?? 1` 폴백으로
 * 정사각형으로 굳은 셰이프) 폭을 유지한 채 높이를 원본 비율로 되돌린 box 를
 * 돌려준다. 1% 이내로 이미 맞으면 null — 보정 결과를 재입력해도 null 이라
 * 업데이트 루프가 돌 수 없다.
 */
export function healedImageBox(
  box: DrawingBox,
  surfaceAspect: number,
  imageAspect: number
): DrawingBox | null {
  if (!finitePositive(surfaceAspect) || !finitePositive(imageAspect)) return null
  if (!finitePositive(box.width) || !finitePositive(box.height)) return null

  const currentAspect = (box.height * surfaceAspect) / box.width
  if (Math.abs(currentAspect - imageAspect) / imageAspect <= ASPECT_TOLERANCE) {
    return null
  }

  let width = box.width
  let height = (width * imageAspect) / surfaceAspect
  if (height > 1) {
    width = width / height
    height = 1
  }
  const centerY = box.y + box.height / 2
  const x = Math.max(0, Math.min(1 - width, box.x))
  const y = Math.max(0, Math.min(1 - height, centerY - height / 2))
  return { x, y, width, height }
}

export function dataUrlImageAspect(dataUrl: string): Promise<number | null> {
  return new Promise((resolve) => {
    const image = new Image()
    image.onload = () => resolve(
      image.naturalWidth > 0 && image.naturalHeight > 0
        ? image.naturalHeight / image.naturalWidth
        : null
    )
    image.onerror = () => resolve(null)
    image.src = dataUrl
  })
}
