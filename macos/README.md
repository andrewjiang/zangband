# Zangband macOS App

This directory contains the macOS app targets for Zangband.

The primary target is now `ZangbandNative.app`. It links the Zangband game core
directly into an AppKit process and implements the game's `z-term` hooks in
`src/main-cocoa.m`.

The wrapper target, `Zangband.app`, remains available as a compatibility
fallback. It launches the existing `zangband -mgcu` game process inside a
pseudo-terminal, parses the curses/ANSI screen output, renders cells with
AppKit, and forwards keyboard input back to the game.

Both renderers use stable fixed-cell layout. Window resizing recenters or
resizes the native viewport without letting glyphs drift out of alignment.

The Mac app also applies a Mac-specific terrain palette. Zangband's default
feature data draws open floor as a white `.` and many wilderness features as
bright `%` glyphs. The app keeps those symbols, but tints map glyphs darker
than UI text so floors, grass, dirt, trees, rock, water, lava, and swamp read as
environment instead of foreground chrome.

## Build

From the repository root:

```sh
make -C macos native
```

The app is created at:

```sh
macos/build/ZangbandNative.app
```

To launch it:

```sh
open macos/build/ZangbandNative.app
```

To build the wrapper target:

```sh
make -C macos
open macos/build/Zangband.app
```

## Release Artifact

From the repository root:

```sh
scripts/build-native-macos-release.sh
```

The script builds `macos/build/ZangbandNative.app`, signs the app bundle,
verifies the signature, then writes a zip and SHA-256 checksum under `dist/`.

If no `CODESIGN_IDENTITY` is set, it uses ad-hoc signing (`codesign -s -`).
Set `CODESIGN_IDENTITY` to a Developer ID Application certificate for a
distributable signed build that can later be notarized.

The wrapper release script is still available:

```sh
scripts/build-macos-release.sh
```

## Native Backend Features

The native target includes Mac-facing gameplay surfaces on top of the direct
`z-term` renderer:

- File > Save Manager shows the active character, level, depth, status, save
  files, and last played timestamps.
- File > Morgue Gallery reads `scores.raw` and builds shareable run summaries.
- Commands > Command Palette searches common commands and sends the original
  Zangband keybinding.
- View > Side Inspector stacks live inventory and equipment above bottom tabs
  for newest-first messages and monster recall.
- View > Tile Mode adds an optional terrain/object color layer while preserving
  ASCII glyphs as the primary display.

## Runtime Data

On first launch, the bundled `lib` directory is copied to:

```sh
~/Library/Application Support/ZangbandNative/lib
```

The game runs with `ANGBAND_PATH` pointed at that writable copy, so save files,
scores, and generated data do not need to be written inside the app bundle.
The wrapper target uses `~/Library/Application Support/Zangband/lib` so it can
be tested side by side with the native app.

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
