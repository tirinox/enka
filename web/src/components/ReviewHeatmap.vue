<script setup lang="ts">
/**
 * A year of reviews, one square per day, laid out in week columns like a
 * contribution graph. The API returns a flat list of days; the grid work is
 * all here.
 */
import { computed } from 'vue'
import type { HeatmapDay } from '@/api/types'

const props = defineProps<{ days: HeatmapDay[]; maxReviews: number }>()

interface Cell {
  day: string
  reviews: number
  level: 0 | 1 | 2 | 3 | 4
}

/** Five buckets by share of the busiest day, so the ramp adapts to any volume. */
function levelFor(reviews: number, max: number): Cell['level'] {
  if (reviews === 0) return 0
  if (max <= 1) return 4
  const ratio = reviews / max
  if (ratio <= 0.25) return 1
  if (ratio <= 0.5) return 2
  if (ratio <= 0.75) return 3
  return 4
}

const weeks = computed<Cell[][]>(() => {
  if (!props.days.length) return []
  const sorted = [...props.days].sort((a, b) => a.day.localeCompare(b.day))
  const columns: Cell[][] = []
  let column: Cell[] = []

  // Pad the first column so the earliest day lands on its real weekday.
  const firstWeekday = new Date(`${sorted[0].day}T00:00:00`).getDay()
  for (let i = 0; i < firstWeekday; i++) {
    column.push({ day: '', reviews: -1, level: 0 })
  }

  for (const d of sorted) {
    column.push({ day: d.day, reviews: d.reviews, level: levelFor(d.reviews, props.maxReviews) })
    if (column.length === 7) {
      columns.push(column)
      column = []
    }
  }
  if (column.length) columns.push(column)
  return columns
})

/** Month labels, placed at the column where each month first appears. */
const monthLabels = computed(() => {
  const labels: { index: number; text: string }[] = []
  let lastMonth = ''
  weeks.value.forEach((week, i) => {
    const first = week.find((c) => c.day)
    if (!first) return
    const month = first.day.slice(0, 7)
    if (month !== lastMonth) {
      lastMonth = month
      labels.push({
        index: i,
        text: new Date(`${first.day}T00:00:00`).toLocaleDateString(undefined, { month: 'short' }),
      })
    }
  })
  return labels
})

function tooltip(cell: Cell): string {
  if (!cell.day) return ''
  const date = new Date(`${cell.day}T00:00:00`).toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
  return `${cell.reviews} review${cell.reviews === 1 ? '' : 's'} · ${date}`
}
</script>

<template>
  <div class="heatmap">
    <div class="scroll">
      <div class="months">
        <span
          v-for="m in monthLabels"
          :key="`${m.index}-${m.text}`"
          class="month"
          :style="{ gridColumn: m.index + 1 }"
        >
          {{ m.text }}
        </span>
      </div>
      <div class="grid">
        <div v-for="(week, wi) in weeks" :key="wi" class="week">
          <span
            v-for="(cell, ci) in week"
            :key="ci"
            class="cell"
            :class="[`l${cell.level}`, { blank: cell.reviews < 0 }]"
            :title="tooltip(cell)"
          />
        </div>
      </div>
    </div>
    <div class="legend">
      <span class="faint">Less</span>
      <span v-for="l in [0, 1, 2, 3, 4]" :key="l" class="cell" :class="`l${l}`" />
      <span class="faint">More</span>
    </div>
  </div>
</template>

<style scoped>
.heatmap {
  display: flex;
  flex-direction: column;
  gap: var(--sp-3);
}

/* The year is wider than most panels — let it scroll on its own. */
.scroll {
  overflow-x: auto;
  padding-bottom: var(--sp-1);
}

.months {
  display: grid;
  grid-auto-flow: column;
  grid-auto-columns: 13px;
  height: 1rem;
  margin-bottom: 2px;
}

.month {
  font-size: var(--text-xs);
  color: var(--text-faint);
  white-space: nowrap;
}

.grid {
  display: flex;
  gap: 3px;
}

.week {
  display: flex;
  flex-direction: column;
  gap: 3px;
}

.cell {
  width: 10px;
  height: 10px;
  border-radius: 2px;
  background: var(--heat-0);
}

.cell.blank {
  background: transparent;
}

.l1 {
  background: var(--heat-1);
}

.l2 {
  background: var(--heat-2);
}

.l3 {
  background: var(--heat-3);
}

.l4 {
  background: var(--heat-4);
}

.legend {
  display: flex;
  align-items: center;
  gap: 3px;
  font-size: var(--text-xs);
}

.legend .faint {
  margin: 0 var(--sp-1);
}
</style>
