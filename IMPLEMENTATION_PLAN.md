# gtm Implementation Plan

## Legend
- `[code]` = confirmed present in source code
- `[missing]` = confirmed absent after code search
- `[spec-outdated]` = spec describes feature as missing/broken but source has it
- `[new]` = not previously documented in plan

---

## P0 — Must Fix (blocking audio, security, crashes)

### [FIXED] Security: SQL injection in `getArtistId` INSERT (`library.nim:173`)
- **Status**: [fixed] parameterized prepared statement replaces string concat
- Changed fallback INSERT to use prepared statement with bind parameter

### [FIXED] Security: Command injection via ffprobe (`audio.nim:219`)
- **Status**: [fixed] uses `execProcess` with separate args array instead of shell command
- Also fixed `execCmd` shell injection in `ProcessBackend.pause`/`togglePause` (use `posix.kill` directly)
- Also fixed `execCmd` shell injection in `daemonIsRunning` (use `posix.kill(pid, 0)`)

### [FIXED] Stability: Daemon crashes on exception (`daemon.nim:269-276`)
- **Status**: [fixed] `executeCommand` wrapped in `try/except` with error logging
- Returns JSON error response instead of crashing

### [FIXED] Visualizer: `destroyShm` uses `shm_open` instead of `shm_unlink` (`visualizer.nim:88`)
- **Status**: [fixed] replaced `shm_open` with `shm_unlink`

### Bug: No audio playback — PCM data path possibly disconnected
- **Status**: [new] undiagnosed
- `PcmRingBuffer.writePcm` is defined in `visualizer.nim:59-69` but **never called anywhere**
- Daemon loop calls `viz.readPcm()` but nothing writes PCM data to shared memory
- MiniAudio C prototypes (`gtm_audio_*` functions) don't include any shared memory writing
- The visualizer reads from an empty ring buffer → spectrum is always flat
- **Investigation needed**: Check `vendor/miniaudio/miniaudio_impl.c` to see if PCM is written to SHM from C side. If not, the visualizer gets no data and audio init path may be incomplete.
- **Fix**: Either add PCM writing in C implementation or connect from Nim side

### P0 Dependency Resolution (`DEPENDENCIES.md`)
- **Status**: [code] partially fixed, hardcoded fallback remains
- `config.nims:12-31` already has flexible dependency resolution: env var → relative path → nimble pkgs → hardcoded fallback
- Hardcoded `/home/prjctimg/sources/{nimwave,illwave,ansiutils}/src` still exists at `config.nims:24` as last-resort fallback
- This is less urgent than spec claims (P0) since it only triggers if other methods fail
- **Fix**: Remove hardcoded fallback line or make it emit a clear error message

---

## P1 — High Priority

### [FIXED] Daemon: `getVolume()` not overridden (`daemon_client.nim`)
- **Status**: [fixed] added `method getVolume*(cli: DaemonClient): int` that sends `get_volume` command

### Daemon: Missing commands for shuffle/repeat/sleep
- **Status**: [code] confirmed absent
- Shuffle, repeat, sleep state lives only in TUI client (`state.nim:121-126`, `gtm.nim:157-166`)
- No daemon commands (`set_shuffle`, `set_repeat`, `set_sleep_timer`) exist
- DaemonCmdKind enum in `daemon.nim:6-12` has no entries for these
- Means remote control via socat cannot toggle shuffle/repeat/sleep
- **Fix**: Add daemon commands, DaemonCmdKind entries, executeCommand handlers, and DaemonClient proxy methods

### Daemon: No `set_shuffle`/`set_repeat`/`set_sleep_timer` in `parseDaemonCommand`
- Same as above — TUI-only features need daemon integration for remote control

### [FIXED] Code Quality: `Q` key bypasses `cleanupAndQuit` (`gtm.nim:775-781`)
- **Status**: [fixed] replaced inline cleanup with `cleanupAndQuit(state, false)`

### [FIXED] Code Quality: `ProcessBackend.backendType` misassigned (`audio.nim:110-114`)
- **Status**: [fixed] added `abtProcess` to `AudioBackendType` enum and use correct type

### [FIXED] Code Quality: `"scan"` command is dead code (`daemon.nim`)
- **Status**: [fixed] added `"scan"` case to `parseDaemonCommand`

### [FIXED] Robustness: 11+ `except: discard` error swallowing locations
- **Status**: [fixed] all `except: discard` replaced with `except: stderr.writeLine(...)` with context info

### UI: Tab bar active tab background and bracket display
- **Status**: [code] partially addressed — TODO confirm vs PROMPT.md
- Active tab already gets `fillBg` with `theme.mauve` at `ui.nim:67`
- Brackets `[]` already present around tab number for both active and inactive tabs (`ui.nim:68`, `ui.nim:70`)
- Version label on right already at `ui.nim:75` with fixed position `w - 12`
- PROMPT.md asks for active tab background change and `[]` wrapping — already done
- **Spec update needed**: `UI_COMPONENTS.md` describes this as issue but code is correct

### UI: Volume cue mute icon
- **Status**: [code] already implemented
- `VolumeCueOverlay` at `ui.nim:508-519` shows when `volumeCueTimer > 0`
- `showVolumeCue()` called from `adjustVolume` and `toggleMute`
- Displays `VOL ████░░░░░░` bar with green color
- However: no mute-specific icon in the cue (always `VOL` label regardless of mute state)
- **Minor enhancement**: Show `MUT` or mute icon when volume is 0

### UI: Song details — hide fields with "Unknown" values
- **Status**: [code] already implemented
- `wlCond` template at `ui.nim:99-103` skips value if it starts with "Unknown"
- Applied to Artist and Album at `ui.nim:105-106`
- Same behavior requested in PROMPT.md — already done

### UI: Time display shows elapsed / remaining
- **Status**: [code] already implemented
- `ui.nim:120`: `formatTime(state.timePos) & " / -" & formatTime(max(0.0, state.duration - state.timePos))`
- Shows `1:23 / -2:22` format as requested
- Also in ProgressBarComp at `ui.nim:296-298`

### UI: State-dependent icons
- **Status**: [code] already implemented
- `ProgressBarComp` at `ui.nim:318-322`: Uses `currentIcons().play/pause/stop` based on `state.status`
- Volume icons at `ui.nim:110-114`: Selects based on volume level (muted/low/medium/high)
- LibraryView at `ui.nim:180-184`: Uses icon pack for artist/album/playlist/track
- Shuffle/repeat icons at `ui.nim:330-335`: Uses icon pack with conditional colors
- Spec says "not actually used" but code shows they ARE used — spec needs updating

### Playlist: Missing reorder, export/import (daemon level)
- **Status**: [code] confirmed missing
- `reorderPlaylist` (reorder tracks within a playlist) — no daemon command or library function
- `exportPlaylist` / `importPlaylist` — `parseM3u` exists at `library.nim:443` but no daemon-level import/export
- TUI side: `saveCurrentQueue` exists at `gtm.nim:246` but saves entire library, not individual playlist
- **Fix**: Add library functions, daemon commands, and TUI UI for:
  - Reorder tracks (swap position values)
  - Export playlist to M3U
  - Import M3U as new playlist (daemon route)

### Playlist: Daemon commands for playlist rename/delete at TUI level
- **Status**: [code] already implemented
- `renamePlaylist`, `deletePlaylist`, `addTrackToPlaylist`, `removeTrackFromPlaylist` all have daemon commands and client methods
- `listPlaylists`, `getPlaylistTracks` also implemented
- Spec says "no daemon commands for playlist operations" but they exist (7 commands)

---

## P2 — Medium Priority

### Dead Code Cleanup (many items)
- **Status**: [code] all confirmed unused
- Full list from source scan:
  | Function/Variable | File | Notes |
  |---|---|---|
  | `execSql` / `execSqlI` | `library.nim:86-100` | Never called |
  | `fuzzySearchCommands` | `commands.nim:22-33` | Exported, never called (gtm.nim uses inline filter) |
  | `filterCommandsByContext` + `CommandCategory` | `commands.nim:4-20` | Never used |
  | `findCommandIdx` | `commands.nim:45-48` | Never called |
  | `removeFromPlaylist` | `daemon_client.nim:159-162` | Never called |
  | `playlistContentsTracks` | `state.nim:128` | Field exists, never populated |
  | `needsRedraw` | `state.nim:83` | Never checked |
  | `daemonPid` | `state.nim:112` | Never read |
  | `currentPlayingPath` / `currentPlayingId` | `state.nim:116-117` | Never written or read |
  | `ConfigData.lastTab` | `state.nim:47` | Saved/loaded but never used to restore tab |
  | `loadArtists` / `loadAlbums` | `library.nim:256-277` | Never called |
  | `updatePlayCount` | `library.nim:360-365` | Never called |
  | `CommandEntry.icon` | `state.nim:67` | Stored but never rendered in palette |
  | `AudioEvent.metadata` | `audio.nim:16` | Never populated |
  | `AudioBackendType.abtNone` | `audio.nim:4` | Never used |
  | `getVolume` | `audio.nim:40` | Base method returns 80; never overridden by DaemonClient (P1) |

### `ProcessBackend.seek` is `discard` (`audio.nim:87`)
- **Status**: [code] confirmed
- No seek support for mpv/ffplay process backend
- Could be implemented via mpv IPC (`--input-ipc-server`) or remain as documented limitation

### Cover Art (new feature)
- **Status**: [missing] no cover art support anywhere
- `TrackMetadata` in `audio.nim:18-22` has no cover art field
- No image loading or rendering capability
- Need new module `src/coverart.nim`
- **Spec**: `COVER_ART.md` exists with detailed plan
- **Priority**: P3 in spec but PROMPT.md mentions it at item 13

### [FIXED] Config: `lastTab` saved but never restored
- **Status**: [fixed] `tabNowPlaying` assignment now only happens when no valid tab was loaded from config

### [FIXED] Config: `idle_timeout` in schema but never read
- **Status**: [fixed] `loadConfig` reads `idle_timeout` into `ConfigData.idleTimeout`
- Daemon still hardcodes 300; future work: add daemon command to set idle timeout dynamically

### TUI: Theme picker — Enter doesn't close after selection
- **Status**: [code] confirmed
- On Enter, calls `state.applyTheme(seed)` then closes (`gtm.nim:448-453`)
- This works fine. No issue here.

### TUI: Navigation — `gg`/`ShiftG` on all tabs
- **Status**: [code] confirmed working
- `gg` (double `g` with timer) at `gtm.nim:727-734`
- `ShiftG` at `gtm.nim:735-738`
- Both work regardless of tab

### TUI: Command palette — `/` triggers search within palette
- **Status**: [code] confirmed
- `paletteSearchMode` at `gtm.nim:564-565`
- `/` in palette mode sets `paletteSearchMode = true` and clears query
- Subsequent typing filters commands
- Hitting `/` again (or Escape toggles) not handled — query filter is always on when typing

### TUI: Command palette display limit already 20
- **Status**: [code] spec-outdated
- `ui.nim:426`: `displayResults = min(20, ...)`
- Spec says "increase to 15-20" but it's already 20

---

## P3 — Low Priority / Enhancement

### Crossfade / Gapless Playback
- **Status**: [missing] not implemented
- Requires mixing buffer in daemon, playback queue management, configurable duration
- No crossfade state in `ConfigData`, no daemon logic
- **Spec**: `AUDIO_PLAYBACK.md` section exists

### ReplayGain / Volume Normalization
- **Status**: [missing] not implemented
- Parse ReplayGain tags, apply gain adjustment
- **Spec**: `AUDIO_PLAYBACK.md` section exists

### Daemon IPC — Persistent Event Streaming
- **Status**: [missing] not implemented
- Currently request-response poll every 16ms
- Persistent subscription would reduce latency
- **Spec**: `DAEMON_IPC.md`

### Playback Queue Management in Daemon
- **Status**: [missing] TUI-only
- `nextTrack`/`prevTrack` operate on `displayItems` in TUI client
- Daemon has no concept of queue — makes remote control limited
- **Fix**: Add queue management to daemon (playlist ID, shuffle order, repeat state)

---

## Specs Needing Updates (spec-implementation drift)

### `SHUFFLE_REPEAT_SLEEP.md` — CLAIMS FEATURES ARE "ENTIRELY MISSING"
- All three are implemented in source:
  - `state.nim:121-126`: state fields
  - `gtm.nim:85-89`: `generateShuffleOrder`
  - `gtm.nim:111-145`: `nextTrack`/`prevTrack` with shuffle/repeat support
  - `gtm.nim:157-166`: `toggleShuffle` / `cycleRepeat`
  - `gtm.nim:867-876`: sleep timer countdown
  - `ui.nim:330-335`: UI indicators
  - Keybindings `Shift+S` and `Shift+R` in `gtm.nim:748-751`
  - Command palette entries in `commands.nim:127-132`
- **What's actually missing**: Daemon-side commands for these features (shuffle/repeat/sleep state only in TUI)

### `PLAYLIST_MGMT.md` — CLAIMS FEATURES MISSING THAT ARE IMPLEMENTED
- Create, delete, rename playlists — all via daemon commands
- Add/remove tracks — via daemon commands
- View playlist contents (Enter on playlist, Escape to go back) — working
- Playlist input overlay for naming/confirmation — working
- **What's actually missing**: Reorder tracks, M3U export/import at daemon level

### `UI_COMPONENTS.md` — DESCRIBES VISUALIZER OVERLAP BUG AS CURRENT
- Fix already in source at `ui.nim:586-589` (60-119 width: split into nowplaying + 20-col visualizer sidebar)
- Tab bar issues described as "current behavior" but code shows correct implementation

### `DAEMON_IPC.md` — MISSING COMMANDS DOCUMENTATION
- 7 playlist commands not documented: `create_playlist`, `delete_playlist`, `rename_playlist`, `add_to_playlist`, `remove_from_playlist`, `list_playlists`, `get_playlist_tracks`
- `audio_working` field in status response not documented
- `scan` command documented but not parseable (dead code)
- `dckNext`/`dckPrev` in handler stop player but don't advance queue — this is expected (client handles queue)

### `ICONS_VISUALS.md` — CLAIMS ICONS NOT USED IN UI
- `ProgressBarComp` at `ui.nim:318-322` uses `currentIcons()` for play/pause/stop
- Volume icon selection at `ui.nim:110-114`
- LibraryView at `ui.nim:180-184` uses icon pack
- Shuffle/repeat icons at `ui.nim:330-335`

### `VOLUME_CUE.md` — CLAIMS NO VOLUME CUE EXISTS
- `VolumeCueOverlay` at `ui.nim:508-519` fully implemented
- `volumeCueTimer` and `volumeCueVolume` state fields
- `showVolumeCue()` called from both `adjustVolume` and `toggleMute`
- Timer decremented each frame at `gtm.nim:867-868`

### `COMMAND_PALETTE.md` — CLAIMS ISSUE WITH `/` TRIGGERING FILTER
- `/` in `imCommandPalette` mode sets `paletteSearchMode = true` (`gtm.nim:564-565`)
- This is already the correct behavior — `/` searches within palette
- Display limit already 20 (spec says to increase to 15-20)

---

## New Findings (not in previous plan)

### No test files exist anywhere
- Zero tests in entire project — no `tests/` directory, no test files
- **Action**: Add test infrastructure when implementing fixes

### `PcmRingBuffer.writePcm` never called
- `visualizer.nim:59-69` defines `writePcm` but no code calls it
- Daemon calls `viz.readPcm()` but nothing writes to the SHM ring buffer
- MiniAudio C prototypes don't include SHM writing
- This may explain flat visualizer and potential audio init issues

### `config.nims` already has flexible dep resolution
- Previous plan treated this as P0 blocker, but code already handles:
  1. Env var (`NIMWAVE_PATH` etc.)
  2. Relative path (`../../sources/*`)
  3. Nimble packages (`~/.nimble/pkgs/*`)
  4. Hardcoded `/home/prjctimg/sources/*` (last resort)
- **Action**: Remove the hardcoded fallback at `config.nims:24` and add error message directing user to set env var

### `idle_timeout` config exists in schema but unused
- Schema has it, daemon hardcodes 300
- loadConfig doesn't read it
- **Fix**: Wire config value to daemon

### `lastTab` saved/loaded but overwritten
- `loadConfig` sets `state.tab`, then `runTui` immediately overwrites to `tabNowPlaying`
- **Fix**: Remove the overwrite or make it conditional

### Theme `tmLigh` typo (`theme.nim:5`)
- Cosmetic only (used consistently throughout as `tmLigh`)
- But should be `tmLight` for correctness

### Help overlay doesn't list shuffle, repeat, sleep keybindings
- `ui.nim:488-498` hardcodes keybinding help list
- Missing: `Shift+S` shuffle, `Shift+R` repeat, `: sleep_timer`, `m` mute

### ProcessBackend has no metadata extraction
- `audio.nim:217-236` — `getMetadata` is only implemented for `MiniAudioBackend`
- `ProcessBackend` uses base method which returns empty data
- When daemon falls back to process backend, metadata is always empty

---

## Infrastructure

- **No test files** — need test infrastructure
- `vendor/miniaudio/miniaudio_impl.c` — needs review for: PCM SHM writing, audio init success on various systems
- `vendor/sqlite/sqlite3.c` — vendored; `library.nim` still has one SQL injection issue (getArtistId INSERT)

## Cleaned/Resolved Items (removed from active plan)

These items from previous plan are already implemented in source and no longer need action:
- Visualizer overlap fix (spec-outdated: code already has fix)
- Shuffle/repeat/sleep implementation (code has full TUI-side implementation)
- Playlist CRUD + daemon commands (all 7 commands exist)
- Volume visual cue (full implementation exists)
- Command palette features (all requested commands present)
- State-dependent icons (ProgressBarComp, LibraryView use currentIcons())
- Tab bar `[]` wrapping (both active/inactive have brackets)
- Song details unknown field filtering (wlCond template works)
- Time elapsed/remaining display (correct format in both places)
- `/` search within command palette (paletteSearchMode works)
