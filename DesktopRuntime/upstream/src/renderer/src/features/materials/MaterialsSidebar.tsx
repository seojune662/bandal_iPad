const materialScrollPositions = new Map<string, number>()
import { useCallback, useEffect, useRef, useState } from 'react'
import type { Course } from '../../../../shared/types/course'
import type { MaterialNode } from '../../../../shared/types/materials'
import { Icon } from '../../app/icons'
import { Tooltip } from '../../components/Tooltip'
import { invoke, onPush } from '../../lib/ipc'
import { showToast } from '../../app/toast'
import { useCoursesStore } from '../../stores/coursesStore'
import { useMaterialsStore } from '../../stores/materialsStore'
import { closeResourceTabs, reconcileWorkspaceMaterialRename, useWorkspaceStore } from '../../stores/workspaceStore'
import { CourseMark } from '../courses/CourseMark'
import { LinkPickerDialog } from '../links/LinkPickerDialog'
import { requestOpenPdfPageNote } from '../links/pdfPageNoteNavigation'
import {
  flushOpenNoteSession,
  openNotePanelId,
  openNoteRefForPanel,
  retargetOpenNoteSession
} from '../notes/noteSessionRegistry'
import { openMaterialInWorkspace } from '../workspace/openMaterial'
import { descriptorFor } from '../workspace/tabIdentity'
import { MaterialDeleteDialog } from './MaterialDeleteDialog'
import { MaterialSearchResults, MaterialTree } from './MaterialTree'
import {
  MaterialsContextMenu,
  type MaterialsContextMenuState
} from './MaterialsContextMenu'
import {
  absoluteMaterialPath,
  findMaterialNode,
  kindForMaterialName,
  materialBaseName,
  materialParentPath,
  targetDirectory,
  unusedFolderName
} from './materialPaths'
import { isEditableTarget } from '../ink/domTarget'
import { isEditablePasteTarget } from './clipboardPaste'
import {
  classifyDrop,
  importDroppedFiles,
  isFileDrag,
  isSelfMaterialDrop,
  reportUnsupportedDrop
} from './importDrop'
import {
  clearMaterialFileDrag,
  getMaterialFileDrag,
  subscribeMaterialFileDrag
} from './materialFileDrag'
import { MaterialsIcon } from './materialIcons'
import {
  MATERIAL_MOVE_MIME,
  canAcceptMaterialMove,
  getCurrentMaterialDrag,
  parseMaterialMoveDrag,
  type MaterialMoveDragPayload
} from './materialMoveDrag'
import { canAcceptUrlDrop } from './urlDrop'
import { useMaterialsPaste } from './useMaterialsPaste'
import { WhiteboardsGroup } from './WhiteboardsGroup'
import { MaterialAffordancesProvider } from './MaterialAffordances'
import { WidgetDock } from '../widgets/WidgetDock'
import './materials.css'

const SEARCH_DEBOUNCE_MS = 240

interface MaterialsSidebarProps {
  course: Course | null
}

interface EditingState {
  relPath: string
  /** New notes are already open before their first inline rename. */
  reopenAfterRename: boolean
}

function operationError(error: unknown, fallback: string): string {
  return error instanceof Error ? error.message : fallback
}

function pathIsTargetOrChild(path: string, target: string): boolean {
  return path === target || path.startsWith(`${target}/`)
}

function reconcileTabsAfterRename(
  courseId: string,
  node: MaterialNode,
  newRelPath: string,
  forceReopen: boolean
): void {
  const workspace = useWorkspaceStore.getState()
  if (reconcileWorkspaceMaterialRename(courseId, node.relPath, newRelPath) > 0) return
  if (workspace.activeCourseId !== courseId) return
  const registeredNotePanelId =
    node.kind === 'note'
      ? (openNotePanelId({ courseId, relPath: newRelPath }) ??
        openNotePanelId({ courseId, relPath: node.relPath }))
      : null
  const closedPanelIds = new Set<string>()
  let reopened = false
  for (const [panelId, descriptor] of Object.entries(workspace.openTabs)) {
    if (descriptor.kind !== 'pdf' && descriptor.kind !== 'note') continue
    if (descriptor.payload.courseId !== courseId) continue
    if (!pathIsTargetOrChild(descriptor.payload.relPath, node.relPath)) continue
    const liveNoteRef =
      descriptor.kind === 'note' ? openNoteRefForPanel(panelId) : null
    const sourceRelPath = liveNoteRef?.relPath ?? descriptor.payload.relPath
    const nextRelPath = pathIsTargetOrChild(sourceRelPath, newRelPath)
      ? sourceRelPath
      : pathIsTargetOrChild(sourceRelPath, node.relPath)
        ? `${newRelPath}${sourceRelPath.slice(node.relPath.length)}`
        : `${newRelPath}${descriptor.payload.relPath.slice(node.relPath.length)}`
    if (descriptor.kind === 'note') {
      retargetOpenNoteSession(liveNoteRef ?? descriptor.payload, nextRelPath)
    }
    workspace.closeTab(panelId)
    closedPanelIds.add(panelId)
    const nextKind =
      node.kind === 'dir'
        ? descriptor.kind
        : kindForMaterialName(materialBaseName(nextRelPath))
    if (nextKind === 'pdf' || nextKind === 'note') {
      openMaterialInWorkspace(nextKind, nextRelPath)
    }
    reopened = true
  }

  if (
    !reopened &&
    registeredNotePanelId !== null &&
    !closedPanelIds.has(registeredNotePanelId)
  ) {
    const liveNoteRef = openNoteRefForPanel(registeredNotePanelId)
    if (liveNoteRef !== null) {
      retargetOpenNoteSession(liveNoteRef, newRelPath)
    }
    workspace.closeTab(registeredNotePanelId)
    const nextKind = kindForMaterialName(materialBaseName(newRelPath))
    if (nextKind === 'pdf' || nextKind === 'note') {
      openMaterialInWorkspace(nextKind, newRelPath)
    }
    reopened = true
  }

  if (!reopened && node.kind !== 'dir') {
    const oldKind = node.kind
    if (oldKind === 'pdf' || oldKind === 'note') {
      workspace.closeTabsMatching(
        descriptorFor(oldKind, { courseId, relPath: node.relPath })
      )
    }
  }

  if (!reopened && forceReopen && node.kind !== 'dir') {
    const newKind = kindForMaterialName(materialBaseName(newRelPath))
    if (newKind === 'pdf' || newKind === 'note') {
      openMaterialInWorkspace(newKind, newRelPath)
    }
  }
}

function closeDeletedTabs(courseId: string, node: MaterialNode): void {
  closeResourceTabs(descriptor => 'courseId' in descriptor.payload && descriptor.payload.courseId === courseId &&
    'relPath' in descriptor.payload && pathIsTargetOrChild(descriptor.payload.relPath, node.relPath))
  const workspace = useWorkspaceStore.getState()
  for (const [panelId, descriptor] of Object.entries(workspace.openTabs)) {
    if (descriptor.kind !== 'pdf' && descriptor.kind !== 'note') continue
    if (
      descriptor.payload.courseId === courseId &&
      pathIsTargetOrChild(descriptor.payload.relPath, node.relPath)
    ) {
      workspace.closeTab(panelId)
    }
  }
  if (node.kind === 'pdf' || node.kind === 'note') {
    workspace.closeTabsMatching(
      descriptorFor(node.kind, { courseId, relPath: node.relPath })
    )
  }
}

export function MaterialsSidebar({ course }: MaterialsSidebarProps): JSX.Element {
  const tree = useMaterialsStore((state) => state.tree)
  const searchResults = useMaterialsStore((state) => state.searchResults)
  const expandedPaths = useMaterialsStore((state) => state.expandedPaths)
  const isLoading = useMaterialsStore((state) => state.isLoading)
  const isSearching = useMaterialsStore((state) => state.isSearching)
  const error = useMaterialsStore((state) => state.error)
  const loadTree = useMaterialsStore((state) => state.loadTree)
  const search = useMaterialsStore((state) => state.search)
  const clearSearch = useMaterialsStore((state) => state.clearSearch)
  const clear = useMaterialsStore((state) => state.clear)
  const toggleFolder = useMaterialsStore((state) => state.toggleFolder)
  const pickFolder = useCoursesStore((state) => state.pickFolder)
  const relinkCourse = useCoursesStore((state) => state.relinkCourse)
  const [filesOpen, setFilesOpen] = useState(true)
  const [query, setQuery] = useState('')
  const [isDebouncing, setIsDebouncing] = useState(false)
  const [isRelinking, setIsRelinking] = useState(false)
  const [contextMenu, setContextMenu] = useState<MaterialsContextMenuState | null>(
    null
  )
  const [linkTarget, setLinkTarget] = useState<MaterialNode | null>(null)
  const [editing, setEditing] = useState<EditingState | null>(null)
  const [selectedRelPath, setSelectedRelPath] = useState<string | null>(null)
  const [pasteFocused, setPasteFocused] = useState(false)
  const [isDropActive, setDropActive] = useState(false)
  const [dropTargetDirRelPath, setDropTargetDirRelPath] = useState<string | null>(
    null
  )
  const [urlDropTargetDirRelPath, setUrlDropTargetDirRelPath] = useState<
    string | null
  >(null)
  const [downloadingDirRelPath, setDownloadingDirRelPath] = useState<
    string | null
  >(null)
  const [deleteTarget, setDeleteTarget] = useState<MaterialNode | null>(null)
  const [deletePending, setDeletePending] = useState(false)
  const [deleteError, setDeleteError] = useState<string | null>(null)
  const sidebarRef = useRef<HTMLElement>(null)
  useEffect(() => {
    const id = course?.id
    const body = sidebarRef.current?.querySelector<HTMLElement>('.materials-body')
    if (!id || !body) return
    const restore = requestAnimationFrame(() => { body.scrollTop = materialScrollPositions.get(id) ?? 0 })
    const save = (): void => { materialScrollPositions.set(id, body.scrollTop) }
    body.addEventListener('scroll', save, { passive: true })
    return () => { cancelAnimationFrame(restore); body.removeEventListener('scroll', save) }
  }, [course?.id])
  const fileInputRef = useRef<HTMLInputElement>(null)
  const downloadPendingRef = useRef(false)
  const activeCourseIdRef = useRef<string | null>(course?.id ?? null)
  activeCourseIdRef.current = course?.id ?? null

  const closeContextMenu = useCallback(() => setContextMenu(null), [])
  const closeDeleteDialog = useCallback(() => {
    if (deletePending) return
    setDeleteTarget(null)
    setDeleteError(null)
  }, [deletePending])

  /** 연결 끊김 복구: re-pick the folder this course points at. */
  const relink = async (courseId: string): Promise<void> => {
    setIsRelinking(true)
    try {
      const picked = await pickFolder()
      if (picked === null) return
      const result = await relinkCourse(courseId, picked.path)
      if (result.status === 'ok') showToast('폴더를 다시 연결했어요.')
    } catch {
      // The course rail shows the store's persistent error message.
    } finally {
      setIsRelinking(false)
    }
  }

  // Re-runs when the course is re-linked too — folderPath is part of the key.
  useEffect(() => {
    setQuery('')
    setContextMenu(null)
    setLinkTarget(null)
    setEditing(null)
    setSelectedRelPath(null)
    setDropActive(false)
    setDropTargetDirRelPath(null)
    setUrlDropTargetDirRelPath(null)
    setDownloadingDirRelPath(null)
    setDeleteTarget(null)
    setDeleteError(null)
    clearSearch()
    if (course === null || course.missing) {
      clear()
      return
    }
    void loadTree(course.id)
  }, [clear, clearSearch, course?.id, course?.folderPath, course?.missing, loadTree])

  // 네이티브 파일 드래그는 dragend 가 없다 — 드래그 상태가 걷히는 순간
  // (어디에 놓였든/취소든) 드롭 하이라이트와 행 활성을 확실히 원복하는 안전망.
  useEffect(() => {
    let wasDragging = getMaterialFileDrag() !== null
    return subscribeMaterialFileDrag(() => {
      const dragging = getMaterialFileDrag() !== null
      if (wasDragging && !dragging) {
        setDropActive(false)
        setDropTargetDirRelPath(null)
        setUrlDropTargetDirRelPath(null)
        setSelectedRelPath(null)
      }
      wasDragging = dragging
    })
  }, [])

  // [M5] Live tree: watch the course folder, refresh silently on pushes.
  // A 연결 끊김 course has no folder to watch.
  useEffect(() => {
    if (course === null || course.missing) return
    const courseId = course.id
    void invoke('materials:watch', { courseId }).catch((error: unknown) => {
      console.error('[Bandal] 자료 폴더 감시를 시작하지 못했습니다.', error)
    })
    const unsubscribe = onPush('materials:changed', (payload) => {
      if (payload.courseId === courseId) {
        void loadTree(courseId, { silent: true })
      }
    })
    return () => {
      unsubscribe()
      void invoke('materials:unwatch', { courseId }).catch(() => undefined)
    }
  }, [course?.id, course?.folderPath, course?.missing, loadTree])

  useEffect(() => {
    const normalizedQuery = query.trim()
    if (course === null || normalizedQuery.length === 0) {
      setIsDebouncing(false)
      clearSearch()
      return
    }

    setIsDebouncing(true)
    const timeout = window.setTimeout(() => {
      setIsDebouncing(false)
      void search(course.id, normalizedQuery)
    }, SEARCH_DEBOUNCE_MS)
    return () => window.clearTimeout(timeout)
  }, [clearSearch, course, query, search])

  const searching = query.trim().length > 0
  const pendingSearch = isDebouncing || isSearching

  const ensureFolderExpanded = useCallback((dirRelPath: string): void => {
    if (dirRelPath === '') return
    const materials = useMaterialsStore.getState()
    if (materials.expandedPaths[dirRelPath] !== true) {
      materials.toggleFolder(dirRelPath)
    }
  }, [])

  const ensureAncestorsExpanded = useCallback(
    (relPath: string): void => {
      const segments = materialParentPath(relPath).split('/').filter(Boolean)
      let ancestor = ''
      for (const segment of segments) {
        ancestor = ancestor === '' ? segment : `${ancestor}/${segment}`
        ensureFolderExpanded(ancestor)
      }
    },
    [ensureFolderExpanded]
  )

  const handleCreated = useCallback(
    (relPaths: string[]): void => {
      const newest = relPaths.at(-1)
      if (newest === undefined) return
      ensureAncestorsExpanded(newest)
      setSelectedRelPath(newest)
    },
    [ensureAncestorsExpanded]
  )

  const selectedNode = findMaterialNode(tree, selectedRelPath)
  const pasteDirRelPath = targetDirectory(selectedNode)
  const pasteDestinationName =
    pasteDirRelPath === ''
      ? `${course?.name ?? '과목'} 루트`
      : `‘${materialBaseName(pasteDirRelPath)}’ 폴더`
  const { pasteNotice, isPasting, onPaste } = useMaterialsPaste({
    enabled: pasteFocused,
    courseId: course !== null && !course.missing ? course.id : null,
    courseName: course?.name ?? null,
    dirRelPath: pasteDirRelPath,
    destinationName: pasteDestinationName,
    onCreated: handleCreated
  })
  const pasteReady = pasteFocused && course !== null && !course.missing

  useEffect(() => {
    if (selectedRelPath === null) return
    const frame = window.requestAnimationFrame(() => {
      const rows = sidebarRef.current?.querySelectorAll<HTMLElement>(
        '[data-material-path]'
      )
      const row = Array.from(rows ?? []).find(
        (candidate) => candidate.dataset.materialPath === selectedRelPath
      )
      row?.scrollIntoView({ block: 'nearest' })
    })
    return () => window.cancelAnimationFrame(frame)
  }, [selectedRelPath, tree])

  const refreshAfterMutation = async (courseId: string): Promise<void> => {
    await useMaterialsStore.getState().loadTree(courseId, { refreshOnly: true })
  }

  const moveMaterial = async (
    payload: MaterialMoveDragPayload,
    toDirRelPath: string
  ): Promise<void> => {
    if (course === null || course.missing || payload.courseId !== course.id) return
    const node =
      findMaterialNode(useMaterialsStore.getState().tree, payload.relPath) ??
      ({
        relPath: payload.relPath,
        name: materialBaseName(payload.relPath),
        kind: payload.kind
      } satisfies MaterialNode)
    try {
      const moved = await invoke('materials:move', {
        courseId: course.id,
        fromRelPath: payload.relPath,
        toDirRelPath
      })
      reconcileTabsAfterRename(course.id, node, moved.relPath, false)
      if (activeCourseIdRef.current !== course.id) return
      setQuery('')
      clearSearch()
      await refreshAfterMutation(course.id)
      if (activeCourseIdRef.current !== course.id) return
      ensureAncestorsExpanded(moved.relPath)
      setSelectedRelPath(moved.relPath)
    } catch (moveError) {
      console.error('[Bandal] 자료를 이동하지 못했습니다.', moveError)
      showToast(operationError(moveError, '자료를 이동하지 못했습니다.'), 'danger')
    }
  }

  const importFiles = (files: File[], dirRelPath?: string): void => {
    setDropActive(false)
    setDropTargetDirRelPath(null)
    setUrlDropTargetDirRelPath(null)
    if (course === null || course.missing || files.length === 0) return
    const courseId = course.id
    void importDroppedFiles(courseId, files, dirRelPath).then(paths => {
      if (activeCourseIdRef.current === courseId) handleCreated(paths)
    })
  }

  const downloadFromUrl = async (
    url: string,
    dirRelPath: string,
    fileName?: string
  ): Promise<void> => {
    if (course === null || course.missing || downloadPendingRef.current) return
    const courseId = course.id
    downloadPendingRef.current = true
    setDropTargetDirRelPath(null)
    setUrlDropTargetDirRelPath(null)
    setDownloadingDirRelPath(dirRelPath)
    try {
      const sourceTab = useWorkspaceStore.getState().activeTabDescriptor()
      const downloaded = await invoke('materials:downloadFromUrl', {
        ...(sourceTab?.kind === 'browser' ? { tabId: sourceTab.payload.tabId } : {}),
        courseId,
        dirRelPath,
        url
      })
      showToast(
        `자료로 저장했어요: ${fileName ?? materialBaseName(downloaded.relPath)}`
      )
      if (activeCourseIdRef.current !== courseId) return
      setQuery('')
      clearSearch()
      await refreshAfterMutation(courseId)
      if (activeCourseIdRef.current !== courseId) return
      ensureAncestorsExpanded(downloaded.relPath)
      setSelectedRelPath(downloaded.relPath)
    } catch (downloadError) {
      console.error('[Bandal] 링크를 자료로 저장하지 못했습니다.', downloadError)
      showToast(
        operationError(downloadError, '링크를 자료로 저장하지 못했습니다.'),
        'danger'
      )
    } finally {
      downloadPendingRef.current = false
      setDownloadingDirRelPath(null)
    }
  }

  const handleContextMenu = (
    event: React.MouseEvent,
    target: MaterialNode | null
  ): void => {
    if (course === null || course.missing) return
    event.preventDefault()
    event.stopPropagation()
    setEditing(null)
    setSelectedRelPath(target?.relPath ?? null)
    setContextMenu({
      target,
      x: event.clientX,
      y: event.clientY,
      placement: event.clientY > window.innerHeight / 2 ? 'top' : 'bottom',
      align: event.clientX > window.innerWidth / 2 ? 'end' : 'start',
      returnFocus: event.currentTarget as HTMLElement
    })
  }

  const writeClipboard = async (value: string): Promise<void> => {
    setContextMenu(null)
    try {
      await navigator.clipboard.writeText(value)
      showToast('경로를 복사했어요.')
    } catch (clipboardError) {
      console.error('[Bandal] 경로를 복사하지 못했습니다.', clipboardError)
      showToast('경로를 복사하지 못했습니다.', 'danger')
    }
  }

  const createFile = async (target: MaterialNode | null): Promise<void> => {
    if (course === null) return
    setContextMenu(null)
    const dirRelPath = targetDirectory(target)
    try {
      const created = await invoke('notes:create', {
        courseId: course.id,
        dirRelPath,
        title: '새 파일'
      })
      if (activeCourseIdRef.current !== course.id) { showToast('원래 과목에 새 파일을 만들었어요.'); return }
      ensureAncestorsExpanded(created.relPath)
      openMaterialInWorkspace('note', created.relPath)
      await refreshAfterMutation(course.id)
      if (activeCourseIdRef.current !== course.id) return
      setSelectedRelPath(created.relPath)
      setEditing({ relPath: created.relPath, reopenAfterRename: true })
    } catch (createError) {
      console.error('[Bandal] 새 파일을 만들지 못했습니다.', createError)
      showToast('새 파일을 만들지 못했습니다.', 'danger')
    }
  }

  const createFolder = async (target: MaterialNode | null): Promise<void> => {
    if (course === null) return
    setContextMenu(null)
    const dirRelPath = targetDirectory(target)
    const name = unusedFolderName(useMaterialsStore.getState().tree, dirRelPath)
    try {
      const created = await invoke('materials:createFolder', {
        courseId: course.id,
        dirRelPath,
        name
      })
      if (activeCourseIdRef.current !== course.id) return
      ensureAncestorsExpanded(created.relPath)
      await refreshAfterMutation(course.id)
      if (activeCourseIdRef.current !== course.id) return
      setSelectedRelPath(created.relPath)
      setEditing({ relPath: created.relPath, reopenAfterRename: false })
    } catch (createError) {
      console.error('[Bandal] 새 폴더를 만들지 못했습니다.', createError)
      showToast('새 폴더를 만들지 못했습니다.', 'danger')
    }
  }

  const duplicate = async (target: MaterialNode): Promise<void> => {
    if (course === null) return
    setContextMenu(null)
    try {
      const duplicated = await invoke('materials:duplicate', {
        courseId: course.id,
        relPath: target.relPath
      })
      if (activeCourseIdRef.current !== course.id) return
      ensureAncestorsExpanded(duplicated.relPath)
      await refreshAfterMutation(course.id)
      if (activeCourseIdRef.current !== course.id) return
      setSelectedRelPath(duplicated.relPath)
      showToast('자료를 복제했어요.')
    } catch (duplicateError) {
      console.error('[Bandal] 자료를 복제하지 못했습니다.', duplicateError)
      showToast('자료를 복제하지 못했습니다.', 'danger')
    }
  }

  const reveal = async (target: MaterialNode): Promise<void> => {
    if (course === null) return
    setContextMenu(null)
    try {
      await invoke('materials:reveal', {
        courseId: course.id,
        relPath: target.relPath
      })
    } catch (revealError) {
      console.error('[Bandal] 폴더에서 자료를 표시하지 못했습니다.', revealError)
      showToast('폴더에서 자료를 표시하지 못했습니다.', 'danger')
    }
  }

  const beginRename = (target: MaterialNode): void => {
    setContextMenu(null)
    setQuery('')
    clearSearch()
    ensureAncestorsExpanded(target.relPath)
    setEditing({ relPath: target.relPath, reopenAfterRename: false })
  }

  const rename = async (
    node: MaterialNode,
    newName: string
  ): Promise<string | null> => {
    if (course === null) return '과목을 선택하세요.'
    try {
      let noteRef = { courseId: course.id, relPath: node.relPath }
      if (node.kind === 'note') {
        const flushed = await flushOpenNoteSession(noteRef)
        if (
          flushed !== null &&
          flushed.result.status !== 'saved' &&
          flushed.result.status !== 'unavailable'
        ) {
          showToast('저장되지 않아 이름을 변경하지 않았습니다.', 'danger')
          return flushed.result.detail
        }
        if (flushed !== null) noteRef = flushed.ref
      }

      let renamedRelPath: string
      if (node.kind === 'note') {
        // The rename can rewrite the H1 and references. Compare with the bytes
        // before the request so live sessions retain concurrent body edits.
        const beforeRename = await invoke('notes:read', noteRef)
        const renamed = await invoke('notes:rename', {
          ...noteRef,
          newName
        })
        renamedRelPath = renamed.relPath
        retargetOpenNoteSession(noteRef, renamed.relPath, renamed.mtime, {
          sourceMarkdown: beforeRename.markdown,
          title: renamed.title,
          markdown: renamed.markdown
        })
      } else {
        const renamed = await invoke('materials:rename', {
          ...noteRef,
          newName
        })
        renamedRelPath = renamed.relPath
      }
      const reconciledNode =
        node.kind === 'note' && node.relPath !== noteRef.relPath
          ? {
              ...node,
              relPath: noteRef.relPath,
              name: materialBaseName(noteRef.relPath)
            }
          : node
      reconcileTabsAfterRename(
        course.id,
        reconciledNode,
        renamedRelPath,
        activeCourseIdRef.current === course.id && editing?.reopenAfterRename === true
      )
      await refreshAfterMutation(course.id)
      if (activeCourseIdRef.current !== course.id) return null
      setSelectedRelPath(renamedRelPath)
      setEditing(null)
      return null
    } catch (renameError) {
      const message = operationError(renameError, '이름을 변경하지 못했습니다.')
      console.error('[Bandal] 자료 이름을 변경하지 못했습니다.', renameError)
      showToast('이름을 변경하지 못했습니다.', 'danger')
      return message
    }
  }

  const confirmDelete = async (): Promise<void> => {
    if (course === null || deleteTarget === null) return
    setDeletePending(true)
    setDeleteError(null)
    try {
      await invoke('materials:delete', {
        courseId: course.id,
        relPath: deleteTarget.relPath
      })
      closeDeletedTabs(course.id, deleteTarget)
      await refreshAfterMutation(course.id)
      if (activeCourseIdRef.current !== course.id) return
      if (
        selectedRelPath !== null &&
        pathIsTargetOrChild(selectedRelPath, deleteTarget.relPath)
      ) {
        setSelectedRelPath(null)
      }
      setDeleteTarget(null)
      showToast('휴지통으로 이동했어요.')
    } catch (deleteFailure) {
      if (activeCourseIdRef.current === course.id) setDeleteError(operationError(deleteFailure, '휴지통으로 이동하지 못했습니다.'))
      else showToast(operationError(deleteFailure, '휴지통으로 이동하지 못했습니다.'), 'danger')
    } finally {
      setDeletePending(false)
    }
  }

  return (
    <MaterialAffordancesProvider courseId={course?.id ?? null}>
    <aside
      ref={sidebarRef}
      className="app-rail app-rail--right"
      role="region"
      tabIndex={0}
      aria-label="자료 사이드바. 포커스한 뒤 Command V로 자료 붙여넣기"
      data-drop-active={isDropActive || undefined}
      data-paste-ready={pasteReady || undefined}
      data-pasting={isPasting || undefined}
      onPaste={onPaste}
      onKeyDown={(event) => {
        // Delete/Backspace = 선택 자료 삭제 (확인 다이얼로그 경유 — 휴지통행).
        if (event.key !== 'Delete' && event.key !== 'Backspace') return
        if (isEditableTarget(event.target)) return
        if (selectedNode === null || deleteTarget !== null) return
        event.preventDefault()
        setDeleteTarget(selectedNode)
      }}
      onFocusCapture={(event) => {
        setPasteFocused(!isEditablePasteTarget(event.target))
      }}
      onBlurCapture={(event) => {
        const next = event.relatedTarget
        if (!(next instanceof Node) || !event.currentTarget.contains(next)) {
          setPasteFocused(false)
        }
      }}
      onMouseDown={(event) => {
        const target = event.target as HTMLElement
        if (
          target.closest('button, input, textarea, a, [contenteditable="true"]') ===
          null
        ) {
          setSelectedRelPath(null)
          event.currentTarget.focus()
        }
      }}
      onDragEnterCapture={(event) => {
        const types = [...event.dataTransfer.types]
        if (
          course === null ||
          course.missing ||
          canAcceptMaterialMove(types) ||
          canAcceptUrlDrop(types) ||
          !isFileDrag(event.dataTransfer)
        ) {
          return
        }
        event.preventDefault()
        setDropActive(true)
      }}
      onDragOverCapture={(event) => {
        const types = [...event.dataTransfer.types]
        if (
          course === null ||
          course.missing ||
          canAcceptMaterialMove(types) ||
          canAcceptUrlDrop(types) ||
          !isFileDrag(event.dataTransfer)
        ) {
          return
        }
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
        setDropActive(true)
      }}
      onDragLeaveCapture={(event) => {
        const types = [...event.dataTransfer.types]
        if (
          canAcceptMaterialMove(types) ||
          canAcceptUrlDrop(types) ||
          !isFileDrag(event.dataTransfer)
        ) {
          return
        }
        const nextTarget = event.relatedTarget
        if (
          nextTarget instanceof Node &&
          event.currentTarget.contains(nextTarget)
        ) {
          return
        }
        setDropActive(false)
        setDropTargetDirRelPath(null)
        setUrlDropTargetDirRelPath(null)
      }}
      onDragEnter={(event) => {
        if (
          course === null ||
          course.missing ||
          downloadingDirRelPath !== null ||
          !canAcceptUrlDrop([...event.dataTransfer.types])
        ) {
          return
        }
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
        setDropTargetDirRelPath(null)
        setUrlDropTargetDirRelPath('')
      }}
      onDragOver={(event) => {
        if (
          course === null ||
          course.missing ||
          downloadingDirRelPath !== null ||
          !canAcceptUrlDrop([...event.dataTransfer.types])
        ) {
          return
        }
        event.preventDefault()
        event.dataTransfer.dropEffect = 'copy'
        setDropTargetDirRelPath(null)
        setUrlDropTargetDirRelPath('')
      }}
      onDragLeave={(event) => {
        if (!canAcceptUrlDrop([...event.dataTransfer.types])) return
        const nextTarget = event.relatedTarget
        if (
          nextTarget instanceof Node &&
          event.currentTarget.contains(nextTarget)
        ) {
          return
        }
        setUrlDropTargetDirRelPath(null)
      }}
      onDrop={(event) => {
        if (course === null || course.missing) return
        const types = [...event.dataTransfer.types]
        const files = [...event.dataTransfer.files]
        const drop = classifyDrop(
          types,
          (type) => event.dataTransfer.getData(type),
          files
        )
        if (drop.kind === 'move') return
        event.preventDefault()
        setDropActive(false)
        setDropTargetDirRelPath(null)
        setUrlDropTargetDirRelPath(null)
        if (drop.kind === 'url') {
          void downloadFromUrl(drop.url, '', drop.fileName)
          return
        }
        if (drop.kind === 'files') {
          // 이 사이드바에서 시작한 자료 드래그가 (폴더 행이 아닌) 사이드바로
          // 되돌아온 경우 = 드래그 취소 의도. 루트로 이동시키지 않고,
          // 드롭 하이라이트·행 활성까지 전부 원상 복구한다.
          if (isSelfMaterialDrop(course.id, files)) {
            clearMaterialFileDrag()
            setSelectedRelPath(null)
            if (document.activeElement instanceof HTMLElement) {
              document.activeElement.blur()
            }
            return
          }
          importFiles(files)
          return
        }
        reportUnsupportedDrop(types)
      }}
    >
      <div className="rail-heading materials-heading">
        <div className="materials-heading__text">
          <h2>자료</h2>
          {course !== null && (
            <span className="materials-heading__course" title={course.name}>
              <CourseMark color={course.color} />
              {course.name}
            </span>
          )}
        </div>
        <div className="materials-heading__actions">
          <input
            ref={fileInputRef}
            type="file"
            multiple
            hidden
            tabIndex={-1}
            aria-hidden="true"
            onChange={(event) => {
              if (course === null || course.missing) return
              const input = event.currentTarget
              const files = Array.from(input.files ?? [])
              input.value = ''
              if (files.length === 0) return
              void importDroppedFiles(course.id, files).then(handleCreated)
            }}
          />
          <Tooltip label="자료 가져오기">
            <button
              type="button"
              className="bare-icon-button"
              data-tour="materials-import"
              aria-label="자료 가져오기"
              disabled={course === null || course.missing || isPasting}
              onClick={() => fileInputRef.current?.click()}
            >
              <MaterialsIcon name="fileImport" />
            </button>
          </Tooltip>
          <Tooltip label="새 폴더 만들기">
            <button
              type="button"
              className="bare-icon-button"
              aria-label="새 폴더 만들기"
              disabled={course === null || course.missing || isPasting}
              onClick={() => void createFolder(selectedNode)}
            >
              <MaterialsIcon name="folderPlus" />
            </button>
          </Tooltip>
          <Tooltip label="자료 새로고침">
            <button
              type="button"
              className="bare-icon-button"
              aria-label="자료 새로고침"
              disabled={course === null || isLoading}
              onClick={() => {
                if (course !== null) void loadTree(course.id)
              }}
            >
              <Icon name="refresh" className={isLoading ? 'is-spinning' : ''} />
            </button>
          </Tooltip>
        </div>
      </div>

      <div className="rail-search">
        <Icon name="search" className="rail-search__icon" />
        <label className="sr-only" htmlFor="material-search">
          파일 검색
        </label>
        <input
          id="material-search"
          type="search"
          placeholder="자료 검색"
          value={query}
          disabled={course === null}
          onChange={(event) => setQuery(event.target.value)}
        />
        {query.length > 0 && (
          <button
            type="button"
            className="rail-search__clear"
            aria-label="검색어 지우기"
            onClick={() => setQuery('')}
          >
            <Icon name="x" />
          </button>
        )}
      </div>

      {error !== null && (
        <div className="rail-error" role="alert">
          <span>{error}</span>
          <button
            type="button"
            onClick={() => {
              if (course === null) return
              if (searching) void search(course.id, query)
              else void loadTree(course.id)
            }}
          >
            다시 시도
          </button>
        </div>
      )}

      <div
        className="app-rail__body materials-body"
        data-paste-target-root={
          pasteReady && pasteDirRelPath === '' ? true : undefined
        }
        data-move-target-root={dropTargetDirRelPath === '' || undefined}
        data-url-target-root={urlDropTargetDirRelPath === '' || undefined}
        data-downloading={downloadingDirRelPath === '' || undefined}
        aria-busy={downloadingDirRelPath === '' || undefined}
        onDragEnter={(event) => {
          if (event.target !== event.currentTarget) return
          if (!canAcceptMaterialMove([...event.dataTransfer.types])) return
          const payload = getCurrentMaterialDrag()
          if (payload === null || payload.courseId !== course?.id) return
          event.preventDefault()
          event.stopPropagation()
          event.dataTransfer.dropEffect = 'move'
          setUrlDropTargetDirRelPath(null)
          setDropTargetDirRelPath('')
        }}
        onDragOver={(event) => {
          if (event.target !== event.currentTarget) return
          if (!canAcceptMaterialMove([...event.dataTransfer.types])) return
          const payload = getCurrentMaterialDrag()
          if (payload === null || payload.courseId !== course?.id) return
          event.preventDefault()
          event.stopPropagation()
          event.dataTransfer.dropEffect = 'move'
          setUrlDropTargetDirRelPath(null)
          setDropTargetDirRelPath('')
        }}
        onDragLeave={(event) => {
          if (event.target !== event.currentTarget) return
          if (!canAcceptMaterialMove([...event.dataTransfer.types])) return
          event.stopPropagation()
          setDropTargetDirRelPath(null)
          setUrlDropTargetDirRelPath(null)
        }}
        onDrop={(event) => {
          if (event.target !== event.currentTarget) return
          const types = [...event.dataTransfer.types]
          const drop = classifyDrop(
            types,
            (type) => event.dataTransfer.getData(type),
            [...event.dataTransfer.files]
          )
          if (drop.kind !== 'move') return
          event.preventDefault()
          event.stopPropagation()
          setDropTargetDirRelPath(null)
          const payload = parseMaterialMoveDrag(
            event.dataTransfer.getData(MATERIAL_MOVE_MIME)
          )
          if (payload !== null && payload.courseId === course?.id) {
            void moveMaterial(payload, '')
          }
        }}
      >
        {pasteNotice !== null && (
          <div className="materials-paste-notice" role="status">
            <MaterialsIcon name="fileImport" />
            <span>{pasteNotice}</span>
          </div>
        )}
        {course === null ? (
          <div className="empty-state empty-state--materials">
            <Icon name="folder" className="empty-state__folder" />
            <p className="empty-state__text">과목이나 학습 공간을 선택하세요</p>
            <p className="empty-state__hint">선택한 공간의 자료가 여기에 표시됩니다.</p>
          </div>
        ) : (
          <>
            <WhiteboardsGroup courseId={course.id} />
            <section
              className="materials-files-group"
              aria-label="자료 파일"
              onContextMenu={(event) => handleContextMenu(event, null)}
            >
              <div className="materials-group-heading">
                <button className="materials-section-toggle" aria-expanded={filesOpen || searching} onClick={() => setFilesOpen(!filesOpen)}><span aria-hidden="true">{filesOpen || searching ? '⌄' : '›'}</span>파일</button>
                {downloadingDirRelPath === '' && (
                  <span className="materials-download-status" role="status">
                    <Icon name="refresh" className="is-spinning" />
                    저장 중…
                  </span>
                )}
              </div>
              <div hidden={!filesOpen && !searching}>
              {course.missing ? (
                <div className="empty-state empty-state--materials">
                  <Icon name="folder" className="empty-state__folder" />
                  <p className="empty-state__text">폴더 연결이 끊겼어요</p>
                  <p className="empty-state__hint" title={course.folderPath}>
                    {course.folderPath} 을(를) 찾을 수 없어요. 폴더를 옮겼다면 다시
                    연결해주세요.
                  </p>
                  <button
                    type="button"
                    className="button button--primary"
                    disabled={isRelinking}
                    onClick={() => void relink(course.id)}
                  >
                    <Icon name="link" />
                    {isRelinking ? '연결 중…' : '다시 연결'}
                  </button>
                </div>
              ) : pendingSearch || (isLoading && !searching) ? (
                <div className="loading-list" aria-label="자료 불러오는 중">
                  <span />
                  <span />
                  <span />
                </div>
              ) : searching ? (
                searchResults.length === 0 ? (
                  <div className="rail-zero-result">
                    <p>일치하는 자료가 없어요</p>
                    <button type="button" onClick={() => setQuery('')}>
                      전체 자료 보기
                    </button>
                  </div>
                ) : (
                  <MaterialSearchResults
                    courseId={course.id}
                    results={searchResults}
                    selectedRelPath={selectedRelPath}
                    onSelect={(node) => setSelectedRelPath(node.relPath)}
                    onContextMenu={handleContextMenu}
                    onDragEnd={() => setDropTargetDirRelPath(null)}
                  />
                )
              ) : tree.length === 0 ? (
                <div className="empty-state empty-state--materials">
                  <Icon name="folder" className="empty-state__folder" />
                </div>
              ) : (
                <MaterialTree
                  courseId={course.id}
                  nodes={tree}
                  expandedPaths={expandedPaths}
                  editingRelPath={editing?.relPath ?? null}
                  selectedRelPath={selectedRelPath}
                  pasteTargetDirRelPath={
                    pasteReady && pasteDirRelPath !== '' ? pasteDirRelPath : null
                  }
                  dropTargetDirRelPath={dropTargetDirRelPath}
                  urlDropTargetDirRelPath={urlDropTargetDirRelPath}
                  downloadingDirRelPath={downloadingDirRelPath}
                  onToggleFolder={toggleFolder}
                  onSelect={(node) => setSelectedRelPath(node.relPath)}
                  onContextMenu={handleContextMenu}
                  onCancelRename={() => setEditing(null)}
                  onRename={rename}
                  onDropTargetChange={setDropTargetDirRelPath}
                  onUrlDropTargetChange={setUrlDropTargetDirRelPath}
                  onMove={(payload, toDirRelPath) => {
                    void moveMaterial(payload, toDirRelPath)
                  }}
                  onImportFiles={(files, dirRelPath) => {
                    importFiles(files, dirRelPath)
                  }}
                  onDownloadUrl={(url, dirRelPath, fileName) => {
                    void downloadFromUrl(url, dirRelPath, fileName)
                  }}
                  onUnsupportedDrop={(types) => {
                    setDropActive(false)
                    reportUnsupportedDrop(types)
                  }}
                />
              )}
              </div>
            </section>
          </>
        )}
      </div>

      <WidgetDock />

      {contextMenu !== null && (
        <MaterialsContextMenu
          {...contextMenu}
          onClose={closeContextMenu}
          onCreateFile={() => void createFile(contextMenu.target)}
          onCreateFolder={() => void createFolder(contextMenu.target)}
          onDuplicate={() => {
            if (contextMenu.target !== null) void duplicate(contextMenu.target)
          }}
          onCopyAbsolutePath={() => {
            if (course === null) return
            void writeClipboard(
              absoluteMaterialPath(
                course.folderPath,
                contextMenu.target?.relPath ?? ''
              )
            )
          }}
          onCopyRelativePath={() => {
            void writeClipboard(contextMenu.target?.relPath ?? '.')
          }}
          onReveal={() => {
            if (contextMenu.target !== null) void reveal(contextMenu.target)
          }}
          onConnect={() => {
            const target = contextMenu.target
            if (target === null || target.kind === 'dir') return
            setLinkTarget(target)
            setContextMenu(null)
          }}
          onPageNote={() => {
            const target = contextMenu.target
            if (course === null || target === null || (target.kind !== 'pdf' && !/\.pptx?$/i.test(target.relPath))) return
            useWorkspaceStore.getState().openTab(
              descriptorFor(target.kind === 'pdf' ? 'pdf' : 'file', { courseId: course.id, relPath: target.relPath })
            )
            requestOpenPdfPageNote({ courseId: course.id, relPath: target.relPath })
            setContextMenu(null)
          }}
          onRename={() => {
            if (contextMenu.target !== null) beginRename(contextMenu.target)
          }}
          onDelete={() => {
            if (contextMenu.target === null) return
            setDeleteError(null)
            setDeleteTarget(contextMenu.target)
            setContextMenu(null)
          }}
        />
      )}

      {course !== null && !course.missing && linkTarget !== null && (
        <LinkPickerDialog
          courseId={course.id}
          sourceRelPath={linkTarget.relPath}
          onClose={() => setLinkTarget(null)}
        />
      )}

      <MaterialDeleteDialog
        target={deleteTarget}
        pending={deletePending}
        error={deleteError}
        onClose={closeDeleteDialog}
        onConfirm={confirmDelete}
      />
    </aside>
    </MaterialAffordancesProvider>
  )
}
