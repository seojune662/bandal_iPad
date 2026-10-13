import type { PluginSettingDefinition } from '../types/plugin'

export function validSettingValue(
  definition: PluginSettingDefinition,
  value: unknown,
): boolean {
  switch (definition.type) {
    case 'boolean':
      return typeof value === 'boolean'
    case 'number':
      return (
        typeof value === 'number' &&
        Number.isFinite(value) &&
        (definition.min === undefined || value >= definition.min) &&
        (definition.max === undefined || value <= definition.max)
      )
    case 'select':
      return (
        typeof value === 'string' &&
        definition.options?.includes(value) === true
      )
    case 'string':
      return (
        typeof value === 'string' &&
        value.length <= (definition.max ?? 4096) &&
        value.length >= (definition.min ?? 0)
      )
  }
}

export function parseSettingsSchema(raw: unknown): PluginSettingDefinition[] {
  if (raw === undefined) return []
  if (!Array.isArray(raw) || raw.length > 64)
    throw new Error('contributes.settings must contain at most 64 fields')
  const keys = new Set<string>()
  return raw.map((value: unknown) => {
    if (typeof value !== 'object' || value === null || Array.isArray(value))
      throw new Error('invalid setting definition')
    const field = value as PluginSettingDefinition
    if (
      typeof field.key !== 'string' ||
      !/^[a-z][a-zA-Z0-9_-]{0,63}$/.test(field.key) ||
      ['constructor', 'prototype', '__proto__'].includes(field.key) ||
      keys.has(field.key) ||
      typeof field.title !== 'string' ||
      !field.title.trim() ||
      field.title.length > 80 ||
      (field.description !== undefined &&
        (typeof field.description !== 'string' ||
          field.description.length > 300)) ||
      !['string', 'number', 'boolean', 'select'].includes(field.type) ||
      (field.min !== undefined &&
        (typeof field.min !== 'number' || !Number.isFinite(field.min))) ||
      (field.max !== undefined &&
        (typeof field.max !== 'number' || !Number.isFinite(field.max))) ||
      (field.min !== undefined &&
        field.max !== undefined &&
        field.min > field.max) ||
      (field.type === 'string' &&
        [field.min, field.max].some(
          (bound) =>
            bound !== undefined &&
            (!Number.isInteger(bound) || bound < 0 || bound > 4096),
        )) ||
      (field.options !== undefined && field.type !== 'select') ||
      (field.type === 'select' &&
        (!Array.isArray(field.options) ||
          !field.options.length ||
          field.options.length > 64 ||
          new Set(field.options).size !== field.options.length ||
          !field.options.every(
            (option) => typeof option === 'string' && option.length <= 200,
          ))) ||
      !validSettingValue(field, field.default)
    )
      throw new Error('invalid setting definition or default')
    keys.add(field.key)
    return {
      key: field.key,
      title: field.title,
      type: field.type,
      default: field.default,
      ...(field.description === undefined
        ? {}
        : { description: field.description }),
      ...(field.min === undefined ? {} : { min: field.min }),
      ...(field.max === undefined ? {} : { max: field.max }),
      ...(field.options === undefined ? {} : { options: [...field.options] }),
    }
  })
}

export function resolvePluginSettings(
  schema: readonly PluginSettingDefinition[],
  raw: unknown,
): Record<string, unknown> {
  const stored =
    typeof raw === 'object' && raw !== null && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : {}
  return Object.fromEntries(
    schema.map((field) => [
      field.key,
      Object.hasOwn(stored, field.key) &&
      validSettingValue(field, stored[field.key])
        ? stored[field.key]
        : field.default,
    ]),
  )
}
