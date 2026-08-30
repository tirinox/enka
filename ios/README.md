# The iOS client

A phone client for Enka, built around one thing: answering a card with a
thumb, quickly, in the minute somebody has while a kettle boils.

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
| `Keychain` / `Preferences` | where the two secrets and the settings live |
| `PastedCredentials` | pulling an address and a secret out of pasted text |

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

The scheduling, the `elapsed_ms`, the undo and the "next in 8 days" that
follows an answer are all `StudySession`, unchanged from the Mac. The menu in
the corner switches mode and direction and signs out.

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

## Where this is going

Rating works; making it *pleasant* is next. A card should be draggable — left
for again, right for good — with the interval each rating buys written on the
button before it is pressed, and a haptic that tells the thumb what happened
without the eyes leaving the word. Then audio, then adding a word from Safari.
