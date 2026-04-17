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

## Runtime Data

On first launch, the bundled `lib` directory is copied to:

```sh
~/Library/Application Support/Zangband/lib
```

The game runs with `ANGBAND_PATH` pointed at that writable copy, so save files,
scores, and generated data do not need to be written inside the app bundle.

## App Controls

The app provides native menu items for common Mac workflows:

- File > New Game
- File > Restart
- View > Bigger Text
- View > Smaller Text
- View > Actual Size
- View > Enter Full Screen
