# Mac App Ideas

These are product directions for making Zangband feel like a real Mac app while
keeping deterministic gameplay intact.

## Native App Polish

- Shipped in the native backend: save manager showing active character, last
  played time, depth, level, and death status.
- Shipped in the native backend: morgue gallery for dead characters using
  `scores.raw`, with copyable run summaries.
- Shipped in the native backend: command palette that searches commands by name
  and sends the original keybinding.
- Shipped in the native backend: side inspector with stacked inventory and
  equipment boxes plus bottom tabs for newest-first messages and monster recall.
- Add iCloud/Dropbox-friendly save export and import without hiding the original
  save files.
- Add native preferences for font, palette, key mode, window scale, and terrain
  contrast.
- Shipped in the native backend: optional tile rendering as a view mode, while
  keeping ASCII as the primary mode.
- Add crash-safe autosave snapshots and a "restore previous turn" debug-only
  recovery tool for development builds.

## Performance Work

- Move native drawing from full string rows to dirty-cell/dirty-run invalidation.
- Add a Metal or Core Text renderer once the direct `z-term` backend is stable.
- Keep the game simulation on one thread and the renderer on the main thread,
  with a compact immutable frame snapshot between them.
- Add frame timing logs and a debug HUD for redraw count, dirty cells, input
  latency, and game tick time.
- Add a scripted benchmark that drives a replay through birth, town, wilderness,
  combat, inventory, and save/load.

## LLM Magic

- Run Chronicle: generate a short private journal after major milestones,
  deaths, escapes, mutations, and artifacts.
- Death Eulogies: produce a flavorful tomb inscription from the actual final
  state and message log.
- Rumor Engine: rewrite non-critical rumor text using only current character,
  town, and discovered lore.
- Monster Barks: generate optional one-line taunts for uniques, constrained to
  visible game facts.
- Artifact Lore: generate inspectable backstory for artifacts after discovery,
  never before.
- Oracle Help: answer "what just happened?" from the visible screen, message
  log, and known rules, without seeing hidden dungeon state.

## Rules For LLM Features

- Never let generated text affect combat, loot, map generation, RNG, saves, or
  scoring.
- Make every LLM feature optional and clearly cosmetic.
- Cache generated text into run logs so the same event does not change every
  time the UI redraws.
- Keep prompts grounded in visible information only unless the feature is
  explicitly post-run analysis.
