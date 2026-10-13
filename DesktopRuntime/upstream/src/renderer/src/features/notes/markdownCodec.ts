import { Clock, Container, Ctx, type MilkdownPlugin } from '@milkdown/ctx'
import {
  Editor,
  config,
  editorViewCtx,
  init,
  parser,
  parserCtx,
  schema,
  serializer,
  serializerCtx
} from '@milkdown/core'
import type { Node as ProseNode } from '@milkdown/prose/model'
import type { EditorView } from '@milkdown/prose/view'
import {
  plugins as commonmarkPlugins,
  schema as commonmarkSchema
} from '@milkdown/preset-commonmark'
import {
  plugins as gfmPlugins,
  schema as gfmSchema
} from '@milkdown/preset-gfm'
import { NOTE_MARKDOWN_EXTENSIONS } from './noteMarkdownExtensions'

export interface MarkdownCodec {
  parse: (markdown: string) => ProseNode
  serialize: (document: ProseNode) => string
  normalize: (markdown: string) => string
}

/**
 * Builds the same parser/serializer stack used by NoteTab, without mounting an
 * EditorView. Keeping this headless is useful for round-trip regression tests
 * and for future note migrations.
 */
export async function createMarkdownCodec(): Promise<MarkdownCodec> {
  const context = new Ctx(new Container(), new Clock())
  const viewState = { doc: null as ProseNode | null }
  const headlessView = { state: viewState } as unknown as EditorView

  // The commonmark paragraph serializer checks the current document to decide
  // whether an empty final paragraph needs preserving.
  context.inject(editorViewCtx, headlessView)

  const remarkPlugins = [...commonmarkPlugins, ...gfmPlugins].filter(
    (plugin) => plugin.meta?.group === 'Remark'
  )
  const plugins: MilkdownPlugin[] = [
    schema,
    parser,
    serializer,
    init(Editor.make()),
    config(() => undefined),
    ...commonmarkSchema,
    ...gfmSchema,
    ...NOTE_MARKDOWN_EXTENSIONS,
    ...remarkPlugins
  ]

  const runners = plugins.map((plugin) => plugin(context))
  await Promise.all(runners.map((run) => Promise.resolve(run())))

  const parse = context.get(parserCtx)
  const serializeDocument = context.get(serializerCtx)
  const serialize = (document: ProseNode): string => {
    viewState.doc = document
    return serializeDocument(document)
  }

  return {
    parse,
    serialize,
    normalize: (markdown) => serialize(parse(markdown))
  }
}
