# Enka web client

A Vue 3 + TypeScript client for the Enka API. Dark by default, keyboard-first,
and it covers the whole API surface: studying, the card library, fuzzy search,
tags, audio and statistics.

## Running it

The API has to be up first (`make up` in the repository root).

```bash
npm install --prefix web
npm run dev --prefix web
```

That serves <http://localhost:5273>. Sign in with the value of
`ENKA_ACCESS_SECRET` — `make secret` prints it.

Vite proxies `/api` and `/health` to `http://localhost:8010`, so the browser
sees a single origin and CORS never enters into it. Point it somewhere else
with `ENKA_API_URL`:

```bash
ENKA_API_URL=https://enka.example.com npm run dev --prefix web
```

## Building

```bash
npm run build --prefix web      # type-checks, then bundles into web/dist
npm run typecheck --prefix web
```

`dist/` is a static bundle — any web server will do. There's no dev proxy in a
build, so set `VITE_API_BASE` at build time if the API lives on another origin:

```bash
VITE_API_BASE=https://enka.example.com npm run build --prefix web
```

## Keyboard

Studying is meant to be done without the mouse.

| | |
|---|---|
| `Space` / `Enter` | show the answer, then rate it *good* |
| `1` `2` `3` `4` | again · hard · good · easy |
| `U` | undo the last answer |
| `A` | play the card's audio |
| `S` | open the mode and direction settings |

In the Library, `N` opens a new card, `/` jumps to the search box, `F` toggles
the filters, and `Esc` closes whatever is open.

## How it's put together

```
src/
├── api/          client.ts — the only place that talks to the server
│                 types.ts  — hand-written mirror of /openapi.json
├── stores/       auth (the JWT), media (audio tokens), toast
├── composables/  format.ts (dates, intervals), keyboard.ts
├── components/   card editor, audio player, tag chip, heatmap…
├── views/        Login, Study, Library, Tags, Statistics
└── styles/       tokens.css (the palette), base.css (elements + utilities)
```

**One fetch wrapper.** The API answers every failure with the same
`{"error": {"code", "message", "details"}}` envelope, so `client.ts` is the
only file that parses it. Everything else catches `ApiError` and shows
`.message`. A 401 anywhere clears the session and bounces to the login screen.

**Tokens.** The 30-day JWT lives in `localStorage` alongside its expiry, and a
token known to be stale counts as no token — you get the login screen instead
of watching a request fail. Audio is the exception the API carves out: a
browser can't set a header on `<audio src>`, so clips are fetched with a
short-lived media-scoped token from `POST /auth/media-token`. The media store
holds one and re-mints it 30 seconds before it lapses, rather than one per
clip.

**No prefetching in the study loop.** Cards come from `GET /study/next`, one at
a time. Batching with `/study/queue` looks tempting but is wrong here:
answering a card changes the scheduler state the queue was drawn from, and
`queue` doesn't mark cards as shown. One round-trip per card keeps the server's
picker authoritative.

**Two kinds of finding.** The Library's *Exact* toggle filters through
`GET /cards?q=` — a paginated substring match. *Fuzzy* switches to
`GET /cards/search`, which is trigram-backed, accent-insensitive and forgiving
of typos; that's the one that answers "do I already have this word?", and it
shows a match score per hit.

**Theming.** Every colour is a custom property in `tokens.css`, defined twice —
once for dark, once under `:root[data-theme='light']`. No component hard-codes
a colour, so the toggle in the sidebar is a single attribute flip.

## Dependencies

Vue, Vue Router and Pinia. No UI kit, no CSS framework, no charting library —
the heatmap and the activity bars are a few dozen lines of CSS grid and
flexbox, and a system font stack means no network request for type.
