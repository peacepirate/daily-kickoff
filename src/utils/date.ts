/** Format a UTC-midnight date (from YAML frontmatter) without timezone offset. */
export function fmtDate(d: Date, opts: Intl.DateTimeFormatOptions): string {
  return d.toLocaleDateString('en-US', { timeZone: 'UTC', ...opts });
}

export const DAY_NAMES_UTC = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];

export function dayOfWeekUTC(d: Date): string {
  return DAY_NAMES_UTC[d.getUTCDay()]!;
}

/** YYYY-MM-DD string for a given date in UTC. */
export function utcDateKey(d: Date): string {
  return d.toISOString().split('T')[0]!;
}
