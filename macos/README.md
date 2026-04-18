# Zangband macOS App

This directory contains the first native macOS app target for Zangband.

The current app is a Cocoa shell with a native fixed-grid renderer. It launches
the existing `zangband -mgcu` game process inside a pseudo-terminal, parses the
curses/ANSI screen output, renders cells with AppKit, and forwards keyboard
input back to the game.

This gives us a double-clickable `.app` while keeping the game core unchanged.
It is also a practical stepping stone toward the higher-performance version:
replace the pseudo-terminal bridge with a direct Cocoa/Metal `z-term` backend.

The renderer intentionally keeps the game at an 80x24 logical terminal. Window
resizing recenters the native viewport instead of resizing the pseudo-terminal,
because the legacy curses UI can visually corrupt itself when its row/column
count changes mid-game.

The renderer also applies a Mac-specific terrain palette. Zangband's default
feature data draws open floor as a white `.` and many wilderness features as
bright `%` glyphs. The app keeps those symbols, but tints map glyphs darker
than UI text so floors, grass, dirt, trees, rock, water, lava, and swamp read as
environment instead of foreground chrome.

## Build

From the repository root:

```sh
make -C macos
```

The app is created at:

```sh
macos/build/Zangband.app
```

To launch it:

```sh
open macos/build/Zangband.app
```

## Release Artifact

From the repository root:

```sh
scripts/build-macos-release.sh
```

The script builds `macos/build/Zangband.app`, signs the embedded game binary and
the app bundle, verifies the signature, then writes a zip and SHA-256 checksum
under `dist/`.

If no `CODESIGN_IDENTITY` is set, it uses ad-hoc signing (`codesign -s -`).
Set `CODESIGN_IDENTITY` to a Developer ID Application certificate for a
distributable signed build that can later be notarized.

## Experimental Native Backend

The native backend target links the game core directly into a Cocoa app and
implements the Zangband `z-term` hooks in `src/main-cocoa.m`:

```sh
make -C macos native
open macos/build/ZangbandNative.app
```

This removes the pseudo-terminal/curses layer for that target. The native target
now includes Mac-facing gameplay surfaces on top of the direct `z-term` renderer:

- File > Save Manager shows the active character, level, depth, status, save
  files, and last played timestamps.
- File > Morgue Gallery reads `scores.raw` and builds shareable run summaries.
- Commands > Command Palette searches common commands and sends the original
  Zangband keybinding.
- View > Side Inspector stacks live inventory and equipment above bottom tabs
  for newest-first messages and monster recall.
- View > Tile Mode adds an optional terrain/object color layer while preserving
  ASCII glyphs as the primary display.

The stable release artifact can still use the wrapper app while the native
backend finishes broader gameplay QA.

## Runtime Data

On first launch, the bundled `lib` directory is copied to:

```sh
~/Library/Application Support/Zangband/lib
```

The game runs with `ANGBAND_PATH` pointed at that writable copy, so save files,
scores, and generated data do not need to be written inside the app bundle.
The direct native target uses `~/Library/Application Support/ZangbandNative/lib`
so it can be tested side-by-side with the wrapper app.

## App Controls

The app provides native menu items for common Mac workflows:

- File > New Game
- File > Restart
- File > Save
- File > Save and Quit
- File > Save Manager
- File > Morgue Gallery
- View > Side Inspector
- View > Tile Mode
- View > Enter Full Screen
- Commands > Command Palette
