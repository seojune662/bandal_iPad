import { fetchLmsList, lmsTargetFor, type LmsListKind } from '../../upstream/src/main/features/browserAgent/siteRecipes'
import { createSeenRepo, itemKey } from '../../upstream/src/main/features/browserAgent/seenRepo'
import { resolveUniversity } from '../../upstream/src/shared/universities'
import { getSettings } from '../../upstream/src/main/settingsStore'

/** Original Canvas parsers and seen-history repository, with a cookie-scoped
 * native GET transport. Moodle remains the original explicit unsupported case. */
export function createLMSBrowserTools(deps: {
  db: any; courseId: string; courseLinks: any; enabled: () => void
  gate: (url: string, capability: 'read') => Promise<void>
  native: (tool: string, input?: any) => Promise<any>
  log: (action: 'read', url: string, detail: string) => void
}) {
  const seen = createSeenRepo(deps.db)
  const kinds: LmsListKind[] = ['announcements','assignments','modules','files']
  function target(requested: string) {
    deps.enabled()
    if (requested !== deps.courseId) throw new Error('이 대화에 연결된 과목의 강의실만 사용할 수 있어요.')
    const spec = resolveUniversity(getSettings().university)?.courseLink
    for (const link of deps.courseLinks.list({courseId:requested})) {
      let matches = false
      try { matches = !!spec && new RegExp(spec.idPattern).test(link.url) } catch {}
      const result = lmsTargetFor(link, matches && spec ? {platform:spec.platform} : null)
      if (result) return { target:result, url:link.url }
    }
    return null
  }
  async function list(requested: string, rawKind: string | null, onlyNew: boolean) {
    const selected = target(requested)
    if (!selected) return {status:'error',message:'이 과목에 학교 강의실이 연결돼 있지 않아요. 과목 링크를 먼저 추가해 주세요.'}
    const {target:lms} = selected
    const kind = kinds.includes(rawKind as LmsListKind) ? rawKind as LmsListKind : onlyNew ? 'announcements' : 'files'
    await deps.gate(lms.origin,'read')
    const result = await fetchLmsList({fetch: async url => {
      const response = await deps.native('lmsFetch',{url,origin:lms.origin})
      if (!Number.isInteger(response.httpStatus) || response.httpStatus < 200 || response.httpStatus > 599 || typeof response.text !== 'string') throw new Error('강의실 응답을 확인하지 못했어요.')
      // JavaScriptCore has no DOM Response constructor. The original recipe
      // consumes these three properties only; body/status are the real native
      // HTTP reply and JSON failures remain failures.
      return {status:response.httpStatus,ok:response.httpStatus >= 200 && response.httpStatus < 300,json:async()=>JSON.parse(response.text)} as Response
    }},lms,kind)
    deps.enabled()
    if (result.status !== 'ok') { deps.log('read',lms.origin,`${kind}: ${result.message}`); return {status:'error',message:result.message} }
    let items = result.items
    let firstRun = false
    if (onlyNew) {
      const listKey = `${lms.origin}|${lms.lmsCourseId}|${kind}`
      const indexed = items.map(item => ({key:itemKey(item.id,item.title,item.at),title:item.title}))
      firstRun = !seen.has(requested,listKey)
      if (firstRun) { seen.seed({courseId:requested,listKey,items:indexed}); items = [] }
      else {
        const keys = new Set(seen.diffAndRecord({courseId:requested,listKey,items:indexed}).map(item => item.key))
        items = items.filter(item => keys.has(itemKey(item.id,item.title,item.at)))
      }
    }
    deps.log('read',lms.origin,`${kind}: ${items.length}건${firstRun ? ' · 처음 확인' : ''}`)
    return {status:'ok',kind,items:items.map(item=>({title:item.title,at:item.at,url:item.url})),...(onlyNew ? {firstRun} : {})}
  }
  return {
    lms_course_page(requested: string) { const selected = target(requested); return {url:selected?.url ?? null,platform:selected?.target.platform ?? null} },
    lms_list: (requested: string, kind: string | null) => list(requested,kind,false),
    lms_new_items: (requested: string, kind: string | null) => list(requested,kind,true)
  }
}
