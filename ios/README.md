# The iOS client

A phone client for Enka. It began as one screen — answering a card with a
thumb, in the minute somebody has while a kettle boils — and now carries the
whole collection: adding a word, finding one, editing it, the tags, and where
the whole thing stands.

Five tabs, which is what a phone has room for:

| | |
|---|---|
| **Study** | one card, filling the screen, answered with a thumb or a flick |
| **Add** | a word and a return, with the duplicate warning underneath |
| **Cards** | browse or search the collection, and open any card whole |
| **Progress** | the numbers, a month of activity, and the words that beat you |
| **Settings** | the server, the study defaults, the tags, the way out |

The Mac panel has six tabs because a strip of chrome under the notch gets a row
of icons for free. A phone pays a fifth of the bottom bar for each, so the two
that are read rather than used — the tag list and the connection — share one:
Settings owns the server, and Tags is a push away from both it and the cards it
labels.

```bash
make ios-run
```

That builds the app, boots the simulator and launches it. On first run it
wants two things — the address of your server and the secret `make secret`
prints. Both are asked for once: the secret goes to the keychain and the
thirty-day token minted from it is renewed in the background from then on.

Neither has to be typed. Paste whatever carries them — both on one line, two
lines of a note, a line of `.env`, an address with the secret hung off it as
`#secret` or `?secret=` — into either field, and it lands in the right one:

```
http://192.168.1.20:8010 3f9a2b6c1d8e4750a1b2c3d4e5f60718
ENKA_ACCESS_SECRET=3f9a2b6c1d8e4750a1b2c3d4e5f60718
http://enka.local:8010#3f9a2b6c1d8e4750a1b2c3d4e5f60718
```

A **Paste from clipboard** button does the same in one press, and appears only
when there is text to take. The split runs on every keystroke too, but only
ever moves a field when it found *both* values — which typing cannot produce,
so it never fights the person typing.

## On a real iPhone

```bash
make ios-device
```

Builds, installs over the cable and launches. It picks the wired device, so a
phone that is also on Wi-Fi is not ambiguous, and prints the date the signature
runs out.

Getting there the first time needs three things the command line cannot do:

**Trust.** Unlock the phone and tap Trust when it asks. `xcrun devicectl list
devices` shows whether it is paired.

**Developer Mode.** Settings → Privacy & Security → Developer Mode, then a
restart, then confirm once it is back. The toggle only appears after something
has tried to install a development build, so the first `make ios-device` failing
here is the thing that makes it appear.

**One run from Xcode.** Open the project, pick a Team under the target's Signing
& Capabilities, select the phone, ⌘R. This registers the device and issues the
profile — and on a *free* personal team it is the only thing that can, because
`xcodebuild -allowProvisioningUpdates` answers "No Account for Team" for those
from the command line however signed-in Xcode is. Once the profile is on disk
`make ios-device` works on its own, because it no longer has to ask Apple
anything.

The phone then needs to be told the developer is not a stranger: Settings →
General → VPN & Device Management → the certificate → Trust.

A free personal team signs for **seven days** and allows three devices. When the
week is up the app stops launching, and another `make ios-device` fixes it. A
paid team signs for a year — worth switching to if this stops being a novelty,
and the reason `IOS_DEVELOPMENT_TEAM` in `.env` exists.

Once it is on the phone, `localhost` means the phone. `make lan` prints the
address of the Mac to type instead.

## What is shared with the Mac

Nothing in `ios/` talks to the server. That code — the API client, the models,
the session, the study logic — lives in [`shared/Enka`](../shared/Enka) and is
compiled into both apps from one copy:

| | |
|---|---|
| `APIClient` / `APIModels` | every endpoint, and the schema they return |
| `Session` | the secret, the token, and renewing it before anyone notices |
| `StudySession` | the card, the reveal, the rating, the undo |
| `CaptureStore` | the Add screen: the lookup, the duplicate, the save |
| `LibraryStore` | browsing, searching, suspending, deleting, and the undo behind it |
| `CardEditor` | one card's draft, and the patch of only what moved |
| `TagStore` / `StatsStore` | the tags, the numbers, and the due count |
| `AudioPlayback` | fetching a clip and playing it |
| `Keychain` / `Preferences` | where the two secrets and the settings live |
| `PastedCredentials` | pulling an address and a secret out of pasted text |

Two of those are new and only the phone uses them so far — `LibraryStore` and
`CardEditor`. They live in `shared/` anyway, because nothing in either is about
a phone: a list that pages, a patch that sends only what changed, and a delete
that can be taken back are things Enka does, and the Mac can have them the day
its panel wants them.

Compiled in, not linked as a library, and the reason is written down in the
[package manifest](../Package.swift): a module boundary across forty types
would mean `public` on every one of them, for a seam with one consumer on
each side.

So `ios/Enka` is only views. It is meant to stay that way — a behaviour that
belongs to Enka rather than to a phone belongs in `shared/`, where the Mac
gets it too. Reading a pasted secret is the current example: nothing about it
is a phone, so the Mac's settings pane can have it for free.

## Colour

[`Theme.swift`](Enka/Theme.swift) is the web client's
[`tokens.css`](../web/src/styles/tokens.css) ported value for value — the same
warm greys, the same clay accent, the same four rating colours. Both themes are
here, unlike the Mac's, which is dark because the notch is; a phone is held in
daylight as often as not and follows the system.

The ratings are the part that has to agree. They are the only place in any
client where colour carries meaning rather than emphasis, so a red *Again*
here and an orange one in the browser would be a mis-press waiting to happen.

## The icon

[`Scripts/make-icon.swift`](Scripts/make-icon.swift) draws it — no design tool
in the loop, the same arrangement the Mac's icon uses:

```bash
make ios-icon
```

That rewrites `Enka/Assets.xcassets/AppIcon.appiconset` from one 1024 canvas,
and Xcode derives every size the system asks for. The Mac's icon is two cards
lying flat with the notch cut into the top edge, because that is where the Mac
app lives. A phone has no notch worth pointing at, so the cards stand upright —
the way one is held here — and a third joins the fan, because what the phone
shows is a queue. The two behind are dimmed rather than outlined, so at the
size a home screen draws it the whole thing stays one silhouette.

## Plain HTTP

`Info.plist` turns off App Transport Security. A self-hosted Enka on a home
network or a Tailnet is spoken to over `http://`, and a login screen that
fails silently on `http://192.168.1.20:8010` is worse than the exemption. Put
the server behind HTTPS and the exemption stops being used; the app is built
for one person and never goes near the App Store, so it costs nothing else.

## Studying

One card fills the screen. Tap anywhere to reveal the answer, then rate it with
one of the four buttons along the bottom — inside the arc a thumb reaches
without the phone changing hands. The word is set in the same serif the Mac
uses, at whichever of four sizes fits it.

Both halves of the card are laid out from the start and the answer is faded in
rather than inserted, so revealing costs no layout. A prompt that jumped upward
at the moment of recall would pull the eye away from the exact place the answer
is about to appear.

A card can also be flicked: left is *again*, right is *good*, down is *hard*,
up is *easy* — the four laid out the way the buttons are, so the drag is the
buttons without having to look at them. A haptic fires the moment a release
would start counting, and the rating and the interval it buys fade in above the
card while the thumb is still deciding.

The scheduling, the `elapsed_ms`, the undo and the "next in 8 days" that
follows an answer are all `StudySession`, unchanged from the Mac. The menu in
the corner switches mode and direction, plays the card's audio, pauses the card,
and opens it in the editor — filling in a meaning at the moment of failing to
remember it is the single most useful edit there is, and sending somebody to
another tab for it loses both the card and the impulse.

Along the top, beside the due count: the streak, and how many cards have been
answered today. The flame is grey until the day's first answer lands and then
turns clay — that moment is the whole feedback loop of a streak, and it costs
one colour.

Both are seeded from `/stats` once per appearance and then moved by
`StudySession.recordedAnswers`, which counts one up per answer and one down per
undo. Refetching a dozen queries and a leech list to learn that a number went
up by one would be absurd, and the only part of that payload which moves while
somebody is studying moves by exactly one at a time.

`/stats` now takes a `tz`, and the Apple clients send their own. A day counted
in UTC puts a session studied at one in the morning on the day before, so the
tally would reset three hours into the night — defensible for a chart, wrong
for a streak. The server still defaults to UTC for anything that does not ask.

## Adding

One field that matters and one that can wait. The API allows a card with no
definition and that is the intended shape of the screen: you met a word, you
have three seconds, type it and move on. Saving clears the fields and keeps the
keyboard, because the screen is for adding words, plural.

Underneath the field, the collection answers back. Two letters in, a trigram
search runs — debounced, so it is a search per pause and not per keystroke —
and says either *already here, with the meaning you gave it in March*, or lists
the three closest things it found. Half of adding a word is finding out you
already have it.

**Define** and **Translate** generate a meaning for whatever is in the term
field and drop it straight in, editable like anything typed. Translate needs a
native language; the first time it is used it asks for one in the row itself
rather than sending the server a request it would reject.

## Cards, and editing them

Empty, the search field browses: the collection newest first, forty at a time,
narrowed by a tag chip. Typed into, it searches — the trigram one, so `cafe`
finds `café` and `fenstr` finds `das Fenster`.

A row swipes two ways: right to pause a card (kept, never asked) and left to
delete it. The delete is soft — a tombstone the other clients learn about on
their next sync — so a bar slides up offering it back for a few seconds, and
the undo is a real `POST /cards/{id}/restore` rather than a local trick. That
is what makes it safe to offer from a swipe with no dialog in front of it.

Tapping a row opens the card whole: both sides, the notes, the tags, a 1–5
grade, the pause switch, whatever audio it carries, what the scheduler knows
about it, and a delete. Saving sends only the fields that moved —
`PATCH /cards/{id}` reads its body with `exclude_unset` — so editing a
definition here leaves alone whatever the web client changed in the notes
meanwhile. The same sheet writes a new card, from the **+** in the corner.

This is the one place the two Apple clients deliberately differ. The Mac's
search tab is read-mostly, because a panel that unfolds on a hover is four
seconds of somebody's attention and "look here, edit in the web client" was the
right trade for it. A phone is the other case: it is where a collection gets
tidied, on a sofa, a card at a time.

## Tags, progress, settings

**Tags** is a name, a colour from the same eight the other clients offer, and a
count. Renaming and recolouring happen in a sheet rather than in the row, since
a phone row is a thumb wide; deleting asks first, and says what survives — the
label goes, the cards keep everything else.

**Progress** is six numbers, the last thirty days as bars, what the scheduler
is holding, and the leeches. The bars fill in the empty days themselves:
`/stats` reports only the days that had reviews, and two bars stretched across a
month reads as "you studied constantly" and means the opposite. A leech row
opens that card in the editor, because a leech is the one statistic that tells
you to go and do something.

**Settings** holds the two connection questions — is the address right, is the
secret right — asked separately, because conflated they are a guessing game.
Under them: which cards to study and which way round, whether audio plays
itself, the native language the AI translates into, and signing out.

## Where this is going

Adding a word from Safari, which wants a share extension. Recording a clip on
the phone, which is the one thing the editor shows but cannot make. And an
offline queue: `/study/queue` exists to be prefetched, and a subway is exactly
where somebody would answer twenty cards.
