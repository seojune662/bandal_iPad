/**
 * Friendly Korean presentation of tool calls for the chat timeline:
 * title (running vs done form), a short detail derived from the input, and
 * the before/after change extracted from Edit/Write inputs for the diff view.
 */

import type { ToolBlockView } from './chatModel'

export interface ToolPresentation {
  /** e.g. "파일 읽는 중" while running, "파일 읽음" when done. */
  title: string
  /** Short human detail, e.g. the file basename or search pattern. */
  detail: string | null
}

export interface ToolChange {
  path: string | null
  before: string
  after: string
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)
    : {}
}

function asString(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

function basename(path: string): string {
  const parts = path.split(/[\\/]/)
  return parts[parts.length - 1] ?? path
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

interface ToolCopy {
  running: string
  done: string
  detail: (input: Record<string, unknown>) => string | null
}

const fileDetail = (input: Record<string, unknown>): string | null => {
  const path =
    asString(input['file_path']) ??
    asString(input['path']) ??
    asString(input['notebook_path'])
  return path === null ? null : basename(path)
}

const TOOL_COPY: Record<string, ToolCopy> = {
  Read: { running: '파일 읽는 중', done: '파일 읽음', detail: fileDetail },
  Grep: {
    running: '검색 중',
    done: '검색 완료',
    detail: (input) => asString(input['pattern'])
  },
  Glob: {
    running: '검색 중',
    done: '검색 완료',
    detail: (input) => asString(input['pattern'])
  },
  Edit: { running: '필기 수정 중', done: '필기 수정됨', detail: fileDetail },
  MultiEdit: {
    running: '필기 수정 중',
    done: '필기 수정됨',
    detail: fileDetail
  },
  Write: { running: '필기 작성 중', done: '필기 작성됨', detail: fileDetail },
  NotebookEdit: {
    running: '필기 수정 중',
    done: '필기 수정됨',
    detail: fileDetail
  },
  Bash: {
    running: '명령 실행 중',
    done: '명령 실행됨',
    detail: (input) => {
      const command = asString(input['command'])
      return command === null ? null : truncate(command, 60)
    }
  },
  WebSearch: {
    running: '웹 검색 중',
    done: '웹 검색 완료',
    detail: (input) => asString(input['query'])
  },
  WebFetch: {
    running: '웹 페이지 읽는 중',
    done: '웹 페이지 읽음',
    detail: (input) => asString(input['url'])
  },
  TodoWrite: { running: '계획 정리 중', done: '계획 정리됨', detail: () => null },
  Task: {
    running: '보조 작업 실행 중',
    done: '보조 작업 완료',
    detail: (input) => asString(input['description'])
  }
}

export function presentTool(block: ToolBlockView): ToolPresentation {
  const copy = TOOL_COPY[block.toolName]
  const input = asRecord(block.input)
  if (copy === undefined) {
    // The CLI label ("Reading lecture-3.pdf") is already human-readable.
    const fallback = block.label !== '' ? block.label : block.toolName
    return { title: fallback, detail: null }
  }
  return {
    title: block.status === 'running' ? copy.running : copy.done,
    detail: copy.detail(input)
  }
}

/** Extracts a before/after change from Edit/Write inputs when available. */
export function toolChange(block: ToolBlockView): ToolChange | null {
  const input = asRecord(block.input)
  const path =
    asString(input['file_path']) ?? asString(input['notebook_path'])
  if (block.toolName === 'Edit') {
    const before = asString(input['old_string'])
    const after = asString(input['new_string'])
    if (before === null || after === null) {
      return null
    }
    return { path, before, after }
  }
  if (block.toolName === 'Write') {
    const content = asString(input['content'])
    if (content === null) {
      return null
    }
    return { path, before: '', after: content }
  }
  return null
}

/** Compact single-line JSON summary of an arbitrary tool/permission input. */
export function summarizeInput(input: unknown, max = 120): string {
  if (input === undefined || input === null) {
    return ''
  }
  try {
    return truncate(JSON.stringify(input), max)
  } catch {
    return ''
  }
}
