import type { LearningBinding } from '../../../../shared/types/learning'
import { showToast } from '../../app/toast'
import { useWorkflowPacksStore } from '../../stores/workflowPacksStore'
import { useCoursesStore } from '../../stores/coursesStore'
import { requestFeatureAction, studyToolFeatureEntry } from '../launcher/featureActions'
import { captureLauncherContext, EMPTY_LAUNCHER_CONTEXT } from '../launcher/launcherContext'
import { studyToolFromPack } from '../study/studyToolsStore'
import { requestLearningCreation } from './LearningDialogsHost'
import { learningError } from './learningNavigation'

export function launchNewLearning(kind: 'english' | 'quiz' | 'flashcards', options: { binding?: LearningBinding; sourceCourseId?: string } = {}): void {
  if (kind === 'english') { requestLearningCreation(); return }
  void (async () => {
    await useWorkflowPacksStore.getState().load()
    const summary = useWorkflowPacksStore.getState().packs.find(item => item.pack.id === kind && item.pack.schemaVersion === 2)
    if (!summary) throw new Error('학습 기능을 불러오지 못했어요. 도구 관리에서 확인해 주세요.')
    const captured = await captureLauncherContext()
    const mismatchedBinding = options.binding && captured.binding && (captured.binding.courseId !== options.binding.courseId || captured.binding.rootRelPath !== options.binding.rootRelPath)
    const hasSource = captured.material?.relPath || captured.browser || captured.articleIds.length || captured.wordIds.length
    const context = mismatchedBinding || options.sourceCourseId && !hasSource
      ? { ...EMPTY_LAUNCHER_CONTEXT, courseId: options.sourceCourseId ?? null, courseName: useCoursesStore.getState().courses.find(course => course.id === options.sourceCourseId)?.name ?? null } : captured
    const result = await requestFeatureAction(studyToolFeatureEntry(studyToolFromPack(summary)), context, options)
    if (result.status === 'failed') throw new Error(result.message)
  })().catch(caught => showToast(learningError(caught), 'danger'))
}
