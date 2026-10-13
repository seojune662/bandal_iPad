/**
 * bandal-media:// URL 빌더 — main 의 mediaProtocol.ts(parseMediaUrl)와
 * 인코딩 규약이 반드시 일치해야 한다.
 *
 * 형식: bandal-media://material/<encodeURIComponent(courseId)>/<seg>/<seg>/…
 * relPath 는 '/' 를 포함할 수 있으므로 세그먼트별로 encodeURIComponent 한다
 * (전체를 한 번에 인코딩하면 '/'(%2F)가 경로 구분자와 섞여 모호해진다).
 */
export function mediaUrlFor(courseId: string, relPath: string): string {
  const segments = relPath
    .split('/')
    .map((segment) => encodeURIComponent(segment))
    .join('/')
  return `bandal-media://material/${encodeURIComponent(courseId)}/${segments}`
}
