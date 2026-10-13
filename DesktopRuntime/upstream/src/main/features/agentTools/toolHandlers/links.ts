import { existsSync, statSync } from 'node:fs'
import type { TabDescriptor } from '../../../../shared/tabs'
import type { MaterialLinkRecord } from '../../../../shared/types/link'
import { materialKindForPath } from '../../../../shared/materialKind'
import { NotFoundError } from '../../../db/errors'
import {
  optionalString,
  stringField,
  type ToolContext,
  type ToolHandler
} from './context'

type LinkToolName = 'link_materials' | 'list_links'
type LinkToolHandlers = Record<LinkToolName, ToolHandler>

interface ConciseMaterialLink {
  id: string
  fromRelPath: string | null
  toRelPath: string | null
  label: string
}

function descriptorForMaterial(
  courseId: string,
  relPath: string
): TabDescriptor {
  switch (materialKindForPath(relPath)) {
    case 'pdf':
      return { kind: 'pdf', payload: { courseId, relPath } }
    case 'note':
      return { kind: 'note', payload: { courseId, relPath } }
    case 'image':
      return { kind: 'image', payload: { courseId, relPath } }
    case 'video':
    case 'other':
      return { kind: 'file', payload: { courseId, relPath } }
  }
}

function relPathForDescriptor(descriptor: TabDescriptor): string | null {
  switch (descriptor.kind) {
    case 'pdf':
    case 'note':
    case 'image':
    case 'file':
      return descriptor.payload.relPath
    case 'browser':
    case 'chat':
    case 'board':
    case 'whiteboard':
    case 'plugin-panel':
    case 'recording':
    case 'learning':
      return null
  }
}

function concise(record: MaterialLinkRecord): ConciseMaterialLink {
  return {
    id: record.id,
    fromRelPath: relPathForDescriptor(record.source),
    toRelPath: relPathForDescriptor(record.target),
    label: record.label
  }
}

function assertMaterialFile(ctx: ToolContext, courseId: string, relPath: string): void {
  const absPath = ctx.assertCoursePath(courseId, relPath)
  if (!existsSync(absPath) || !statSync(absPath).isFile()) {
    throw new NotFoundError('material', relPath)
  }
}

export function linkTools(ctx: ToolContext): LinkToolHandlers {
  return {
    link_materials(input) {
      const turn = ctx.currentTurn()
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const fromRelPath = stringField(input, 'fromRelPath', { nonEmpty: true })
      const toRelPath = stringField(input, 'toRelPath', { nonEmpty: true })
      const label = optionalString(input, 'label') ?? ''

      assertMaterialFile(ctx, courseId, fromRelPath)
      assertMaterialFile(ctx, courseId, toRelPath)
      const record = ctx.deps.materialLinksRepo.create({
        courseId,
        source: descriptorForMaterial(courseId, fromRelPath),
        target: descriptorForMaterial(courseId, toRelPath),
        label
      })
      ctx.record(
        turn,
        courseId,
        'link_materials',
        'link',
        record.id,
        `자료 연결 «${fromRelPath} → ${toRelPath}»`,
        true
      )
      return concise(record)
    },

    list_links(input) {
      const courseId = stringField(input, 'courseId', { nonEmpty: true })
      const relPath = stringField(input, 'relPath', { nonEmpty: true })
      assertMaterialFile(ctx, courseId, relPath)
      const result = ctx.deps.materialLinksRepo.listFor(courseId, relPath)
      return {
        outgoing: result.outgoing.map(concise),
        incoming: result.incoming.map(concise)
      }
    }
  }
}
