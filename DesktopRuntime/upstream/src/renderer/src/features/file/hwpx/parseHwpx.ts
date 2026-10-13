/**
 * HWPX(OWPML, zip 컨테이너)의 본문 텍스트 추출 — 순수 함수.
 * 서식·표·이미지는 다루지 않는다: "본문 텍스트 미리보기"가 목표다.
 */

/** Contents/section*.xml 경로를 섹션 번호 순으로 정렬한다. */
export function sortSectionPaths(paths: readonly string[]): string[] {
  const sectionNumber = (path: string): number => {
    const match = /section(\d+)\.xml$/iu.exec(path)
    return match === null ? Number.MAX_SAFE_INTEGER : Number(match[1])
  }
  return [...paths].sort((left, right) =>
    sectionNumber(left) - sectionNumber(right) || left.localeCompare(right)
  )
}

/**
 * 섹션 XML들에서 문단 텍스트를 뽑는다. 네임스페이스 접두사(hp: 등)에
 * 의존하지 않고 localName 으로 매칭한다. 파싱 불가 XML 은 건너뛴다.
 */
export function parseHwpxSections(sectionXmls: readonly string[]): string[] {
  const paragraphs: string[] = []
  const parser = new DOMParser()
  for (const xml of sectionXmls) {
    const document_ = parser.parseFromString(xml, 'application/xml')
    if (document_.getElementsByTagName('parsererror').length > 0) continue
    const all = document_.getElementsByTagName('*')
    for (const element of Array.from(all)) {
      if (element.localName !== 'p') continue
      let text = ''
      for (const child of Array.from(element.getElementsByTagName('*'))) {
        if (child.localName === 't') text += child.textContent ?? ''
      }
      paragraphs.push(text)
    }
  }
  return paragraphs
}
