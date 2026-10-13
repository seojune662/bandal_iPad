import type { DrawingImageSource } from '../../../../shared/types/drawing'
import { pathForFile } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { relPathInsideCourse } from './importDrop'
import { kindForMaterialName } from './materialPaths'

type FilePathResolver = (file: File) => string

/** Resolves the first native dropped file to an image in this course. */
export function imageSourceFromFileDrop(
  courseId: string,
  dataTransfer: DataTransfer,
  resolveFilePath: FilePathResolver = pathForFile
): DrawingImageSource | null {
  const file = dataTransfer.files[0]
  if (file === undefined) return null
  const absolutePath = resolveFilePath(file)
  if (absolutePath.length === 0) return null
  const courseFolder = useCoursesStore
    .getState()
    .courses.find((course) => course.id === courseId)?.folderPath
  if (courseFolder === undefined) return null
  const relPath = relPathInsideCourse(absolutePath, courseFolder)
  if (relPath === null || kindForMaterialName(relPath) !== 'image') return null
  return { relPath, label: file.name }
}
