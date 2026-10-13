import { readFile, stat } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import { posix } from 'node:path'
import type { LearningBinding, LearningSourceRef } from '../../../shared/types/learning'
import { ValidationError } from '../../db/errors'
import { resolveInsideReal } from '../../db/validate'
import { learningPage } from './validation'
import { extractLearningMaterialSource, type LearningMaterialSource } from './materialSource'

const normalize = (text: string): string => text.normalize('NFC').replace(/\s+/gu, ' ').trim()

/** Resolves citations inside their course, with exact retained content as evidence. */
export function createLearningGrounding(getCourseFolder: (courseId: string) => string) {
  const sourcePath = (binding: LearningBinding, ref: LearningSourceRef): string =>
    ref.pathScope === 'course' ? ref.relPath ?? '' : posix.join(binding.rootRelPath, ref.relPath ?? '')
  async function material(binding: LearningBinding, relPath: string, sourceCourseId = binding.courseId, page?: number) {
      const absPath = resolveInsideReal(getCourseFolder(sourceCourseId), relPath)
      const source = await extractLearningMaterialSource(absPath)
      if (!source?.text.trim()) throw new Error('이 자료에서 학습에 사용할 텍스트를 찾지 못했어요.')
      if (page !== undefined) {
        const pageNumber = learningPage(page)
        const selected = source.pages.find(entry => entry.page === pageNumber)
        if (!selected?.text.trim()) throw new ValidationError('선택한 PDF 페이지의 본문을 찾지 못했어요. 원본 페이지를 다시 확인하세요.')
        return { ...source, text: selected.text, pages: [selected] }
      }
      return source
  }
  function validator(binding: LearningBinding, linkedCourseId?: string): (ref: LearningSourceRef) => Promise<void> {
    const sources = new Map<string, Promise<LearningMaterialSource>>()
    return async ref => {
      const sourceCourseId = ref.sourceCourseId ?? binding.courseId
      if (ref.sourceCourseId && (ref.pathScope !== 'course' || (sourceCourseId !== binding.courseId && sourceCourseId !== linkedCourseId))) throw new ValidationError('연결되지 않은 과목의 출처입니다.')
      const relPath = sourcePath(binding, ref)
      const key = `${sourceCourseId}:${relPath}`
      if (!sources.has(key)) sources.set(key, material(binding, relPath, sourceCourseId))
      const source = await sources.get(key)!
      if (ref.contentHash && ref.contentHash !== source.contentHash) throw new Error('자료가 생성할 때와 달라졌어요. 최신 자료로 다시 생성하세요.')
      const text = ref.page === undefined ? source.text : source.pages.find(page => page.page === ref.page)?.text
      if (!text || !normalize(text).includes(normalize(ref.quote))) throw new Error('학습 자료의 근거 문장이 원본에 없어요.')
      ref.contentHash = source.contentHash
    }
  }
  return {
    material, validator,
    validateMaterial: (binding: LearningBinding, ref: LearningSourceRef, linkedCourseId?: string) => validator(binding, linkedCourseId)(ref),
    async resolve(binding: LearningBinding, ref: LearningSourceRef, linkedCourseId?: string): Promise<{ relPath: string | null; missing: boolean; sourceCourseId?: string }> {
      try {
        if (ref.availability === 'missing' || ref.availability === 'changed') return { relPath: null, missing: true }
        const sourceCourseId = ref.sourceCourseId ?? binding.courseId
        if (ref.sourceCourseId && (ref.pathScope !== 'course' || (sourceCourseId !== binding.courseId && sourceCourseId !== linkedCourseId))) return { relPath: null, missing: true }
        const relPath = sourcePath(binding, ref)
        const absPath = resolveInsideReal(getCourseFolder(sourceCourseId), relPath)
        if ((await stat(absPath)).size > 50 * 1024 * 1024) return { relPath: null, missing: true }
        const bytes = await readFile(absPath)
        if (ref.contentHash && createHash('sha256').update(bytes).digest('hex') !== ref.contentHash) return { relPath: null, missing: true }
        return { relPath, missing: false, ...(ref.sourceCourseId ? { sourceCourseId } : {}) }
      } catch { return { relPath: null, missing: true } }
    }
  }
}
