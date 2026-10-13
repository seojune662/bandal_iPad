import { useEffect, useLayoutEffect, useRef, useState, useMemo, type CSSProperties } from 'react'
import type {
  MaterialKind,
  MaterialNode,
  MaterialSearchHit
} from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { MaterialFileIcon } from './materialIcons'
import { startMaterialDrag as startNativeMaterialDrag } from '../../lib/ipc'
import { openMaterialInWorkspace } from '../workspace/openMaterial'
import { isViewableFile } from '../file/fileFormats'
import {
  classifyDrop,
  isFileDrag
} from './importDrop'
import { beginMaterialFileDrag } from './materialFileDrag'
import {
  MATERIAL_MOVE_MIME,
  canAcceptMaterialMove,
  clearCurrentMaterialDrag,
  getCurrentMaterialDrag,
  parseMaterialMoveDrag,
  serializeMaterialMoveDrag,
  setCurrentMaterialDrag,
  type MaterialMoveDragPayload
} from './materialMoveDrag'
import { canAcceptUrlDrop } from './urlDrop'
import { MaterialRowAffordance } from './MaterialAffordances'

/** Keep the row hint aligned with the viewer used by openMaterialInWorkspace. */
function rowTitle(kind: MaterialKind | 'dir', relPath: string): string {
  if (kind !== 'other' || isViewableFile(relPath) || relPath.toLowerCase().endsWith('.wav')) {
    return relPath
  }
  return `${relPath} — 폴더에서 보기`
}

function canMoveToDirectory(
  payload: MaterialMoveDragPayload,
  courseId: string,
  dirRelPath: string
): boolean {
  if (payload.courseId !== courseId) return false
  if (payload.kind !== 'dir') return true
  return (
    dirRelPath !== payload.relPath &&
    !dirRelPath.startsWith(`${payload.relPath}/`)
  )
}

function canDropCurrentMaterial(
  dataTransfer: DataTransfer,
  courseId: string,
  dirRelPath: string
): boolean {
  if (!canAcceptMaterialMove([...dataTransfer.types])) return false
  const payload = getCurrentMaterialDrag()
  return (
    payload !== null && canMoveToDirectory(payload, courseId, dirRelPath)
  )
}

function startMaterialDragEvent(
  event: React.DragEvent,
  courseId: string,
  node: MaterialNode
): void {
  // 파일 행은 진짜 OS 파일 드래그로 승격한다 — 웹뷰 안의 업로드 폼(메일
  // 첨부, 과제 제출)이 일반 파일처럼 받는다. HTML5 드래그는 여기서 죽지만,
  // 우리 패널 안의 이동은 importDroppedFiles 가 "과목 폴더 내부 경로면
  // 이동"으로 판별하므로 폴더 간 이동도 그대로 동작한다.
  // 화이트보드/PDF는 네이티브 Files 드롭에서 과목 내부 이미지를 판별한다.
  if (node.kind !== 'dir') {
    // 탭 가장자리 드롭존(자료 연결)이 이 드래그의 정체를 알 수 있도록,
    // 네이티브 승격 전에 모듈 상태에 기록한다.
    beginMaterialFileDrag({
      courseId,
      relPath: node.relPath,
      kind: node.kind
    })
    event.preventDefault()
    startNativeMaterialDrag(courseId, node.relPath)
    return
  }
  const dataTransfer = event.dataTransfer
  const payload: MaterialMoveDragPayload = {
    version: 1,
    courseId,
    relPath: node.relPath,
    kind: node.kind
  }
  dataTransfer.effectAllowed = 'copyMove'
  dataTransfer.setData(
    MATERIAL_MOVE_MIME,
    serializeMaterialMoveDrag({
      courseId: payload.courseId,
      relPath: payload.relPath,
      kind: payload.kind
    })
  )
  setCurrentMaterialDrag(payload)
}

function focusAdjacentRow(
  event: React.KeyboardEvent<HTMLButtonElement>,
  direction: -1 | 1
): void {
  const container = event.currentTarget.closest<HTMLElement>(
    '.material-tree, .material-results'
  )
  if (container === null) return
  const rows = Array.from(
    container.querySelectorAll<HTMLButtonElement>('[data-material-row="true"]')
  )
  const index = rows.indexOf(event.currentTarget)
  const next = rows[index + direction]
  if (next === undefined) return
  event.preventDefault()
  next.focus()
}

interface InlineNameEditorProps {
  node: MaterialNode
  onCancel: () => void
  onRename: (newName: string) => Promise<string | null>
}

function InlineNameEditor({
  node,
  onCancel,
  onRename
}: InlineNameEditorProps): JSX.Element {
  const inputRef = useRef<HTMLInputElement>(null)
  const [draft, setDraft] = useState(node.name)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useLayoutEffect(() => {
    // Complete selection before the input becomes interactive. A delayed frame
    // can select the old stem midway through typing/pasting a replacement name.
    const input = inputRef.current
    if (input === null) return
    input.focus()
    const extensionStart = node.kind === 'dir' ? -1 : node.name.lastIndexOf('.')
    input.setSelectionRange(0, extensionStart > 0 ? extensionStart : node.name.length)
  }, [node.kind, node.name])

  const submit = async (): Promise<void> => {
    if (pending) return
    if (draft === node.name) {
      onCancel()
      return
    }
    setPending(true)
    setError(null)
    const renameError = await onRename(draft)
    if (renameError !== null) {
      setError(renameError)
      setPending(false)
    }
  }

  return (
    <input
      ref={inputRef}
      className="material-row__rename"
      value={draft}
      disabled={pending}
      aria-label={`${node.name} 이름 변경`}
      aria-invalid={error === null ? undefined : true}
      title={error ?? undefined}
      onChange={(event) => setDraft(event.target.value)}
      onBlur={() => {
        if (!pending && error === null) onCancel()
      }}
      onKeyDown={(event) => {
        event.stopPropagation()
        if (event.key === 'Enter') {
          event.preventDefault()
          void submit()
        }
        if (event.key === 'Escape') {
          event.preventDefault()
          onCancel()
        }
      }}
    />
  )
}

interface TreeNodeProps {
  flat?: boolean
  virtualIndex?: number
  courseId: string
  node: MaterialNode
  depth: number
  expandedPaths: Record<string, boolean>
  editingRelPath: string | null
  selectedRelPath: string | null
  pasteTargetDirRelPath: string | null
  dropTargetDirRelPath: string | null
  urlDropTargetDirRelPath: string | null
  downloadingDirRelPath: string | null
  onToggleFolder: (relPath: string) => void
  onSelect: (node: MaterialNode) => void
  onContextMenu: (event: React.MouseEvent, node: MaterialNode) => void
  onCancelRename: () => void
  onRename: (node: MaterialNode, newName: string) => Promise<string | null>
  onDropTargetChange: (dirRelPath: string | null) => void
  onUrlDropTargetChange: (dirRelPath: string | null) => void
  onMove: (payload: MaterialMoveDragPayload, toDirRelPath: string) => void
  onImportFiles: (files: File[], dirRelPath: string) => void
  onDownloadUrl: (url: string, dirRelPath: string, fileName?: string) => void
  onUnsupportedDrop: (types: readonly string[]) => void
}

function TreeNode({
  flat = false,
  virtualIndex,
  courseId,
  node,
  depth,
  expandedPaths,
  editingRelPath,
  selectedRelPath,
  pasteTargetDirRelPath,
  dropTargetDirRelPath,
  urlDropTargetDirRelPath,
  downloadingDirRelPath,
  onToggleFolder,
  onSelect,
  onContextMenu,
  onCancelRename,
  onRename,
  onDropTargetChange,
  onUrlDropTargetChange,
  onMove,
  onImportFiles,
  onDownloadUrl,
  onUnsupportedDrop
}: TreeNodeProps): JSX.Element {
  const isDirectory = node.kind === 'dir'
  const expanded = isDirectory && expandedPaths[node.relPath] === true
  const editing = editingRelPath === node.relPath
  const downloading =
    isDirectory && downloadingDirRelPath === node.relPath
  const rowStyle = { '--tree-depth': depth } as CSSProperties
  const rowContents = (
    <>
      <span
        className="material-row__chevron"
        data-visible={isDirectory}
        data-expanded={expanded}
      >
        <Icon name="chevronRight" />
      </span>
      <MaterialFileIcon kind={node.kind} expanded={expanded} />
      {editing ? (
        <InlineNameEditor
          node={node}
          onCancel={onCancelRename}
          onRename={(newName) => onRename(node, newName)}
        />
      ) : (
        <span className="material-row__name">{node.name}</span>
      )}
      {downloading && (
        <Icon
          name="refresh"
          className="material-row__download-spinner is-spinning"
        />
      )}
    </>
  )

  return (
    <li
      role="treeitem"
      data-material-index={virtualIndex}
      aria-level={depth + 1}
      aria-expanded={isDirectory ? expanded : undefined}
    >
      {editing ? (
        <div
          className="material-row"
          data-kind={node.kind}
          data-selected={selectedRelPath === node.relPath || undefined}
          data-paste-target={
            isDirectory && pasteTargetDirRelPath === node.relPath
              ? true
              : undefined
          }
          data-move-target={
            isDirectory && dropTargetDirRelPath === node.relPath
              ? true
              : undefined
          }
          data-url-target={
            isDirectory && urlDropTargetDirRelPath === node.relPath
              ? true
              : undefined
          }
          data-downloading={downloading || undefined}
          aria-busy={downloading || undefined}
          data-material-path={node.relPath}
          style={rowStyle}
        >
          {rowContents}
        </div>
      ) : (
        <MaterialRowAffordance target={{ courseId, node }}>
        <button
          type="button"
          className="material-row"
          draggable
          data-material-row="true"
          data-kind={node.kind}
          data-selected={selectedRelPath === node.relPath || undefined}
          data-paste-target={
            isDirectory && pasteTargetDirRelPath === node.relPath
              ? true
              : undefined
          }
          data-move-target={
            isDirectory && dropTargetDirRelPath === node.relPath
              ? true
              : undefined
          }
          data-url-target={
            isDirectory && urlDropTargetDirRelPath === node.relPath
              ? true
              : undefined
          }
          data-downloading={downloading || undefined}
          aria-busy={downloading || undefined}
          data-material-path={node.relPath}
          style={rowStyle}
          title={rowTitle(node.kind, node.relPath)}
          onFocus={() => onSelect(node)}
          onClick={(event) => {
            onSelect(node)
            if (isDirectory) onToggleFolder(node.relPath)
            else if (node.kind !== 'dir') {
              const newInstance =
                window.bandal?.platform === 'darwin'
                  ? event.metaKey
                  : event.ctrlKey
              openMaterialInWorkspace(
                node.kind,
                node.relPath,
                newInstance ? { newInstance: true } : undefined
              )
            }
          }}
          onContextMenu={(event) => onContextMenu(event, node)}
          onDragStart={(event) => {
            startMaterialDragEvent(event, courseId, node)
          }}
          onDragEnd={() => {
            clearCurrentMaterialDrag()
            onDropTargetChange(null)
            onUrlDropTargetChange(null)
          }}
          onDragEnter={(event) => {
            if (!isDirectory) return
            const types = [...event.dataTransfer.types]
            if (canAcceptMaterialMove(types)) {
              event.stopPropagation()
              onUrlDropTargetChange(null)
              if (!canDropCurrentMaterial(event.dataTransfer, courseId, node.relPath)) {
                onDropTargetChange(null)
                return
              }
              event.preventDefault()
              event.dataTransfer.dropEffect = 'move'
              onDropTargetChange(node.relPath)
              return
            }
            if (canAcceptUrlDrop(types) && downloadingDirRelPath === null) {
              event.preventDefault()
              event.stopPropagation()
              event.dataTransfer.dropEffect = 'copy'
              onDropTargetChange(null)
              onUrlDropTargetChange(node.relPath)
              return
            }
            if (isFileDrag(event.dataTransfer)) {
              event.preventDefault()
              event.stopPropagation()
              event.dataTransfer.dropEffect = 'copy'
              onUrlDropTargetChange(null)
              onDropTargetChange(node.relPath)
            }
          }}
          onDragOver={(event) => {
            if (!isDirectory) return
            const types = [...event.dataTransfer.types]
            if (canAcceptMaterialMove(types)) {
              event.stopPropagation()
              onUrlDropTargetChange(null)
              if (!canDropCurrentMaterial(event.dataTransfer, courseId, node.relPath)) {
                onDropTargetChange(null)
                return
              }
              event.preventDefault()
              event.dataTransfer.dropEffect = 'move'
              onDropTargetChange(node.relPath)
              return
            }
            if (canAcceptUrlDrop(types) && downloadingDirRelPath === null) {
              event.preventDefault()
              event.stopPropagation()
              event.dataTransfer.dropEffect = 'copy'
              onDropTargetChange(null)
              onUrlDropTargetChange(node.relPath)
              return
            }
            if (isFileDrag(event.dataTransfer)) {
              event.preventDefault()
              event.stopPropagation()
              event.dataTransfer.dropEffect = 'copy'
              onUrlDropTargetChange(null)
              onDropTargetChange(node.relPath)
            }
          }}
          onDragLeave={(event) => {
            if (!isDirectory) return
            const types = [...event.dataTransfer.types]
            const handlesFiles = isFileDrag(event.dataTransfer)
            const handlesMove = canAcceptMaterialMove(types)
            const handlesUrl = canAcceptUrlDrop(types)
            if (!handlesMove && !handlesFiles && !handlesUrl) return
            event.stopPropagation()
            const nextTarget = event.relatedTarget
            if (
              nextTarget instanceof Node &&
              event.currentTarget.contains(nextTarget)
            ) {
              return
            }
            onDropTargetChange(null)
            onUrlDropTargetChange(null)
          }}
          onDrop={(event) => {
            if (!isDirectory) return
            const types = [...event.dataTransfer.types]
            const files = [...event.dataTransfer.files]
            const drop = classifyDrop(
              types,
              (type) => event.dataTransfer.getData(type),
              files
            )
            event.preventDefault()
            event.stopPropagation()
            onDropTargetChange(null)
            onUrlDropTargetChange(null)
            if (drop.kind === 'move') {
              const payload = parseMaterialMoveDrag(
                event.dataTransfer.getData(MATERIAL_MOVE_MIME)
              )
              if (
                payload === null ||
                !canMoveToDirectory(payload, courseId, node.relPath)
              ) {
                return
              }
              onMove(payload, node.relPath)
              return
            }
            if (drop.kind === 'url') {
              onDownloadUrl(drop.url, node.relPath, drop.fileName)
              return
            }
            if (drop.kind === 'files') {
              onImportFiles(files, node.relPath)
              return
            }
            onUnsupportedDrop(types)
          }}
          onKeyDown={(event) => {
            if (event.key === 'ArrowDown') focusAdjacentRow(event, 1)
            if (event.key === 'ArrowUp') focusAdjacentRow(event, -1)
            if (isDirectory && event.key === 'ArrowRight' && !expanded) {
              event.preventDefault()
              onToggleFolder(node.relPath)
            }
            if (isDirectory && event.key === 'ArrowLeft' && expanded) {
              event.preventDefault()
              onToggleFolder(node.relPath)
            }
          }}
        >
          {rowContents}
        </button>
        </MaterialRowAffordance>
      )}
      {!flat && isDirectory && expanded && node.children !== undefined && (
        <ul role="group">
          {node.children.map((child) => (
            <TreeNode
              key={child.relPath}
              courseId={courseId}
              node={child}
              depth={depth + 1}
              expandedPaths={expandedPaths}
              editingRelPath={editingRelPath}
              selectedRelPath={selectedRelPath}
              pasteTargetDirRelPath={pasteTargetDirRelPath}
              dropTargetDirRelPath={dropTargetDirRelPath}
              urlDropTargetDirRelPath={urlDropTargetDirRelPath}
              downloadingDirRelPath={downloadingDirRelPath}
              onToggleFolder={onToggleFolder}
              onSelect={onSelect}
              onContextMenu={onContextMenu}
              onCancelRename={onCancelRename}
              onRename={onRename}
              onDropTargetChange={onDropTargetChange}
              onUrlDropTargetChange={onUrlDropTargetChange}
              onMove={onMove}
              onImportFiles={onImportFiles}
              onDownloadUrl={onDownloadUrl}
              onUnsupportedDrop={onUnsupportedDrop}
            />
          ))}
        </ul>
      )}
    </li>
  )
}

interface MaterialTreeProps {
  courseId: string
  nodes: MaterialNode[]
  expandedPaths: Record<string, boolean>
  editingRelPath: string | null
  selectedRelPath: string | null
  pasteTargetDirRelPath: string | null
  dropTargetDirRelPath: string | null
  urlDropTargetDirRelPath: string | null
  downloadingDirRelPath: string | null
  onToggleFolder: (relPath: string) => void
  onSelect: (node: MaterialNode) => void
  onContextMenu: (event: React.MouseEvent, node: MaterialNode) => void
  onCancelRename: () => void
  onRename: (node: MaterialNode, newName: string) => Promise<string | null>
  onDropTargetChange: (dirRelPath: string | null) => void
  onUrlDropTargetChange: (dirRelPath: string | null) => void
  onMove: (payload: MaterialMoveDragPayload, toDirRelPath: string) => void
  onImportFiles: (files: File[], dirRelPath: string) => void
  onDownloadUrl: (url: string, dirRelPath: string, fileName?: string) => void
  onUnsupportedDrop: (types: readonly string[]) => void
}

interface FlatMaterial { node: MaterialNode; depth: number }
function flattenVisible(nodes: MaterialNode[], expanded: Record<string, boolean>, depth = 0): FlatMaterial[] {
  const rows: FlatMaterial[] = []
  for (const node of nodes) {
    rows.push({ node, depth })
    if (node.kind === 'dir' && expanded[node.relPath]) rows.push(...flattenVisible(node.children ?? [], expanded, depth + 1))
  }
  return rows
}

function VirtualMaterialTree({ rows, ...props }: MaterialTreeProps & { rows: FlatMaterial[] }): JSX.Element {
  const root = useRef<HTMLUListElement>(null)
  const [window, setWindow] = useState({ start: 0, end: 60, height: 32 })
  const scrollToIndex = (index: number): void => {
    const list = root.current, body = list?.closest<HTMLElement>('.materials-body')
    if (!list || !body) return
    const listTop = list.getBoundingClientRect().top - body.getBoundingClientRect().top + body.scrollTop
    body.scrollTop = listTop + index * window.height - body.clientHeight / 2
    setWindow(current => ({ ...current, start: Math.max(0, index - 20), end: Math.min(rows.length, index + 40) }))
    requestAnimationFrame(() => root.current?.querySelector<HTMLButtonElement>(`[data-material-index="${index}"] button`)?.focus())
  }
  useEffect(() => {
    const list = root.current, body = list?.closest<HTMLElement>('.materials-body')
    if (!list || !body) return
    let frame: number | null = null
    const update = (): void => {
      if (frame !== null) return
      frame = requestAnimationFrame(() => {
        frame = null
        const row = list.querySelector<HTMLElement>('.material-row')
        const height = row?.getBoundingClientRect().height || 32
        const top = Math.max(0, body.getBoundingClientRect().top - list.getBoundingClientRect().top)
        const start = Math.max(0, Math.floor(top / height) - 12)
        const end = Math.min(rows.length, Math.ceil((top + body.clientHeight) / height) + 12)
        setWindow(current => current.start === start && current.end === end && current.height === height ? current : { start, end, height })
      })
    }
    const observer = new ResizeObserver(update)
    observer.observe(body)
    body.addEventListener('scroll', update, { passive: true })
    update()
    return () => { if (frame !== null) cancelAnimationFrame(frame); observer.disconnect(); body.removeEventListener('scroll', update) }
  }, [rows.length])
  useEffect(() => {
    if (!props.editingRelPath) return
    const index = rows.findIndex(row => row.node.relPath === props.editingRelPath)
    if (index >= 0 && (index < window.start || index >= window.end)) scrollToIndex(index)
  }, [props.editingRelPath])
  const start = Math.min(window.start, Math.max(0, rows.length - 1)), end = Math.max(start + 1, window.end)
  return <ul ref={root} className="material-tree" data-total-rows={rows.length} role="tree" aria-label="자료 파일 트리"
    onKeyDownCapture={event => {
      if (!['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key) || (event.target as HTMLElement).tagName !== 'BUTTON') return
      const element = (event.target as HTMLElement).closest<HTMLElement>('[data-material-index]')
      if (!element) return
      const index = Number(element.dataset['materialIndex'])
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? rows.length - 1 : index + (event.key === 'ArrowDown' ? 1 : -1)
      if (next < 0 || next >= rows.length) return
      event.preventDefault(); event.stopPropagation(); scrollToIndex(next)
    }}>
    <li role="presentation" aria-hidden style={{ height: start * window.height }} />
    {rows.slice(start, end).map(({ node, depth }, index) =>
      <TreeNode {...props} key={node.relPath} node={node} depth={depth} flat virtualIndex={start + index} />)}
    <li role="presentation" aria-hidden style={{ height: Math.max(0, rows.length - end) * window.height }} />
  </ul>
}

export function MaterialTree(props: MaterialTreeProps): JSX.Element {
  const rows = useMemo(() => flattenVisible(props.nodes, props.expandedPaths), [props.nodes, props.expandedPaths])
  if (rows.length > 200) return <VirtualMaterialTree {...props} rows={rows} />
  return <ul className="material-tree" role="tree" aria-label="자료 파일 트리">
    {props.nodes.map(node => <TreeNode {...props} key={node.relPath} node={node} depth={0} />)}
  </ul>
}

interface MaterialSearchResultsProps {
  courseId: string
  results: MaterialSearchHit[]
  selectedRelPath: string | null
  onSelect: (node: MaterialNode) => void
  onContextMenu: (event: React.MouseEvent, node: MaterialNode) => void
  onDragEnd: () => void
}

export function MaterialSearchResults({
  courseId,
  results,
  selectedRelPath,
  onSelect,
  onContextMenu,
  onDragEnd
}: MaterialSearchResultsProps): JSX.Element {
  return (
    <ul className="material-results" aria-label="자료 검색 결과">
      {results.map((result) => {
        const node: MaterialNode = { ...result }
        return (
          <li key={result.relPath}>
            <MaterialRowAffordance target={{ courseId, node }}>
            <button
              type="button"
              className="material-result"
              draggable
              data-material-row="true"
              data-kind={result.kind}
              data-selected={selectedRelPath === result.relPath || undefined}
              data-material-path={result.relPath}
              title={rowTitle(result.kind, result.relPath)}
              onFocus={() => onSelect(node)}
              onClick={(event) => {
                onSelect(node)
                const newInstance =
                  window.bandal?.platform === 'darwin'
                    ? event.metaKey
                    : event.ctrlKey
                openMaterialInWorkspace(
                  result.kind,
                  result.relPath,
                  newInstance ? { newInstance: true } : undefined
                )
              }}
              onContextMenu={(event) => onContextMenu(event, node)}
              onDragStart={(event) => {
                startMaterialDragEvent(event, courseId, node)
              }}
              onDragEnd={() => {
                clearCurrentMaterialDrag()
                onDragEnd()
              }}
              onKeyDown={(event) => {
                if (event.key === 'ArrowDown') focusAdjacentRow(event, 1)
                if (event.key === 'ArrowUp') focusAdjacentRow(event, -1)
              }}
            >
              <MaterialFileIcon kind={result.kind} />
              <span>
                <strong>{result.name}</strong>
                <small>{result.relPath}</small>
              </span>
            </button>
            </MaterialRowAffordance>
          </li>
        )
      })}
    </ul>
  )
}
