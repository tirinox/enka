<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ApiError, api } from '@/api/client'
import { percent, shortDate } from '@/composables/format'
import { useToastStore } from '@/stores/toast'
import PageHeader from '@/components/PageHeader.vue'
import ReviewHeatmap from '@/components/ReviewHeatmap.vue'
import type { HeatmapResponse, StatsResponse } from '@/api/types'

const toasts = useToastStore()

const stats = ref<StatsResponse | null>(null)
const heatmap = ref<HeatmapResponse | null>(null)
const loading = ref(true)

/** Scale the 30-day bars to the busiest day, with a floor so 1 review shows. */
const busiestDay = computed(() =>
  Math.max(1, ...(stats.value?.reviews_last_30_days ?? []).map((d) => d.reviews)),
)

const scheduleBreakdown = computed(() => {
  const s = stats.value?.schedule
  if (!s) return []
  return [
    { label: 'New', value: s.new_count, tone: 'var(--accent)' },
    { label: 'Learning', value: s.learning, tone: 'var(--warning)' },
    { label: 'Review', value: s.review, tone: 'var(--success)' },
    { label: 'Relearning', value: s.relearning, tone: 'var(--again)' },
  ].filter((seg) => seg.value > 0)
})

const breakdownTotal = computed(() =>
  scheduleBreakdown.value.reduce((sum, s) => sum + s.value, 0),
)

onMounted(async () => {
  try {
    // Independent endpoints — no reason to wait for one before the other.
    const [overview, heat] = await Promise.all([
      api.stats.overview(10),
      api.stats.heatmap(365),
    ])
    stats.value = overview
    heatmap.value = heat
  } catch (e) {
    if (e instanceof ApiError) toasts.error(e.message)
  } finally {
    loading.value = false
  }
})
</script>

<template>
  <div class="stats-view">
    <PageHeader
      title="Statistics"
      :subtitle="stats ? `${stats.collection.total_cards} cards · ${stats.study.total_reviews} reviews all time` : 'Loading…'"
    />

    <div v-if="loading" class="loading"><span class="spinner" /></div>

    <template v-else-if="stats">
      <!-- Headline tiles -->
      <section class="tiles">
        <div class="tile">
          <span class="tile-label">Due now</span>
          <span class="tile-value" :class="{ hot: stats.schedule.due_now > 0 }">
            {{ stats.schedule.due_now }}
          </span>
          <span class="tile-note faint">{{ stats.schedule.due_today }} due today</span>
        </div>
        <div class="tile">
          <span class="tile-label">Streak</span>
          <span class="tile-value">{{ stats.current_streak_days }}<small>d</small></span>
          <span class="tile-note faint">best {{ stats.longest_streak_days }}d</span>
        </div>
        <div class="tile">
          <span class="tile-label">Accuracy</span>
          <span class="tile-value">{{ percent(stats.study.accuracy) }}</span>
          <span class="tile-note faint">
            {{ stats.study.correct }} right · {{ stats.study.wrong }} wrong
          </span>
        </div>
        <div class="tile">
          <span class="tile-label">Not yet studied</span>
          <span class="tile-value">{{ stats.study.never_studied }}</span>
          <span class="tile-note faint">{{ stats.study.studied_unique }} seen at least once</span>
        </div>
      </section>

      <!-- Last 30 days -->
      <section class="panel block">
        <div class="block-head">
          <h2>Last 30 days</h2>
          <span class="faint">
            {{ stats.reviews_last_30_days.reduce((s, d) => s + d.reviews, 0) }} reviews
          </span>
        </div>
        <div class="bars">
          <div
            v-for="d in stats.reviews_last_30_days"
            :key="d.day"
            class="bar-col"
            :title="`${shortDate(d.day)} — ${d.reviews} reviews, ${d.correct} correct`"
          >
            <div class="bar-stack" :style="{ height: `${(d.reviews / busiestDay) * 100}%` }">
              <div
                class="bar-correct"
                :style="{ height: d.reviews ? `${(d.correct / d.reviews) * 100}%` : '0%' }"
              />
            </div>
          </div>
        </div>
        <div class="bars-legend">
          <span class="key"><i class="sw correct" /> correct</span>
          <span class="key"><i class="sw wrong" /> wrong</span>
        </div>
      </section>

      <!-- Heatmap -->
      <section v-if="heatmap" class="panel block">
        <div class="block-head">
          <h2>A year of study</h2>
          <span class="faint">{{ heatmap.total_reviews }} reviews</span>
        </div>
        <ReviewHeatmap :days="heatmap.days" :max-reviews="heatmap.max_reviews" />
      </section>

      <div class="two-up">
        <!-- Scheduling -->
        <section class="panel block">
          <div class="block-head"><h2>Scheduling</h2></div>

          <div v-if="breakdownTotal" class="meter">
            <span
              v-for="seg in scheduleBreakdown"
              :key="seg.label"
              class="seg"
              :style="{ width: `${(seg.value / breakdownTotal) * 100}%`, background: seg.tone }"
              :title="`${seg.label}: ${seg.value}`"
            />
          </div>
          <div class="meter-keys">
            <span v-for="seg in scheduleBreakdown" :key="seg.label" class="key">
              <i class="sw" :style="{ background: seg.tone }" />
              {{ seg.label }} <b class="mono">{{ seg.value }}</b>
            </span>
          </div>

          <dl class="facts">
            <div>
              <dt>Average stability</dt>
              <dd>
                {{ stats.schedule.avg_stability_days ? `${stats.schedule.avg_stability_days.toFixed(1)} days` : '—' }}
              </dd>
            </div>
            <div>
              <dt>Average difficulty</dt>
              <dd>{{ stats.schedule.avg_difficulty?.toFixed(2) ?? '—' }}</dd>
            </div>
            <div>
              <dt>Average priority</dt>
              <dd>{{ stats.schedule.avg_star_rating?.toFixed(1) ?? '—' }}</dd>
            </div>
            <div>
              <dt>Total shows</dt>
              <dd>{{ stats.study.total_shows }}</dd>
            </div>
          </dl>
        </section>

        <!-- Collection -->
        <section class="panel block">
          <div class="block-head"><h2>Collection</h2></div>
          <dl class="facts">
            <div><dt>Cards</dt><dd>{{ stats.collection.total_cards }}</dd></div>
            <div>
              <dt>Waiting for a definition</dt>
              <dd>{{ stats.collection.cards_without_definition }}</dd>
            </div>
            <div><dt>With audio</dt><dd>{{ stats.collection.cards_with_audio }}</dd></div>
            <div><dt>Suspended</dt><dd>{{ stats.collection.suspended_cards }}</dd></div>
            <div><dt>Tags</dt><dd>{{ stats.collection.total_tags }}</dd></div>
          </dl>
        </section>
      </div>

      <!-- Leeches -->
      <section v-if="stats.leeches.length" class="panel block">
        <div class="block-head">
          <h2>Hardest cards</h2>
          <span class="faint">the ones you keep forgetting</span>
        </div>
        <div class="leeches">
          <div v-for="l in stats.leeches" :key="l.id" class="leech">
            <span class="l-term">{{ l.term }}</span>
            <span class="l-def truncate faint">{{ l.definition ?? '—' }}</span>
            <span class="badge">{{ l.lapses }}× lapsed</span>
            <span class="l-acc mono">{{ percent(l.accuracy) }}</span>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>

<style scoped>
.stats-view {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  padding: var(--sp-5);
  max-width: var(--content-max);
  width: 100%;
  margin: 0 auto;
}

.loading {
  display: grid;
  place-items: center;
  padding: var(--sp-8);
}

.spinner {
  width: 1.5rem;
  height: 1.5rem;
  border: 2px solid var(--border);
  border-top-color: var(--accent);
  border-radius: var(--radius-full);
  animation: spin 700ms linear infinite;
}

/* --- tiles --- */

.tiles {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(11rem, 1fr));
  gap: var(--sp-3);
}

.tile {
  display: flex;
  flex-direction: column;
  gap: 0.125rem;
  padding: var(--sp-4);
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: var(--radius-lg);
}

.tile-label {
  font-size: var(--text-xs);
  font-weight: 600;
  color: var(--text-faint);
  text-transform: uppercase;
  letter-spacing: 0.06em;
}

.tile-value {
  font-family: var(--font-serif);
  font-size: var(--text-xl);
  font-variant-numeric: tabular-nums;
  line-height: 1.1;
}

.tile-value.hot {
  color: var(--accent);
}

.tile-value small {
  font-size: 0.5em;
  color: var(--text-faint);
  margin-left: 0.0625rem;
}

.tile-note {
  font-size: var(--text-xs);
}

/* --- blocks --- */

.block {
  display: flex;
  flex-direction: column;
  gap: var(--sp-4);
  padding: var(--sp-4) var(--sp-5) var(--sp-5);
}

.block-head {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  gap: var(--sp-3);
  font-size: var(--text-xs);
}

.block-head h2 {
  font-family: var(--font-serif);
  font-size: var(--text-base);
  font-weight: 500;
}

.two-up {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(20rem, 1fr));
  gap: var(--sp-4);
}

/* --- 30-day bars --- */

.bars {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 7rem;
}

.bar-col {
  flex: 1;
  height: 100%;
  display: flex;
  align-items: flex-end;
  min-width: 0;
}

/* Full bar = all reviews; the inner fill = the share that was correct. */
.bar-stack {
  width: 100%;
  min-height: 2px;
  background: var(--again);
  border-radius: 2px;
  display: flex;
  flex-direction: column;
  justify-content: flex-end;
  transition: height var(--normal) var(--ease);
}

.bar-correct {
  width: 100%;
  background: var(--good);
  border-radius: 2px;
}

.bars-legend,
.meter-keys {
  display: flex;
  flex-wrap: wrap;
  gap: var(--sp-4);
  font-size: var(--text-xs);
  color: var(--text-muted);
}

.key {
  display: inline-flex;
  align-items: center;
  gap: var(--sp-2);
}

.sw {
  width: 8px;
  height: 8px;
  border-radius: 2px;
  display: inline-block;
}

.sw.correct {
  background: var(--good);
}

.sw.wrong {
  background: var(--again);
}

.key b {
  color: var(--text);
  font-weight: 600;
}

/* --- meter --- */

.meter {
  display: flex;
  height: 0.5rem;
  border-radius: var(--radius-full);
  overflow: hidden;
  background: var(--bg-elevated);
}

.seg {
  transition: width var(--normal) var(--ease);
}

/* --- facts --- */

.facts {
  display: flex;
  flex-direction: column;
  gap: var(--sp-2);
}

.facts > div {
  display: flex;
  justify-content: space-between;
  gap: var(--sp-3);
  padding-bottom: var(--sp-2);
  border-bottom: 1px dotted var(--border);
  font-size: var(--text-sm);
}

.facts > div:last-child {
  border-bottom: none;
  padding-bottom: 0;
}

.facts dt {
  color: var(--text-faint);
}

.facts dd {
  color: var(--text);
  font-variant-numeric: tabular-nums;
}

/* --- leeches --- */

.leeches {
  display: flex;
  flex-direction: column;
}

.leech {
  display: flex;
  align-items: center;
  gap: var(--sp-3);
  padding: var(--sp-2) 0;
  border-bottom: 1px solid var(--border);
  font-size: var(--text-sm);
}

.leech:last-child {
  border-bottom: none;
}

.l-term {
  font-family: var(--font-serif);
  font-size: var(--text-base);
  white-space: nowrap;
}

.l-def {
  flex: 1;
  min-width: 0;
  font-size: var(--text-xs);
}

.l-acc {
  color: var(--again);
  font-size: var(--text-xs);
  min-width: 2.5rem;
  text-align: right;
}
</style>
