// ABOUTME: Browser-side extraction run via page.evaluate — walks every visible
// ABOUTME: element under <body>, computes a stable path, and snapshots getComputedStyle.

export interface ExtractedElement {
  path: string
  rect: { x: number; y: number; width: number; height: number }
  styles: Record<string, string>
}

/**
 * Runs INSIDE the page (page.evaluate serializes this function and calls it in
 * the browser). Must not reference anything outside its own closure/arguments —
 * no imports, no outer-scope TypeScript types at runtime.
 */
export function extractInBrowser(properties: readonly string[]): ExtractedElement[] {
  const IMPLICIT_ROLE: Record<string, string> = {
    BUTTON: 'button',
    A: 'link',
    NAV: 'navigation',
    HEADER: 'banner',
    FOOTER: 'contentinfo',
    MAIN: 'main',
    H1: 'heading',
    H2: 'heading',
    H3: 'heading',
    H4: 'heading',
    H5: 'heading',
    H6: 'heading',
    INPUT: 'textbox',
    TEXTAREA: 'textbox',
    IMG: 'img',
    UL: 'list',
    OL: 'list',
    LI: 'listitem',
  }

  function accessibleName(el: Element): string | null {
    const ariaLabel = el.getAttribute('aria-label')
    if (ariaLabel && ariaLabel.trim()) return ariaLabel.trim()
    const text = (el.textContent || '').trim().replace(/\s+/g, ' ')
    if (text && text.length > 0 && text.length <= 60) return text
    return null
  }

  function roleOf(el: Element): string | null {
    const explicit = el.getAttribute('role')
    if (explicit) return explicit
    return IMPLICIT_ROLE[el.tagName] ?? null
  }

  /** One path segment for `el`, relative to its parent. Prefers (in order)
   *  #id, [data-testid], role+accessible-name (only when it uniquely selects
   *  `el` among same-tag siblings), falling back to tag:nth-of-type. */
  const VOLATILE_ROLES: Record<string, true> = {
    timer: true,
    status: true,
    alert: true,
    log: true,
  }

  function segmentFor(el: Element): string {
    const id = el.id
    if (id) return '#' + CSS.escape(id)

    const testId = el.getAttribute('data-testid')
    if (testId) return `[data-testid="${testId}"]`

    // 'timer'/'status'/'alert'/'log' are ARIA live-region roles whose
    // accessible name is expected to change between captures (e.g. a
    // ticking countdown) — using it as a path segment would make the path
    // itself non-deterministic, so these always fall through to nth-of-type.
    const role = roleOf(el)
    const name = role && !VOLATILE_ROLES[role] ? accessibleName(el) : null
    if (role && name) {
      const parent = el.parentElement
      if (parent) {
        const siblings = Array.from(parent.children).filter(
          (sib) => roleOf(sib) === role && accessibleName(sib) === name,
        )
        if (siblings.length === 1) {
          return `role=${role}[name="${name}"]`
        }
      }
    }

    const parent = el.parentElement
    const tag = el.tagName.toLowerCase()
    if (!parent) return tag
    const sameTag = Array.from(parent.children).filter((sib) => sib.tagName === el.tagName)
    const index = sameTag.indexOf(el) + 1
    return `${tag}:nth-of-type(${index})`
  }

  function fullPath(el: Element): string {
    const segments: string[] = []
    let node: Element | null = el
    while (node && node.tagName !== 'BODY') {
      segments.unshift(segmentFor(node))
      // A segment anchored on #id or [data-testid] is globally stable —
      // stop climbing further once we hit one.
      if (segments[0]!.startsWith('#') || segments[0]!.startsWith('[data-testid')) break
      node = node.parentElement
    }
    return 'body>' + segments.join('>')
  }

  function isVisible(el: Element, style: CSSStyleDeclaration, rect: DOMRect): boolean {
    if (style.display === 'none' || style.visibility === 'hidden') return false
    if (rect.width <= 0 || rect.height <= 0) return false
    return true
  }

  const out: ExtractedElement[] = []
  const body = document.body
  const all = body.querySelectorAll('*')

  for (const el of Array.from(all)) {
    const style = window.getComputedStyle(el)
    const rect = el.getBoundingClientRect()
    if (!isVisible(el, style, rect)) continue

    const styles: Record<string, string> = {}
    for (const prop of properties) {
      styles[prop] = style.getPropertyValue(
        prop.replace(/[A-Z]/g, (m) => '-' + m.toLowerCase()),
      )
    }

    out.push({
      path: fullPath(el),
      rect: {
        x: Math.round(rect.x * 100) / 100,
        y: Math.round(rect.y * 100) / 100,
        width: Math.round(rect.width * 100) / 100,
        height: Math.round(rect.height * 100) / 100,
      },
      styles,
    })
  }

  out.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))
  return out
}
