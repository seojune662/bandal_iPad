import type { StudyToolId } from '../types/study'
import {
  WORKFLOW_PACK_SCHEMA_VERSION,
  LEGACY_WORKFLOW_PACK_SCHEMA_VERSION,
  type WorkflowPack,
  type WorkflowPackV1,
  type WorkflowPackV2,
  type WorkflowPackScope
} from '../types/workflowPack'

interface LegacyStudyPack extends WorkflowPackV1 {
  id: StudyToolId
}

const COURSE_SCOPES = [
  'course',
  'material',
  'selection'
] as const satisfies readonly WorkflowPackScope[]
const MATERIAL_SCOPES = [
  'material',
  'selection'
] as const satisfies readonly WorkflowPackScope[]
const COURSE_TOOLS = [
  'create_note',
  'write_file',
  'list_materials',
  'read_material'
] as const
const MATERIAL_TOOLS = ['create_note', 'write_file', 'read_material'] as const

function studyPack(input: {
  id: StudyToolId
  name: string
  description: string
  worksOnCourse: boolean
  recipe: string
}): LegacyStudyPack {
  return {
    schemaVersion: LEGACY_WORKFLOW_PACK_SCHEMA_VERSION,
    id: input.id,
    name: input.name,
    description: input.description,
    author: 'Bandal',
    version: '1.0.0',
    locale: 'ko-KR',
    worksOn: input.worksOnCourse ? COURSE_SCOPES : MATERIAL_SCOPES,
    recipe: input.recipe,
    allowedTools: input.worksOnCourse ? COURSE_TOOLS : MATERIAL_TOOLS,
    usesWeb: false,
    outputs: {
      dir: 'AI 학습자료',
      primary: input.name
    }
  }
}

/**
 * Stable built-in ids are referenced by the existing study runner. Keep the
 * ids and recipes unchanged; user packs with the same id are resolved by the
 * persistence layer before this catalog is exposed.
 */
export const LEGACY_STUDY_PACKS: readonly LegacyStudyPack[] = [
  studyPack({
    id: 'summary',
    name: '요약',
    description: '핵심 개념과 자료의 구조, 놓치기 쉬운 부분을 요약합니다.',
    worksOnCourse: true,
    recipe: [
      '자료를 시험 복습에 유용한 요약 노트로 재구성하라.',
      '- 먼저 자료 전체의 흐름과 구조를 짧게 보여 줘라.',
      '- 핵심 개념마다 정의, 역할, 개념 간 관계를 정리하라.',
      '- 공식이나 절차가 있다면 각 기호와 단계의 의미를 설명하라.',
      '- 학생이 지나치기 쉬운 예외, 조건, 비교 포인트를 별도 섹션으로 모아라.',
      '- 마지막에 빠른 복습용 핵심 문장을 5~10개로 정리하라.'
    ].join('\n')
  }),
  studyPack({
    id: 'quiz',
    name: '퀴즈',
    description: '객관식과 단답형 문제를 만들고 정답과 해설을 분리합니다.',
    worksOnCourse: true,
    recipe: [
      '자료의 핵심 내용을 스스로 점검할 수 있는 퀴즈를 만들어라.',
      '- 객관식과 단답형을 모두 포함하고, 단순 암기와 이해·적용 문제를 섞어라.',
      '- 객관식에는 서로 그럴듯하지만 명확히 구분되는 선택지를 제공하라.',
      '- 문제 영역에는 답을 암시하는 표현을 넣지 마라.',
      '- 학생이 먼저 풀 수 있도록 모든 문제를 앞부분에 배치하라.',
      '- 문서 하단에 `정답과 해설` 섹션을 따로 만들고, 문제 번호별 정답, 근거, 오답 포인트를 설명하라.'
    ].join('\n')
  }),
  studyPack({
    id: 'flashcards',
    name: '플래시카드',
    description: '복습에 바로 쓸 수 있는 앞면·뒷면 플래시카드 표를 만듭니다.',
    worksOnCourse: true,
    recipe: [
      '자료를 반복 학습용 플래시카드로 변환하라.',
      '- 마크다운 표의 열을 `번호 | 앞면 | 뒷면 | 출처`로 구성하라.',
      '- 앞면에는 한 번에 하나의 개념을 묻는 질문이나 용어를 두고, 뒷면에는 간결하지만 충분한 답을 써라.',
      '- 정의, 공식, 비교, 과정, 예외를 균형 있게 포함하라.',
      '- 문맥 없이도 이해할 수 있게 약어와 기호를 필요한 만큼 풀어 써라.',
      '- 같은 사실을 표현만 바꿔 중복 카드로 만들지 마라.'
    ].join('\n')
  }),
  studyPack({
    id: 'mindmap',
    name: '마인드맵',
    description: '개념 사이의 관계를 Mermaid 마인드맵으로 정리합니다.',
    worksOnCourse: true,
    recipe: [
      '자료의 전체 구조와 개념 관계를 한눈에 볼 수 있는 마인드맵을 만들어라.',
      '- 렌더 가능한 `mermaid` 언어의 `mindmap` 코드 블록을 문서의 중심 결과물로 넣어라.',
      '- 하나의 중심 주제 아래 대주제, 핵심 개념, 세부 근거를 계층적으로 배치하라.',
      '- 노드 문구는 짧게 쓰되 개념 간 포함·대조·인과 관계가 드러나게 구성하라.',
      '- Mermaid 문법을 깨뜨릴 수 있는 불필요한 특수문자와 긴 문장을 피하라.',
      '- 코드 블록 뒤에 주요 연결 관계를 설명하는 짧은 해설을 덧붙여라.'
    ].join('\n')
  }),
  studyPack({
    id: 'structured-notes',
    name: '구조화 노트',
    description: '강의자료를 제목과 하위 항목이 분명한 계층형 노트로 바꿉니다.',
    worksOnCourse: true,
    recipe: [
      '강의자료를 원래 흐름을 보존한 계층적 학습 노트로 재구성하라.',
      '- 제목, 대단원, 소단원, 핵심 항목의 계층이 분명한 마크다운 헤딩을 사용하라.',
      '- 각 단원에 핵심 주장, 정의, 근거·예시, 공식·절차, 주의점을 알맞게 배치하라.',
      '- 흩어진 설명이 같은 개념을 다루면 한곳에 모으되 원래 출처를 잃지 마라.',
      '- 표가 비교나 분류를 더 명확하게 만드는 경우 마크다운 표를 사용하라.',
      '- 마지막에 용어 목록과 단원 간 연결 관계를 정리하라.'
    ].join('\n')
  }),
  studyPack({
    id: 'exam-predictions',
    name: '시험 예상 문제',
    description: '출제 가능성이 높은 문제와 그 근거, 답안 포인트를 제안합니다.',
    worksOnCourse: true,
    recipe: [
      '자료에 근거해 출제 가능성이 높은 시험 예상 문제를 만들어라.',
      '- 각 문제에 문제 유형, 예상 난이도, 출제 가능성을 함께 표시하라.',
      '- 반복 강조, 학습목표, 핵심 정의, 비교 가능한 개념, 계산·적용 가능성을 출제 근거로 제시하라.',
      '- 객관식, 단답형, 서술형, 계산·적용형 중 자료에 맞는 유형을 고르게 사용하라.',
      '- 각 문제 바로 아래가 아니라 문서 하단의 `모범 답안과 채점 포인트` 섹션에 답을 모아라.',
      '- 실제 출제를 확정적으로 예언하지 말고 자료에서 판단할 수 있는 가능성과 근거만 써라.'
    ].join('\n')
  }),
  studyPack({
    id: 'explain',
    name: '개념 설명',
    description: '특정 자료나 선택한 부분의 개념을 단계적으로 풀어 설명합니다.',
    worksOnCourse: false,
    recipe: [
      '대상 자료의 개념을 처음 배우는 학생도 따라올 수 있도록 단계적으로 설명하라.',
      '- 선택한 텍스트가 제공되면 그 부분을 최우선 대상으로 삼고 주변 문맥과 연결해 설명하라.',
      '- 먼저 한 문단 직관, 다음으로 정확한 정의와 원리, 이어서 예시나 비유 순서로 풀어라.',
      '- 수식이나 코드가 있으면 기호와 각 단계를 생략하지 말고 설명하라.',
      '- 자주 생기는 오해와 틀리기 쉬운 추론을 바로잡아라.',
      '- 마지막에 이해 확인 질문 3개와 짧은 답을 제공하라.'
    ].join('\n')
  })
]

const LEGACY_VOCAB_CHAIN_EN: WorkflowPackV1 = {
  schemaVersion: LEGACY_WORKFLOW_PACK_SCHEMA_VERSION,
  id: 'vocab-chain-en',
  name: '영어 단어 사슬',
  description:
    '기사에서 어려운 단어를 모으고, 그 단어가 쓰인 다음 기사로 이어가요.',
  author: 'Bandal',
  version: '1.0.0',
  locale: 'ko-KR',
  worksOn: ['material', 'browser-tab'],
  recipe: [
    '영어 원문을 읽고 어휘 사슬 한 회차를 진행하라. 아래 단계를 순서대로 수행하라.',
    '1. 대상(파일 또는 지정된 웹 페이지)을 정독하고, 대학생 학습자에게 어려운 단어 10~20개를 골라라. 각 단어마다 한국어 뜻과, 그 단어가 실제로 쓰인 원문 문장을 그대로 기록하라.',
    '2. `영어 학습/단어장.md`가 없으면 만들고, 있으면 먼저 읽은 뒤 끝에 이어 붙여라. 형식은 마크다운 표 `| 단어 | 뜻 | 원문 예문 | 출처 |` 하나를 계속 키운다. 이미 표에 있는 단어는 새 행을 만들지 말고 그 행의 예문·출처만 보강하라. 출처 칸에는 대상 문서로 가는 마크다운 링크 `[제목](bandal://material?path=URL인코딩된-과목상대경로)` 를 넣고, 웹 페이지가 대상이면 원문 URL 을 넣어라.',
    '3. WebSearch 로, 2에서 고른 단어 중 여러 개가 실제로 등장할 만한 새 영어 기사 2~3개를 찾아라. 무료로 전문이 읽히는 뉴스·에세이·과학 기사만 고르고, WebFetch 로 본문을 확인해 학습 단어가 실제로 몇 개 등장하는지 세어라. 확인되지 않은 기사는 버려라.',
    '4. 확인된 기사마다 `영어 학습/기사/` 아래에 마크다운 노트를 write_file 로 저장하라. 내용: 제목, 원문 URL, 등장하는 학습 단어 목록(등장 문장 포함), 두세 문단 발췌. 파일명은 기사 제목을 짧게 줄인 것으로 하라.',
    '5. 새 기사 노트 각각의 상단에 `[출발 문서](bandal://material?path=…)` 와 `[단어장](bandal://material?path=영어%20학습/단어장.md)` 링크를 넣고, link_materials 도구로 각 새 기사 노트와 출발 문서를 연결하라. 사슬은 이 링크로 이어진다.',
    '6. 지정된 결과 파일(리포트)에는 이번 회차 요약을 저장하라: 고른 단어 목록, 저장한 기사 목록(학습 단어 등장 수 포함), 다음에 읽을 기사 추천 1개와 그 이유. 채팅 답변 마지막에도 같은 추천을 한 줄로 알려 줘라.'
  ].join('\n'),
  allowedTools: [
    'write_file',
    'create_note',
    'send_web_clip_to_note',
    'link_materials',
    'list_links'
  ],
  usesWeb: true,
  outputs: {
    dir: '영어 학습',
    primary: '단어 사슬 리포트'
  },
  followUp: {
    label: '이 기사로 이어가기',
    recipe:
      '이번 실행은 어휘 사슬의 다음 회차다. 대상 파일은 이전 회차가 저장한 기사 노트다. 노트에 적힌 원문 URL 을 WebFetch 로 다시 읽고, 위 1~6단계를 그대로 반복하라. 단어장은 같은 `영어 학습/단어장.md` 에 이어 붙이고, 새 기사 노트의 링크(5단계)는 이번 대상 노트를 출발 문서로 가리키게 하라. 리포트에는 사슬이 몇 번째 회차인지도 적어라.'
  }
}

export const LEGACY_BUILTIN_PACKS: readonly WorkflowPackV1[] = [
  ...LEGACY_STUDY_PACKS,
  LEGACY_VOCAB_CHAIN_EN
]

function nativePack(pack: WorkflowPackV1, experience: WorkflowPackV2['experience']): WorkflowPackV2 {
  const recipe = experience === 'article-vocabulary'
    ? '사용자가 정한 관심 주제와 직접 체크한 단어를 바탕으로 짧은 영어 기사를 찾아라. 현재 제공자의 웹 검색 도구를 사용하고, 없으면 반달 브라우저에서 검색하라. 후보 기사 본문은 learning_verify_article로 확인하고, 실제 등장 단어와 출처가 확인된 결과만 learning_submit_result로 제출하라. 사용자가 모르는 단어를 임의로 추가하거나 원문을 지어내지 마라.'
    : experience === 'quiz'
      ? '자료에 근거한 객관식과 단답형 퀴즈를 생성하라. 각 문제의 정답, 해설, 출처 근거를 함께 구조화하여 learning_submit_result로 제출하라. 자료에서 확인하지 못한 사실로 문제를 만들지 마라.'
      : '자료에 근거한 플래시카드를 생성하라. 한 카드에서 한 개념을 묻고, 앞면 질문과 뒷면 답, 출처 근거를 함께 구조화하여 learning_submit_result로 제출하라. 중복 카드를 만들지 마라.'
  return {
    ...pack,
    schemaVersion: WORKFLOW_PACK_SCHEMA_VERSION,
    experience,
    recipe,
    ...(experience === 'article-vocabulary' ? { name: '영어 이어읽기', description: '관심 있는 영어 글을 읽고 표현을 모아 다음 글에서 다시 만나요.', followUp: { label: '다음 기사 찾기', recipe: '현재 학습 프로젝트의 사용자 선택 단어와 읽은 기사 기록을 이어받아 다음 기사를 찾아라. 본문이 확인된 새 기사만 제출하라.' } } : {}),
    allowedTools: experience === 'article-vocabulary'
      ? ['learning_verify_article', 'learning_submit_result', 'browser_open', 'browser_snapshot', 'browser_read']
      : ['read_material', 'list_materials', 'learning_submit_result']
  }
}

export const BUILTIN_STUDY_PACKS: readonly (WorkflowPack & { id: StudyToolId })[] = LEGACY_STUDY_PACKS.map(pack =>
  pack.id === 'quiz' || pack.id === 'flashcards'
    ? { ...nativePack(pack, pack.id), id: pack.id }
    : pack
)

export const BUILTIN_PACKS: readonly WorkflowPack[] = [
  ...BUILTIN_STUDY_PACKS,
  nativePack(LEGACY_VOCAB_CHAIN_EN, 'article-vocabulary')
]

/** Keeps study:run and v1 callers on their original Markdown contract. */
export function getLegacyPack(pack: WorkflowPack): WorkflowPackV1 {
  if (pack.schemaVersion === 1) return pack
  const legacy = LEGACY_BUILTIN_PACKS.find(candidate => candidate.id === pack.id)
  if (legacy === undefined) throw new TypeError(`Native workflow pack ${pack.id} requires the learning runtime`)
  return legacy
}
