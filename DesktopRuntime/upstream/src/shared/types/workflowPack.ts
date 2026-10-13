export const WORKFLOW_PACK_SCHEMA_VERSION = 2
export const LEGACY_WORKFLOW_PACK_SCHEMA_VERSION = 1
export const CUSTOM_PACK_PREFIX = 'custom:'

export type WorkflowPackScope =
  | 'course'
  | 'material'
  | 'selection'
  | 'browser-tab'

export interface WorkflowPackOutputs {
  dir: string
  primary: string
}

export interface WorkflowPackFollowUp {
  label: string
  recipe: string
}

interface WorkflowPackBase {
  id: string
  name: string
  description: string
  author: string
  version: string
  locale: 'ko-KR' | 'en-US'
  worksOn: readonly WorkflowPackScope[]
  recipe: string
  allowedTools: readonly string[]
  usesWeb: boolean
  outputs: WorkflowPackOutputs
  followUp?: WorkflowPackFollowUp
}

/** Existing imported JSON recipes continue to run and export unchanged. */
export interface WorkflowPackV1 extends WorkflowPackBase {
  schemaVersion: 1
}

export type WorkflowPackExperience = 'article-vocabulary' | 'quiz' | 'flashcards'
export type NativeStudyExperience = WorkflowPackExperience

/** Native experiences share their catalog/permissions with the recipe packs. */
export interface WorkflowPackV2 extends WorkflowPackBase {
  schemaVersion: 2
  experience: WorkflowPackExperience
}

export type WorkflowPack = WorkflowPackV1 | WorkflowPackV2

export interface WorkflowPackSummary {
  pack: WorkflowPack
  source: 'builtin' | 'user'
  enabled: boolean
  approvedAt: string | null
}
