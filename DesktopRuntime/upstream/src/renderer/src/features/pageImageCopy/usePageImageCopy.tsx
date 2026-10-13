import { useCallback, useLayoutEffect, useRef, useState, type MouseEvent } from 'react'
import { showToast } from '../../app/toast'
import { PageImageContextMenu } from './PageImageContextMenu'
import { copyPageImage, type PageImageTarget } from './pageImage'

export function usePageImageCopy(documentIdentity: unknown): {
  openMenu: (event: MouseEvent<HTMLElement>, target: Omit<PageImageTarget, 'node'>) => void
  overlay: JSX.Element
} {
  const [menu, setMenu] = useState<(PageImageTarget & { x: number; y: number }) | null>(null)
  const [copying, setCopying] = useState<string | null>(null)
  const job = useRef<AbortController | null>(null)
  useLayoutEffect(() => {
    setMenu(null)
    setCopying(null)
    return () => { job.current?.abort(); job.current = null }
  }, [documentIdentity])
  const close = useCallback((restoreFocus = true): void => {
    if (restoreFocus && menu?.node.isConnected) menu.node.focus({ preventScroll: true })
    setMenu(null)
  }, [menu])
  const openMenu = useCallback((event: MouseEvent<HTMLElement>, target: Omit<PageImageTarget, 'node'>): void => {
    const origin = event.target
    if (origin instanceof Element && (origin.closest('input,textarea,[contenteditable]:not([contenteditable="false"])') || (origin instanceof HTMLElement && origin.isContentEditable))) return
    event.preventDefault()
    event.stopPropagation()
    if (job.current) return
    const bounds = event.currentTarget.getBoundingClientRect()
    setMenu({ ...target, node: event.currentTarget, x: event.clientX || Math.max(8, bounds.left + 24), y: event.clientY || Math.max(8, bounds.top + 24) })
  }, [])
  const copy = async (includeInk: boolean): Promise<void> => {
    if (!menu || job.current) return
    const abort = new AbortController()
    job.current = abort
    setCopying(menu.label)
    const pending = copyPageImage(menu, includeInk, abort.signal)
    close()
    try {
      await pending
      if (!abort.signal.aborted) showToast(`${menu.label}를 이미지로 복사했어요.`)
    } catch (cause) {
      if (!abort.signal.aborted) {
        console.error('[Bandal] 페이지 이미지 복사 실패', cause)
        showToast(cause instanceof Error ? cause.message : '이미지를 복사하지 못했어요. 다시 시도해 주세요.', 'danger')
      }
    } finally {
      abort.abort()
      if (job.current === abort) { job.current = null; setCopying(null) }
    }
  }
  return { openMenu, overlay: <>
    {menu && <PageImageContextMenu {...menu} onCopy={(ink) => void copy(ink)} onClose={close} />}
    {copying && <span className="page-image-copy-status" role="status" aria-live="polite">{copying} 이미지를 복사하는 중…</span>}
  </> }
}
