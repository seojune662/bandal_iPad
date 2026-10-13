/**
 * [M5] Drop-target hook for Finder file drops. Returns spreadable drag
 * handlers plus an `isDropActive` flag for the highlight. Depth-counted so
 * child elements don't flicker the highlight off, and inert while no course
 * is selected.
 */

import { useCallback, useRef, useState, type DragEvent } from 'react'
import { importDroppedFiles, isFileDrag } from './importDrop'

export interface FileDropTarget {
  isDropActive: boolean
  dropProps: {
    onDragEnter: (event: DragEvent<HTMLElement>) => void
    onDragOver: (event: DragEvent<HTMLElement>) => void
    onDragLeave: (event: DragEvent<HTMLElement>) => void
    onDrop: (event: DragEvent<HTMLElement>) => void
  }
}

export function useFileDropTarget(courseId: string | null): FileDropTarget {
  const [isDropActive, setDropActive] = useState(false)
  const depthRef = useRef(0)

  const reset = useCallback((): void => {
    depthRef.current = 0
    setDropActive(false)
  }, [])

  const onDragEnter = useCallback(
    (event: DragEvent<HTMLElement>): void => {
      if (courseId === null || !isFileDrag(event.dataTransfer)) return
      event.preventDefault()
      depthRef.current += 1
      setDropActive(true)
    },
    [courseId]
  )

  const onDragOver = useCallback(
    (event: DragEvent<HTMLElement>): void => {
      if (courseId === null || !isFileDrag(event.dataTransfer)) return
      event.preventDefault()
      event.dataTransfer.dropEffect = 'copy'
    },
    [courseId]
  )

  const onDragLeave = useCallback(
    (event: DragEvent<HTMLElement>): void => {
      if (courseId === null || !isFileDrag(event.dataTransfer)) return
      depthRef.current = Math.max(0, depthRef.current - 1)
      if (depthRef.current === 0) setDropActive(false)
    },
    [courseId]
  )

  const onDrop = useCallback(
    (event: DragEvent<HTMLElement>): void => {
      if (courseId === null || !isFileDrag(event.dataTransfer)) return
      event.preventDefault()
      reset()
      const files = [...event.dataTransfer.files]
      if (files.length > 0) void importDroppedFiles(courseId, files)
    },
    [courseId, reset]
  )

  return {
    isDropActive,
    dropProps: { onDragEnter, onDragOver, onDragLeave, onDrop }
  }
}
