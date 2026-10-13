import type { LearningBinding, LearningSourceRef } from '../../../../shared/types/learning'
import { createBrowserTab } from '../../app/tabCommands'
import { Icon } from '../../app/icons'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { kindForMaterialName } from '../materials/materialPaths'
import { openMaterialInCourse } from '../workspace/openMaterial'
import { requestPdfPageNavigation } from '../pdf/pdfPageNavigation'

export function LearningSources({ sources, binding, onArticle }: { sources: LearningSourceRef[]; binding: LearningBinding; onArticle: (id: string) => void }): JSX.Element | null {
  if (sources.length === 0) return null
  return <div className="learning-sources">{sources.map((source, index) => <button key={index} type="button" className="learning-text-button" title={source.quote} disabled={source.availability === 'missing' || source.availability === 'changed'} onClick={() => {
    if (source.kind === 'article' && source.articleId) onArticle(source.articleId)
    else if (source.relPath) void invoke('learning:resolveSource', { binding, sourceRef: source }).then(result => {
      if (result.missing || result.relPath === null) { showToast('원문 자료를 찾을 수 없어요. 저장된 예문은 계속 볼 수 있습니다.', 'danger'); return }
      const courseId = result.sourceCourseId ?? source.sourceCourseId ?? binding.courseId
      const kind = kindForMaterialName(result.relPath)
      openMaterialInCourse(courseId, kind, result.relPath)
      if (kind === 'pdf' && source.page) requestPdfPageNavigation({ courseId, relPath: result.relPath, page: source.page })
    }).catch(() => showToast('원문 자료를 열지 못했어요.', 'danger'))
    else if (source.url) createBrowserTab(source.url)
  }}><Icon name="link" />{source.title ?? source.relPath ?? '원문 예문'}{source.page ? ` · ${source.page}쪽` : ''}{source.availability === 'missing' ? ' · 원문 없음' : source.availability === 'changed' ? ' · 원문 변경됨' : ''}</button>)}</div>
}
