interface NoteHeading {
  line: number
  title: string
}

function frontMatterEnd(lines: readonly string[]): number {
  if (lines[0]?.trim() !== '---') return -1
  const end = lines.findIndex((line, index) => index > 0 && /^(?:---|\.\.\.)\s*$/.test(line))
  // A leading thematic rule is ordinary Markdown, not necessarily metadata.
  return end > 0 && lines.slice(1, end).some(line => /^[\w.-]+[ \t]*:/.test(line)) ? end : -1
}

/** Ignore literal examples when syncing a Markdown title to its filename. */
function firstNoteHeading(lines: readonly string[]): NoteHeading | null {
  let fence: { marker: string; length: number } | null = null
  let comment = false
  let literalTag: string | null = null
  const metadataEnd = frontMatterEnd(lines)
  for (const [index, line] of lines.entries()) {
    if (index <= metadataEnd) continue
    if (comment) {
      if (line.includes('-->')) comment = false
      continue
    }
    if (literalTag !== null) {
      if (new RegExp(`</${literalTag}\\s*>`, 'i').test(line)) literalTag = null
      continue
    }
    if (fence !== null) {
      const close = /^ {0,3}(`+|~+)[ \t]*$/.exec(line)?.[1]
      if (close?.[0] === fence.marker && close.length >= fence.length) fence = null
      continue
    }
    const openingFence = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line)
    if (openingFence !== null && !(openingFence[1]![0] === '`' && openingFence[2]!.includes('`'))) {
      fence = { marker: openingFence[1]![0]!, length: openingFence[1]!.length }
      continue
    }
    if (/^ {0,3}<!--/.test(line)) {
      comment = !line.includes('-->')
      continue
    }
    const openingTag = /^ {0,3}<(pre|script|style|textarea)(?:\s|>)/i.exec(line)?.[1]
    if (openingTag !== undefined) {
      if (!new RegExp(`</${openingTag}\\s*>`, 'i').test(line)) literalTag = openingTag
      continue
    }
    const match = /^ {0,3}#(?:[ \t]+(.*)|[ \t]*)$/.exec(line)
    if (match === null) continue
    const title = (match[1] ?? '').replace(/[ \t]+#+[ \t]*$/, '').trim()
    return { line: index, title }
  }
  return null
}

export function firstNoteTitle(markdown: string): string | null {
  const title = firstNoteHeading(markdown.split('\n'))?.title
  return title === undefined || title === '' ? null : title
}

export function replaceNoteTitle(markdown: string, title: string): string {
  const lines = markdown.split('\n')
  const heading = firstNoteHeading(lines)
  if (heading !== null) {
    lines[heading.line] = `# ${title}`
    return lines.join('\n')
  }
  // Keep a YAML metadata block at the beginning of the document.
  const metadataEnd = frontMatterEnd(lines)
  if (metadataEnd >= 0) {
    lines.splice(metadataEnd + 1, 0, '', `# ${title}`, '')
    return lines.join('\n')
  }
  return `# ${title}\n\n${markdown}`
}
