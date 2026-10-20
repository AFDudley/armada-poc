// ABOUTME: Decorative tick grid layer for the Progress bar track — pure CSS, no JS measurement.
// ABOUTME: Renders a single absolutely-positioned div consumed inside Progress.

import styles from "./BarTrackTicks.module.css";

/**
 * Full-width tick grid via CSS repeat — positions are fixed to the track, not
 * the animated fill. The fill layer stacks above and covers ticks where filled.
 */
export function BarTrackTicks() {
  return <div className={styles.host} aria-hidden />;
}
