// Full alpha-mask comparisons catch coverage seams that centerline checks miss.
import { LiveInkPreview } from './livePreview'
import { strokePathV5, predictionPolygonsV5, strokeSegmentsV5, segmentPolygonsV5, diameterFactorsV5 } from '../../upstream/src/shared/inkV5'
import type { InkVertex } from '../../upstream/src/shared/inkV2'
import type { DrawingPoint } from '../../upstream/src/shared/types/drawing'
const NS = 'http://www.w3.org/2000/svg'
const polygonPath = (polygons: Iterable<InkVertex[]>): string => [...polygons].map(polygon => polygon.map(([x, y], i) => `${i === 0 ? 'M' : 'L'} ${x} ${y}`).join(' ') + ' Z').join(' ')

function surface(scale: number): SVGSVGElement {
  const svg = document.createElementNS(NS, 'svg')
  svg.setAttribute('xmlns', NS)
  svg.setAttribute('width', String(600 * scale)); svg.setAttribute('height', String(900 * scale))
  svg.setAttribute('viewBox', '0 0 1 1'); svg.setAttribute('preserveAspectRatio', 'none')
  return svg
}
async function alpha(svg: SVGSVGElement): Promise<Uint8ClampedArray> {
  const image = new Image()
  image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(new XMLSerializer().serializeToString(svg))
  await image.decode()
  const canvas = document.createElement('canvas')
  canvas.width = Number(svg.getAttribute('width')); canvas.height = Number(svg.getAttribute('height'))
  const context = canvas.getContext('2d')!
  context.drawImage(image, 0, 0)
  const rgba = context.getImageData(0, 0, canvas.width, canvas.height).data
  return rgba.filter((_, i) => i % 4 === 3)
}
function difference(a: Uint8ClampedArray, b: Uint8ClampedArray): { maximum: number; pixels: number } {
  let maximum = 0, pixels = 0
  for (let i = 0; i < a.length; i++) {
    const diff = Math.abs(a[i]! - b[i]!)
    maximum = Math.max(maximum, diff)
    if (diff) pixels++
  }
  return { maximum, pixels }
}

export async function verifyPreviewCoverage(): Promise<string> {
  let comparisons = 0, negativeMaximum = 0
  for (const highlighter of [false, true]) for (const scale of [1, 2]) for (const crossing of [false, true]) {
    const all: DrawingPoint[] = Array.from({ length: 110 }, (_, i) => ({
      x: crossing ? 0.5 + Math.sin(i / 8) * 0.3 : 0.05 + i * 0.008,
      y: crossing ? 0.5 + Math.cos(i / 11) * 0.14 : 0.4 + Math.sin(i / 7) * 0.08,
      p: (i % 12) / 11, t: i * 4
    }))
    const width = highlighter ? 0.025 : 0.009, opacity = highlighter ? 0.3 : 1
    const actual = surface(scale), host = document.createElementNS(NS, 'g')
    actual.append(host)
    const preview = new LiveInkPreview(), points: DrawingPoint[] = []
    for (const point of all.slice(0, -4)) {
      points.push(point)
      preview.render(host, points, { color: 'ink', width, opacity }, 1.5, highlighter, '#000')
    }
    const predicted = all.slice(-4).map((point, i) => ({ ...point, p: i % 2 }))
    for (const tail of [[], predicted, []]) {
      preview.render(host, points, { color: 'ink', width, opacity }, 1.5, highlighter, '#000', tail)
      const canonical = surface(scale), path = document.createElementNS(NS, 'path')
      const tailPath = polygonPath(predictionPolygonsV5(points, tail, width, 1.5, highlighter))
      path.setAttribute('d', strokePathV5(points, width, 1.5, highlighter) + (tailPath ? ' ' + tailPath : ''))
      path.setAttribute('fill', '#000'); path.setAttribute('opacity', String(opacity)); canonical.append(path)
      const [reference, rendered] = await Promise.all([alpha(canonical), alpha(actual)])
      const diff = difference(reference, rendered)
      if (diff.maximum !== 0) throw new Error(`Preview alpha coverage differs: ${JSON.stringify({ highlighter, scale, crossing, predicted: tail.length, ...diff })}`)
      comparisons++
      // Negative control: these independently rasterized chunks used to pass
      // centerline checks. Full alpha masks must detect their boundary seams.
      if (!crossing && !tail.length) {
        const separate = surface(scale), group = document.createElementNS(NS, 'g')
        group.setAttribute('fill', '#000'); group.setAttribute('opacity', String(opacity)); separate.append(group)
        const first = points[0]!
        let chunk = document.createElementNS(NS, 'path')
        let chunkData = polygonPath(segmentPolygonsV5([{x:first.x,y:first.y,factor:diameterFactorsV5(points,width,1.5,highlighter)[0]!}], width, 1.5))
        group.append(chunk)
        for (const { index, samples } of strokeSegmentsV5(points, width, 1.5, highlighter)) {
          if (index && index % 32 === 0) {
            chunk.setAttribute('d', chunkData); chunk = document.createElementNS(NS, 'path')
            group.append(chunk); chunkData = ''
          }
          const addition = polygonPath(segmentPolygonsV5(samples, width, 1.5, false))
          chunkData += (chunkData ? ' ' : '') + addition
        }
        chunk.setAttribute('d', chunkData)
        negativeMaximum = Math.max(negativeMaximum, difference(reference, await alpha(separate)).maximum)
      }
    }
  }
  if (negativeMaximum < 10) throw new Error('Alpha coverage regression did not detect the independently filled chunk seams')
  return `WebKit alpha masks: ${comparisons} pen/highlighter curved/crossing/predicted/replaced cases at 1×/2× exactly equal canonical ink; old separate-fill negative control max error ${negativeMaximum}/255`
}
