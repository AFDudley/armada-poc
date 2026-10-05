// ABOUTME: Fixed, sorted list of getComputedStyle properties captured for every element.
// ABOUTME: Covers color, border/radius/shadow, typography, spacing, layout, opacity, transform, transition.

/**
 * Deliberately fixed and explicit (not "every computed property") so the
 * baseline stays legible and the vocabulary report only sees properties the
 * design system actually cares about. Keep sorted — `extract.ts` relies on
 * iteration order matching this list for a stable JSON key order, and
 * `capture.ts` re-sorts defensively regardless.
 */
export const CSS_PROPERTIES: readonly string[] = [
  // Color
  'color',
  'backgroundColor',
  'backgroundImage',
  'backgroundPosition',
  'backgroundSize',
  'backgroundRepeat',
  'opacity',

  // Border / radius / shadow
  'borderTopWidth',
  'borderRightWidth',
  'borderBottomWidth',
  'borderLeftWidth',
  'borderTopStyle',
  'borderRightStyle',
  'borderBottomStyle',
  'borderLeftStyle',
  'borderTopColor',
  'borderRightColor',
  'borderBottomColor',
  'borderLeftColor',
  'borderTopLeftRadius',
  'borderTopRightRadius',
  'borderBottomRightRadius',
  'borderBottomLeftRadius',
  'boxShadow',
  'outlineWidth',
  'outlineStyle',
  'outlineColor',
  'outlineOffset',

  // Typography
  'fontFamily',
  'fontSize',
  'fontWeight',
  'fontStyle',
  'lineHeight',
  'letterSpacing',
  'textAlign',
  'textTransform',
  'textDecorationLine',
  'textDecorationColor',
  'textDecorationStyle',
  'whiteSpace',
  'textOverflow',

  // Spacing
  'marginTop',
  'marginRight',
  'marginBottom',
  'marginLeft',
  'paddingTop',
  'paddingRight',
  'paddingBottom',
  'paddingLeft',
  'gap',
  'rowGap',
  'columnGap',

  // Layout
  'display',
  'position',
  'top',
  'right',
  'bottom',
  'left',
  'boxSizing',
  'overflowX',
  'overflowY',
  'zIndex',
  'flexDirection',
  'flexWrap',
  'justifyContent',
  'alignItems',
  'alignContent',
  'alignSelf',
  'flexGrow',
  'flexShrink',
  'flexBasis',
  'gridTemplateColumns',
  'gridTemplateRows',
  'gridColumn',
  'gridRow',
  'gridAutoFlow',
  'width',
  'height',
  'minWidth',
  'minHeight',
  'maxWidth',
  'maxHeight',

  // Motion / interaction
  'transform',
  'transformOrigin',
  'transition',
  'cursor',
  'pointerEvents',
  'visibility',
].sort()
