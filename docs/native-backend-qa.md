# Native Cocoa Backend QA

The native backend is intentionally not the default app target yet. It links the
legacy Zangband game core into the AppKit process, so these checks are the gate
before replacing the stable pty/curses wrapper.

## Automated Checks

Run from the repository root:

```sh
scripts/smoke-native-backend.sh
```

Or run the individual checks:

```sh
make -C macos native
plutil -lint macos/build/ZangbandNative.app/Contents/Info.plist
test -x macos/build/ZangbandNative.app/Contents/MacOS/ZangbandNative
test -d macos/build/ZangbandNative.app/Contents/Resources/lib
macos/build/ZangbandNative.app/Contents/MacOS/ZangbandNative
```

The app should open a Cocoa window, draw the Zangband startup screen, and remain
running without stderr output.

## Manual Gameplay Checklist

- Startup: app opens to the expected first game screen.
- Character creation: name entry, sex/race/class selection, autoroller weights,
  Enter, Escape, Backspace, and Ctrl-X all work.
- Movement: arrow keys, keypad 1-9, Home/End/Page Up/Page Down diagonals, and
  wait/rest commands behave like the terminal build.
- Text input: normal letters, shifted punctuation, Return, Tab, Delete, and
  Paste work in prompts.
- Save: File > Save writes the current game without quitting.
- Save and Quit: File > Save and Quit exits through Zangband's Ctrl-X path.
- Restart: File > Restart relaunches the native app cleanly.
- New Game: File > New Game relaunches with `-n`.
- Resize: window resizing recenters the 80x24 grid without corrupting the
  display.
- Gameplay loop: enter town/wilderness, open inventory/equipment, enter a
  store, leave a store, descend/ascend stairs, fight one monster, and save.
- Recovery: relaunch after Save and Quit and confirm the save loads.

## Default-App Gate

Before making `ZangbandNative.app` the default release target:

- Complete the manual checklist on a fresh support directory.
- Complete it again using an existing save.
- Verify no generated files are written inside the app bundle.
- Verify menu actions work while the game is waiting for input and while it is
  redrawing.
- Add a screenshot comparison against the stable wrapper for title, birth,
  town, inventory, and store screens.
