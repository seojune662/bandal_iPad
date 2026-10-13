import { randomUUID } from 'node:crypto'
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync
} from 'node:fs'
import { basename, join } from 'node:path'
import type {
  WorkflowPack,
  WorkflowPackSummary
} from '../../../shared/types/workflowPack'
import { CUSTOM_PACK_PREFIX } from '../../../shared/types/workflowPack'
import { BUILTIN_PACKS } from '../../../shared/workflowPacks/builtins'
import { sanitizeWorkflowPack } from '../../../shared/workflowPacks/sanitize'
import { ConflictError, NotFoundError, ValidationError } from '../../db/errors'
import { requireId } from '../../db/validate'
import { quarantineFile, writeFileAtomic } from '../../lib/atomicWrite'

export const WORKFLOW_PACKS_FILE_NAME = 'workflow-packs.json'
export const MAX_CUSTOM_WORKFLOW_PACKS = 50

const ENVELOPE_FORMAT = 'bandal-workflow-packs'
const ENVELOPE_VERSION = 1

interface WorkflowPackEnvelope {
  format: typeof ENVELOPE_FORMAT
  version: typeof ENVELOPE_VERSION
  packs: WorkflowPack[]
  disabledIds: string[]
  approvals: Record<string, string>
}

export interface PackStoreDeps {
  userDataPath: string
  builtins?: readonly WorkflowPack[]
  now?: () => Date
  randomUUID?: () => string
  /** Every persisted mutation, including catalog imports and approvals. */
  onChanged?: () => void
}

export interface PackStore {
  list(): WorkflowPackSummary[]
  importText(json: string, replaceId?: string): { pack: WorkflowPack; warnings: string[] }
  remove(id: string): void
  setEnabled(id: string, enabled: boolean): void
  approve(id: string, at: string): void
  /** Returns enabled packs only. Disabled and unknown ids resolve to null. */
  resolve(id: string): WorkflowPack | null
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function clonePack(pack: WorkflowPack): WorkflowPack {
  return {
    ...pack,
    worksOn: [...pack.worksOn],
    allowedTools: [...pack.allowedTools],
    outputs: { ...pack.outputs },
    ...(pack.followUp === undefined
      ? {}
      : { followUp: { ...pack.followUp } })
  }
}

function parseStringSet(value: unknown, field: string): string[] {
  if (
    !Array.isArray(value) ||
    value.some((item) => typeof item !== 'string' || item.trim() === '')
  ) {
    throw new TypeError(`Invalid workflow pack ${field}`)
  }
  const values = value as string[]
  values.forEach((item) => requireId(item, field))
  if (new Set(values).size !== values.length) {
    throw new TypeError(`Duplicate workflow pack ${field}`)
  }
  return [...values]
}

function parseApprovals(value: unknown): Record<string, string> {
  if (!isRecord(value)) {
    throw new TypeError('Invalid workflow pack approvals')
  }
  const approvals: Record<string, string> = {}
  for (const [id, at] of Object.entries(value)) {
    if (
      !id.startsWith(CUSTOM_PACK_PREFIX) ||
      typeof at !== 'string' ||
      !Number.isFinite(Date.parse(at))
    ) {
      throw new TypeError('Invalid workflow pack approval')
    }
    requireId(id, 'approval id')
    approvals[id] = at
  }
  return approvals
}

function parseEnvelope(text: string): WorkflowPackEnvelope {
  const raw: unknown = JSON.parse(text)
  if (
    !isRecord(raw) ||
    raw['format'] !== ENVELOPE_FORMAT ||
    raw['version'] !== ENVELOPE_VERSION ||
    !Array.isArray(raw['packs']) ||
    raw['packs'].length > MAX_CUSTOM_WORKFLOW_PACKS
  ) {
    throw new TypeError('Invalid workflow pack file')
  }

  const packs = raw['packs'].map((candidate) => {
    const { pack } = sanitizeWorkflowPack(candidate)
    if (pack === null || !pack.id.startsWith(CUSTOM_PACK_PREFIX)) {
      throw new TypeError('Invalid stored workflow pack')
    }
    requireId(pack.id, 'pack id')
    return pack
  })
  if (new Set(packs.map((pack) => pack.id)).size !== packs.length) {
    throw new TypeError('Duplicate workflow pack id')
  }

  return {
    format: ENVELOPE_FORMAT,
    version: ENVELOPE_VERSION,
    packs,
    disabledIds: parseStringSet(raw['disabledIds'], 'disabledIds'),
    approvals: parseApprovals(raw['approvals'])
  }
}

function emptyEnvelope(): WorkflowPackEnvelope {
  return {
    format: ENVELOPE_FORMAT,
    version: ENVELOPE_VERSION,
    packs: [],
    disabledIds: [],
    approvals: {}
  }
}

export function createPackStore(deps: PackStoreDeps): PackStore {
  const filePath = join(deps.userDataPath, WORKFLOW_PACKS_FILE_NAME)
  const builtins = (deps.builtins ?? BUILTIN_PACKS).map(clonePack)
  const now = deps.now ?? (() => new Date())
  const makeId = deps.randomUUID ?? randomUUID
  let cache: WorkflowPackEnvelope | undefined

  function load(): WorkflowPackEnvelope {
    if (cache !== undefined) return cache
    if (!existsSync(filePath)) {
      cache = emptyEnvelope()
      return cache
    }

    // An I/O failure does not mean the registry is corrupt. Preserve it and
    // surface the error so a later mutation cannot replace unreadable data.
    const text = readFileSync(filePath, 'utf8')
    try {
      cache = parseEnvelope(text)
    } catch (error) {
      const quarantined = quarantineFile(filePath, now())
      console.warn(
        `[workflow-packs] 저장 파일 읽기 실패 — 격리: ${basename(quarantined ?? filePath)}`,
        error
      )
      cache = emptyEnvelope()
    }
    return cache
  }

  function persist(next: WorkflowPackEnvelope): void {
    mkdirSync(deps.userDataPath, { recursive: true, mode: 0o700 })
    writeFileAtomic(filePath, JSON.stringify(next, null, 2), { mode: 0o600 })
    chmodSync(filePath, 0o600)
    cache = next
    deps.onChanged?.()
  }

  function findKnown(id: string): WorkflowPack | undefined {
    const state = load()
    return (
      builtins.find((pack) => pack.id === id) ??
      state.packs.find((pack) => pack.id === id)
    )
  }

  return {
    list() {
      const state = load()
      const disabled = new Set(state.disabledIds)
      return [
        ...builtins.map((pack): WorkflowPackSummary => ({
          pack: clonePack(pack),
          source: 'builtin',
          enabled: !disabled.has(pack.id),
          approvedAt: null
        })),
        ...state.packs.map((pack): WorkflowPackSummary => ({
          pack: clonePack(pack),
          source: 'user',
          enabled: !disabled.has(pack.id),
          approvedAt: state.approvals[pack.id] ?? null
        }))
      ]
    },

    importText(json, replaceId) {
      let raw: unknown
      try {
        raw = JSON.parse(json)
      } catch {
        throw new ValidationError('워크플로 팩 JSON을 읽을 수 없습니다.')
      }
      const sanitized = sanitizeWorkflowPack(raw)
      if (sanitized.pack === null) {
        throw new ValidationError(
          `워크플로 팩 형식이 올바르지 않습니다: ${sanitized.warnings.join(' ')}`
        )
      }

      const state = load()
      if (replaceId !== undefined) {
        if (!replaceId.startsWith(CUSTOM_PACK_PREFIX) || !state.packs.some((pack) => pack.id === replaceId)) throw new ValidationError('Unknown custom pack')
        const pack = clonePack({ ...sanitized.pack, id: replaceId })
        const { [replaceId]: _approval, ...approvals } = state.approvals
        persist({ ...state, packs: state.packs.map((previous) => previous.id === replaceId ? pack : previous), approvals,
          disabledIds: [...new Set([...state.disabledIds, replaceId])] })
        return { pack: clonePack(pack), warnings: [...sanitized.warnings] }
      }
      if (state.packs.length >= MAX_CUSTOM_WORKFLOW_PACKS) {
        throw new ConflictError(
          `사용자 워크플로 팩은 최대 ${MAX_CUSTOM_WORKFLOW_PACKS}개까지 저장할 수 있습니다.`
        )
      }

      let id = ''
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const candidate = `${CUSTOM_PACK_PREFIX}${makeId()}`
        if (!state.packs.some((pack) => pack.id === candidate)) {
          id = candidate
          break
        }
      }
      if (id === '') {
        throw new ConflictError('새 워크플로 팩 ID를 발급하지 못했습니다.')
      }
      const pack = clonePack({ ...sanitized.pack, id })
      persist({
        ...state,
        packs: [...state.packs, pack]
      })
      return { pack: clonePack(pack), warnings: [...sanitized.warnings] }
    },

    remove(id) {
      const packId = requireId(id, 'id')
      if (!packId.startsWith(CUSTOM_PACK_PREFIX)) {
        throw new ValidationError('기본 제공 워크플로 팩은 삭제할 수 없습니다.')
      }
      const state = load()
      if (!state.packs.some((pack) => pack.id === packId)) {
        throw new NotFoundError('workflow pack', packId)
      }
      const { [packId]: _removedApproval, ...approvals } = state.approvals
      persist({
        ...state,
        packs: state.packs.filter((pack) => pack.id !== packId),
        disabledIds: state.disabledIds.filter(
          (disabledId) => disabledId !== packId
        ),
        approvals
      })
    },

    setEnabled(id, enabled) {
      const packId = requireId(id, 'id')
      if (typeof enabled !== 'boolean') {
        throw new ValidationError('enabled must be a boolean')
      }
      if (findKnown(packId) === undefined) {
        throw new NotFoundError('workflow pack', packId)
      }
      const state = load()
      const disabled = new Set(state.disabledIds)
      if (enabled) disabled.delete(packId)
      else disabled.add(packId)
      persist({ ...state, disabledIds: [...disabled] })
    },

    approve(id, at) {
      const packId = requireId(id, 'id')
      const state = load()
      if (!packId.startsWith(CUSTOM_PACK_PREFIX)) {
        throw new ValidationError('기본 제공 워크플로 팩에는 승인이 필요하지 않습니다.')
      }
      if (!state.packs.some((pack) => pack.id === packId)) {
        throw new NotFoundError('workflow pack', packId)
      }
      if (typeof at !== 'string' || !Number.isFinite(Date.parse(at))) {
        throw new ValidationError('워크플로 팩 승인 시각이 올바르지 않습니다.')
      }
      persist({
        ...state,
        approvals: { ...state.approvals, [packId]: at }
      })
    },

    resolve(id) {
      const packId = requireId(id, 'id')
      const state = load()
      if (state.disabledIds.includes(packId)) return null
      const pack = findKnown(packId)
      return pack === undefined ? null : clonePack(pack)
    }
  }
}
