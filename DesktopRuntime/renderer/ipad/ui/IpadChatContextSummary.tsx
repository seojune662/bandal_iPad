import { useMaterialContext } from '../../../upstream/src/renderer/src/features/chat/ContextChips'
import { useComposerDraft } from '../../../upstream/src/renderer/src/features/chat/composerDraftStore'

/** Persistent context at the top; attachment editing stays in the composer. */
export function IpadChatContextSummary({ courseId, conversationId, sourcePanelId }: {
  courseId: string; conversationId: string; sourcePanelId?: string | undefined
}): JSX.Element {
  const { snapshot, error } = useMaterialContext(courseId, sourcePanelId)
  const draft = useComposerDraft(conversationId)
  const material = draft.excludeCurrentMaterial ? undefined : snapshot?.material
  const attached = draft.files.length + draft.images.length + (draft.quotes?.length ?? 0) + Number(draft.browser) + Number(draft.screen)
  const failed = error || snapshot?.refresh === 'failed' || material?.unavailable
  const title = material ? `${material.title}${material.page ? ` · ${material.page}쪽` : ''}` : snapshot?.courseName ?? '현재 과목'
  const details = [
    material && snapshot?.courseName,
    material?.selection && '선택한 글 포함',
    material?.unsaved && '저장 전 필기 포함',
    attached > 0 && `첨부 ${attached}개`,
    draft.skills.length > 0 && `도구 ${draft.skills.length}개`,
    failed && '자료 연결을 확인할 수 없어요',
    !material && !attached && !failed && (draft.excludeCurrentMaterial ? '현재 자료 연결 해제됨' : '과목의 자료를 참고해요')
  ].filter(Boolean).join(' · ')
  return <section className="ipad-chat-context-summary" aria-label="현재 대화 자료">
    <strong title={title}>{title}</strong>
    {details && <span>{details}</span>}
  </section>
}
