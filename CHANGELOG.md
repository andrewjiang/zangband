# Changelog

## macos-v0.1.0 - 2026-04-18

### Added

- Direct native Cocoa app target at `macos/build/ZangbandNative.app`.
- Native Cocoa `z-term` backend that links the Zangband core into an AppKit app
  instead of driving gameplay through a pseudo-terminal.
- Native save manager with active character, level, depth, status, save files,
  and last-played timestamps.
- Native morgue gallery for dead characters and shareable run summaries.
- Command palette that searches common Zangband commands and sends the original
  keybindings.
- Side inspector with stacked inventory and equipment panels plus bottom tabs
  for newest-first messages and monster recall.
- Optional tile mode that preserves ASCII glyphs as the primary display.
- Native death-screen restart flow.
- Random default character names for new runs.
- Native release script at `scripts/build-native-macos-release.sh`.

### Changed

- Updated the README with the current native Mac app screenshot and build
  instructions.
- Made the default native window wider and gave more room to the side inspector.
- Hardened resize behavior so glyphs stay aligned when the window changes size.
- Tuned terrain coloring so floors, trees, grass, dirt, rock, water, lava, and
  swamp read as environment instead of bright terminal foreground.
- Fixed native message history ordering and missing leading characters in
  captured message lines.

### Notes

- Release artifacts are ad-hoc signed unless `CODESIGN_IDENTITY` is set to a
  Developer ID Application certificate.
- The wrapper app target, `macos/build/Zangband.app`, remains available as a
  fallback through `scripts/build-macos-release.sh`.
