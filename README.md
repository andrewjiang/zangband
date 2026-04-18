# Zangband Mac App

This repo is an active macOS port of **Zangband 2.7.6**, the old-school
Angband variant with Amber, chaos, mutations, wilderness, weird monsters, and
the specific kind of unfairness that made 90s roguelikes worth remembering.

The goal is simple:

> make Zangband feel at home on a modern Mac without sanding off what makes it
> Zangband.

Right now this builds a double-clickable native `.app` bundle that links the
original game core into an AppKit process, renders through a Cocoa `z-term`
backend, and fixes several 64-bit macOS portability issues.

![Zangband running as a native macOS app](docs/assets/zangband-mac-app.png)

## Upstream

This work is based on the original Zangband source repository:

https://github.com/jjnoo/Zangband

That repository preserves the historical C codebase. This fork focuses on
making it playable and pleasant on modern macOS.

## What Works

- Native macOS `.app` bundle at `macos/build/ZangbandNative.app`
- Direct Cocoa `z-term` renderer
- Bundled game binary and game data
- Writable runtime data under `~/Library/Application Support/ZangbandNative`
- Keyboard input routed through the app window
- Native menus for:
  - New Game
  - Restart
  - Save
  - Save and Quit
  - Save Manager
  - Morgue Gallery
  - Command Palette
  - Bigger Text
  - Smaller Text
  - Actual Size
  - Side Inspector
  - Tile Mode
  - Fullscreen
- Stable fixed-cell grid, so resizing the Mac window keeps the dungeon aligned
- Mac-specific terrain palette, so floors, trees, dirt, grass, rock, water,
  lava, and swamp read as environment instead of bright terminal foreground
- Side inspector with stacked inventory, equipment, and tabbed message/recall
  history
- Random default character names instead of hardcoded player names
- Death-screen restart flow, so a run can be restarted without closing the app
- 64-bit macOS RNG/type-sizing fix for character generation
- Fallback wrapper app at `macos/build/Zangband.app`

## Current Architecture

The primary Mac app is now the direct Cocoa backend.

`ZangbandNative.app` links the Zangband game core into the app process and
implements the game's `z-term` hooks in `src/main-cocoa.m`. That removes the
pseudo-terminal bridge from the main app path and lets the Mac UI observe game
state directly enough to support native panels like the save manager, morgue
gallery, command palette, and side inspector.

The older wrapper app still exists as a compatibility fallback. It runs
`zangband -mgcu` inside a pseudo-terminal, parses the terminal output, and draws
the resulting cells with AppKit.

## Build

From the repo root:

```sh
./configure --with-x11=no
make
make -C macos native
```

Then launch the native Mac app:

```sh
open macos/build/ZangbandNative.app
```

To build the fallback wrapper app:

```sh
make -C macos
open macos/build/Zangband.app
```

To produce a signed native zip release artifact:

```sh
scripts/build-native-macos-release.sh
```

Without a local Apple Developer certificate, the script uses ad-hoc signing.
For a Developer ID build, set:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-native-macos-release.sh
```

To produce a signed wrapper zip instead:

```sh
scripts/build-macos-release.sh
```

For terminal play without the app:

```sh
TERM=xterm-256color ANGBAND_PATH="$PWD/lib" ./zangband -mgcu
```

## Native Cocoa Backend

Native backend QA lives in `docs/native-backend-qa.md`. Mac app product ideas
live in `docs/mac-app-ideas.md`.

## macOS Runtime Data

On first launch, the native app copies the bundled `lib` directory to:

```sh
~/Library/Application Support/ZangbandNative/lib
```

The game runs with `ANGBAND_PATH` pointed at that writable copy, so save files,
scores, generated raw data, and player state do not need to be written inside
the app bundle.

The wrapper app uses `~/Library/Application Support/Zangband/lib`, so the two
targets can be tested side by side.

## Why This Exists

Old open-source games should not stay trapped on dead platforms.

Zangband has a great core: dense systems, strange tone, huge item/monster data,
and a very specific flavor of roguelike chaos. The original source is still
here. Modern Macs are fast. The missing piece is care.

This repo is that care.

## Roadmap

### Near Term

- Add app icon and notarized Developer ID release artifacts
- Broaden gameplay QA before making the native target the only shipped app
- Add regression tests for macOS portability fixes

### Native Renderer

- Keep hardening direct Cocoa `z-term` input and restart behavior
- Move from AppKit text drawing to a faster renderer if profiling says it is
  needed
- Expand optional tile mode while keeping ASCII first-class
- Add richer native panels without changing deterministic gameplay

### LLM Experiments

The fun direction: make the dungeon remember you.

Ideas under consideration:

- Dungeon Chronicle: short generated run journal entries
- Death Eulogies: tomb inscriptions and post-run obituaries
- Living Monster Speech: contextual barks and taunts
- Rumor Engine: personalized rumors and scroll text
- Artifact Lore: optional generated history for special items
- Oracle Mode: visible-info-only explanations for new players

The rule: LLMs can add atmosphere and reflection, but deterministic gameplay
stays deterministic.

## Notes for Contributors

This is legacy C. Expect old assumptions.

The original code predates modern 64-bit macOS conventions, so portability fixes
should be small, explicit, and tested against actual gameplay paths. The macOS
app should stay a thin layer until the direct `z-term` backend is ready.

Generated build files and local app bundles are ignored. Source changes should
stay in:

- `src/` for game/core fixes
- `macos/` for the native app target
- `lib/` only when intentionally changing game data

## License and Attribution

Zangband descends from Moria and Angband. The original source files retain their
historical copyright and distribution notices.

This fork keeps those notices intact and credits the upstream Zangband source at
https://github.com/jjnoo/Zangband.
