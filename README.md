# Enka

Personal, cloud-based flashcards for language study — an Anki alternative built
around one person's collection rather than shared decks.

A card is a **term** and its **definition**, either side of which can carry
audio of a native speaker saying it. The definition may be left empty: add the
word when you meet it, fill in the meaning later. Scheduling uses
[FSRS](https://github.com/open-spaced-repetition/py-fsrs), the algorithm behind
modern Anki.

Three parts, all talking to the same API.

```
enka/
├── backend/     ← FastAPI + Postgres
├── web/         ← Vue 3 client
└── macos/       ← a panel that lives in the notch
```

## Quick start

You need Docker. Nothing else.

```bash
make up
```

That generates a `.env` with fresh random secrets, starts Postgres and the API,
applies migrations, and prints your access secret. The API lands on
<http://localhost:8010> with interactive docs at
<http://localhost:8010/docs>.

```bash
make secret   # the secret to type into a client
make seed     # a few demo cards to look at
make stats    # collection statistics
```

`make` on its own lists every target.

## The web client

```bash
npm install --prefix web
npm run dev --prefix web
```

<http://localhost:5273>, then sign in with the secret above. Studying is
keyboard-first: `Space` reveals, `1`–`4` rate, `U` undoes. See
[`web/README.md`](web/README.md) for the rest.

## The macOS app

```bash
make mac-run
```

No window and no Dock icon: the app puts the due count in the menu bar and
unfolds a panel out of the notch when the pointer rests there. The same four
keys study a card; `Add` captures a word in one line while you are reading
something else; `Tags` is the one place it edits the collection. `make
mac-install` puts it in `/Applications`. See
[`macos/README.md`](macos/README.md).

## How auth works

There are no accounts. The server holds one secret (`ENKA_ACCESS_SECRET` in
`.env`); a client sends it once and receives a JWT good for 30 days.

```bash
curl -X POST localhost:8010/api/v1/auth/token \
     -H 'Content-Type: application/json' \
     -d '{"secret":"<your secret>"}'
```

Send the token back as `Authorization: Bearer <token>` on every other endpoint.
The token endpoint is rate-limited to 5 attempts per minute per IP, because a
short hand-typed secret is otherwise guessable.

Audio is the one exception. A browser `<audio src="...">` cannot set headers,
so `GET /api/v1/audio/{id}` also accepts `?token=` — mint a short-lived one
from `POST /api/v1/auth/media-token` rather than putting your 30-day token in a
URL.

## The API

Everything lives under `/api/v1`. Full schemas and a try-it console are at
`/docs`.

| | |
|---|---|
| **Cards** | `GET/POST /cards`, `GET/PATCH/DELETE /cards/{id}`, `POST /cards/bulk`, `POST /cards/{id}/restore` |
| **Search** | `GET /cards/search?q=` |
| **Tags** | `GET/POST /tags`, `PATCH/DELETE /tags/{id}` |
| **Audio** | `POST /cards/{id}/audio?side=term`, `GET /audio/{id}`, `PATCH/DELETE /audio/{id}` |
| **Study** | `GET /study/next`, `GET /study/queue`, `POST /study/{id}/answer`, `POST /study/{id}/undo` |
| **Stats** | `GET /stats`, `GET /stats/heatmap` |

### Studying

`GET /study/next?mode=…` picks the next card and marks it as shown. Modes:

- **`smart`** (default) — what's due, then words you haven't met, then your weakest.
- **`due`** — only cards the scheduler says are due, oldest first.
- **`new`** — cards you've never answered.
- **`reinforce`** — most-forgotten first, whether or not they're due. For cramming.
- **`random`** — uniform over everything active.

`direction` controls which side is shown: `term_to_def`, `def_to_term`, or
`random`. A card with no definition yet is always asked term-first, since there
is nothing on the other side to prompt with.

Answer with `POST /study/{id}/answer`:

| rating | meaning | roughly |
|---|---|---|
| `again` | didn't remember at all | ~1 minute |
| `hard` | remembered, with difficulty | minutes |
| `good` | remembered after a pause | ~10 minutes, then days |
| `easy` | instant | ~8 days, growing fast |

Only `again` counts as a wrong answer. Forgetting a card that had already
graduated to review counts as a *lapse*, and repeat offenders show up under
`leeches` in `/stats`.

### Search

`GET /cards/search?q=` is a trigram search that tolerates typos and ignores
case and accents — `cafe` finds `café`, `ubung` finds `Übung`, `ПРИВЕТ` finds
`привет`, `fenstr` finds `das Fenster`. It searches both sides, so `windo`
finds the card whose *definition* is `window`.

The response carries a top-level **`exact_match`** boolean, which is the point
of the endpoint: as you type a phrase you're about to add, it tells you whether
you already have it.

### Syncing

Every list response includes `server_time`. Store it, and pass it back as
`updated_since` with `include_deleted=true` to get only what changed:

```
GET /api/v1/cards?updated_since=2026-08-18T09:00:00Z&include_deleted=true
```

Deletes are soft by default, so deleted cards come back as tombstones
(`deleted_at` set) and other devices learn about them. `?hard=true` purges a
card and its audio for good — that one leaves no tombstone.

## Development

```bash
make test     # pytest
make lint     # ruff check + format check
make fmt      # autofix
make logs     # tail
make psql     # a database shell
```

Tests run against a real Postgres in a throwaway `enka_test` database built by
running the actual migrations. That's deliberate: `pg_trgm`, `unaccent` and the
expression indexes are load-bearing, and a SQLite stand-in would test none of
them.

### Schema changes

```bash
make revision m="add something"
make migrate
```

### Backups

```bash
make backup                                 # database + audio, into backups/
make restore f=backups/enka-20260818.sql
```

## Notes on some choices

**Postgres, not SQLite** — `pg_trgm` gives real fuzzy search with an index and
no extra service, which is exactly what the "do I already have this word?"
feature needs.

**The `postgres:17` image, not `-alpine`** — musl's locale support is stubbed
out, which makes `lower()` a no-op outside ASCII. On Alpine, searching for
`ПРИВЕТ` would silently fail to match `привет`. There's a regression test for
this.

**Timestamps come from Python, not `now()`** — `now()` is the *transaction*
start time, and a server-side `onupdate` makes SQLAlchemy re-read the column
lazily, which breaks under asyncio. Generating them in one place also keeps
`updated_at` on the same clock as the `server_time` that sync clients store.

**`owner_id` on every table** — there is one owner row today. It's there so
that adding real accounts later is a change to how tokens are issued, rather
than a migration that has to backfill ownership across thousands of cards.

**Audio on a volume, behind an interface** — `app/storage/base.py` defines the
seam; `local.py` implements it. Moving to S3 means writing one more class, with
no change to the API or schema.

## Configuration

All settings are environment variables prefixed `ENKA_`; see `.env.example`.
The ones worth knowing:

| variable | default | |
|---|---|---|
| `ENKA_ACCESS_SECRET` | — | what you type into a client |
| `ENKA_JWT_SECRET` | — | signs tokens; changing it logs everyone out |
| `ENKA_JWT_TTL_HOURS` | `720` | how long a client stays signed in |
| `ENKA_MAX_AUDIO_MB` | `25` | per-clip upload limit |
| `ENKA_FSRS_DESIRED_RETENTION` | `0.9` | higher = more frequent reviews |
| `ENKA_CORS_ORIGINS` | `*` | tighten before exposing the API |

The API refuses to start if the secrets are still at their placeholder values.
