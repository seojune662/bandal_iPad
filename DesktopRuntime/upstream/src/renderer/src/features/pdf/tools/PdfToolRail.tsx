import { createPortal } from 'react-dom'
import { useDismissableMenu } from '../../../components/useDismissableMenu'
import { useViewportBounds } from '../../../lib/useViewportBounds'
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react'
import type { DrawingColor } from '../../../../../shared/types/drawing'
import { Icon } from '../../../app/icons'
import { invoke } from '../../../lib/ipc'
import { PdfToolIcon } from './pdfToolIcons'
import type { DrawingsApi } from './useDrawings'
import { usePdfToolStore, type PdfDrawingTool } from './toolStore'
import './pdfTools.css'

interface PdfToolRailProps {
  courseId: string
  relPath: string
  drawingsApi: DrawingsApi
  onExport?: () => Promise<void>
  beforeExport?: (() => Promise<void>) | undefined
  expanded?: boolean
  interactive?: boolean
}

interface ToolButton {
  tool: PdfDrawingTool
  label: string
  shortcut?: string
  icon: JSX.Element
}

const TOOLS: readonly ToolButton[] = [
  {
    tool: 'select',
    label: '선택',
    shortcut: 'V',
    icon: <PdfToolIcon name="select" />
  },
  { tool: 'pen', label: '펜', shortcut: 'P', icon: <PdfToolIcon name="pen" /> },
  {
    tool: 'highlighter',
    label: '형광펜',
    shortcut: 'H',
    icon: <PdfToolIcon name="highlighter" />
  },
  {
    tool: 'eraser',
    label: '지우개',
    shortcut: 'E',
    icon: <PdfToolIcon name="eraser" />
  },
  {
    tool: 'text',
    label: '텍스트',
    shortcut: 'T',
    icon: <PdfToolIcon name="text" />
  },
  {
    tool: 'rect',
    label: '사각형',
    shortcut: 'R',
    icon: <PdfToolIcon name="rect" />
  },
  {
    tool: 'ellipse',
    label: '타원',
    shortcut: 'O',
    icon: <PdfToolIcon name="ellipse" />
  },
  { tool: 'arrow', label: '화살표', icon: <PdfToolIcon name="arrow" /> },
  { tool: 'line', label: '직선', icon: <PdfToolIcon name="line" /> }
]

const COLORS: readonly DrawingColor[] = [
  'ink',
  'red',
  'orange',
  'yellow',
  'green',
  'blue',
  'violet'
]

const COLOR_LABELS: Record<DrawingColor, string> = {
  ink: '먹색',
  red: '빨강',
  orange: '주황',
  yellow: '노랑',
  green: '초록',
  blue: '파랑',
  violet: '보라'
}

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  return (
    target.isContentEditable ||
    target.closest('input, textarea, select, [contenteditable="true"]') !== null
  )
}

export function PdfToolRail({
  courseId,
  relPath,
  drawingsApi,
  onExport,
  beforeExport,
  interactive = true,
  expanded = true
}: PdfToolRailProps): JSX.Element {
  const activeTool = usePdfToolStore((state) => state.activeTool)
  const color = usePdfToolStore((state) => state.color)
  const width = usePdfToolStore((state) => state.width)
  const opacity = usePdfToolStore((state) => state.opacity)
  const setActiveTool = usePdfToolStore((state) => state.setActiveTool)
  const setColor = usePdfToolStore((state) => state.setColor)
  const setWidth = usePdfToolStore((state) => state.setWidth)
  const setOpacity = usePdfToolStore((state) => state.setOpacity)
  const [exporting, setExporting] = useState(false)
  const [exportMessage, setExportMessage] = useState<string | null>(null)
  const rootRef = useRef<HTMLDivElement>(null)
  const railRef = useRef<HTMLDivElement>(null)
  const menuRef = useRef<HTMLDivElement>(null)
  const [menu, setMenu] = useState<{
    x: number
    y: number
  } | null>(null)
  const [scroll, setScroll] = useState({
    overflow: false,
    canBack: false,
    canForward: false
  })
  const updateScroll = useCallback(() => {
    const shell = rootRef.current
    const rail = railRef.current
    if (!shell || !rail) return
    const overflow = rail.scrollWidth > shell.clientWidth + 1
    const next = {
      overflow,
      canBack: overflow && rail.scrollLeft > 1,
      canForward:
        overflow && rail.scrollLeft < rail.scrollWidth - rail.clientWidth - 1
    }
    setScroll((current) =>
      current.overflow === next.overflow &&
      current.canBack === next.canBack &&
      current.canForward === next.canForward
        ? current
        : next
    )
  }, [])
  useLayoutEffect(() => {
    const shell = rootRef.current
    const rail = railRef.current
    if (!shell || !rail) return
    updateScroll()
    const observer = new ResizeObserver(updateScroll)
    observer.observe(shell)
    observer.observe(rail)
    for (const child of rail.children) observer.observe(child)
    const wheel = (event: WheelEvent): void => {
      if (event.ctrlKey || rail.scrollWidth <= rail.clientWidth + 1) return
      const delta =
        Math.abs(event.deltaX) > Math.abs(event.deltaY)
          ? event.deltaX
          : event.deltaY
      if (delta === 0) return
      const scale =
        event.deltaMode === 1
          ? 16
          : event.deltaMode === 2
            ? rail.clientWidth
            : 1
      event.preventDefault()
      rail.scrollLeft += delta * scale
      updateScroll()
    }
    rail.addEventListener('wheel', wheel, { passive: false })
    return () => {
      observer.disconnect()
      rail.removeEventListener('wheel', wheel)
    }
  }, [expanded, drawingsApi.error, exportMessage, updateScroll])
  const scrollTools = (direction: -1 | 1): void => {
    const rail = railRef.current
    if (!rail) return
    rail.scrollBy({
      left: direction * Math.max(120, rail.clientWidth * 0.75),
      behavior: 'smooth'
    })
  }
  const closeMenu = useCallback(() => setMenu(null), [])
  useDismissableMenu(menu !== null, menuRef, closeMenu)
  useViewportBounds(menuRef)
  useEffect(() => {
    if (!expanded) closeMenu()
  }, [expanded, closeMenu])
  const openMenu = (button: HTMLButtonElement): void => {
    const rect = button.getBoundingClientRect()
    setMenu((current) => current ? null : { x: rect.left, y: rect.bottom + 6 })
  }

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent): void => {
      if (!interactive || rootRef.current?.closest('.workspace-course[hidden]'))
        return
      if (
        rootRef.current
          ?.closest('.pdf-tab, .presentation-viewer')
          ?.getClientRects().length === 0
      )
        return
      if (
        rootRef.current?.closest('.dv-groupview') &&
        !rootRef.current.closest('.dv-active-group')
      )
        return
      if (isEditableTarget(event.target)) return
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
        event.preventDefault()
        if (event.shiftKey) void drawingsApi.redo()
        else void drawingsApi.undo()
        return
      }
      if (event.metaKey || event.ctrlKey || event.altKey) return
      const tool = TOOLS.find(
        (entry) => entry.shortcut?.toLowerCase() === event.key.toLowerCase()
      )
      if (tool !== undefined) {
        event.preventDefault()
        setActiveTool(tool.tool)
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [drawingsApi, setActiveTool, interactive])

  const exportPdf = async (): Promise<void> => {
    if (exporting) return
    setExporting(true)
    setExportMessage(null)
    try {
      await drawingsApi.flush?.()
      await beforeExport?.()
      if (onExport) {
        await onExport()
        return
      }
      const result = await invoke('pdf:exportAnnotated', { courseId, relPath })
      setExportMessage(
        result.savedPath === null ? null : '주석 포함 PDF를 저장했어요.'
      )
    } catch (error: unknown) {
      setExportMessage(
        error instanceof Error ? error.message : 'PDF 내보내기에 실패했어요.'
      )
    } finally {
      setExporting(false)
    }
  }

  const toolButton = (entry: ToolButton): JSX.Element => (
    <button
      key={entry.tool}
      type="button"
      className="pdf-tool-rail__button"
      data-active={activeTool === entry.tool ? 'true' : 'false'}
      aria-pressed={activeTool === entry.tool}
      aria-label={entry.label}
      title={`${entry.label}${entry.shortcut ? ` (${entry.shortcut})` : ''}`}
      onClick={() => {
        setActiveTool(entry.tool)
        closeMenu()
      }}
    >
      {entry.icon}
    </button>
  )
  return (
    <div
      ref={rootRef}
      className="pdf-tool-rail-shell"
      hidden={!expanded}
      data-overflow={scroll.overflow}
    >
      {scroll.overflow && (
        <button
          type="button"
          className="pdf-tool-rail__button pdf-tool-rail__scroll"
          aria-label="이전 필기 도구"
          title="이전 필기 도구"
          disabled={!scroll.canBack}
          onClick={() => scrollTools(-1)}
        >
          <Icon name="chevronLeft" />
        </button>
      )}
      <div
        ref={railRef}
        className="pdf-tool-rail"
        role="group"
        aria-label="자유 필기 도구"
        onScroll={updateScroll}
      >
        <div className="pdf-tool-rail__group pdf-tool-rail__tools">
          {TOOLS.map(toolButton)}
        </div>
        <button
          type="button"
          className="pdf-tool-rail__button"
          aria-label="필기 스타일"
          title="색상 · 선 굵기 · 불투명도"
          aria-haspopup="dialog"
          aria-expanded={menu !== null}
          onClick={(event) => openMenu(event.currentTarget)}
        >
          <span className="pdf-tool-rail__swatch" data-color={color} />
        </button>
        <div className="pdf-tool-rail__group pdf-tool-rail__history">
          <button
            className="pdf-tool-rail__button"
            aria-label="되돌리기"
            title="되돌리기 (⌘Z)"
            disabled={!drawingsApi.canUndo || drawingsApi.historyBusy}
            onClick={() => void drawingsApi.undo()}
          >
            <PdfToolIcon name="undo" />
          </button>
          <button
            className="pdf-tool-rail__button"
            aria-label="다시 실행"
            title="다시 실행 (⇧⌘Z)"
            disabled={!drawingsApi.canRedo || drawingsApi.historyBusy}
            onClick={() => void drawingsApi.redo()}
          >
            <PdfToolIcon name="redo" />
          </button>
        </div>
        <button
          type="button"
          className="pdf-tool-rail__button pdf-tool-rail__export"
          aria-label={
            exporting ? '주석 포함 PDF 내보내는 중' : '주석 포함 PDF 내보내기'
          }
          title="주석 포함 PDF 내보내기"
          disabled={exporting}
          onClick={() => void exportPdf()}
        >
          <PdfToolIcon name="export" />
        </button>
        {(drawingsApi.error ?? exportMessage) && (
          <span className="pdf-tool-rail__status" role="status">
            {drawingsApi.error ?? exportMessage}
          </span>
        )}
      </div>
      {scroll.overflow && (
        <button
          type="button"
          className="pdf-tool-rail__button pdf-tool-rail__scroll"
          aria-label="다음 필기 도구"
          title="다음 필기 도구"
          disabled={!scroll.canForward}
          onClick={() => scrollTools(1)}
        >
          <Icon name="chevronRight" />
        </button>
      )}
      {menu &&
        createPortal(
          <div
            ref={menuRef}
            className="pdf-tool-popover"
            role="dialog"
            aria-label="필기 스타일"
            style={{ left: menu.x, top: menu.y }}
          >
            <div
              className="pdf-tool-rail__group pdf-tool-rail__palette"
              role="group"
              aria-label="필기 색상"
            >
              {COLORS.map((entry) => (
                <button
                  key={entry}
                  className="pdf-tool-rail__swatch"
                  data-color={entry}
                  data-selected={color === entry ? 'true' : 'false'}
                  aria-label={COLOR_LABELS[entry]}
                  aria-pressed={color === entry}
                  onClick={() => setColor(entry)}
                />
              ))}
            </div>
            <label className="pdf-tool-rail__range">
              선 굵기
              <input
                type="range"
                min="0.001"
                max="0.025"
                step="0.001"
                value={width}
                aria-label="선 굵기"
                onChange={(event) => setWidth(Number(event.target.value))}
              />
            </label>
            <label className="pdf-tool-rail__range">
              불투명도
              <input
                type="range"
                min="0.1"
                max="1"
                step="0.05"
                value={opacity}
                aria-label="불투명도"
                onChange={(event) => setOpacity(Number(event.target.value))}
              />
            </label>
          </div>,
          document.body
        )}
    </div>
  )
}
