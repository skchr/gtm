# gtm Implementation Plan

## Legend
- `[spec]` = spec exists, implementation may be partial/missing
- `[no-spec]` = referenced in specs/README.md but file doesn't exist — needs authoring
- `[found]` = issue confirmed via code reading
- `[inferred]` = issue inferred from pattern analysis

---

## P0 — Must Fix (blocking)

- **[found] Dependency Resolution — Hardcoded paths in `config.nims`**
  `config.nims:11-13` references `/home/prjctimg/sources/nimwave/src`, `/home/prjctimg/sources/illwave/src`, `/home/prjctimg/sources/ansiutils/src` — absolute paths that don't exist on other machines. Must use Nimble package resolution or relative paths. Add `DEPENDENCIES.md` spec.

- **[found] No Audio Output Bug**
  `audio.nim:146-153`: `MiniAudioBackend.newMiniAudioBackend()` calls `gtm_audio_init()` which may return nil. When ctx is nil, `loadFile` at `audio.nim:77` returns early silently. Need to debug `vendor/miniaudio/miniaudio_impl.c` — check device init, ALSA/PulseAudio availability, linker flags (`-lm -ldl -lpthread`). Add debug logging to trace full path: TUI → DaemonClient → Unix socket → daemon → MiniAudioBackend.

- **[found] Missing metadata extraction**
  `audio.nim:85`: `b.metadata.title` is set to just filename (`path.splitPath().tail`). Real metadata (artist, album, etc.) is never extracted from audio files. Only uses filename as title.

## P1 — High Priority

- **[found] Playlist Management — Incomplete (spec: PLAYLIST_MGMT.md)**
  - Keybindings for create/delete/rename playlist from UI: missing entirely (`gtm.nim`).
  - Enter on playlist (`ui.nim:173-194`) does nothing useful — playlist items are `likPlaylist` but `playSelected()` looks for `likTrack`.
  - No playlist contents sub-view.
  - No rename/reorder/export/import (except `parseM3u` exists).
  - Daemon has zero playlist commands — all ops are in-memory only in state, not routed through daemon DB.
  - `addSelectionToPlaylist` (`gtm.nim:193-209`) uses in-memory playlists only, not library DB.

- ~~**[found] Visualizer overlaps NowPlaying at 60-119 cols (spec: UI_COMPONENTS.md)**~~ ✅ fixed in code (ui.nim:510 uses `splitW = w - 20`)
  `ui.nim:480-481`: Both NowPlayingView and VisualizerView rendered at same position `(0, y, w, mainH)`. Visualizer should be a narrow right sidebar (e.g. 20 cols).

- ~~**[found] Tab bar display issues (spec: UI_COMPONENTS.md)**~~ ✅ fixed
  `ui.nim:65-73`: Inactive tab `[N]` and Name now rendered at consistent positions.

- ~~**[found] "Unknown" field not hidden (spec: UI_COMPONENTS.md)**~~ ✅ fixed in code (ui.nim:99-103 `wlCond` template checks for "Unknown")
  `ui.nim:98-99`: `displayArtist`/`displayAlbum` return "Unknown Artist"/"Unknown Album" strings but `wl` template doesn't check for "Unknown" prefix. Should hide entire row.

- ~~**[found] Time display shows total not remaining (spec: UI_COMPONENTS.md)**~~ ✅ fixed (ui.nim:112 shows `elapsed / -remaining`)
  `ui.nim:245-247`: Shows `elapsed / total`. Should show `elapsed / remaining` where remaining = duration - timePos (e.g. `1:23 / -2:22`).

- ~~**[no-spec] Volume Visual Cue missing (PROMPT.md #4)**~~ ✅ implemented (VolumeCueOverlay, volumeCueTimer in gtm.nim:110-128)
  No visual indicator when volume changes via `Shift+J`/`Shift+K`. Need a transient overlay or progress indicator. Author `VOLUME_CUE.md` spec.

- ~~**[found] State-dependent icons (PROMPT.md #11)**~~ ✅ implemented
  - `ui.nim`: ProgressBarComp uses `currentIcons().play/pause/stop` for status
  - `ui.nim`: NowPlayingView uses `currentIcons().volumeHigh/Mid/Low/Muted` for volume
  - `ui.nim`: LibraryView uses `currentIcons().music/artist/album/playlist` for item icons
  - `ui.nim`: PlaylistsView uses `currentIcons().playlist` for playlist icons
  - `icons.nim`: `detectNerdFonts()` now also checks `TERM_PROGRAM` and `TERM` env vars

## P2 — Medium Priority

- **[found] Command Palette improvements (PROMPT.md #10)**
  - Navigation (j/k) in palette works? — `gtm.nim:340-344` implements it, but palette display in `ui.nim:348` iterates `paletteResults` with index `i` but compares against `paletteSelect` which is a separate index. Need to verify filtering works correctly.
  - Should trigger search with `/` in command palette mode? Or keep `:` to open and `/` to filter within palette.
  - Commands need review — add useful ones (shuffle, repeat, sleep, crossfade toggle).
  - Need to verify `fuzzySearchCommands` in `commands.nim` is used (it exists but `buildDefaultCommands` doesn't use it, `palette` filtering uses inline fuzzy match in `gtm.nim:353-356`).

- **[no-spec] Shuffle / Repeat / Sleep (PROMPT.md #12)**
  No implementation exists. Need: shuffle mode (random track order), repeat modes (none/one/all), sleep timer (stop playback after N minutes). Author `SHUFFLE_REPEAT_SLEEP.md` spec.

- ~~**[found] Settings tab — volume Enter does nothing**~~ ✅ fixed
  `gtm.nim:472`: Now calls `state.toggleMute()` + `state.rebuildDisplayItems()`. Also fixed `toggleMute` to preserve previous volume for unmute restore.

- ~~**[found] Config save/load is incomplete**~~ ✅ fixed
  `gtm.nim:6-34`: `saveConfig` now saves `viz_visible` and `visualizer.bar_count`. `loadConfig` reads them back.

- **[found] `performFilter` doesn't call `rebuildDisplayItems` first**
  `gtm.nim:77-87`: Filters `state.displayItems` but these may be stale if `rebuildDisplayItems` wasn't called before filtering.

## P3 — Low Priority / Enhancement

- **[spec] Cover Art (COVER_ART.md)**
  No cover art support exists. `TrackMetadata` in `audio.nim:18-22` has no cover art field. No image loading/rendering. New module `src/coverart.nim` needed.

- **[spec] Crossfade / Gapless Playback (AUDIO_PLAYBACK.md)**
  P3 enhancement. Requires mixing buffer in daemon, playback queue management, configurable crossfade duration.

- **[spec] Daemon IPC — persistent event streaming (DAEMON_IPC.md)**
  Currently request-response poll (16ms interval). Persistent event subscription would reduce latency/overhead.

- **[found] sqlite3 SQL injection in library.nim**
  `library.nim:173`, `library.nim:297`, `library.nim:323`: Uses string concatenation for SQL queries with user-provided values instead of parameterized bindings. Replace with prepared statements.

- **[found] Quit functions call `quit(0)` directly**
  `gtm.nim:155-170`: `quitBackground` and `quitDaemon` call `quit(0)` which doesn't unwind the main loop properly. Should set a flag and let main loop exit cleanly.

- **[found] Nerd Font detection is only env-var based**
  `icons.nim:51-54`: Only checks `NERD_FONTS` env var. Could try rendering a test character and measuring width.

- **[found] Playback queue management is in TUI client only**
  `nextTrack`/`prevTrack` in `gtm.nim:96-108` operate on `displayItems` in the TUI, not on a daemon-managed queue. Makes remote control via socat limited.

- **[no-spec] Command Palette spec** — exists in specs README index but file missing. Should document (trigger with `:`, navigation, fuzzy search, available commands).

## Missing Specs (now authored)
- ~~`specs/DEPENDENCIES.md` (P0)~~ ✅ authored
- ~~`specs/VOLUME_CUE.md` (P1)~~ ✅ authored
- ~~`specs/ICONS_VISUALS.md` (P1)~~ ✅ authored
- ~~`specs/COMMAND_PALETTE.md` (P2)~~ ✅ authored
- ~~`specs/SHUFFLE_REPEAT_SLEEP.md` (P3)~~ ✅ authored

## Infrastructure
- No test files exist anywhere — need test infrastructure
- `vendor/miniaudio/miniaudio_impl.c` needs review for audio init issues
- `vendor/sqlite/sqlite3.c` is vendored but `library.nim` has SQL injection issues
