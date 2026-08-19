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
make mac-install
```

from the repository root: that builds `Enka.app`, puts it in `/Applications`,
and starts it. Add it to Login Items from the Settings tab and you are done.

| | |
|---|---|
| `make mac` | build only, into `macos/build/Enka.app` |
| `make mac-run` | build and run from `macos/build`, without installing |
| `make mac-install` | build, install into `/Applications`, run |
| `make mac-uninstall` | quit and remove `/Applications/Enka.app` |
| `make mac-dev` | compile without bundling — the fast loop while editing |
| `make mac-icon` | re-render the icon from `Scripts/make-icon.swift` |
| `make mac-clean` | remove build products |
| `make mac-identity` | list code-signing identities |

Or from this directory, without `make`:

```bash
./Scripts/bundle.sh release && open build/Enka.app
```

`mac-install` quits the running copy before replacing the bundle. Swapping it
underneath a live process leaves that process running from a path that no longer
exists, and the next code-signing check it makes — the keychain does one —
fails.

### Signing

By default the bundle is **ad-hoc signed**, which needs no setup and works —
but it has one visible cost. An ad-hoc identity *is* the binary's hash, so every
rebuild looks to macOS like a different application asking for the same keychain
item, and you get:

> Enka wants to access key "com.enka.app" in your keychain.

That prompt is genuine: `com.enka.app` is where the app keeps your access secret
and its token, and nothing else uses that name. But **Always Allow** grants the
*current* binary, so the next build asks again. The same churn makes the login
item re-register on every install.

Naming a certificate stops the identity moving, and the grant then holds:

```bash
make mac-identity          # what you have, and how to make one
```

Put the name in `.env`:

```
MACOS_CODESIGN_IDENTITY=Enka Dev
```

`make mac` and everything built on it will use it; `CODESIGN_IDENTITY` in the
environment overrides it for one build. A **self-signed** certificate is enough
— Keychain Access → Certificate Assistant → Create a Certificate, type *Code
Signing*. Nothing here leaves your Mac, so there is nothing for Apple to
notarise.

Gatekeeper will still ask once on first launch if the app was downloaded rather
than built locally, whichever identity signed it.

### Signing in to the server

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
| **Tags** | make, rename, recolour, delete | `return` saves, `esc` backs out |
| **Progress** | due counts, thirty days of activity, leeches | |
| **Settings** | address, secret, three switches | |

`Esc` clears the field you are in, backs out of a tag being edited, or folds the
panel when there is nothing to back out of. The menu bar item opens any tab
directly.

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

- **No card editing.** A card is created here and edited in the web client,
  where there is room to think. Suspending is the one change search will make,
  and it is one click from being undone. Tags are the exception — a tag is a
  word and a colour, the whole of it fits on one row, and the moment you want a
  new one is the moment you are adding the card that needs it.
- **No deleting, except tags.** Deleting a tag is the only destructive thing in
  the panel. It asks first, in the row itself rather than in a dialog, and it
  says what survives: the label goes, the cards keep everything else.
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

`TagStore` is the one store two tabs share: the add tab draws the same tags as
chips, and a tag renamed on the tags tab must not still be showing its old name
on the other. Renames also prune the add tab's selection — a name picked there
and then renamed here would be sent with the next card, which recreates the old
tag and undoes the rename by the back door.

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
