import { useEffect, useRef } from 'react'
import { MOON_SHAPES, MOON_VIEWBOX, MOON_LOOP_MS, MOON_INTRO_MS, moonPose, moonTransform } from '../../../shared/brandMark'

interface BandalMarkProps {
  size?: number
  className?: string
  title?: string
  motion?: 'idle' | 'loop' | 'intro' | 'periodic'
}

// Two seconds of movement, then six seconds at rest. No animation frames run
// during the pause, when offscreen, or while reduced motion is requested.
export const MARK_REST_MS = 6000

export function BandalMark({ size = 18, className, title, motion = size >= 48 ? 'periodic' : 'idle' }: BandalMarkProps): JSX.Element {
  const svg = useRef<SVGSVGElement>(null)
  useEffect(() => {
    const element = svg.current
    if (!element) return
    const paths = element.querySelectorAll('path')
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)')
    let frame = 0, timer = 0, elapsed = 0, last: number | null = null, inView = true, finished = false
    const paint = (progress: number): void => {
      const pose = moonPose(progress)
      paths.forEach((path, i) => path.setAttribute('transform', moonTransform(i, pose[i])))
    }
    const stop = (): void => {
      cancelAnimationFrame(frame); window.clearTimeout(timer)
      frame = 0; timer = 0; elapsed = 0; last = null
      paint(0)
    }
    const allowed = (): boolean => motion !== 'idle' && !document.hidden && inView && !reduced.matches && !finished
    const start = (): void => {
      if (!allowed()) { stop(); return }
      if (!frame && !timer) frame = requestAnimationFrame(tick)
    }
    const tick = (now: number): void => {
      frame = 0
      if (!allowed()) { stop(); return }
      if (last !== null) elapsed += Math.min(now - last, 100)
      last = now
      const duration = motion === 'loop' ? MOON_LOOP_MS : MOON_INTRO_MS
      if (elapsed >= duration && motion !== 'loop') {
        paint(0); elapsed = 0; last = null
        if (motion === 'intro') finished = true
        else timer = window.setTimeout(() => { timer = 0; start() }, MARK_REST_MS)
        return
      }
      elapsed %= duration
      let progress = elapsed / duration
      if (motion !== 'loop') progress = progress ** 3 * (progress * (progress * 6 - 15) + 10)
      paint(progress)
      frame = requestAnimationFrame(tick)
    }
    const observer = new IntersectionObserver(([entry]) => { inView = entry?.isIntersecting ?? false; start() })
    observer.observe(element)
    document.addEventListener('visibilitychange', start)
    reduced.addEventListener('change', start)
    start()
    return () => { stop(); observer.disconnect(); document.removeEventListener('visibilitychange', start); reduced.removeEventListener('change', start) }
  }, [motion])
  return <svg ref={svg} width={size} height={size} viewBox={MOON_VIEWBOX} className={className} data-motion={motion} role={title ? 'img' : undefined} aria-hidden={title ? undefined : true} focusable="false" fill="currentColor">
    {title && <title>{title}</title>}
    {MOON_SHAPES.map((shape, i) => <path key={shape.name} d={shape.path} transform={moonTransform(i)} />)}
  </svg>
}
