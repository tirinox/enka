/** Small formatting helpers, shared by every view. */

const MINUTE = 60
const HOUR = 3600
const DAY = 86_400
const MONTH = 2_592_000
const YEAR = 31_536_000

/** "in 3 days" / "2 hours ago" — the sign carries the direction. */
export function relativeTime(iso: string | null | undefined): string {
  if (!iso) return '—'
  const seconds = (new Date(iso).getTime() - Date.now()) / 1000
  const abs = Math.abs(seconds)
  const suffix = seconds < 0 ? ' ago' : ''
  const prefix = seconds >= 0 ? 'in ' : ''

  if (abs < 45) return seconds < 0 ? 'just now' : 'now'
  const [value, unit] =
    abs < HOUR
      ? [abs / MINUTE, 'min']
      : abs < DAY
        ? [abs / HOUR, 'hour']
        : abs < MONTH
          ? [abs / DAY, 'day']
          : abs < YEAR
            ? [abs / MONTH, 'month']
            : [abs / YEAR, 'year']

  const n = Math.round(value)
  return `${prefix}${n} ${unit}${n === 1 ? '' : 's'}${suffix}`
}

/** Compact duration for scheduling intervals: 4m, 3h, 12d, 1.4y. */
export function humanInterval(seconds: number): string {
  if (seconds < MINUTE) return `${Math.round(seconds)}s`
  if (seconds < HOUR) return `${Math.round(seconds / MINUTE)}m`
  if (seconds < DAY) return `${Math.round(seconds / HOUR)}h`
  if (seconds < YEAR) return `${Math.round(seconds / DAY)}d`
  return `${(seconds / YEAR).toFixed(1)}y`
}

export function shortDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
}

export function fullDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function percent(value: number | null | undefined, digits = 0): string {
  if (value === null || value === undefined) return '—'
  return `${(value * 100).toFixed(digits)}%`
}

export function bytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} KB`
  return `${(n / 1024 ** 2).toFixed(1)} MB`
}

export function clipDuration(ms: number | null | undefined): string {
  if (!ms) return ''
  const total = Math.round(ms / 1000)
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
}

export function isOverdue(dueAt: string): boolean {
  return new Date(dueAt).getTime() <= Date.now()
}

/** Deterministic colour for a tag that hasn't been given one. */
export function tagColor(name: string, explicit?: string | null): string {
  if (explicit) return explicit
  let hash = 0
  for (let i = 0; i < name.length; i++) hash = (hash * 31 + name.charCodeAt(i)) | 0
  return `hsl(${Math.abs(hash) % 360} 42% 58%)`
}
