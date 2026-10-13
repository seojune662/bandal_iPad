import type { Node as ProseNode } from '@milkdown/prose/model'
import { DOMParser as ProseDOMParser, Fragment } from '@milkdown/prose/model'
import { NodeSelection, Plugin, PluginKey } from '@milkdown/prose/state'
import type {
  EditorView,
  NodeView,
  NodeViewConstructor
} from '@milkdown/prose/view'
import type { DrawingImageSource } from '../../../../shared/types/drawing'
import { showToast } from '../../app/toast'
import { invoke } from '../../lib/ipc'
import { imageSourceFromFileDrop } from '../materials/imageDrag'
import { mediaUrlFor } from '../materials/mediaUrl'

const ASSETS_DIRECTORY = 'assets'
const IMAGE_EXTENSIONS = new Set([
  'avif',
  'bmp',
  'gif',
  'jpeg',
  'jpg',
  'png',
  'svg',
  'webp'
])

const MIME_EXTENSION: Readonly<Record<string, string>> = {
  'image/avif': 'avif',
  'image/bmp': 'bmp',
  'image/gif': 'gif',
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/svg+xml': 'svg',
  'image/webp': 'webp'
}

interface PendingImageRange {
  from: number
  to: number
}

type PendingImageState = ReadonlyMap<string, PendingImageRange>

type PendingImageMeta =
  | { type: 'add'; id: string; range: PendingImageRange }
  | { type: 'remove'; id: string }

interface SavedImage {
  relPath: string
  alt: string
}

interface SaveImagesResult {
  images: SavedImage[]
  failures: unknown[]
}

export const noteImageInsertKey = new PluginKey<PendingImageState>(
  'note-image-insert'
)

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function fileExtension(file: File): string {
  const fromMime = MIME_EXTENSION[file.type.toLocaleLowerCase()]
  if (fromMime !== undefined) return fromMime
  const fromName = /\.([a-z0-9]+)$/iu.exec(file.name)?.[1]?.toLocaleLowerCase()
  return fromName !== undefined && IMAGE_EXTENSIONS.has(fromName)
    ? fromName
    : 'png'
}

function fileLabel(file: File): string {
  const label = file.name.replace(/\.[^.]+$/u, '').trim()
  return label.length > 0 ? label : '붙여넣은 이미지'
}

function pad(value: number): string {
  return String(value).padStart(2, '0')
}

/** `붙여넣은 이미지 2026-08-18 22.04.05.png` */
export function pastedNoteImageFileName(file: File, now: Date): string {
  const date = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`
  const time = `${pad(now.getHours())}.${pad(now.getMinutes())}.${pad(now.getSeconds())}`
  return `붙여넣은 이미지 ${date} ${time}.${fileExtension(file)}`
}

export function isNoteImageFile(file: File): boolean {
  if (file.type.toLocaleLowerCase().startsWith('image/')) return true
  const extension = /\.([a-z0-9]+)$/iu.exec(file.name)?.[1]?.toLocaleLowerCase()
  return extension !== undefined && IMAGE_EXTENSIONS.has(extension)
}

function imageFiles(dataTransfer: DataTransfer | null): File[] {
  if (dataTransfer === null) return []
  const files = [...dataTransfer.files]
  const candidates =
    files.length > 0
      ? files
      : [...dataTransfer.items]
          .filter((item) => item.kind === 'file')
          .map((item) => item.getAsFile())
          .filter((file): file is File => file !== null)
  return candidates.filter(isNoteImageFile)
}

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () =>
      reject(reader.error ?? new Error('이미지를 읽지 못했습니다.'))
    reader.onload = () => {
      if (typeof reader.result !== 'string') {
        reject(new Error('이미지를 읽지 못했습니다.'))
        return
      }
      const comma = reader.result.indexOf(',')
      if (comma < 0) {
        reject(new Error('이미지 인코딩이 올바르지 않습니다.'))
        return
      }
      resolve(reader.result.slice(comma + 1))
    }
    reader.readAsDataURL(file)
  })
}

async function ensureAssetsDirectory(courseId: string): Promise<void> {
  try {
    await invoke('materials:createFolder', {
      courseId,
      dirRelPath: '',
      name: ASSETS_DIRECTORY
    })
  } catch (error) {
    // The shared assets directory normally already exists. Any other failure
    // must remain visible instead of being mistaken for that expected race.
    if (!errorMessage(error).includes('[conflict]')) throw error
  }
}

async function saveImages(
  courseId: string,
  files: readonly File[]
): Promise<SaveImagesResult> {
  await ensureAssetsDirectory(courseId)
  const timestamp = new Date()
  const images: SavedImage[] = []
  const failures: unknown[] = []

  for (const file of files) {
    try {
      const result = await invoke('materials:writeFile', {
        courseId,
        dirRelPath: ASSETS_DIRECTORY,
        fileName: pastedNoteImageFileName(file, timestamp),
        encoding: 'base64',
        data: await fileToBase64(file)
      })
      images.push({ relPath: result.relPath, alt: fileLabel(file) })
    } catch (error) {
      failures.push(error)
    }
  }
  return { images, failures }
}

function addPendingRange(view: EditorView, range: PendingImageRange): string {
  const id = crypto.randomUUID()
  view.dispatch(
    view.state.tr.setMeta(noteImageInsertKey, {
      type: 'add',
      id,
      range
    } satisfies PendingImageMeta)
  )
  return id
}

function removePendingRange(view: EditorView, id: string): void {
  view.dispatch(
    view.state.tr.setMeta(noteImageInsertKey, {
      type: 'remove',
      id
    } satisfies PendingImageMeta)
  )
}

/**
 * Saves image files under the course's assets/ directory, then inserts image
 * nodes whose src stays portable (`assets/...`) in serialized Markdown.
 */
export async function insertNoteImageFiles(
  view: EditorView,
  courseId: string,
  inputFiles: readonly File[],
  range: PendingImageRange = {
    from: view.state.selection.from,
    to: view.state.selection.to
  }
): Promise<void> {
  const files = inputFiles.filter(isNoteImageFile)
  if (files.length === 0) return

  const requestId = addPendingRange(view, range)
  try {
    const { images, failures } = await saveImages(courseId, files)
    if (images.length === 0) {
      throw failures[0] ?? new Error('이미지를 저장하지 못했습니다.')
    }
    const pendingRange = noteImageInsertKey.getState(view.state)?.get(requestId)
    if (pendingRange === undefined) return
    const imageType = view.state.schema.nodes['image']
    if (imageType === undefined) throw new Error('이미지 노드를 만들 수 없습니다.')

    const nodes = images.map(({ relPath, alt }) =>
      imageType.create({ src: relPath, alt, title: '' })
    )
    const transaction = view.state.tr
      .replaceWith(
        pendingRange.from,
        pendingRange.to,
        Fragment.fromArray(nodes)
      )
      .setMeta(noteImageInsertKey, {
        type: 'remove',
        id: requestId
      } satisfies PendingImageMeta)
      .scrollIntoView()
    view.dispatch(transaction)
    view.focus()
    if (failures.length > 0) {
      showToast(
        `${failures.length}개 이미지를 삽입하지 못했습니다: ${errorMessage(failures[0])}`,
        'danger'
      )
    }
  } catch (error) {
    removePendingRange(view, requestId)
    showToast(errorMessage(error) || '이미지를 삽입하지 못했습니다.', 'danger')
  }
}

/** 과목 안 이미지를 복사 없이 그대로 가리키는 image 노드를 삽입한다. */
function insertExistingCourseImage(
  view: EditorView,
  source: DrawingImageSource,
  insertAt: number
): void {
  const imageType = view.state.schema.nodes['image']
  if (imageType === undefined) return
  const alt = source.label.replace(/\.[^.]+$/u, '')
  const node = imageType.create({ src: source.relPath, alt, title: '' })
  view.dispatch(view.state.tr.insert(insertAt, node).scrollIntoView())
  view.focus()
}

/**
 * Any scheme-less relative source is a course-relative path — `assets/...`
 * saved by this plugin, or an existing material dropped from the sidebar.
 */
function noteLocalRelPath(source: string): string | null {
  const normalized = source.replace(/^\.\//u, '')
  if (normalized.length === 0) return null
  if (/^[a-z][a-z0-9+.-]*:/iu.test(normalized)) return null
  if (normalized.startsWith('/')) return null
  try {
    // remark-stringify escapes spaces as %20. Decode that portable Markdown
    // URL before mediaUrlFor encodes each filesystem path segment.
    return decodeURI(normalized)
  } catch {
    return normalized
  }
}

export function noteImageSource(courseId: string, source: string): string {
  const relPath = noteLocalRelPath(source)
  return relPath === null ? source : mediaUrlFor(courseId, relPath)
}

/** Renders local portable paths without mutating the node attrs/serializer. */
export function createNoteImageView(courseId: string): NodeViewConstructor {
  return (initialNode): NodeView => {
    let currentNode: ProseNode = initialNode
    const image = document.createElement('img')
    image.draggable = true

    const render = (): void => {
      const source = String(currentNode.attrs['src'] ?? '')
      const alt = String(currentNode.attrs['alt'] ?? '')
      const title = String(currentNode.attrs['title'] ?? '')
      image.src = noteImageSource(courseId, source)
      image.alt = alt
      if (title.length > 0) image.title = title
      else image.removeAttribute('title')
      const relPath = noteLocalRelPath(source)
      if (relPath !== null) {
        image.dataset.materialRelPath = relPath
      } else {
        delete image.dataset.materialRelPath
      }
    }

    render()
    return {
      dom: image,
      update: (node) => {
        if (node.type !== currentNode.type) return false
        currentNode = node
        render()
        return true
      },
      selectNode: () => image.classList.add('ProseMirror-selectednode'),
      deselectNode: () => image.classList.remove('ProseMirror-selectednode'),
      ignoreMutation: (mutation) =>
        mutation.type === 'attributes' && mutation.target === image
    }
  }
}

let copySerial = 0

async function portableImage(courseId: string, source: string): Promise<string> {
  const image = new Image()
  image.crossOrigin = 'anonymous'
  image.src = noteImageSource(courseId, source)
  await image.decode()
  const canvas = document.createElement('canvas')
  if (!image.naturalWidth || !image.naturalHeight || image.naturalWidth * image.naturalHeight > 32_000_000) throw new Error('이미지가 너무 크거나 아직 준비되지 않았어요.')
  canvas.width = image.naturalWidth
  canvas.height = image.naturalHeight
  try {
    const context = canvas.getContext('2d')
    if (!context) throw new Error('이미지를 복사하지 못했어요.')
    context.drawImage(image, 0, 0)
    return canvas.toDataURL('image/png')
  } finally { canvas.width = canvas.height = 0 }
}

async function copyNoteSelection(view: EditorView, courseId: string, cut: boolean, serial: number): Promise<void> {
  const { selection, doc } = view.state
  const { dom, text } = view.serializeForClipboard(selection.content())
  const { token } = await invoke('clipboard:beginCopy', {})
  const images = [...dom.querySelectorAll('img')]
  await Promise.all(images.map(async (image) => {
    const source = image.getAttribute('src') ?? ''
    image.src = await portableImage(courseId, source)
    image.dataset.bandalCourse = courseId
    const relPath = noteLocalRelPath(source)
    if (relPath) image.dataset.bandalSource = relPath
  }))
  if (serial !== copySerial || view.isDestroyed) return
  const single = selection instanceof NodeSelection && selection.node.type.name === 'image'
  const result = await invoke('clipboard:writeImage', {
    token, png: single ? images[0]?.src ?? null : null,
    html: dom.outerHTML, text
  })
  if (result.written && cut && view.state.doc === doc && view.state.selection.eq(selection)) {
    view.dispatch(view.state.tr.deleteSelection().scrollIntoView())
  }
}

async function pastePortableImages(view: EditorView, courseId: string, html: string): Promise<void> {
  const requestId = addPendingRange(view, view.state.selection)
  try {
    const container = document.createElement('div')
    container.innerHTML = html
    for (const image of container.querySelectorAll<HTMLImageElement>('img[data-bandal-course]')) {
      const existing = image.dataset.bandalSource
      if (image.dataset.bandalCourse === courseId && existing && !existing.split('/').includes('..')) {
        image.setAttribute('src', existing)
      } else {
        const data = image.getAttribute('src') ?? ''
        if (!data.startsWith('data:image/png;base64,')) throw new Error('복사된 이미지가 올바르지 않아요.')
        const bytes = Uint8Array.from(atob(data.split(',')[1]!), (c) => c.charCodeAt(0))
        const result = await saveImages(courseId, [new File([bytes], 'image.png', { type: 'image/png' })])
        const saved = result.images[0]
        if (!saved) throw result.failures[0] ?? new Error('이미지를 저장하지 못했어요.')
        image.setAttribute('src', saved.relPath)
      }
      delete image.dataset.bandalCourse
      delete image.dataset.bandalSource
    }
    if (view.isDestroyed) return
    const range = noteImageInsertKey.getState(view.state)?.get(requestId)
    if (!range) return
    const slice = ProseDOMParser.fromSchema(view.state.schema).parseSlice(container)
    view.dispatch(view.state.tr.replaceRange(range.from, range.to, slice)
      .setMeta(noteImageInsertKey, { type: 'remove', id: requestId } satisfies PendingImageMeta).scrollIntoView())
  } catch (error) {
    if (!view.isDestroyed) removePendingRange(view, requestId)
    showToast(errorMessage(error), 'danger')
  }
}

export function createNoteImagePlugin(
  courseId: string
): Plugin<PendingImageState> {
  let closeMenu: (() => void) | undefined
  return new Plugin<PendingImageState>({
    view: () => ({ destroy: () => closeMenu?.() }),
    key: noteImageInsertKey,
    state: {
      init: () => new Map(),
      apply: (transaction, previous) => {
        const next = new Map<string, PendingImageRange>()
        for (const [id, range] of previous) {
          next.set(id, {
            from: transaction.mapping.map(range.from, -1),
            to: transaction.mapping.map(range.to, 1)
          })
        }

        const meta = transaction.getMeta(noteImageInsertKey) as
          | PendingImageMeta
          | undefined
        if (meta?.type === 'add') next.set(meta.id, meta.range)
        if (meta?.type === 'remove') next.delete(meta.id)
        return next
      }
    },
    props: {
      handleDOMEvents: {
        copy: (view, event) => handleImageCopy(view, event, courseId, false),
        cut: (view, event) => handleImageCopy(view, event, courseId, true),
        contextmenu: (view, event) => {
          const image = event.target instanceof HTMLImageElement ? event.target : null
          if (!image) return false
          event.preventDefault()
          closeMenu?.()
          const position = view.posAtDOM(image, 0)
          view.dispatch(view.state.tr.setSelection(NodeSelection.create(view.state.doc, position)))
          const menu = document.createElement('button')
          menu.textContent = '이미지 복사'
          menu.className = 'note-image-copy-menu'
          menu.style.cssText = `position:fixed;z-index:10000;left:${Math.min(event.clientX, window.innerWidth - 120)}px;top:${Math.min(event.clientY, window.innerHeight - 40)}px;padding:10px 16px;background:var(--bg-surface);color:var(--text-primary);border:1px solid var(--border-subtle);border-radius:8px`
          const close = (): void => { menu.remove(); document.removeEventListener('pointerdown', outside, true); closeMenu = undefined }
          closeMenu = close
          const outside = (e: Event): void => { if (e.target !== menu) close() }
          menu.onclick = () => { close(); void copyNoteSelection(view, courseId, false, ++copySerial).catch(error => showToast(errorMessage(error), 'danger')) }
          document.body.append(menu)
          document.addEventListener('pointerdown', outside, true)
          menu.onkeydown = (e) => { if (e.key === 'Escape') close() }
          menu.focus()
          return true
        }
      },
      handlePaste: (view, event) => {
        const html = event.clipboardData?.getData('text/html') ?? ''
        if (html.includes('data-bandal-course=')) {
          event.preventDefault()
          void pastePortableImages(view, courseId, html)
          return true
        }
        const files = imageFiles(event.clipboardData)
        if (files.length === 0) return false
        event.preventDefault()
        event.stopPropagation()
        void insertNoteImageFiles(view, courseId, files)
        return true
      },
      handleDrop: (view, event) => {
        const files = imageFiles(event.dataTransfer)
        if (files.length === 0) return false
        event.preventDefault()
        event.stopPropagation()
        const position = view.posAtCoords({
          left: event.clientX,
          top: event.clientY
        })?.pos
        const insertAt = position ?? view.state.selection.from

        // 사이드바에서 끌어온 과목 안 이미지는 assets/ 로 복사하지 않고
        // 기존 relPath 를 그대로 참조한다 — 드롭할 때마다 사본이 늘어나는
        // 것을 막는다. 과목 밖(Finder) 이미지만 저장 흐름을 탄다.
        const existing =
          event.dataTransfer === null
            ? null
            : imageSourceFromFileDrop(courseId, event.dataTransfer)
        if (existing !== null) {
          insertExistingCourseImage(view, existing, insertAt)
          return true
        }

        void insertNoteImageFiles(view, courseId, files, {
          from: insertAt,
          to: insertAt
        })
        return true
      }
    }
  })
}

function handleImageCopy(view: EditorView, event: ClipboardEvent, courseId: string, cut: boolean): boolean {
  const serial = ++copySerial
  let hasImage = false
  view.state.selection.content().content.descendants((node) => { if (node.type.name === 'image') hasImage = true })
  if (!hasImage) return false
  event.preventDefault()
  void copyNoteSelection(view, courseId, cut, serial).catch(error => showToast(errorMessage(error), 'danger'))
  return true
}
