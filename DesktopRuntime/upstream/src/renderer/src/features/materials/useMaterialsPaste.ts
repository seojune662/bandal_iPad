import { useCallback, useEffect, useRef, useState, type ClipboardEvent } from 'react'
import { showToast } from '../../app/toast'
import { invoke, pathForFile } from '../../lib/ipc'
import { useMaterialsStore } from '../../stores/materialsStore'
import {
  fileToBase64,
  isShortWebUrl,
  markdownForPastedText,
  pastedImageFileName,
  pastedTextFileName,
  planClipboardPaste,
  shouldHandleMaterialsPaste,
  snapshotClipboard
} from './clipboardPaste'
import { importMaterialPaths } from './importDrop'

interface MaterialsPasteOptions {
  enabled: boolean
  courseId: string | null
  courseName: string | null
  dirRelPath: string
  destinationName: string
  onCreated: (relPaths: string[]) => void
}

interface MaterialsPasteResult {
  pasteNotice: string | null
  isPasting: boolean
  onPaste: (event: ClipboardEvent<HTMLElement>) => void
}

function nextPaint(): Promise<void> {
  return new Promise((resolve) => {
    window.requestAnimationFrame(() => resolve())
  })
}

export function useMaterialsPaste({
  enabled,
  courseId,
  courseName,
  dirRelPath,
  destinationName,
  onCreated
}: MaterialsPasteOptions): MaterialsPasteResult {
  const [pasteNotice, setPasteNotice] = useState<string | null>(null)
  const [isPasting, setIsPasting] = useState(false)
  const clearTimerRef = useRef<number | null>(null)
  const activeCourse = useRef(courseId)
  activeCourse.current = courseId
  const pending = useRef(false)

  const showNotice = useCallback((message: string, clearAfter = false): void => {
    if (clearTimerRef.current !== null) {
      window.clearTimeout(clearTimerRef.current)
      clearTimerRef.current = null
    }
    setPasteNotice(message)
    if (clearAfter) {
      clearTimerRef.current = window.setTimeout(() => {
        setPasteNotice(null)
        clearTimerRef.current = null
      }, 1600)
    }
  }, [])

  useEffect(
    () => () => {
      if (clearTimerRef.current !== null) window.clearTimeout(clearTimerRef.current)
    },
    []
  )

  useEffect(() => { setPasteNotice(null) }, [courseId])

  const paste = useCallback(
    async (plan: ReturnType<typeof planClipboardPaste>): Promise<void> => {
      if (courseId === null || courseName === null) {
        showToast('먼저 과목을 선택하세요.', 'danger')
        return
      }
      if (plan.kind === 'empty' || plan.kind === 'unsupported') {
        showToast(plan.reason, 'danger')
        return
      }

      const isFileImport = plan.kind === 'files'
      const targetName = isFileImport ? `${courseName} 루트` : destinationName
      showNotice(`${targetName}에 추가됩니다`)
      setIsPasting(true)
      await nextPaint()

      const created: string[] = []
      try {
        if (plan.kind === 'files') {
          const imported = await importMaterialPaths(courseId, plan.paths)
          if (activeCourse.current !== courseId) return
          onCreated(imported)
          if (imported.length > 0) showNotice(`${targetName}에 추가했어요`, true)
          else showNotice('추가된 파일이 없어요', true)
          return
        }

        if (plan.kind === 'images') {
          const timestamp = new Date()
          for (const file of plan.files) {
            const result = await invoke('materials:writeFile', {
              courseId,
              dirRelPath,
              fileName: pastedImageFileName(file, timestamp),
              encoding: 'base64',
              data: await fileToBase64(file)
            })
            created.push(result.relPath)
          }
        } else {
          const trimmed = plan.text.trim()
          const asLink =
            isShortWebUrl(trimmed) &&
            window.confirm('URL을 클릭 가능한 링크 자료로 저장할까요?')
          const result = await invoke('materials:writeFile', {
            courseId,
            dirRelPath,
            fileName: pastedTextFileName(new Date()),
            encoding: 'utf8',
            data: markdownForPastedText(plan.text, asLink)
          })
          created.push(result.relPath)
        }

        await useMaterialsStore.getState().loadTree(courseId, { refreshOnly: true })
        if (activeCourse.current !== courseId) return
        onCreated(created)
        showToast(
          created.length === 1 ? '자료를 붙여넣었어요.' : `${created.length}개 붙여넣었어요.`
        )
        showNotice(`${targetName}에 추가했어요`, true)
      } catch (error) {
        if (created.length > 0) {
          await useMaterialsStore.getState().loadTree(courseId, { silent: true, refreshOnly: true })
          if (activeCourse.current === courseId) onCreated(created)
        }
        const message =
          error instanceof Error ? error.message : '클립보드 자료를 추가하지 못했습니다.'
        console.error('[Bandal] 클립보드 자료를 추가하지 못했습니다.', error)
        showToast(message, 'danger')
        if (activeCourse.current === courseId) showNotice('붙여넣지 못했어요', true)
      } finally {
        setIsPasting(false)
      }
    }, [courseId, courseName, destinationName, dirRelPath, onCreated, showNotice]
  )

  const onPaste = useCallback(
    (event: ClipboardEvent<HTMLElement>): void => {
      if (!shouldHandleMaterialsPaste(enabled, event.target)) return
      event.preventDefault()
      if (pending.current) {
        showToast('이전 자료를 붙여넣는 중이에요.', 'danger')
        return
      }
      const plan = planClipboardPaste(snapshotClipboard(event.clipboardData), pathForFile)
      pending.current = true
      void paste(plan).finally(() => { pending.current = false })
    },
    [enabled, paste]
  )

  return { pasteNotice, isPasting, onPaste }
}
