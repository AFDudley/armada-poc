// ABOUTME: Deterministic JSON.stringify — recursively sorts object keys so byte-identical
// ABOUTME: output does not depend on property insertion order (array order is preserved).

export function stableStringify(value: unknown, space = 2): string {
  return JSON.stringify(sortDeep(value), null, space) + '\n'
}

function sortDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortDeep)
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = sortDeep((value as Record<string, unknown>)[key])
    }
    return out
  }
  return value
}
