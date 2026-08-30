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

Building for a real phone needs a signing team, which is a setting in Xcode
rather than something the Makefile can guess:

```bash
open ios/Enka.xcodeproj
```

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

## Plain HTTP

`Info.plist` turns off App Transport Security. A self-hosted Enka on a home
network or a Tailnet is spoken to over `http://`, and a login screen that
fails silently on `http://192.168.1.20:8010` is worse than the exemption. Put
the server behind HTTPS and the exemption stops being used; the app is built
for one person and never goes near the App Store, so it costs nothing else.

## Where this is going

Sign-in and a due count are in. Next is the study screen, and after it the
part that all of this is for: rating a card by dragging it, with the interval
each rating buys written on the button, and a haptic that tells the thumb what
happened without the eyes leaving the word.
