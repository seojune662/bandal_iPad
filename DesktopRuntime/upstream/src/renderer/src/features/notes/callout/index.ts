import type { MilkdownPlugin } from '@milkdown/ctx'
import { calloutInputRule, calloutKeymap, wrapInCalloutCommand } from './calloutCommands'
import { calloutSchema } from './calloutSchema'
import { calloutView } from './calloutView'
import { remarkCalloutPlugin } from './remarkCallout'

export * from './calloutCommands'
export * from './calloutSchema'
export * from './calloutTypes'
export * from './remarkCallout'

export const calloutMarkdown: MilkdownPlugin[] = [
  calloutSchema,
  remarkCalloutPlugin
].flat()

export const calloutEditor: MilkdownPlugin[] = [
  calloutView,
  wrapInCalloutCommand,
  calloutInputRule,
  calloutKeymap
].flat()
