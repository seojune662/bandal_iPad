import { useEffect, useState } from 'react'

interface DocxViewerProps {
  base64: string
  fileName: string
  onError: () => void
}

type DocxState =
  | { status: 'loading' }
  | { status: 'ready'; html: string }

const BLOCKED_ELEMENTS =
  'script, iframe, object, embed, link, meta, base, form, input, button, textarea, select, svg, math'
const URL_ATTRIBUTES = new Set(['href', 'src', 'xlink:href', 'action', 'formaction'])
const URL_SCHEME = /^[a-z][a-z0-9+.-]*:/i
const ALLOWED_LINK_SCHEME = /^(?:https?|mailto):/i
const INLINE_IMAGE = /^data:image\/(?:png|jpe?g);base64,/i
const SUPPORTED_IMAGE_TYPE = /^image\/(?:png|jpe?g)$/i
const UNSUPPORTED_IMAGE_LABEL = '[이미지: 지원하지 않는 형식]'
const UNSAFE_STYLE_VALUE =
  /(?:url|expression)\s*\(|@import|(?:javascript|vbscript|file)\s*:|\\/i
const SAFE_STYLE_PROPERTIES = new Set([
  'color',
  'background-color',
  'font-weight',
  'font-style',
  'font-size',
  'text-align',
  'text-decoration',
  'width',
  'height'
])
const DOCX_STYLE_MAP = [
  'b => strong',
  'i => em',
  "r[style-name='Strong'] => strong",
  "r[style-name='Intense Emphasis'] => strong",
  "r[style-name='Emphasis'] => em",
  "p[style-name='Title'] => h1:fresh",
  "p[style-name='Subtitle'] => h2:fresh",
  ...Array.from(
    { length: 6 },
    (_, index) =>
      `p[style-name='Heading ${index + 1}'] => h${index + 1}:fresh`
  ),
  ...Array.from(
    { length: 6 },
    (_, index) => `p[style-name='제목 ${index + 1}'] => h${index + 1}:fresh`
  )
]

function base64ToArrayBuffer(base64: string): ArrayBuffer {
  const binary = window.atob(base64)
  const buffer = new ArrayBuffer(binary.length)
  const bytes = new Uint8Array(buffer)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return buffer
}

function isSafeStyleProperty(property: string): boolean {
  return (
    SAFE_STYLE_PROPERTIES.has(property) ||
    property.startsWith('margin') ||
    property.startsWith('padding') ||
    property.startsWith('border')
  )
}

function sanitizeStyleAttribute(
  document: Document,
  element: Element
): void {
  const source = element.getAttribute('style')
  if (source === null) return

  const parsedStyle = document.createElement('span').style
  parsedStyle.cssText = source
  const safeDeclarations: string[] = []

  for (let index = 0; index < parsedStyle.length; index += 1) {
    const property = parsedStyle.item(index).toLowerCase()
    const value = parsedStyle.getPropertyValue(property).trim()
    if (
      isSafeStyleProperty(property) &&
      value.length > 0 &&
      !UNSAFE_STYLE_VALUE.test(value)
    ) {
      safeDeclarations.push(`${property}: ${value}`)
    }
  }

  if (safeDeclarations.length === 0) {
    element.removeAttribute('style')
  } else {
    element.setAttribute('style', safeDeclarations.join('; '))
  }
}

function normalizedUrl(value: string): string {
  return value.replace(/[\u0000-\u0020\u007f-\u009f]/g, '')
}

export type SanitizedDocxAnchor =
  | {
      tagName: 'a'
      href: string
      target: '_blank'
      rel: 'noopener noreferrer'
      text: string
    }
  | { tagName: 'span'; text: string }

/** Allows web/mail links and local document references, never OS app schemes. */
export function isAllowedDocxHref(href: string): boolean {
  const normalized = normalizedUrl(href.trim())
  return (
    ALLOWED_LINK_SCHEME.test(normalized) ||
    (!URL_SCHEME.test(normalized) && !normalized.startsWith('//'))
  )
}

/** Pure link-policy boundary used by the DOM sanitizer below. */
export function sanitizeDocxAnchor(
  href: string,
  text: string
): SanitizedDocxAnchor {
  const trimmedHref = href.trim()
  if (!isAllowedDocxHref(trimmedHref)) return { tagName: 'span', text }
  return {
    tagName: 'a',
    href: trimmedHref,
    target: '_blank',
    rel: 'noopener noreferrer',
    text
  }
}

/** Defensive boundary for HTML produced from an untrusted external document. */
export function sanitizeDocxHtml(html: string): string {
  const document = new DOMParser().parseFromString(html, 'text/html')

  document
    .querySelectorAll('img[data-docx-unsupported-image]')
    .forEach((image) =>
      image.replaceWith(document.createTextNode(UNSUPPORTED_IMAGE_LABEL))
    )
  document.querySelectorAll(BLOCKED_ELEMENTS).forEach((element) => element.remove())
  document.body.querySelectorAll('*').forEach((element) => {
    const anchorPolicy =
      element.tagName === 'A' && element.hasAttribute('href')
        ? sanitizeDocxAnchor(
            element.getAttribute('href') ?? '',
            element.textContent ?? ''
          )
        : null
    if (anchorPolicy?.tagName === 'span') {
      const replacement = document.createElement('span')
      replacement.textContent = anchorPolicy.text
      element.replaceWith(replacement)
      return
    }

    for (const attribute of [...element.attributes]) {
      const name = attribute.name.toLowerCase()
      const value = attribute.value.trim()
      if (name.startsWith('on') || name === 'srcdoc' || name === 'srcset') {
        element.removeAttribute(attribute.name)
        continue
      }
      if (name === 'style') {
        sanitizeStyleAttribute(document, element)
        continue
      }
      if (name === 'src' && value.length > 0 && !INLINE_IMAGE.test(value)) {
        element.removeAttribute(attribute.name)
        continue
      }
      if (
        name !== 'src' &&
        URL_ATTRIBUTES.has(name) &&
        !isAllowedDocxHref(value)
      ) {
        element.removeAttribute(attribute.name)
      }
    }

    if (anchorPolicy?.tagName === 'a') {
      element.setAttribute('href', anchorPolicy.href)
      element.setAttribute('target', anchorPolicy.target)
      element.setAttribute('rel', anchorPolicy.rel)
    }
  })

  return document.body.innerHTML
}

export function DocxViewer({
  base64,
  fileName,
  onError
}: DocxViewerProps): JSX.Element {
  const [state, setState] = useState<DocxState>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false
    setState({ status: 'loading' })

    void import('mammoth')
      .then(async (mammoth) => {
        const convertImage = mammoth.default.images.imgElement(async (image) => {
          const contentType = (image.contentType.split(';', 1)[0] ?? '')
            .trim()
            .toLowerCase()
          if (!SUPPORTED_IMAGE_TYPE.test(contentType)) {
            return {
              src: '',
              alt: UNSUPPORTED_IMAGE_LABEL,
              'data-docx-unsupported-image': 'true'
            }
          }

          try {
            const imageBase64 = await image.readAsBase64String()
            return { src: `data:${contentType};base64,${imageBase64}` }
          } catch {
            return {
              src: '',
              alt: UNSUPPORTED_IMAGE_LABEL,
              'data-docx-unsupported-image': 'true'
            }
          }
        })
        const result = await mammoth.default.convertToHtml(
          { arrayBuffer: base64ToArrayBuffer(base64) },
          {
            externalFileAccess: false,
            styleMap: DOCX_STYLE_MAP,
            convertImage
          }
        )
        if (!cancelled) {
          setState({ status: 'ready', html: sanitizeDocxHtml(result.value) })
        }
      })
      .catch(() => {
        if (!cancelled) onError()
      })

    return () => {
      cancelled = true
    }
  }, [base64, onError])

  if (state.status === 'loading') {
    return (
      <div className="file-status" role="status">
        Word 문서를 변환하는 중…
      </div>
    )
  }

  return (
    <div
      className="file-docx"
      role="region"
      aria-label={`${fileName} 문서 내용`}
    >
      <article
        className="file-docx__document"
        dangerouslySetInnerHTML={{ __html: state.html }}
      />
    </div>
  )
}
