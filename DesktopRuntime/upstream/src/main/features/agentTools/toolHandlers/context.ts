import type { CallToolResult } from '@modelcontextprotocol/sdk/types.js'
import type { AgentActionTarget } from '../../../../shared/types/agentTools'
import { ValidationError } from '../../../db/errors'
import type {
  AgentToolName,
  BrowserToolName,
  DesktopToolName
} from '../schemas'
import type { AgentToolsDeps, LimitKind } from '../tools'

export interface TurnContext {
  courseId: string
  turnId: string
}

export type ToolHandler = (
  input: Record<string, unknown>
) => Promise<unknown> | unknown

export class RawToolResult {
  constructor(readonly result: CallToolResult) {}
}

export type ToolHandlerMap = Record<AgentToolName, ToolHandler> &
  Partial<Record<BrowserToolName, ToolHandler>> &
  Partial<Record<DesktopToolName, ToolHandler>>

export interface ToolContext {
  deps: AgentToolsDeps
  currentTurn: () => TurnContext
  reserve: (kind: LimitKind, amount: number) => void
  release: (kind: LimitKind, amount: number) => void
  approve: (
    context: TurnContext,
    tool: AgentToolName,
    summary: string,
    details: string[]
  ) => Promise<boolean>
  record: (
    context: TurnContext,
    courseId: string,
    tool: AgentToolName,
    targetKind: AgentActionTarget,
    targetId: string,
    label: string,
    undoable: boolean
  ) => void
  courseFolder: (courseId: string) => string
  assertCoursePath: (
    courseId: string,
    relPath: string,
    allowRoot?: boolean
  ) => string
  assertChildPath: (
    courseId: string,
    dirRelPath: string,
    name: string
  ) => void
  findTask: (
    id: string
  ) => ReturnType<AgentToolsDeps['boardRepo']['list']>[number]
}

export function inputObject(value: unknown): Record<string, unknown> {
  if (value === undefined) return {}
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ValidationError('tool arguments must be an object')
  }
  return value as Record<string, unknown>
}

export function has(input: Record<string, unknown>, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(input, key)
}

export function stringField(
  input: Record<string, unknown>,
  key: string,
  options: { nonEmpty?: boolean } = {}
): string {
  const value = input[key]
  if (typeof value !== 'string') {
    throw new ValidationError(`${key} must be a string`)
  }
  if (options.nonEmpty === true && value.trim() === '') {
    throw new ValidationError(`${key} must be a non-empty string`)
  }
  return value
}

export function optionalString(
  input: Record<string, unknown>,
  key: string
): string | undefined {
  return has(input, key) ? stringField(input, key) : undefined
}

export function optionalBoolean(
  input: Record<string, unknown>,
  key: string
): boolean | undefined {
  if (!has(input, key)) return undefined
  const value = input[key]
  if (typeof value !== 'boolean') {
    throw new ValidationError(`${key} must be a boolean`)
  }
  return value
}

export function optionalInteger(
  input: Record<string, unknown>,
  key: string,
  minimum: number
): number | undefined {
  if (!has(input, key)) return undefined
  const value = input[key]
  if (typeof value !== 'number' || !Number.isInteger(value) || value < minimum) {
    throw new ValidationError(`${key} must be an integer >= ${minimum}`)
  }
  return value
}

export function nullableStringField(
  input: Record<string, unknown>,
  key: string
): string | null {
  if (input[key] === null) return null
  return stringField(input, key, { nonEmpty: true })
}

export function stringArrayField(
  input: Record<string, unknown>,
  key: string
): string[] {
  const value = input[key]
  if (!Array.isArray(value) || value.length === 0) {
    throw new ValidationError(`${key} must be a non-empty array`)
  }
  return value.map((item, index) => {
    if (typeof item !== 'string' || item.trim() === '') {
      throw new ValidationError(`${key}[${index}] must be a non-empty string`)
    }
    return item
  })
}

export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export function cancelled(tool: string): object {
  return {
    ok: false,
    cancelled: true,
    message: `사용자가 ${tool} 작업을 승인하지 않아 아무것도 변경하지 않았습니다.`
  }
}
