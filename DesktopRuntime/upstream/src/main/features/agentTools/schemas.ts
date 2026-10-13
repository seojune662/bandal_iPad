import type { Tool } from '@modelcontextprotocol/sdk/types.js'
import { DRAWING_COLORS, TEXT_ALIGNS } from '../../../shared/types/drawing'

export const DESKTOP_TOOL_NAMES = [
  'desktop_screenshot',
  'desktop_windows',
  'desktop_frontmost',
  'desktop_clipboard_read'
] as const

export type DesktopToolName = (typeof DESKTOP_TOOL_NAMES)[number]

const string = (description: string): object => ({ type: 'string', description })
const boolean = (description: string): object => ({ type: 'boolean', description })
const integer = (description: string, minimum = 1): object => ({
  type: 'integer',
  minimum,
  description
})
const nullableString = (description: string): object => ({
  type: ['string', 'null'],
  description
})

function objectSchema(
  properties: Record<string, object>,
  required: string[] = []
): Tool['inputSchema'] {
  return {
    type: 'object',
    properties,
    required,
    additionalProperties: false
  }
}

const courseId = string('과목 ID. list_courses 결과의 id를 사용합니다.')
const boardId = string('화이트보드 ID. list_boards 결과의 id를 사용합니다.')
const relPath = string('과목 폴더 기준 상대 경로. 절대 경로와 폴더 밖 경로는 금지됩니다.')

const shapeSchema = {
  type: 'object',
  description: '좌표가 페이지 기준 0..1인 도형 한 개',
  properties: {
    id: string('선택적인 도형 ID. 생략하면 안전한 랜덤 ID가 생성됩니다.'),
    kind: {
      type: 'string',
      enum: ['ink', 'highlighter', 'rect', 'ellipse', 'arrow', 'line', 'textbox', 'clip', 'image']
    },
    data: {
      type: 'object',
      description: 'points, box, text, clip 또는 image. kind별 필수 필드를 포함해야 합니다.',
      properties: {
        points: {
          type: 'array',
          items: objectSchema(
            {
              x: { type: 'number', minimum: 0, maximum: 1 },
              y: { type: 'number', minimum: 0, maximum: 1 },
              p: { type: 'number', minimum: 0, maximum: 1 }
            },
            ['x', 'y', 'p']
          )
        },
        box: objectSchema(
          {
            x: { type: 'number', minimum: 0, maximum: 1 },
            y: { type: 'number', minimum: 0, maximum: 1 },
            width: { type: 'number', minimum: 0, maximum: 1 },
            height: { type: 'number', minimum: 0, maximum: 1 }
          },
          ['x', 'y', 'width', 'height']
        ),
        text: { type: 'string' },
        clip: objectSchema(
          {
            relPath,
            page: integer('원본 PDF의 1부터 시작하는 페이지'),
            label: string('원본을 표시할 이름'),
            crop: { type: 'object', description: '선택적인 원본 페이지의 0..1 영역' }
          },
          ['relPath', 'page', 'label']
        ),
        image: objectSchema(
          { relPath, label: string('이미지를 표시할 이름') },
          ['relPath', 'label']
        )
      },
      additionalProperties: false
    },
    style: objectSchema(
      {
        color: {
          type: 'string',
          enum: ['ink', 'red', 'orange', 'yellow', 'green', 'blue', 'violet']
        },
        width: { type: 'number', exclusiveMinimum: 0, maximum: 1 },
        opacity: { type: 'number', minimum: 0, maximum: 1 },
        fontScale: { type: 'number', exclusiveMinimum: 0, maximum: 10 },
        bold: { type: 'boolean' },
        italic: { type: 'boolean' },
        underline: { type: 'boolean' },
        strike: { type: 'boolean' },
        align: {
          type: 'string',
          enum: [...TEXT_ALIGNS],
          description: 'textbox 전용 가로 정렬. 생략하면 left'
        },
        fill: {
          type: 'string',
          enum: [...DRAWING_COLORS],
          description: 'textbox 전용 배경 색. 생략하면 투명'
        }
      },
      ['color', 'width', 'opacity']
    )
  },
  required: ['kind', 'data', 'style'],
  additionalProperties: false
}

const readOnly = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
}
const creates = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false
}
const mutates = {
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false
}
const confirms = {
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: false
}

export const AGENT_TOOL_DEFINITIONS = [
  {
    name: 'learning_verify_article',
    description: '현재 학습 실행에 사용할 공개 영어 기사 URL을 실제 본문으로 검증합니다. 기사 ID, 길이, 재등장 표현과 근거 문장을 반환합니다.',
    inputSchema: objectSchema({ url: string('검증할 공개 기사 URL') }, ['url']),
    annotations: { ...readOnly, openWorldHint: true }
  },
  {
    name: 'learning_submit_result',
    description: '현재 학습 실행의 구조화 결과 초안을 검증해 제출합니다. 파일에 직접 쓰지 말고 이 도구를 사용하세요. 완료는 응답의 정상 종료 후 앱이 확정합니다.',
    inputSchema: objectSchema({ draft: { type: 'object', description: 'version:1, articles(검증된 id), artifacts(quiz/cards/summary), wordUpdates. 현재 작업에 요청된 결과만 제출.', additionalProperties: true } }, ['draft']),
    annotations: creates
  },
  {
    name: 'app_state',
    description:
      '학생이 지금 반달에서 보고 있는 것을 봅니다. 입력이 없습니다. 어느 과목이 선택돼 있는지, 사이드바에 어떤 학기 그룹이 있는지, 어떤 탭이 열려 있는지(웹·PDF·필기·보드)를 돌려줍니다. **지시가 앱에 대한 것인지 웹페이지에 대한 것인지 헷갈리면 여기서 시작하세요.**',
    inputSchema: objectSchema({}, []),
    annotations: readOnly
  },
  {
    name: 'list_courses',
    description:
      '살아있는 과목 목록을 조회합니다. 각 과목은 groupId 와 groupName 을 가지며, 이는 사이드바에서 그 과목이 들어 있는 학기 그룹입니다(그룹이 없으면 둘 다 null).',
    inputSchema: objectSchema({ includeArchived: boolean('보관된 과목도 포함할지 여부') }),
    annotations: readOnly
  },
  {
    name: 'list_course_groups',
    description:
      '사이드바의 학기 그룹 목록입니다. 「2026년 1학기」처럼 학생이 과목을 묶어 두는 이름 있는 구획이며, 학기를 바꾸거나 정리해 달라는 요청은 대개 이것을 가리킵니다.',
    inputSchema: objectSchema({}, []),
    annotations: readOnly
  },
  {
    name: 'create_course_group',
    description: '새 학기 그룹을 만듭니다. 예: "2026년 2학기".',
    inputSchema: objectSchema({ name: string('그룹 이름') }, ['name']),
    annotations: readOnly
  },
  {
    name: 'rename_course_group',
    description:
      '학기 그룹의 이름을 바꿉니다. 안에 든 과목은 그대로입니다. 학생이 "학기를 바꿔줘"라고 하면 보통 이것입니다.',
    inputSchema: objectSchema(
      { groupId: string('그룹 ID. list_course_groups 결과의 id'), name: string('새 이름') },
      ['groupId', 'name']
    ),
    annotations: confirms
  },
  {
    name: 'delete_course_group',
    description:
      '학기 그룹을 없앱니다. 안에 든 과목은 삭제되지 않고 그룹에서 빠져 나옵니다.',
    inputSchema: objectSchema({ groupId: string('그룹 ID') }, ['groupId']),
    annotations: confirms
  },
  {
    name: 'set_course_group',
    description:
      '과목을 학기 그룹에 넣거나 뺍니다. groupId 가 null 이면 그룹에서 빼냅니다. 사이드바에서 과목을 끌어다 놓는 것과 같은 동작입니다.',
    inputSchema: objectSchema(
      {
        courseId,
        groupId: nullableString('넣을 그룹 ID. null 이면 그룹에서 빼냅니다'),
        beforeCourseId: nullableString(
          '이 과목 바로 앞에 놓습니다. null 이면 맨 뒤'
        )
      },
      ['courseId', 'groupId']
    ),
    annotations: readOnly
  },
  {
    name: 'archive_course',
    description:
      '과목을 보관하거나 보관을 풉니다. 삭제와 다릅니다 — 자료는 그대로 남고 목록에서만 빠집니다.',
    inputSchema: objectSchema(
      { courseId, archived: boolean('true 면 보관, false 면 되돌리기') },
      ['courseId', 'archived']
    ),
    annotations: confirms
  },
  {
    name: 'list_materials',
    description: '과목 폴더 안의 자료와 하위 폴더를 조회합니다.',
    inputSchema: objectSchema({ courseId }, ['courseId']),
    annotations: readOnly
  },
  {
    name: 'link_materials',
    description: '두 자료를 서로 연결해요',
    inputSchema: objectSchema(
      {
        courseId,
        fromRelPath: string('출발 자료의 과목 기준 상대 경로'),
        toRelPath: string('도착 자료의 과목 기준 상대 경로'),
        label: string('선택적인 연결 이름')
      },
      ['courseId', 'fromRelPath', 'toRelPath']
    ),
    annotations: creates
  },
  {
    name: 'list_links',
    description: '자료에 연결된 다른 자료를 조회합니다.',
    inputSchema: objectSchema({ courseId, relPath }, ['courseId', 'relPath']),
    annotations: readOnly
  },
  {
    name: 'list_boards',
    description: '과목의 개인 화이트보드 목록을 조회합니다.',
    inputSchema: objectSchema({ courseId }, ['courseId']),
    annotations: readOnly
  },
  {
    name: 'read_material',
    description:
      '자료 파일의 텍스트를 읽습니다. 텍스트/마크다운은 물론 .docx 와 .xlsx/.xls 도 텍스트로 변환해 돌려줍니다. PDF 는 이 도구 대신 파일을 직접 읽으세요.',
    inputSchema: objectSchema(
      {
        courseId,
        relPath,
        maxChars: integer('돌려줄 최대 글자 수. 생략하면 20000')
      },
      ['courseId', 'relPath']
    ),
    annotations: readOnly
  },
  {
    name: 'list_tasks',
    description: '할 일 목록을 조회합니다. courseId를 생략하면 전체를 조회합니다.',
    inputSchema: objectSchema({
      courseId: nullableString('과목 ID, null이면 전역 할 일, 생략하면 전체'),
      includeDone: boolean('완료한 할 일도 포함할지 여부')
    }),
    annotations: readOnly
  },
  {
    name: 'create_course',
    description: '과목을 만듭니다. 같은 이름의 살아있는 과목이 있으면 기존 과목을 반환합니다.',
    inputSchema: objectSchema(
      { name: string('과목 이름'), color: string('과목 색상. 생략하면 blue') },
      ['name']
    ),
    annotations: creates
  },
  {
    name: 'create_note',
    description: '과목 폴더 안에 새 Markdown 필기를 만듭니다.',
    inputSchema: objectSchema(
      {
        courseId,
        dirRelPath: string('만들 디렉터리의 과목 기준 상대 경로. 루트는 빈 문자열'),
        title: string('필기 제목'),
        markdown: string('선택적인 초기 Markdown 본문')
      },
      ['courseId', 'dirRelPath', 'title']
    ),
    annotations: creates
  },
  {
    name: 'write_file',
    description: '과목 폴더 안에 새 파일을 씁니다. 같은 이름이 있으면 새 이름을 골라 덮어쓰지 않습니다.',
    inputSchema: objectSchema(
      {
        courseId,
        dirRelPath: string('대상 디렉터리의 과목 기준 상대 경로. 루트는 빈 문자열'),
        fileName: string('경로 구분자가 없는 파일 이름'),
        encoding: { type: 'string', enum: ['utf8', 'base64'] },
        data: string('파일 내용')
      },
      ['courseId', 'dirRelPath', 'fileName', 'data']
    ),
    annotations: creates
  },
  {
    name: 'create_folder',
    description: '과목 폴더 안에 새 폴더를 만듭니다.',
    inputSchema: objectSchema(
      {
        courseId,
        dirRelPath: string('부모 디렉터리의 과목 기준 상대 경로. 루트는 빈 문자열'),
        name: string('경로 구분자가 없는 폴더 이름')
      },
      ['courseId', 'dirRelPath', 'name']
    ),
    annotations: creates
  },
  {
    name: 'create_task',
    description: '새 할 일, 과제, 시험 또는 수업 일정을 만듭니다.',
    inputSchema: objectSchema(
      {
        courseId: nullableString('과목 ID. 전역 할 일은 null'),
        title: string('제목'),
        notes: string('설명'),
        status: { type: 'string', enum: ['todo', 'in-progress', 'done'] },
        kind: { type: 'string', enum: ['task', 'assignment', 'exam', 'class'] },
        startAt: nullableString('기간 시작. 종일은 YYYY-MM-DD, 시간 지정은 ISO instant. 마감만 지정할 때 null'),
        dueAt: nullableString('마감 또는 기간 종료. 종일은 마지막 날을 포함하는 YYYY-MM-DD, 시간 지정은 ISO instant, 날짜 없음은 null'),
        allDay: boolean('종일 일정인지 여부')
      },
      ['courseId', 'title']
    ),
    annotations: creates
  },
  {
    name: 'update_task',
    description: '기존 할 일의 제목, 상태, 종류, 기한 등을 수정합니다.',
    inputSchema: objectSchema(
      {
        id: string('할 일 ID'),
        courseId: nullableString('새 과목 ID 또는 전역으로 옮길 때 null'),
        title: string('새 제목'),
        notes: string('새 설명'),
        status: { type: 'string', enum: ['todo', 'in-progress', 'done'] },
        kind: { type: 'string', enum: ['task', 'assignment', 'exam', 'class'] },
        startAt: nullableString('기간 시작. 종일은 YYYY-MM-DD, 시간 지정은 ISO instant. 마감만 지정할 때 null'),
        dueAt: nullableString('마감 또는 기간 종료. 종일은 마지막 날을 포함하는 YYYY-MM-DD, 시간 지정은 ISO instant, 날짜 없음은 null'),
        allDay: boolean('종일 일정인지 여부'),
        sortOrder: integer('0부터 시작하는 정렬 순서', 0)
      },
      ['id']
    ),
    annotations: mutates
  },
  {
    name: 'create_board',
    description: '과목에 개인 화이트보드를 만듭니다.',
    inputSchema: objectSchema(
      {
        courseId,
        title: string('화이트보드 제목'),
        background: { type: 'string', enum: ['grid', 'dots', 'lines', 'blank'] },
        surface: { type: 'string', enum: ['dark', 'light'] }
      },
      ['courseId']
    ),
    annotations: creates
  },
  {
    name: 'add_page',
    description: '화이트보드 끝에 빈 페이지 한 장을 추가합니다.',
    inputSchema: objectSchema({ boardId }, ['boardId']),
    annotations: creates
  },
  {
    name: 'add_shapes',
    description: '화이트보드 페이지에 검증된 0..1 좌표 도형을 추가합니다. 한 호출의 도형은 모두 검증된 뒤 저장됩니다.',
    inputSchema: objectSchema(
      {
        boardId,
        page: integer('화이트보드의 1부터 시작하는 페이지. 생략하면 1'),
        shapes: { type: 'array', minItems: 1, items: shapeSchema }
      },
      ['boardId', 'shapes']
    ),
    annotations: creates
  },
  {
    name: 'rename_material',
    description: '확인을 받은 뒤 자료 파일이나 폴더의 이름을 바꿉니다.',
    inputSchema: objectSchema(
      { courseId, relPath, newName: string('경로 구분자가 없는 새 이름') },
      ['courseId', 'relPath', 'newName']
    ),
    annotations: confirms
  },
  {
    name: 'rename_course',
    description: '확인을 받은 뒤 과목 이름을 바꿉니다.',
    inputSchema: objectSchema(
      { courseId, name: string('새 과목 이름') },
      ['courseId', 'name']
    ),
    annotations: confirms
  },
  {
    name: 'rename_board',
    description: '확인을 받은 뒤 화이트보드 이름을 바꿉니다.',
    inputSchema: objectSchema(
      { id: boardId, title: string('새 화이트보드 제목') },
      ['id', 'title']
    ),
    annotations: confirms
  },
  {
    name: 'delete_material',
    description: '확인을 받은 뒤 자료 파일이나 폴더를 휴지통으로 보냅니다.',
    inputSchema: objectSchema({ courseId, relPath }, ['courseId', 'relPath']),
    annotations: confirms
  },
  {
    name: 'delete_task',
    description: '확인을 받은 뒤 할 일을 삭제합니다.',
    inputSchema: objectSchema({ id: string('할 일 ID') }, ['id']),
    annotations: confirms
  },
  {
    name: 'delete_board',
    description: '확인을 받은 뒤 화이트보드와 그 도형을 삭제합니다.',
    inputSchema: objectSchema({ id: boardId }, ['id']),
    annotations: confirms
  },
  {
    name: 'delete_course',
    description: '확인을 받은 뒤 과목을 앱에서 삭제합니다. 과목 폴더는 디스크에 남습니다.',
    inputSchema: objectSchema({ courseId }, ['courseId']),
    annotations: confirms
  },
  {
    name: 'overwrite_note',
    description: '확인을 받은 뒤 기존 Markdown 필기의 전체 내용을 덮어씁니다.',
    inputSchema: objectSchema(
      {
        courseId,
        relPath,
        markdown: string('새 Markdown 전체 내용'),
        expectedMtime: integer('알고 있는 기존 수정 시각(epoch ms)', 0)
      },
      ['courseId', 'relPath', 'markdown']
    ),
    annotations: confirms
  },
  {
    name: 'edit_sheet',
    description:
      '확인을 받은 뒤 .xlsx 스프레드시트의 셀 값을 고치거나 끝에 행을 추가합니다. ' +
      '값/수식 수준의 편집만 지원합니다 — 서식·차트·피벗은 보존되지만 이 도구로 편집할 수는 없습니다. ' +
      '.xls 는 편집할 수 없습니다(.xlsx 만 저장 가능). 편집 전 원본은 자동 백업되어 되돌릴 수 있습니다.',
    inputSchema: objectSchema(
      {
        courseId,
        relPath,
        sheet: string('시트 이름. 생략하면 첫 번째 시트를 편집합니다.'),
        edits: {
          type: 'array',
          minItems: 1,
          maxItems: 200,
          description:
            '셀 단위 수정 목록. value 가 null 이면 셀을 비웁니다. ' +
            '"=SUM(A1:A3)" 처럼 = 로 시작하는 문자열은 수식으로 저장됩니다.',
          items: objectSchema(
            {
              cell: string('A1 형식 셀 주소 (예: "B2")'),
              value: {
                type: ['string', 'number', 'boolean', 'null'],
                description: '새 값. null 은 셀 비우기, "=..." 는 수식.'
              }
            },
            ['cell', 'value']
          )
        },
        appendRows: {
          type: 'array',
          minItems: 1,
          maxItems: 200,
          description:
            '시트 끝에 추가할 행 목록. 각 행은 왼쪽 열부터의 값 배열이며 ' +
            'null 은 빈 셀, "=..." 는 수식입니다. edits 와 appendRows 중 적어도 하나는 필요합니다.',
          items: {
            type: 'array',
            items: { type: ['string', 'number', 'boolean', 'null'] }
          }
        }
      },
      ['courseId', 'relPath']
    ),
    annotations: confirms
  },
  {
    name: 'edit_docx_text',
    description:
      '확인을 받은 뒤 .docx 문서의 본문 텍스트를 찾아 바꿉니다. run(서식이 같은 연속 구간) 안에 ' +
      '온전히 들어 있는 문구만 매칭됩니다 — 문구 중간에 굵기·색 등 서식이 바뀌면 찾지 못하니, ' +
      'read_material 로 정확한 문구를 확인한 뒤 사용하세요. 서식은 보존되고 편집 전 원본은 자동 백업됩니다.',
    inputSchema: objectSchema(
      {
        courseId,
        relPath,
        replacements: {
          type: 'array',
          minItems: 1,
          maxItems: 20,
          description: '순서대로 적용되는 찾아 바꾸기 목록 (1~20개)',
          items: objectSchema(
            {
              find: string('찾을 텍스트. 대소문자까지 정확히 일치해야 합니다.'),
              replace: string('바꿀 텍스트')
            },
            ['find', 'replace']
          )
        },
        scope: {
          type: 'string',
          enum: ['first', 'all'],
          description:
            '각 항목을 첫 번째 일치만 바꿀지(first) 전부 바꿀지(all). 생략하면 all.'
        }
      },
      ['courseId', 'relPath', 'replacements']
    ),
    annotations: confirms
  },
  {
    name: 'list_course_links',
    description: '과목에 저장된 바로가기 목록을 조회합니다.',
    inputSchema: objectSchema({ courseId }, ['courseId']),
    annotations: readOnly
  },
  {
    name: 'create_course_link',
    description: '과목에 새 바로가기를 저장합니다.',
    inputSchema: objectSchema(
      {
        courseId, label: string('바로가기 이름'), rawUrl: string('입력된 원본 URL'),
        kind: { type: 'string', enum: ['lms-course', 'portal', 'lms', 'library', 'mail', 'registration', 'homepage', 'other'] },
        url: string('열 때 사용하는 URL'),
        lmsCourseId: nullableString('강의실의 과목 ID')
      },
      ['courseId', 'label', 'rawUrl', 'kind']
    ),
    annotations: readOnly
  },
  {
    name: 'update_course_link',
    description: '저장된 과목 바로가기의 이름이나 순서를 수정합니다.',
    inputSchema: objectSchema(
      { id: string('바로가기 ID'), label: string('새 바로가기 이름'),
        sortOrder: integer('0부터 시작하는 정렬 순서', 0) },
      ['id']
    ),
    annotations: readOnly
  },
  {
    name: 'delete_course_link',
    description: '확인을 받은 뒤 저장된 과목 바로가기를 삭제합니다.',
    inputSchema: objectSchema({ id: string('바로가기 ID') }, ['id']),
    annotations: confirms
  },
  {
    name: 'move_material',
    description: '확인을 받은 뒤 자료 파일이나 폴더를 다른 폴더로 옮깁니다.',
    inputSchema: objectSchema(
      { courseId, fromRelPath: relPath,
        toDirRelPath: string('대상 폴더의 과목 기준 상대 경로. 루트는 빈 문자열') },
      ['courseId', 'fromRelPath', 'toDirRelPath']
    ),
    annotations: confirms
  },
  {
    name: 'duplicate_material',
    description: '자료 파일이나 폴더의 사본을 만듭니다.',
    inputSchema: objectSchema({ courseId, relPath }, ['courseId', 'relPath']),
    annotations: readOnly
  },
  {
    name: 'list_favorites',
    description: '과목 또는 앱 전체의 즐겨찾기 목록을 조회합니다.',
    inputSchema: objectSchema({ courseId: nullableString('과목 ID. 앱 전체 즐겨찾기는 null') }, ['courseId']),
    annotations: readOnly
  },
  {
    name: 'add_favorite',
    description: '탭을 과목 또는 앱 전체 즐겨찾기에 추가합니다.',
    inputSchema: objectSchema(
      { courseId: nullableString('과목 ID. 앱 전체 즐겨찾기는 null'),
        label: string('즐겨찾기 이름'), descriptor: { type: 'object', description: '저장할 탭 설명자' } },
      ['courseId', 'label', 'descriptor']
    ),
    annotations: readOnly
  },
  {
    name: 'rename_favorite',
    description: '즐겨찾기의 이름을 바꿉니다.',
    inputSchema: objectSchema({ id: string('즐겨찾기 ID'),
      label: string('새 즐겨찾기 이름') }, ['id', 'label']),
    annotations: readOnly
  },
  {
    name: 'remove_favorite',
    description: '확인을 받은 뒤 즐겨찾기를 삭제합니다.',
    inputSchema: objectSchema({ id: string('즐겨찾기 ID') }, ['id']),
    annotations: confirms
  },
  {
    name: 'search_course',
    description: '과목의 필기와 자료 본문을 검색합니다.',
    inputSchema: objectSchema({ courseId, query: string('검색어'),
      limit: integer('최대 결과 수') }, ['courseId', 'query']),
    annotations: readOnly
  },
  {
    name: 'remove_shapes',
    description: '확인을 받은 뒤 개인 화이트보드의 도형을 삭제합니다.',
    inputSchema: objectSchema({ boardId,
      ids: { type: 'array', minItems: 1, items: string('도형 ID') } }, ['boardId', 'ids']),
    annotations: confirms
  },
  {
    name: 'send_highlight_to_note',
    description: '자료의 하이라이트와 원문 링크를 Markdown 필기에 보냅니다.',
    inputSchema: objectSchema(
      {
        courseId, relPath, page: integer('원본 PDF의 1부터 시작하는 페이지'),
        quote: string('하이라이트한 문구'), comment: nullableString('하이라이트에 덧붙일 메모'),
        annotationId: string('하이라이트 ID'),
        noteRelPath: string('대상 필기의 과목 기준 상대 경로')
      },
      ['courseId', 'relPath', 'page', 'quote', 'comment', 'annotationId']
    ),
    annotations: readOnly
  },
  {
    name: 'send_web_clip_to_note',
    description: '웹 페이지의 인용문과 원문 링크를 Markdown 필기에 보냅니다.',
    inputSchema: objectSchema(
      {
        courseId, url: string('인용한 웹 페이지 URL'), title: string('인용한 웹 페이지 제목'),
        quote: string('인용한 문구'), comment: nullableString('인용문에 덧붙일 메모'),
        noteRelPath: string('대상 필기의 과목 기준 상대 경로')
      },
      ['courseId', 'url', 'title', 'quote', 'comment']
    ),
    annotations: readOnly
  }
] as const satisfies readonly Tool[]

/**
 * Browser tools.
 *
 * These used to be gated on the course having a classroom linked, to save the
 * ~1k tokens of schema they cost on every turn. That trade was wrong: a
 * student with their university portal open in front of them was told the
 * assistant had "no tool to read the browser". The schemas ride at the front
 * of the prompt cache, so the saving was near zero and the cost was a whole
 * feature. See registerHandlers.ts `browserToolsFor`.
 */
const browserTabId = string('탭 id')
const browserRef = string('browser_snapshot 이 준 요소 참조')
const tabInput = objectSchema({ tabId: browserTabId }, ['tabId'])
const refInput = objectSchema({ tabId: browserTabId, ref: browserRef }, ['tabId', 'ref'])
function browserTool<const Name extends string>(
  name: Name,
  description: string,
  inputSchema: Tool['inputSchema'],
  annotations: Tool['annotations'] = readOnly
) {
  return { name, description, inputSchema, annotations }
}

export const BROWSER_TOOL_DEFINITIONS = [
  browserTool('browser_tabs', '반달 브라우저에 열린 탭의 tabId·제목·주소·활성 상태를 봅니다.', objectSchema({}, [])),
  browserTool('lms_course_page', '과목에 연결된 학교 강의실 주소를 확인합니다.', objectSchema({ courseId }, ['courseId'])),
  browserTool('lms_new_items', '강의실에서 지난 확인 이후 새로 올라온 항목을 조회합니다.', objectSchema({ courseId, kind: nullableString('announcements | assignments | modules | files') }, ['courseId'])),
  browserTool('lms_list', '강의실의 항목 전체를 조회합니다.', objectSchema({ courseId, kind: nullableString('files | modules | assignments | announcements') }, ['courseId'])),
  browserTool('browser_download', '강의실 파일 하나를 과목 폴더로 내려받습니다.', objectSchema({ courseId, url: string('파일 주소'), dirRelPath: string('과목 폴더 기준 상대 경로') }, ['courseId', 'url', 'dirRelPath'])),
  browserTool('browser_open', '반달 탭에서 주소를 엽니다.', objectSchema({ url: string('열 주소') }, ['url'])),
  browserTool('browser_snapshot', '열린 탭의 상호작용 요소와 세대가 붙은 요소 참조를 봅니다.', objectSchema({ tabId: browserTabId, maxChars: integer('최대 글자 수') }, ['tabId'])),
  browserTool('browser_read', '열린 탭의 본문 텍스트를 읽습니다.', objectSchema({ tabId: browserTabId, maxChars: integer('최대 글자 수') }, ['tabId'])),
  browserTool('browser_scroll', '페이지를 위·아래·처음·끝 또는 지정한 요소까지 스크롤합니다.', objectSchema({ tabId: browserTabId, to: { type: 'string', enum: ['down', 'up', 'top', 'bottom'] }, ref: browserRef }, ['tabId'])),
  browserTool('browser_click', '제출 컨트롤이 아닌 요소를 누릅니다.', refInput),
  browserTool('browser_type', '비밀번호가 아닌 입력 칸에 글을 넣습니다.', objectSchema({ tabId: browserTabId, ref: browserRef, text: string('입력할 글') }, ['tabId', 'ref', 'text'])),
  browserTool('browser_key', 'Enter·Tab·Escape·방향키를 누릅니다. Enter 는 폼을 제출할 수 있습니다.', objectSchema({ tabId: browserTabId, key: { type: 'string', enum: ['Enter', 'Tab', 'Escape', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'] } }, ['tabId', 'key']), confirms),
  browserTool('browser_select', '선택 목록에서 값을 고릅니다.', objectSchema({ tabId: browserTabId, ref: browserRef, value: string('고를 값') }, ['tabId', 'ref', 'value'])),
  browserTool('browser_hover', '요소에 마우스를 올립니다.', refInput, mutates),
  browserTool('browser_back', '탭의 이전 페이지로 이동합니다.', tabInput, mutates),
  browserTool('browser_forward', '탭의 다음 페이지로 이동합니다.', tabInput, mutates),
  browserTool('browser_reload', '탭을 새로고침합니다.', tabInput, mutates),
  browserTool('browser_stop', '탭의 로딩을 멈춥니다.', tabInput, mutates),
  browserTool('browser_focus_tab', '탭을 활성 탭으로 전환합니다.', tabInput, mutates),
  browserTool('browser_close_tab', '탭을 닫습니다.', tabInput, confirms),
  browserTool('browser_find', '페이지에서 글과 일치하는 건수를 셉니다.', objectSchema({ tabId: browserTabId, text: string('찾을 글') }, ['tabId', 'text'])),
  browserTool('browser_handoff', '학생에게 브라우저 조작을 넘기고 재개를 기다립니다.', objectSchema({ tabId: browserTabId, message: string('학생에게 보여줄 한 줄') }, ['tabId', 'message'])),
  browserTool('browser_submit', '폼을 제출하며 학생에게 매번 확인받습니다.', refInput),
  browserTool('browser_use_saved_login', '저장된 아이디·비밀번호를 채우되 제출하지 않습니다.', tabInput),
  browserTool('browser_attach_file', '과목 폴더의 파일을 파일 선택 칸에 붙입니다.', objectSchema({ tabId: browserTabId, ref: browserRef, courseId, relPath }, ['tabId', 'ref', 'courseId', 'relPath']))
] as const satisfies readonly Tool[]

export const BROWSER_TOOL_NAMES = BROWSER_TOOL_DEFINITIONS.map(
  (definition) => definition.name
) as readonly BrowserToolName[]

export type BrowserToolName = (typeof BROWSER_TOOL_DEFINITIONS)[number]['name']

export type AgentToolDefinitionName =
  (typeof AGENT_TOOL_DEFINITIONS)[number]['name']

export type AgentToolName = AgentToolDefinitionName

export const AGENT_TOOL_NAMES = AGENT_TOOL_DEFINITIONS.map(
  (tool) => tool.name
) as readonly AgentToolName[]
