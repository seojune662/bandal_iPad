import type { Tool as ToolDefinition } from '@modelcontextprotocol/sdk/types.js'

const readOnly: NonNullable<ToolDefinition['annotations']> = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false
}

function objectSchema(
  properties: Record<string, object>
): ToolDefinition['inputSchema'] {
  return {
    type: 'object',
    properties,
    required: [],
    additionalProperties: false
  }
}

const optionalString = (description: string): object => ({
  type: 'string',
  description
})

export const DESKTOP_TOOL_DEFINITIONS: readonly ToolDefinition[] = [
  {
    name: 'desktop_screenshot',
    description:
      "학생의 화면을 이미지로 봅니다. '이거', '이 화면', '여기' 같은 말은 먼저 이 도구를 부르세요. 작은 글씨는 desktop_windows 로 창을 고른 뒤 window 로 다시 찍으세요.",
    inputSchema: objectSchema({
      display: optionalString('찍을 디스플레이 ID. 생략하면 기본 디스플레이'),
      window: optionalString('찍을 창 ID. 생략하면 디스플레이 전체')
    }),
    annotations: readOnly
  },
  {
    name: 'desktop_windows',
    description:
      '현재 디스플레이와 열린 창의 ID·앱 이름·제목을 봅니다. 작은 글씨가 있는 창을 골라 다시 찍을 때 사용합니다.',
    inputSchema: objectSchema({}),
    annotations: readOnly
  },
  {
    name: 'desktop_frontmost',
    description: '지금 맨 앞에 있는 앱과 창 제목을 확인합니다.',
    inputSchema: objectSchema({}),
    annotations: readOnly
  },
  {
    name: 'desktop_clipboard_read',
    description:
      '학생이 현재 복사해 둔 텍스트를 한 번 읽습니다. 호출할 때마다 학생에게 확인받습니다.',
    inputSchema: objectSchema({}),
    annotations: readOnly
  }
]
