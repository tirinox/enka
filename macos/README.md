# Enka for macOS

A flashcard client that lives in the notch.

There is no window and no Dock icon. The app puts a small item in the menu bar
carrying the number of cards due, and a panel that unfolds out of the notch when
the pointer rests there. Study a card, add a word you just met, look one up —
then move the mouse away and it folds back into the black.

It talks to the same API as the web client, so a card added here is in the
collection everywhere a second later.

```
      ╭───────────────╮
 ─────╯               ╰──────      ← the notch, at rest
```

## Build and run

You need the Xcode command line tools. Nothing else — no Xcode project, no
CocoaPods, no signing certificate.

```bash
make mac-run
```

from the repository root, or from this directory:

```bash
./Scripts/bundle.sh release && open build/Enka.app
```

`make mac-dev` compiles without assembling the bundle, which is the fast loop
while editing.

The bundle is ad-hoc signed. macOS will let it run, but Gatekeeper will ask once
on the first launch if it was downloaded rather than built locally.

### Signing in

Hover the notch, click the gear, and type the address and the access secret —
the one `make secret` prints. Both are stored in the keychain, and the app mints
a fresh 30-day token from the secret whenever the old one is about to run out,
so this is a one-time exchange.

If the server moves, change the address and press **Reconnect** with the secret
box empty: the secret already held is reused.

## The tabs

| | | |
|---|---|---|
| **Study** | one card at a time | `space` reveals, `1`–`4` rate, `U` undoes, `R` replays the audio |
| **Add** | a word and, optionally, its meaning | `return` saves, `⌘return` saves from the meaning field |
| **Search** | fuzzy, accent- and typo-tolerant | click a row for its history |
| **Progress** | due counts, thirty days of activity, leeches | |
| **Settings** | address, secret, three switches | |

`Esc` clears the field you are in, or folds the panel when there is nothing to
clear. The menu bar item opens any tab directly.

### Why study needs one click first

Every other tab takes the keyboard the moment you land on it. Study does not:
it is the tab a stray hover lands on, and claiming the keyboard dims the caret
in whatever you were writing. So the first click on the card both reveals it and
hands the panel the keyboard — one press, and `1`–`4` are live from then on.

The shortcuts are matched on **key position**, not on the character produced.
This is a language app: its user is expected to be sitting on a Cyrillic or
Greek layout half the time, and `U` for undo prints something else there.

## What it does not do

Deliberately. The panel opens on a hover and closes when the pointer leaves, so
nothing that needs more than a few seconds of attention belongs in it:

- **No editing.** A card is created here and edited in the web client, where
  there is room to think. Suspending is the one change search will make, and it
  is one click from being undone.
- **No deleting.** Nothing destructive is a hover away from the menu bar.
- **No audio recording.** Uploading a clip means picking a file, and that means
  a file dialog, and a file dialog means the panel has already folded.
- **No offline queue.** Everything is a live call. A failed answer keeps the
  card on screen rather than pretending it landed.

## How it is put together

```
Sources/Enka/
├── main.swift            the whole of the app's startup
├── App/                  status item, menu, shared stores
├── Notch/                panel, geometry, pointer tracking, open/close
├── Model/                what is showing
├── Services/             API client, session, one store per tab
└── UI/                   the panes
```

Three things are worth knowing before changing any of it.

**The window never resizes.** It is cut once to the tallest body any tab can
ask for and left there, transparent outside the visible panel. What is clickable
is decided separately, by `NotchRootView.activeRect` — everything outside that
is click-through, so the menu bar underneath keeps working while the panel is
folded.

**Hover is sampled, not observed.** A global `NSEvent` monitor never sees events
delivered to this app's own windows, and a local one only fires while the app is
active — which an `.accessory` app never is. `PointerWatcher` reads
`NSEvent.mouseLocation` on a timer instead, at 60 Hz near the top of the screen
and 8 Hz everywhere else.

**Closing happens in two passes.** Dropping the keyboard and folding the panel
in the same run-loop pass makes SwiftUI apply the state and lose the repaint:
the panel stands there fully expanded with `isOpen` already false. One
`DispatchQueue.main.async` between them is what fixes it.

The panel machinery — the shape, the geometry, the pointer watcher, the
open/close dance — is adapted from
[Cyclop](https://github.com/akalikbergenov/cyclop) (MIT), which worked those
numbers out against real hardware. The comments explaining *why* a number is
what it is came with it, because the reasons still hold.

## Requirements

macOS 14 or later. On a Mac without a notch — an external display, or anything
before 2021 — the app draws one the size of a typical cutout in the middle of
the menu bar, and claims a shallower strip along the top edge so that clicks on
status items underneath still reach them.
